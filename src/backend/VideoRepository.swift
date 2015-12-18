import UIKit

protocol VideoRepositoryListener: class {
    func videoRepositoryUpdateStart()
    func videoRepositoryUpdateProgress(done: Int, total: Int)
    func videoRepositoryUpdated()
}

extension VideoRepositoryListener {
    func videoRepositoryUpdateStart() {}
    func videoRepositoryUpdateProgress(done: Int, total: Int) {}
}

enum CollectionIdentifier {
    case AllVideos
    case Group(String)
    case QrSearch(String)
}

class VideoRepository {
    
    var achRails: AchRails?
    var videoInfos: [VideoInfo] = []
    var videoUploaders: [VideoUploader] = []
    var thumbnailUploaders: [ThumbnailUploader] = []

    var listeners: [VideoRepositoryListener] = []

    var allVideosCollection: Collection?
    
    var groups: [Group] = []
    var groupCollections: [String: Collection] = [:]
    
    var user: User = User.localUser
    
    var progressMax: Int = 0
    var progressDone: Int = 0
    
    func addListener(listener: VideoRepositoryListener) {
        self.listeners.append(listener)
        listener.videoRepositoryUpdated()
    }
    
    func removeListener(listener: VideoRepositoryListener) {
        if let index = self.listeners.indexOf({ $0 === listener}) {
            self.listeners.removeAtIndex(index)
        }
    }
    
    func refresh() {
        let appDelegate = UIApplication.sharedApplication().delegate as! AppDelegate
        
        if let videoInfos = try? appDelegate.getVideoInfos() {
            self.videoInfos = videoInfos
        }
        
        if let groupList = appDelegate.loadGroups() {
            self.groups = groupList.groups
            self.user = groupList.user
        } else {
            self.groups = []
            self.user = User.localUser
        }
        
        let allVideosTitle = NSLocalizedString("all_videos", comment: "Category for all videos")
        let allVideosCollection = Collection(title: allVideosTitle, subtitle: nil, type: .General)
        allVideosCollection.videos = videoInfos
        self.allVideosCollection = allVideosCollection
        
        var groupCollections: [String: Collection] = [:]
        for group in groups {
            let collection = Collection(title: group.name, subtitle: group.groupDescription, type: .Group, extra: group)
            
            collection.videos = group.videos.flatMap { id in
                return self.findVideoInfo(id)
            }.sort({ $0.creationDate > $1.creationDate })
            
            groupCollections[group.id] = collection
        }
        self.groupCollections = groupCollections
        
        for listener in self.listeners {
            listener.videoRepositoryUpdated()
        }
    }
    
    func progressBegin(count: Int) {
        dispatch_async(dispatch_get_main_queue()) {
            self.progressDone = 0
            self.progressMax = count
            for listener in self.listeners {
                listener.videoRepositoryUpdateStart()
            }
        }
    }
    
    func progressAdvance() {
        dispatch_async(dispatch_get_main_queue()) {
            self.progressDone += 1
            for listener in self.listeners {
                listener.videoRepositoryUpdateProgress(self.progressDone, total: self.progressMax)
            }
        }
    }
    
    typealias RepoContext = (achRails: AchRails, videoRepository: VideoRepository)
    
    class RepoTask: Task {
        let ctx: RepoContext
        
        var achRails: AchRails {
            return ctx.achRails
        }

        var videoRepository: VideoRepository {
            return ctx.videoRepository
        }
        
        init(_ ctx: RepoContext) {
            self.ctx = ctx
        }
    }
    
    class RefreshOnlineTask: RepoTask {
        
        override func run() {
            
            let getVideosTask = GetVideosTask(ctx)
            let getGroupsTask = GetGroupsTask(ctx)
            
            self.addSubtask(getVideosTask)
            self.addSubtask(getGroupsTask)
            
            getVideosTask.start()
            getGroupsTask.start()
            
            self.done()
        }
    }
    
    class GetVideosTask: RepoTask {
        
        override func run() {
            self.achRails.getVideos() {
                
                guard let videoRevisions = $0 else {
                    self.fail(DebugError("Failed to retrieve videos"))
                    return
                }
                
                var numberOfTasks: Int = 0
                
                for videoRevision in videoRevisions {
                    if self.updateVideoIfNeeded(videoRevision) {
                        numberOfTasks += 1
                    }
                }
                
                self.ctx.videoRepository.progressBegin(numberOfTasks)
                
                self.done()
            }
        }
        
