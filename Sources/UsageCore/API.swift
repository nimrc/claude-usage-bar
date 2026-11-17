import CryptoKit
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

public struct KimiAPI: Sendable {
    public static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    let http: HTTP

    public init(session: URLSession = .shared) { http = HTTP(session: session) }

    public func usage(apiKey: String) async throws -> Usage {
        var req = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let wire: KimiUsageWire = try await http.send(req)
        return wire.parsed
    }
}

public struct Sub2API: Sendable {
    let http: HTTP

    public init(session: URLSession = .shared) { http = HTTP(session: session) }

    /// HTTPS, or plain HTTP on loopback only, so a key never crosses the network in clear text.
    public static func normalize(baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let c = URLComponents(string: trimmed), let host = c.host, c.query == nil, c.fragment == nil,
              c.user == nil, c.password == nil else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard c.scheme == "https" || (c.scheme == "http" && loopback) else { return nil }
        return trimmed
    }

    public func usage(baseURL: String, apiKey: String) async throws -> (usage: Usage, planName: String?) {
        guard let url = URL(string: baseURL + "/v1/usage") else { throw APIError(status: 0, body: "地址无效") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let wire: Sub2APIUsageWire = try await http.send(req)
        return (wire.parsed, wire.planName)
    }
}

public struct GrokAPI: Sendable {
    public static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    let http: HTTP

    public init(session: URLSession = .shared) { http = HTTP(session: session) }

    public func usage(accessToken: String) async throws -> Usage {
        var req = URLRequest(url: Self.billingURL, timeoutInterval: 20)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        guard let usage = parseGrokBilling(try await http.data(req)) else {
            throw APIError(status: 200, body: "无法解析 Grok 用量")
        }
        return usage
    }
}

/// The grok CLI's own login, read fresh on every poll and never written: the CLI
/// refreshes it, and rotating its refresh token here would log the CLI out.
public struct GrokCredential: Sendable, Equatable {
    public let accessToken: String
    public let userID: String
    public let email: String?
    public let expiresAt: Date?

    public static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok")
        return home.appending(path: "auth.json")
    }

    public static func load(from url: URL = authFile) -> GrokCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> GrokCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = root.keys.sorted()
        let scope = keys.first { $0.hasPrefix("https://auth.x.ai") } ?? keys.first { $0.hasPrefix("https://accounts.x.ai") }
        guard let scope, let entry = root[scope] as? [String: Any], let token = entry["key"] as? String, !token.isEmpty else { return nil }
        let expiry: Date? = switch entry["expires_at"] {
        case let s as String: parseISODate(s) ?? Double(s).map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
        case let n as NSNumber: Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue)
        default: nil
        }
        let user = entry["user_id"] as? String ?? entry["team_id"] as? String ?? "default"
        return GrokCredential(accessToken: token, userID: user, email: entry["email"] as? String, expiresAt: expiry)
    }
}

/// Stable account id for an API key without storing the key in the id.
public func keyAccountID(_ provider: Provider, _ key: String) -> String {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(provider.rawValue):\(digest.prefix(16))"
}

struct HTTP: Sendable {
    let session: URLSession

    func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        try Self.decoder.decode(T.self, from: try await data(req))
    }

    func data(_ req: URLRequest) async throws -> Data {
        var req = req
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
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
