/*

API wrapper for achrails, see https://github.com/learning-layers/achrails

Note: This is only for wrapping the API. All the real logic relating to the syncing of the video and group data is handled in VideoRepository.swift.

achrails is used as the general backend for Ach so!. Authentication is done with OIDC as is with to the other Layers backends.

The server does not store actual video data, but only references to data uploaded to other services. Groups and video sharing are fully stored in achrails.

All communication to the Social Semantic Server is done through achrails.

*/

import Foundation
import Alamofire

struct VideoRevision {
    let id: NSUUID
    let revision: Int
    
    init(data: JSONObject) throws {
        self.id = try NSUUID(UUIDString: data.castGet("uuid")).unwrap()
        self.revision = try data.castGet("revision")
    }
}

class AchRails {
    
    let http: AuthenticatedHTTP
    let endpoint: NSURL
    let userId: String
    
    init(http: AuthenticatedHTTP, endpoint: NSURL, userId: String) {
        self.http = http
        self.endpoint = endpoint
        self.userId = userId
    }
    
    func getVideos(callback: [VideoRevision]? -> ()) {
        
        http.authorizedRequestJSON(endpoint.request(.GET, "videos.json"), canRetry: true) { response in
            let videosJson = response.result.value?["videos"] as? JSONArray
            let videos = videosJson?.flatMap { try? VideoRevision(data: ($0 as? JSONObject).unwrap()) }
            callback(videos)
        }
        
    }
    
    func getVideo(id: NSUUID, callback: Try<Video> -> ()) {
        
        let request = endpoint.request(.GET, "videos/\(id.lowerUUIDString).json")
        http.authorizedRequestJSON(request, canRetry: true) { response in
            let videoJson = response.result.value as? JSONObject
            do {
                let video = try Video(manifest: videoJson.unwrap(), hasLocalModifications: false, downloadedBy: self.userId)
                callback(.Success(video))
            } catch {
                callback(.Error(error))
            }
        }
    }
    
    func getVideo(id: NSUUID, ifNewerThanRevision revision: Int, isView: Bool, callback: Try<Video?> -> ()) {
        
        let request = endpoint.request(.GET, "videos/\(id.lowerUUIDString).json", parameters: [
            "newer_than_rev": String(revision),
            "is_view": isView ? 1 : 0,  
        ])
        http.authorizedRequestJSON(request, canRetry: true) { response in
            if response.response?.statusCode == 304 {
                callback(.Success(nil))
                return
            }
            
            let videoJson = response.result.value as? JSONObject
            do {
                let video = try Video(manifest: videoJson.unwrap(), hasLocalModifications: false, downloadedBy: self.userId)
                callback(.Success(video))
            } catch {
                callback(.Error(error))
            }
        }
    }
    
    func uploadVideo(video: Video, callback: Try<Video> -> ()) {
        
        let manifest = video.toManifest()
        let request = endpoint.request(.PUT, "videos/\(video.id.lowerUUIDString).json", json: manifest)
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(.Error(error))
            case .Success(let videoJson):
                do {
                    let video = try Video(manifest: (videoJson as? JSONObject).unwrap(), hasLocalModifications: false, downloadedBy: self.userId)
                    callback(.Success(video))
                } catch {
                    callback(.Error(error))
                }
            }
        }
    }
    
    func deleteVideo(video: Video, callback: ErrorType? -> ()) {
        
        let request = http.authorizeRequest(endpoint.request(.DELETE, "videos/\(video.id.lowerUUIDString).json"))
        
        alamofireRequest(request)
            .response { request, response, data, error in
                if error != nil {
                    callback(error)
                    return
                }
                
                guard let response = response else {
                    callback(DebugError("no response found"))
                    return
                }
                
                if response.statusCode >= 400 {
                    callback(DebugError("status code \(response.statusCode)"))
                    return
                }
                
                callback(nil)
        }
    }
    
    func makeVideoPublic(videoId: NSUUID, callback: ErrorType? -> ()) {
        self.setVideoPublicity(videoId, isPublic: true, callback: callback)
    }
    
    func makeVideoPrivate(videoId: NSUUID, callback: ErrorType? -> ()) {
        self.setVideoPublicity(videoId, isPublic: false, callback: callback)
    }
    
    func setVideoPublicity(videoId: NSUUID, isPublic: Bool, callback: ErrorType? ->()) {
        let payload = ["isPublic" : isPublic]
        
        let request = endpoint.request(.PUT, "/videos/\(videoId.lowerUUIDString)/shares/set_publicity", json:payload)
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(error)
            case .Success(_):
                callback(nil)
            }
        }
    }
    
    func unshareVideoToGroup(videoId: NSUUID, groupId: Int, callback: ErrorType? ->()) {
        
        let request = endpoint.request(.DELETE, "/videos/\(videoId.lowerUUIDString)/shares/\(groupId)")
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(error)
            case .Success(_):
                callback(nil)
            }
        }
    }
    
    func shareVideoToGroup(videoId: NSUUID, groupId: Int, callback: ErrorType? ->()) {
        let payload = ["group" : groupId]
        
        let request = endpoint.request(.POST, "/videos/\(videoId.lowerUUIDString)/shares", json: payload)
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(error)
            case .Success(_):
                callback(nil)
            }
        }
    }
    
    func getVideosByQuery(search: String, callback:Try<([Video])> -> ()) {
        let request = endpoint.request(.GET, "videos/search", parameters: [ "q": search ])
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(.Error(error))
            case .Success(let videosJson):
                do {
                    let json = try (videosJson as? JSONObject).unwrap()
                    let videosArray: JSONArray = try json.castGet("videos")
                    
                    let videos = videosArray.flatMap { any -> Video? in
                        guard let videoJson = any as? JSONObject else { return nil }
                        return try? Video(manifest: videoJson, hasLocalModifications: false, downloadedBy: self.userId)
                    }
                    
                    callback(.Success(videos))
                    
                } catch {
                    callback(.Error(error))
                }
            }
        }
        
    }
    
    func getGroups(callback: Try<(groups: [Group], user: User)> -> ()) {
        
        let request = endpoint.request(.GET, "groups/own.json")
        http.authorizedRequestJSON(request, canRetry: true) { response in
            switch response.result {
            case .Failure(let error):
                callback(.Error(error))
            case .Success(let groupsJson):
                do {
                    let json = try (groupsJson as? JSONObject).unwrap()
                    let groupsArray: JSONArray = try json.castGet("groups")
                    let user = try User(manifest: json.castGet("user"))
                    
                    let groups = groupsArray.flatMap { any -> Group? in
                        guard let jsonObject = any as? JSONObject else { return nil }
                        return try? Group(manifest: jsonObject)
                    }
                    
                    callback(.Success((groups: groups, user: user)))
                } catch {
                    callback(.Error(error))
                }
            }
        }
    }
}
