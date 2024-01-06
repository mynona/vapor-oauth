import Vapor

struct AuthorizePostRequest {
    let user: OAuthUser
    let userID: String
    let redirectURIBaseString: String
    let approveApplication: Bool
    let clientID: String
    let responseType: String
    let csrfToken: String
    let scopes: [String]?
    let codeChallenge: String?
    let codeChallengeMethod: String?
    let nonce: String?  // OpenID Connect specific
}

struct AuthorizePostHandler {
    
    let tokenManager: TokenManager
    let codeManager: CodeManager
    let clientValidator: ClientValidator
    
    func handleRequest(request: Request) async throws -> Response {
        let requestObject = try validateAuthPostRequest(request)
        var redirectURI = requestObject.redirectURIBaseString
        
        do {
            try await clientValidator.validateClient(clientID: requestObject.clientID, responseType: requestObject.responseType,
                                                     redirectURI: requestObject.redirectURIBaseString, scopes: requestObject.scopes)
        } catch is AbortError {
            throw Abort(.forbidden)
        } catch {
            throw Abort(.badRequest)
        }
        
        guard request.session.data[SessionData.csrfToken] == requestObject.csrfToken else {
            throw Abort(.badRequest)
        }
        
        if requestObject.approveApplication {
            if requestObject.responseType == ResponseType.token {
                let accessToken = try await tokenManager.generateAccessToken(
                    clientID: requestObject.clientID,
                    userID: requestObject.userID,
                    scopes: requestObject.scopes,
                    expiryTime: 3600
                )
                redirectURI += "#token_type=bearer&access_token=\(accessToken.jti)&expires_in=3600"
            } else if requestObject.responseType == ResponseType.code {
                if requestObject.scopes?.contains("openid") == true {
                    // Handle the case where responseType is 'code' and scope includes 'openid'
                    // Generate ID token along with the code
                    let generatedCode = try await codeManager.generateCode(
                        userID: requestObject.userID,
                        clientID: requestObject.clientID,
                        redirectURI: requestObject.redirectURIBaseString,
                        scopes: requestObject.scopes,
                        codeChallenge: requestObject.codeChallenge,
                        codeChallengeMethod: requestObject.codeChallengeMethod,
                        nonce: requestObject.nonce
                    )
                    let idToken = try await tokenManager.generateIDToken(
                        clientID: requestObject.clientID,
                        userID: requestObject.userID,
                        scopes: requestObject.scopes,
                        expiryTime: 3600,
                        nonce: requestObject.nonce
                    )
                    redirectURI += "?code=\(generatedCode)&id_token=\(idToken.jti)"
                } else {
                    // Standard logic for authorization code flow without OpenID Connect
                    let generatedCode = try await codeManager.generateCode(
                        userID: requestObject.userID,
                        clientID: requestObject.clientID,
                        redirectURI: requestObject.redirectURIBaseString,
                        scopes: requestObject.scopes,
                        codeChallenge: requestObject.codeChallenge,
                        codeChallengeMethod: requestObject.codeChallengeMethod,
                        nonce: requestObject.nonce
                    )
                    redirectURI += "?code=\(generatedCode)"
                }
            } else if requestObject.responseType == ResponseType.idToken{
                let idToken = try await tokenManager.generateIDToken(
                    clientID: requestObject.clientID,
                    userID: requestObject.userID,
                    scopes: requestObject.scopes,
                    expiryTime: 3600,
                    nonce: requestObject.nonce
                )
                redirectURI += "#id_token=\(idToken.jti)&expires_in=3600&token_type=bearer"
            }
            else if requestObject.responseType ==  ResponseType.tokenAndIdToken {
                // Handle "token id_token" response type (Hybrid Flow)
                let accessToken = try await tokenManager.generateAccessToken(
                    clientID: requestObject.clientID,
                    userID: requestObject.userID,
                    scopes: requestObject.scopes,
                    expiryTime: 3600
                )
                let idToken = try await tokenManager.generateIDToken(
                    clientID: requestObject.clientID,
                    userID: requestObject.userID,
                    scopes: requestObject.scopes,
                    expiryTime: 3600,
                    nonce: requestObject.nonce
                )
                redirectURI += "#access_token=\(accessToken.jti)&id_token=\(idToken.jti)&expires_in=3600&token_type=bearer"
            } else {
                redirectURI += "?error=invalid_request&error_description=unknown+response+type"
            }
        } else {
            redirectURI += "?error=access_denied&error_description=user+denied+the+request"
        }
        
        if let requestedScopes = requestObject.scopes {
            if !requestedScopes.isEmpty {
                redirectURI += "&scope=\(requestedScopes.joined(separator: "+"))"
            }
        }
        
        if let state = try? request.query.get(String.self, at: OAuthRequestParameters.state) {
            redirectURI += "&state=\(state)"
        }
        
        return request.redirect(to: redirectURI)
    }
    
    private func validateAuthPostRequest(_ request: Request) throws -> AuthorizePostRequest {
        let user = try request.auth.require(OAuthUser.self)
        
        guard let userID = user.id else {
            throw Abort(.unauthorized)
        }
        
        guard let redirectURIBaseString: String = request.query[OAuthRequestParameters.redirectURI] else {
            throw Abort(.badRequest)
        }
        
        guard let approveApplication: Bool = request.content[OAuthRequestParameters.applicationAuthorized] else {
            throw Abort(.badRequest)
        }
        
        guard let clientID: String = request.query[OAuthRequestParameters.clientID] else {
            throw Abort(.badRequest)
        }
        
        guard let responseType: String = request.query[OAuthRequestParameters.responseType] else {
            throw Abort(.badRequest)
        }
        
        guard let csrfToken: String = request.content[OAuthRequestParameters.csrfToken] else {
            throw Abort(.badRequest)
        }
        
        let scopes: [String]?
        
        if let scopeQuery: String = request.query[OAuthRequestParameters.scope] {
            scopes = scopeQuery.components(separatedBy: " ")
        } else {
            scopes = nil
        }
        
        // Extract PKCE parameters
        let codeChallenge: String? = request.content[OAuthRequestParameters.codeChallenge]
        let codeChallengeMethod: String? = request.content[OAuthRequestParameters.codeChallengeMethod]
        
        // Extract nonce for OpenID Connect from the request content
        let nonce: String? = request.content[OAuthRequestParameters.nonce]
        
        
        return AuthorizePostRequest(
            user: user,
            userID: userID,
            redirectURIBaseString: redirectURIBaseString,
            approveApplication: approveApplication,
            clientID: clientID,
            responseType: responseType,
            csrfToken: csrfToken,
            scopes: scopes,
            codeChallenge: codeChallenge,
            codeChallengeMethod: codeChallengeMethod,
            nonce: nonce
        )
    }
    
}
