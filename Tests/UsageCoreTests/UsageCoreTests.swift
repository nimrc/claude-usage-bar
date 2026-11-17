import Foundation
import Testing
@testable import UsageCore

private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
    try HTTP.decoder.decode(T.self, from: Data(json.utf8))
}

private func jwt(_ claims: [String: Any]) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: claims)
    return "e30.\(PKCE.base64URL(payload)).sig"
}

@Test func decodesClaudeLimits() throws {
    let u = try decode(ClaudeUsageWire.self, """
    {"five_hour":{"utilization":98.0,"resets_at":"2026-11-17T11:59:59.908667+00:00"},
     "limits":[
      {"kind":"session","percent":98,"resets_at":"2026-11-17T11:59:59.908667+00:00","scope":null},
      {"kind":"weekly_all","percent":64,"resets_at":"2026-11-22T08:59:59.908691+00:00","scope":null},
      {"kind":"weekly_scoped","percent":57,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
     ]}
    """).usage
    #expect(u.limits.map(\.title) == ["5 小时", "本周", "本周 · Fable"])
    #expect(u.limits[0].percent == 98)
    #expect(u.limits[0].resetDate == parseISODate("2026-11-17T11:59:59Z"))
    #expect(u.limits[2].resetDate == nil)
}

@Test func claudeFallsBackToFlatWindows() throws {
    let u = try decode(ClaudeUsageWire.self, """
    {"five_hour":{"utilization":12.5,"resets_at":"2026-11-17T11:59:59+00:00"},
     "seven_day":{"utilization":40,"resets_at":null},"limits":null}
    """).usage
    #expect(u.limits.map(\.title) == ["5 小时", "本周"])
    #expect(u.limits[0].percent == 12.5)
}

@Test func decodesCodexWindows() throws {
    let u = try decode(CodexUsageWire.self, """
    {"plan_type":"plus","rate_limit":{"allowed":true,
      "primary_window":{"used_percent":5,"limit_window_seconds":18000,"reset_after_seconds":10451,"reset_at":1794915941},
      "secondary_window":{"used_percent":14,"limit_window_seconds":604800,"reset_after_seconds":499585,"reset_at":1795405075}},
     "credits":{"has_credits":false}}
    """).usage
    #expect(u.limits == [
        Limit(title: "5 小时", percent: 5, resetDate: Date(timeIntervalSince1970: 1_794_915_941)),
        Limit(title: "本周", percent: 14, resetDate: Date(timeIntervalSince1970: 1_795_405_075)),
    ])
}

@Test func codexWithoutRateLimitHasNoLimits() throws {
    #expect(try decode(CodexUsageWire.self, #"{"rate_limit":null}"#).usage.limits.isEmpty)
}

@Test func codexIdentityFromIDToken() throws {
    let token = try jwt([
        "email": "a@b.c",
        "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "plus"],
    ])
    let id = try #require(CodexIdentity(idToken: token))
    #expect(id.accountID == "acct-1")
    #expect(id.label == "a@b.c · plus")
    #expect(CodexIdentity(idToken: try jwt(["email": "a@b.c"])) == nil)
}

@Test func tokenExpiryFallsBackToJWT() throws {
    let access = try jwt(["exp": 1_800_000_000])
    let t = try decode(TokenResponse.self, #"{"access_token":"\#(access)"}"#)
    #expect(t.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func legacyAccountsDecodeAsClaude() throws {
    let json = #"[{"id":"org","name":"Example","accessToken":"a","refreshToken":"r","expiresAt":"2026-11-17T11:59:59Z"}]"#
    let accounts = try Vault.decoder.decode([Account].self, from: Data(json.utf8))
    #expect(accounts.first?.provider == .claude)
}

@Test func parsesMicrosecondTimestamps() {
    #expect(parseISODate("2026-11-17T11:59:59.908667+00:00") == Date(timeIntervalSince1970: 1_794_916_799))
}

@Test func formatsCountdown() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(countdown(to: now.addingTimeInterval(3 * 86400 + 5 * 3600), now: now) == "3天5小时")
    #expect(countdown(to: now.addingTimeInterval(3 * 3600 + 50 * 60 + 9), now: now) == "3小时50分")
    #expect(countdown(to: now.addingTimeInterval(20), now: now) == "1分")
    #expect(countdown(to: now.addingTimeInterval(-1), now: now) == nil)
}

@Test func pkceChallengeIsBase64URLSHA256() {
    // Expected value from Python: urlsafe_b64encode(sha256(verifier)).rstrip("=").
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r7wW1gFWFOEjXk")
        == "bwWFMyPfdG9qreDhH2lmftFx_dFeLDalzcT1gb_j68g")
}

private func query(_ url: URL) throws -> [String: String] {
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Test func claudeAuthorizeURLCarriesProfileScopeOnly() throws {
    let p = PKCE()
    let q = try query(ClaudeOAuth.authorizeURL(pkce: p, redirectURI: "http://localhost:5555/callback"))
    #expect(q["scope"] == "user:profile")
    #expect(q["state"] == p.state)
    #expect(q["code_challenge"] == p.challenge)
}

@Test func codexAuthorizeURLUsesRegisteredRedirect() throws {
    let p = PKCE()
    let q = try query(CodexOAuth.authorizeURL(pkce: p, redirectURI: CodexOAuth.redirectURI(port: 1455)))
    #expect(q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
    #expect(q["client_id"] == CodexOAuth.clientID)
    #expect(q["codex_cli_simplified_flow"] == "true")
}

@Test func formBodyEscapesPlus() throws {
    let req = URLRequest.form(CodexOAuth.tokenURL, ["code_verifier": "a+b"])
    #expect(String(decoding: try #require(req.httpBody), as: UTF8.self) == "code_verifier=a%2Bb")
}

@Test func parsesCallbackRequest() {
    let req = Data("GET /auth/callback?code=abc%23s1&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    #expect(LoopbackServer.callbackQuery(req, path: "/auth/callback") == ["code": "abc#s1", "state": "s1"])
    #expect(LoopbackServer.callbackQuery(req, path: "/callback") == nil)
}

private struct Item: Identifiable, Equatable { let id: String }

@Test func moveTakesTargetSlot() {
    var a = ["a", "b", "c", "d"].map(Item.init)
    a.move(id: "a", onto: "c")
    #expect(a.map(\.id) == ["b", "c", "a", "d"])
    a.move(id: "d", onto: "b")
    #expect(a.map(\.id) == ["d", "b", "c", "a"])
    a.move(id: "x", onto: "b")
    a.move(id: "b", onto: "b")
    #expect(a.map(\.id) == ["d", "b", "c", "a"])
}
