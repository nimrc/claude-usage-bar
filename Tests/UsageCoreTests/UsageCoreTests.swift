import Foundation
import Testing
@testable import UsageCore

@Test func decodesLimits() throws {
    let json = """
    {"five_hour":{"utilization":98.0,"resets_at":"2026-11-17T11:59:59.908667+00:00"},
     "limits":[
      {"kind":"session","percent":98,"resets_at":"2026-11-17T11:59:59.908667+00:00","scope":null},
      {"kind":"weekly_all","percent":64,"resets_at":"2026-11-22T08:59:59.908691+00:00","scope":null},
      {"kind":"weekly_scoped","percent":57,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
     ]}
    """
    let u = try ClaudeAPI.decoder.decode(Usage.self, from: Data(json.utf8))
    #expect(u.limits.map(\.title) == ["5 小时", "本周", "本周 · Fable"])
    #expect(u.limits[0].percent == 98)
    #expect(u.limits[0].resetDate == parseISODate("2026-11-17T11:59:59Z"))
    #expect(u.limits[2].resetDate == nil)
}

@Test func fallsBackToFlatWindows() throws {
    let json = """
    {"five_hour":{"utilization":12.5,"resets_at":"2026-11-17T11:59:59+00:00"},
     "seven_day":{"utilization":40,"resets_at":null},"limits":null}
    """
    let u = try ClaudeAPI.decoder.decode(Usage.self, from: Data(json.utf8))
    #expect(u.limits.map(\.kind) == ["session", "weekly_all"])
    #expect(u.limits[0].percent == 12.5)
}

@Test func parsesMicrosecondTimestamps() {
    let d = parseISODate("2026-11-17T11:59:59.908667+00:00")
    #expect(d == Date(timeIntervalSince1970: 1_794_916_799))
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

@Test func authorizeURLCarriesProfileScopeOnly() throws {
    let p = PKCE()
    let url = p.authorizeURL(redirectURI: "http://localhost:5555/callback")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(q["scope"] == "user:profile")
    #expect(q["state"] == p.state)
    #expect(q["code_challenge"] == p.challenge)
    #expect(q["redirect_uri"] == "http://localhost:5555/callback")
}

@Test func parsesCallbackRequest() {
    let req = Data("GET /callback?code=abc%23s1&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    #expect(LoopbackServer.callbackQuery(req) == ["code": "abc#s1", "state": "s1"])
    #expect(LoopbackServer.callbackQuery(Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)) == nil)
}
