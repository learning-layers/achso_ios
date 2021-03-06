/*

`AuthenticatedHTTP` is a HTTP client that can make requests using OAuth2 Bearer authentication. It retrieves the authentication tokens and tries to refresh them if they have expired.

Uses OAuth2.swift internally.

*/

import Alamofire

enum AuthenticationResult {
    case OldSession(AuthenticatedHTTP)
    case NewSession(AuthenticatedHTTP)
    case Error(ErrorType)
    
    var isAuthenticated: Bool {
        switch self {
        case .OldSession: return true
        case .NewSession: return true
        case .Error: return false
        }
    }
    
    var error: ErrorType? {
        switch self {
        case .Error(let error): return error
        default: return nil
        }
    }
    
    var http: AuthenticatedHTTP? {
        switch self {
        case .OldSession(let http): return http
        case .NewSession(let http): return http
        default: return nil
        }
    }
}

typealias TokenSet = (access: String, expires: NSDate, refresh: String?)

// HTTP client that manages OAuth2 tokens
class AuthenticatedHTTP {
    
    let oaClient: OAuth2Client
    let userInfoEndpoint: NSURL
    
    var authUser: AuthUser?
    
    var tokens: TokenSet? {
        return authUser?.tokens
    }
    
    init(oaClient: OAuth2Client, userInfoEndpoint: NSURL) {
        self.oaClient = oaClient
        self.userInfoEndpoint = userInfoEndpoint
    }
    
    func executeOAuth2Request(request: OAuth2Request, callback: ACallback) {
        Alamofire.request(.POST, request.url, parameters: request.body).responseJSON(completionHandler: callback)
    }
    
    func executeOAuth2TokenRequest(request: OAuth2Request, createSession: Bool, callback: AuthenticationResult -> ()) {
        executeOAuth2Request(request) { response in
            guard let data = response.result.value else {
                callback(.Error(AssertionError("Response is JSON")))
                return
            }
            
            let tokens = OAuth2Tokens(data)
            
            let expiryTimePadding = 5 // seconds
            
            let accessToken = tokens.accessToken
            let refreshToken = tokens.refreshToken ?? self.tokens?.refresh
            let expiresIn = tokens.expiresIn.map { expiresIn in
                NSDate(timeIntervalSinceNow: Double(expiresIn - expiryTimePadding))
            }
            
            if let newAccess = accessToken, newExpires = expiresIn {
                
                let tokens = TokenSet(access: newAccess, expires: newExpires, refresh: refreshToken)
                self.getUserInfo(tokens, callback: callback)
            } else {
                callback(.Error(UserError.failedToAuthenticate.withDebugError("No response token found")))
            }
        }
    }
    
    func getUserInfo(tokens: TokenSet, callback: AuthenticationResult -> ()) {
        
        let request = self.userInfoEndpoint.request(.GET)
        self.authorizedRequestJSON(request, canRetry: false, tokens: tokens) { response in
            do {
                let responseJson = try (response.result.value as? JSONObject).unwrap()
                let sub: String = try responseJson.castGet("sub")
                let name: String = try responseJson.castGet("name")
                let email: String = try responseJson.castGet("email")
                
                let authorizeUrl = self.oaClient.provider.authorizeUrl
                self.authUser = AuthUser(tokens: tokens, id: sub, name: name, email: email, authorizeUrl: authorizeUrl)
                
                Session.save()
                
                callback(.NewSession(self))
            } catch {
                callback(.Error(error))
            }
        }
    }
    
    func refreshIfNecessary(callback: AuthenticationResult -> ()) {
        // If the access token is still valid no need to refresh
        let isValid = (self.tokens?.expires).map({ $0 > NSDate() }) ?? false
        if self.tokens?.access != nil && isValid {
            callback(.OldSession(self))
            return
        }
        
        self.refreshTokens(callback)
    }
    
    func createCodeAuthorizationUrl(scopes scopes: [String], extraQuery: [String: String] = [:]) -> NSURL? {
        return self.oaClient.createAuthorizationUrlFor(.AuthorizationCode, scopes: scopes, extraQuery: extraQuery)
    }
    
    func authenticateWithCode(code: String, callback: AuthenticationResult -> ()) {
        let tokensRequest = self.oaClient.requestForTokensFromAuthorizationCode(code)
        executeOAuth2TokenRequest(tokensRequest, createSession: true, callback: callback)
    }
    
    func refreshTokens(callback: AuthenticationResult -> ()) {
        guard let refreshToken = self.tokens?.refresh else {
            callback(.Error(UserError.notSignedIn))
            return
        }
        
        let tokensRequest = self.oaClient.requestForTokensFromRefreshToken(refreshToken)
        executeOAuth2TokenRequest(tokensRequest, createSession: false, callback: callback)
    }
    
    func unauthorizedRequestJSON(request: HTTPRequest, callback: ACallback) {
        let old_headers = request.headers ?? [:]
        var new_headers = ["Accept": "application/json"]
        
        for key in old_headers.keys {
            new_headers[key] = request.headers![key]
        }
        
        Alamofire.request(request.method, request.url, parameters: request.parameters, encoding: request.encoding, headers: new_headers)
            .responseJSON(completionHandler: callback)
        
    }
    
    func authorizeRequest(request: HTTPRequest, tokens: TokenSet?) -> HTTPRequest {
        var headers = request.headers ?? [:]
        
        if let tokens = tokens {
            headers["Authorization"] = "Bearer \(tokens.access)"
        }
        
        return HTTPRequest(request.method, request.url, parameters: request.parameters, encoding: request.encoding, headers: headers)
    }
    
    func authorizeRequest(request: HTTPRequest) -> HTTPRequest {
        return authorizeRequest(request, tokens: self.tokens)
    }
    
    func shouldRetryResponse(response: AResponse) -> Bool {
        guard let nsResponse = response.response else { return false }
        
        return [401, 403, 404, 500].contains(nsResponse.statusCode)
    }
    
    func authorizedRequestJSON(request: HTTPRequest, canRetry: Bool, tokens: TokenSet?, callback: ACallback) {
        
        let authorizedRequest = authorizeRequest(request, tokens: tokens)
        
        // Do the request directly if no need to retry
        if !canRetry {
            unauthorizedRequestJSON(authorizedRequest, callback: callback)
            return
        }
        
        unauthorizedRequestJSON(authorizedRequest) { response in
            
            // Call the callback directly if no need to retry
            if !self.shouldRetryResponse(response) {
                callback(response)
                return
            }
            
            // Refresh the tokens and retry if got new ones
            self.refreshTokens() { result in
                self.authorizedRequestJSON(request, canRetry: false, callback: callback)
            }
        }
    }
    
    func authorizedRequestJSON(request: HTTPRequest, canRetry: Bool, callback: ACallback) {
        self.authorizedRequestJSON(request, canRetry: canRetry, tokens: self.tokens, callback: callback)
    }
}
