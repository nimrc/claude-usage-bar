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

@Test func decodesKimiWindows() throws {
    let u = try decode(KimiUsageWire.self, """
    {"usage":{"limit":"100","used":"33","remaining":"67","resetTime":"2026-11-23T02:52:34.766609Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                "detail":{"limit":"100","used":"4","remaining":"96","resetTime":"2026-11-17T09:52:34.766609Z"}}],
     "booster_wallet":{"status":"STATUS_DISABLED"}}
    """).parsed
    #expect(u.limits == [
        Limit(title: "5 小时", percent: 4, resetDate: parseISODate("2026-11-17T09:52:34Z")),
        Limit(title: "本周", percent: 33, resetDate: parseISODate("2026-11-23T02:52:34Z")),
    ])
}

@Test func decodesSub2APIQuotaKey() throws {
    let u = try decode(Sub2APIUsageWire.self, """
    {"mode":"quota_limited","isValid":true,"status":"active",
     "quota":{"limit":10,"used":2.5,"remaining":7.5,"unit":"USD"},"remaining":7.5,"unit":"USD",
     "rate_limits":[{"window":"5h","limit":2,"used":0.5,"remaining":1.5,
                     "window_start":"2026-11-17T10:00:00.123Z","reset_at":"2026-11-17T15:00:00.123Z"},
                    {"window":"7d","limit":20,"used":5,"remaining":15,"window_start":null}],
     "usage":{"today":{"requests":1}}}
    """).parsed
    #expect(u.limits == [
        Limit(title: "5 小时", percent: 25, resetDate: parseISODate("2026-11-17T15:00:00Z")),
        Limit(title: "7 天", percent: 25, resetDate: nil),
        Limit(title: "总额度", percent: 25, resetDate: nil),
    ])
    #expect(u.note == nil)
}

@Test func decodesSub2APISubscriptionAndWallet() throws {
    let sub = try decode(Sub2APIUsageWire.self, """
    {"mode":"unrestricted","isValid":true,"planName":"Pro","unit":"USD","remaining":12.34,
     "subscription":{"daily_usage_usd":5,"weekly_usage_usd":10,"monthly_usage_usd":0,
                     "daily_limit_usd":10,"weekly_limit_usd":null,"monthly_limit_usd":100,
                     "weekly_window_start":"2026-11-10T00:00:00Z","expires_at":"2027-01-01T00:00:00Z"}}
    """)
    #expect(sub.planName == "Pro")
    #expect(sub.parsed.limits.map(\.title) == ["今日", "本月"])
    #expect(sub.parsed.limits.map(\.percent) == [50, 0])

    let wallet = try decode(Sub2APIUsageWire.self,
        #"{"mode":"unrestricted","isValid":true,"planName":"钱包余额","remaining":5,"unit":"USD","balance":5}"#).parsed
    #expect(wallet.limits.isEmpty)
    #expect(wallet.note == "余额 $5.00")
}

@Test func parsesGrokBillingInEitherCasing() throws {
    let camel = Data(#"{"config":{"creditUsagePercent":42.5,"currentPeriod":{"start":"2026-11-01T00:00:00Z","end":"2026-12-01T00:00:00Z"},"subscriptionTier":"SuperGrok"}}"#.utf8)
    #expect(parseGrokBilling(camel)?.limits == [Limit(title: "本期额度", percent: 42.5, resetDate: parseISODate("2026-12-01T00:00:00Z"))])
    let snake = Data(#"{"config":{"on_demand_used":{"val":25},"on_demand_cap":{"val":100},"billing_period_end":1795000000}}"#.utf8)
    #expect(parseGrokBilling(snake)?.limits == [Limit(title: "本期额度", percent: 25, resetDate: Date(timeIntervalSince1970: 1_795_000_000))])
    #expect(parseGrokBilling(Data(#"{"config":{}}"#.utf8)) == nil)
}

@Test func readsGrokCLICredential() throws {
    let json = #"{"https://accounts.x.ai/sign-in":{"key":"old"},"https://auth.x.ai::client":{"key":"tok","email":"a@b.c","user_id":"u1","expires_at":"2026-11-20T00:00:00Z"}}"#
    let c = try #require(GrokCredential.parse(Data(json.utf8)))
    #expect(c == GrokCredential(accessToken: "tok", userID: "u1", email: "a@b.c", expiresAt: parseISODate("2026-11-20T00:00:00Z")))
    #expect(GrokCredential.parse(Data("{}".utf8)) == nil)
}

@Test func sub2APIBaseURLMustBeSafe() {
    #expect(Sub2API.normalize(baseURL: " https://relay.example.com/ ") == "https://relay.example.com")
    #expect(Sub2API.normalize(baseURL: "http://127.0.0.1:8080") == "http://127.0.0.1:8080")
    #expect(Sub2API.normalize(baseURL: "http://relay.example.com") == nil)
    #expect(Sub2API.normalize(baseURL: "https://u:p@relay.example.com") == nil)
    #expect(Sub2API.normalize(baseURL: "https://relay.example.com?x=1") == nil)
}

@Test func keyAccountIDIsStableAndHidesKey() {
    let id = keyAccountID(.kimi, "sk-kimi-secret")
    #expect(id == keyAccountID(.kimi, "sk-kimi-secret"))
    #expect(id.hasPrefix("kimi:") && !id.contains("secret") && id.count == 21)
}

@Test func aliasOverridesNameAndIsOptional() throws {
    let json = #"[{"provider":"kimi","id":"k","name":"Kimi Code ··abcd","accessToken":"a","refreshToken":"","expiresAt":"2026-11-17T11:59:59Z","alias":"K1"},{"id":"o","name":"Org","accessToken":"a","refreshToken":"r","expiresAt":"2026-11-17T11:59:59Z"}]"#
    let accounts = try Vault.decoder.decode([Account].self, from: Data(json.utf8))
    #expect(accounts.map(\.displayName) == ["K1", "Org"])
    let roundTrip = try Vault.decoder.decode([Account].self, from: Vault.encoder.encode(accounts))
    #expect(roundTrip == accounts)
}