        func updateVideoIfNeeded(videoRevision: VideoRevision) -> Bool {
            if let localVideoInfo = self.videoRepository.findVideoInfo(videoRevision.id) {
                
                // Video found locally, check if it needs to be synced
                
                if localVideoInfo.hasLocalModifications {
                    
                    // Video has been modified locally: upload, merge in the server, and download the result.
                    self.uploadVideo(videoRevision)
                    return true
                    
                } else if videoRevision.revision > localVideoInfo.revision {
                    
                    // Video has been updated remotely, but not modified locally: Just download and overwrite.
                    self.downloadVideo(videoRevision)
                    return true
                    
                } else {
                    // Video up to date: Nothing to do
                }
            } else {
                // No local video yet: download it
                self.downloadVideo(videoRevision)
                return true
            }
            
            return false
        }

        func downloadVideo(videoRevision: VideoRevision) {
            
            let task = DownloadVideoTask(ctx, videoRevision: videoRevision)
            self.addSubtask(task)
            task.start()
            
        }
        
        func uploadVideo(videoRevision: VideoRevision) {
            
            let task = UploadVideoTask(ctx, videoRevision: videoRevision)
            self.addSubtask(task)
            task.start()
            
        }
    }
    
    class DownloadVideoTask: RepoTask {
        
        let videoRevision: VideoRevision
        
        init(_ ctx: RepoContext, videoRevision: VideoRevision) {
            self.videoRevision = videoRevision
            super.init(ctx)
        }
        
        override func run() {
            
            self.achRails.getVideo(self.videoRevision.id) { tryVideo in
                
                self.ctx.videoRepository.progressAdvance()
                
                switch tryVideo {
                case .Error(let error): self.fail(error)
                case .Success(let video):
                    dispatch_async(dispatch_get_main_queue()) {
                        do {
                            try AppDelegate.instance.saveVideo(video, saveToDisk: false)
                            self.done()
                        } catch {
                            self.fail(error)
                        }
                    }
                }
            }
            
        }
    }
    
    class UploadVideoTask: RepoTask {
        let videoRevision: VideoRevision
        
        init(_ ctx: RepoContext, videoRevision: VideoRevision) {
            self.videoRevision = videoRevision
            super.init(ctx)
        }
        
        override func run() {
            do {
                let maybeVideo = try AppDelegate.instance.getVideo(self.videoRevision.id)
                
                guard let video = maybeVideo else {
                    throw DebugError("Video not found locally")
                }
                
                self.achRails.uploadVideo(video) { tryVideo in
                    
                    self.ctx.videoRepository.progressAdvance()
                    
                    dispatch_async(dispatch_get_main_queue()) {
                        switch tryVideo {
                        case .Error(let error): self.fail(error)
                        case .Success(let video):
                            do {
                                try AppDelegate.instance.saveVideo(video, saveToDisk: false)
                                self.done()
                            } catch {
                                self.fail(error)
                            }
                        }
                    }
                    
                }
                
            } catch {
                self.ctx.videoRepository.progressAdvance()
                self.fail(error)
            }
        }
    }
    
    class GetGroupsTask: RepoTask {
        
        override func run() {
            achRails.getGroups() { tryGroups in
                switch tryGroups {
                case .Error(let error):
                    self.fail(error)
                    
                case .Success(let (groups, user)):
                    dispatch_async(dispatch_get_main_queue()) {
                        AppDelegate.instance.saveGroups(groups, user: user, downloadedBy: self.achRails.userId)
                        self.done()
                    }
                }
            }
        }
        
    }
    
    func refreshOnline() -> Bool {
        guard let achRails = self.achRails else { return false }
        let ctx = RepoContext(achRails: achRails, videoRepository: self)
        
        // TODO: Count these if many?
        UIApplication.sharedApplication().networkActivityIndicatorVisible = true
        
        let task = RefreshOnlineTask(ctx)
        task.completionHandler = {
            AppDelegate.instance.saveContext()
            self.refresh()
            UIApplication.sharedApplication().networkActivityIndicatorVisible = false
        }
        task.start()
        
        return true
    }
    
    func saveVideo(video: Video) throws {
        try AppDelegate.instance.saveVideo(video)
        refresh()
    }
    
    func findVideoInfo(id: NSUUID) -> VideoInfo? {
        for info in self.videoInfos {
            if info.id == id {
                return info
            }
        }
        return nil
    }
    
    func refreshVideo(video: Video, callback: Video? -> ()) {
        guard let achRails = self.achRails else {
            callback(nil)
            return
        }
        
        if video.videoUri.isLocal {
            callback(nil)
            return
        }
        
        if video.hasLocalModifications {
            achRails.uploadVideo(video) { tryVideo in
                callback(tryVideo.success)
            }
        } else {
            achRails.getVideo(video.id, ifNewerThanRevision: video.revision) { tryVideo in
                callback(tryVideo.success?.flatMap { $0 })
            }
        }
    }
    
