import CryptoKit
import Foundation
import Security

// Claude Code's public OAuth client. Only `user:profile` is requested: it is
// enough for the usage endpoint and cannot run inference.
public enum OAuthConfig {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let apiBase = URL(string: "https://api.anthropic.com")!
    public static let scope = "user:profile"
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

    public func authorizeURL(redirectURI: String) -> URL {
        var c = URLComponents(url: OAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: OAuthConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: OAuthConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }
}
