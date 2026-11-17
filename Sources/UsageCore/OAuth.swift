import CryptoKit
import Foundation
import Security

// Claude Code's public OAuth client. Only `user:profile` is requested: it is
// enough for the usage endpoint and cannot run inference.
public enum ClaudeOAuth {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let apiBase = URL(string: "https://api.anthropic.com")!
    public static let scope = "user:profile"
    public static let callbackPath = "/callback"

    public static func authorizeURL(pkce: PKCE, redirectURI: String) -> URL {
        url(authorizeURL, [
            ("code", "true"),
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("state", pkce.state),
        ])
    }
}

// Codex CLI's public OAuth client. Its registered redirects are fixed
// loopback ports, so the callback server must bind one of them.
public enum CodexOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let scope = "openid profile email offline_access"
    public static let ports: [UInt16] = [1455, 1457]
    public static let callbackPath = "/auth/callback"

    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    public static func authorizeURL(pkce: PKCE, redirectURI: String) -> URL {
        url(authorizeURL, [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("state", pkce.state),
            ("originator", "codex_cli_rs"),
        ])
    }
}

private func url(_ base: URL, _ items: [(String, String)]) -> URL {
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
    return c.url!
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        verifier = Self.random()
        challenge = Self.challenge(for: verifier)
        state = Self.random()
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Unverified JWT payload: only used to read our own tokens' claims.
public func jwtClaims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    guard let data = Data(base64Encoded: s) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

public func jwtExpiry(_ jwt: String) -> Date? {
    (jwtClaims(jwt)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
}