    func uploadVideo(video: Video, progressCallback: (Float, animated: Bool) -> (), doneCallback: Try<Video> -> ()) {
        
        guard let achRails = self.achRails else {
            doneCallback(.Error(UserError.invalidLayersBoxUrl.withDebugError("achrails not initialized")))
            return
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            let semaphore = dispatch_semaphore_create(0)
            
            var maybeVideoUrl: NSURL?
            var maybeThumbnailUrl: NSURL?
            
            var progressBase: Float = 0.0
            
            for videoUploader in self.videoUploaders {
                
                videoUploader.uploadVideo(video,
                    progressCallback:  { value in
                        
                        dispatch_async(dispatch_get_main_queue()) {
                            progressCallback(value * 0.7, animated: false)
                        }
                        
                    }, doneCallback: { result in
                        if let result = result {
                            maybeVideoUrl = result.video
                            maybeThumbnailUrl = result.thumbnail
                        }
                        
                        dispatch_semaphore_signal(semaphore)
                    })
    
                while dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0 {
                    NSRunLoop.currentRunLoop().runMode(NSDefaultRunLoopMode, beforeDate: NSDate(timeIntervalSinceNow: 1))
                }
                
                if maybeVideoUrl != nil {
                    break
                }
            }
            
            progressBase = 0.7
            
            if maybeThumbnailUrl == nil {
                for thumbnailUploader in self.thumbnailUploaders {
                    thumbnailUploader.uploadThumbnail(video,
                        progressCallback:  { value in
                            
                            dispatch_async(dispatch_get_main_queue()) {
                                progressCallback(progressBase + value * 0.1, animated: false)
                            }
                            
                        },
                        doneCallback: { result in
                            if let result = result {
                                maybeThumbnailUrl = result
                            }
                            dispatch_semaphore_signal(semaphore)
                        }
                    )
                    
                    while dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0 {
                        NSRunLoop.currentRunLoop().runMode(NSDefaultRunLoopMode, beforeDate: NSDate(timeIntervalSinceNow: 1))
                    }
                    
                    if maybeThumbnailUrl != nil {
                        break
                    }
                }
                
                progressBase = 0.8
            }
            
            
            guard let videoUrl = maybeVideoUrl, thumbnailUrl = maybeThumbnailUrl else {
                dispatch_async(dispatch_get_main_queue()) {
                    doneCallback(.Error(UserError.failedToUploadVideo.withDebugError("Failed to upload media")))
                }
                return
            }
            
            let newVideo = Video(copyFrom: video)
            newVideo.videoUri = videoUrl
            newVideo.thumbnailUri = thumbnailUrl
            
            achRails.uploadVideo(newVideo) { tryUploadedVideo in
                dispatch_semaphore_signal(semaphore)
                
                dispatch_async(dispatch_get_main_queue()) {
                    progressCallback(1.0, animated: true)
                    switch tryUploadedVideo {
                    case .Success(let uploadedVideo):
                        do {
                            try videoRepository.saveVideo(uploadedVideo)
                            doneCallback(.Success(uploadedVideo))
                        } catch {
                            doneCallback(.Error(UserError.failedToSaveVideo.withInnerError(error)))
                        }
                    case .Error(let error):
                        doneCallback(.Error(UserError.failedToUploadVideo.withInnerError(error)))
                    }
                }
            }
            
            while dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) != 0 && progressBase <= 0.90 {
                progressBase += 0.05
                
                dispatch_async(dispatch_get_main_queue()) {
                    progressCallback(progressBase, animated: true)
                }
                
                NSRunLoop.currentRunLoop().runMode(NSDefaultRunLoopMode, beforeDate: NSDate(timeIntervalSinceNow: 0.5))
            }
        }
    }
    
    func retrieveCollectionByIdentifier(identifier: CollectionIdentifier) -> Collection? {
        switch identifier {
        case .AllVideos: return self.allVideosCollection
        case .Group(let id): return self.groupCollections[id]
        case .QrSearch(let code): return self.createQrCodeCollection(code)
        }
    }
    
    func createQrCodeCollection(code: String) -> Collection {
        let collection = Collection(title: "QR: \(code)", subtitle: nil, type: .General)
        collection.videos = self.videoInfos.filter({ $0.tag == code })
        return collection
    }
}

var videoRepository = VideoRepository()
