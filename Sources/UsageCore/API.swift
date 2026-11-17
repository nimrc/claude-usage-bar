import Foundation

public struct APIError: LocalizedError, Sendable {
    public let status: Int
    public let body: String

    /// 400/401 from a token endpoint means the refresh token is gone.
    public var needsLogin: Bool { status == 400 || status == 401 }

    public var errorDescription: String? {
        switch status {
        case 401, 403: "授权失效，请重新登录"
        case 429: "请求过于频繁，稍后重试"
        default: "HTTP \(status) \(body.prefix(120))"
        }
    }
}

public struct TokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresIn: Double?

    /// Codex tokens may omit `expires_in`; the access token's `exp` is authoritative then.
    public var expiresAt: Date {
        if let expiresIn { return .now.addingTimeInterval(expiresIn) }
        return jwtExpiry(accessToken) ?? .now.addingTimeInterval(3600)
    }
}

public struct ClaudeProfile: Decodable, Sendable {
    public struct Organization: Decodable, Sendable {
        public let uuid: String
        public let name: String
    }
    public let organization: Organization
}

/// ChatGPT workspace identity from the id_token claims.
public struct CodexIdentity: Sendable, Equatable {
    public let accountID: String
    public let label: String

    public init?(idToken: String) {
        guard let claims = jwtClaims(idToken),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String
        else { return nil }
        self.accountID = accountID
        let email = claims["email"] as? String ?? "ChatGPT"
        label = (auth["chatgpt_plan_type"] as? String).map { "\(email) · \($0)" } ?? email
    }
}

public struct ClaudeAPI: Sendable {
    let http: HTTP

    public init(session: URLSession = .shared) { http = HTTP(session: session) }

    public func exchange(code: String, pkce: PKCE, redirectURI: String) async throws -> TokenResponse {
        try await http.send(.json(ClaudeOAuth.tokenURL, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": ClaudeOAuth.clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ]))
    }

    public func refresh(_ refreshToken: String) async throws -> TokenResponse {
        try await http.send(.json(ClaudeOAuth.tokenURL, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeOAuth.clientID,
            "scope": ClaudeOAuth.scope,
        ]))
    }

    public func profile(accessToken: String) async throws -> ClaudeProfile {
        try await http.send(get("/api/oauth/profile", accessToken))
    }

    public func usage(accessToken: String) async throws -> Usage {
        let wire: ClaudeUsageWire = try await http.send(get("/api/oauth/usage", accessToken))
        return wire.usage
    }

    private func get(_ path: String, _ accessToken: String) -> URLRequest {
        var req = URLRequest(url: ClaudeOAuth.apiBase.appending(path: path), timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return req
    }
}

public struct CodexAPI: Sendable {
    let http: HTTP

    public init(session: URLSession = .shared) { http = HTTP(session: session) }

    // The code exchange is form-encoded, the refresh is JSON: that is what the Codex CLI sends.
    public func exchange(code: String, pkce: PKCE, redirectURI: String) async throws -> TokenResponse {
        try await http.send(.form(CodexOAuth.tokenURL, [
            "grant_type": "authorization_code",
            "client_id": CodexOAuth.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ]))
    }

    public func refresh(_ refreshToken: String) async throws -> TokenResponse {
        try await http.send(.json(CodexOAuth.tokenURL, [
            "grant_type": "refresh_token",
            "client_id": CodexOAuth.clientID,
            "refresh_token": refreshToken,
        ]))
    }

    public func usage(accessToken: String, accountID: String) async throws -> Usage {
        var req = URLRequest(url: CodexOAuth.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        let wire: CodexUsageWire = try await http.send(req)
        return wire.usage
    }
}

struct HTTP: Sendable {
    let session: URLSession

    func send<T: Decodable>(_ req: URLRequest) async throws -> T {
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

extension URLRequest {
    static func json(_ url: URL, _ body: [String: String]) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func form(_ url: URL, _ body: [String: String]) -> URLRequest {
        var c = URLComponents()
        c.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves "+" unescaped, which form decoding reads as a space.
        req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return req
    }
}
