import Foundation

public struct APIError: LocalizedError, Sendable {
    public let status: Int
    public let body: String

    /// 400/401 from the token endpoint means the refresh token is gone.
    public var needsLogin: Bool { status == 400 || status == 401 }

    public var errorDescription: String? {
        switch status {
        case 401, 403: "授权失效，请重新登录"
        case 429: "请求过于频繁，稍后重试"
        default: "HTTP \(status) \(body.prefix(120))"
        }
    }
}

public struct ClaudeAPI: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func exchange(code: String, pkce: PKCE, redirectURI: String) async throws -> TokenResponse {
        try await token([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": OAuthConfig.clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ])
    }

    public func refresh(_ refreshToken: String) async throws -> TokenResponse {
        try await token([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientID,
            "scope": OAuthConfig.scope,
        ])
    }

    public func profile(accessToken: String) async throws -> Profile {
        try await get("/api/oauth/profile", accessToken: accessToken)
    }

    public func usage(accessToken: String) async throws -> Usage {
        try await get("/api/oauth/usage", accessToken: accessToken)
    }

    private func token(_ body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: OAuthConfig.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func get<T: Decodable>(_ path: String, accessToken: String) async throws -> T {
        var req = URLRequest(url: OAuthConfig.apiBase.appending(path: path), timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
