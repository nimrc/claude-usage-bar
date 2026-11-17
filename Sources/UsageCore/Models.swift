import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex, kimi, grok, sub2api

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .kimi: "Kimi Code"
        case .grok: "Grok"
        case .sub2api: "sub2api"
        }
    }
}

/// One account. `id` is the Claude organization UUID, the ChatGPT account id,
/// the Grok user id, or a hash of an API key, because several accounts may share one email.
/// API-key providers keep the key in `accessToken`; Grok keeps nothing and reads the grok CLI login.
public struct Account: Codable, Identifiable, Sendable, Equatable {
    public var provider: Provider
    public var id: String
    public var name: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// sub2api deployment.
    public var baseURL: String?
    /// User-chosen short name shown instead of `name`.
    public var alias: String?

    public var displayName: String { alias ?? name }

    public init(provider: Provider, id: String, name: String, accessToken: String, refreshToken: String,
                expiresAt: Date, baseURL: String? = nil) {
        self.provider = provider
        self.id = id
        self.name = name
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.baseURL = baseURL
    }

    enum CodingKeys: String, CodingKey { case provider, id, name, accessToken, refreshToken, expiresAt, baseURL, alias }

    // Accounts saved before Codex support have no provider; they are all Claude.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
    }
}

extension Array where Element: Identifiable {
    /// Drag-and-drop reorder: the moved element takes the target's slot, so it
    /// lands after the target when moving down and before it when moving up.
    public mutating func move(id: Element.ID, onto target: Element.ID) {
        guard id != target, let from = firstIndex(where: { $0.id == id }),
              let to = firstIndex(where: { $0.id == target }) else { return }
        insert(remove(at: from), at: to)
    }
}

public struct Limit: Sendable, Identifiable, Equatable {
    public let title: String
    public let percent: Double
    public let resetDate: Date?

    public init(title: String, percent: Double, resetDate: Date?) {
        self.title = title
        self.percent = percent
        self.resetDate = resetDate
    }

    public var id: String { title }
}

public struct Usage: Sendable, Equatable {
    public let limits: [Limit]
    /// Non-percentage facts such as a wallet balance.
    public var note: String?

    public init(limits: [Limit], note: String? = nil) {
        self.limits = limits
        self.note = note
    }
}

/// `/api/oauth/usage`. `limits` is the current shape; the flat windows are a fallback.
struct ClaudeUsageWire: Decodable {
    struct Entry: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let displayName: String? }
            let model: Model?
        }
        let kind: String
        let percent: Double
        let resetsAt: String?
        let scope: Scope?
    }

    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    let limits: [Entry]?
    let fiveHour: Window?
    let sevenDay: Window?

    var usage: Usage {
        if let limits, !limits.isEmpty {
            return Usage(limits: limits.map {
                Limit(title: Self.title($0.kind, model: $0.scope?.model?.displayName),
                      percent: $0.percent, resetDate: $0.resetsAt.flatMap(parseISODate))
            })
        }
        let flat: [(String, Window?)] = [("session", fiveHour), ("weekly_all", sevenDay)]
        return Usage(limits: flat.compactMap { kind, w in
            guard let w, let u = w.utilization else { return nil }
            return Limit(title: Self.title(kind, model: nil), percent: u, resetDate: w.resetsAt.flatMap(parseISODate))
        })
    }

    static func title(_ kind: String, model: String?) -> String {
        switch kind {
        case "session": "5 小时"
        case "weekly_all": "本周"
        case "weekly_scoped": "本周 · \(model ?? "模型")"
        default: kind
        }
    }
}

/// `chatgpt.com/backend-api/wham/usage`.
struct CodexUsageWire: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Double?
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    let rateLimit: RateLimit?

    var usage: Usage {
        Usage(limits: [rateLimit?.primaryWindow, rateLimit?.secondaryWindow].compactMap { w in
            guard let w else { return nil }
            return Limit(title: windowTitle(seconds: w.limitWindowSeconds), percent: w.usedPercent,
                         resetDate: w.resetAt.map(Date.init(timeIntervalSince1970:)))
        })
    }
}

/// `api.kimi.com/coding/v1/usages`. Counts are strings; `usage` is the weekly
/// quota and `limits` holds the short windows (5 hours today).
struct KimiUsageWire: Decodable {
    struct Detail: Decodable {
        let limit: String?
        let used: String?
        let resetTime: String?
    }
    struct Window: Decodable {
        let duration: Int?
        let timeUnit: String?
    }
    struct Entry: Decodable {
        let window: Window?
        let detail: Detail?
    }

    let usage: Detail?
    let limits: [Entry]?

    var parsed: Usage {
        var out: [Limit] = []
        for e in limits ?? [] {
            if let l = e.detail.flatMap({ Self.limit($0, title: windowTitle(seconds: Self.seconds(e.window))) }) { out.append(l) }
        }
        if let l = usage.flatMap({ Self.limit($0, title: "本周") }) { out.append(l) }
        return Usage(limits: out)
    }

    static func limit(_ d: Detail, title: String) -> Limit? {
        guard let limit = d.limit.flatMap(Double.init), limit > 0, let used = d.used.flatMap(Double.init) else { return nil }
        return Limit(title: title, percent: used / limit * 100, resetDate: d.resetTime.flatMap(parseISODate))
    }

    static func seconds(_ w: Window?) -> Int? {
        guard let w, let n = w.duration else { return nil }
        let unit = switch w.timeUnit {
        case "TIME_UNIT_SECOND": 1
        case "TIME_UNIT_MINUTE": 60
        case "TIME_UNIT_HOUR": 3600
        case "TIME_UNIT_DAY": 86400
        default: 0
        }
        return unit == 0 ? nil : n * unit
    }
}

/// sub2api `GET /v1/usage`, amounts in USD. Three shapes: a quota-limited key
/// (total quota and rolling rate-limit windows), a subscription group
/// (daily/weekly/monthly spend limits), or a wallet (balance only).
struct Sub2APIUsageWire: Decodable {
    struct Quota: Decodable {
        let limit: Double
        let used: Double
    }
    struct RateLimit: Decodable {
        let window: String
        let limit: Double
        let used: Double
        let resetAt: String?
    }
    struct Subscription: Decodable {
        let dailyUsageUsd: Double?
        let weeklyUsageUsd: Double?
        let monthlyUsageUsd: Double?
        let dailyLimitUsd: Double?
        let weeklyLimitUsd: Double?
        let monthlyLimitUsd: Double?
        let weeklyWindowStart: String?
        let expiresAt: String?
    }

    let planName: String?
    let quota: Quota?
    let rateLimits: [RateLimit]?
    let subscription: Subscription?
    let balance: Double?
    let remaining: Double?

    var parsed: Usage {
        var out: [Limit] = []
        for r in rateLimits ?? [] where r.limit > 0 {
            let title = switch r.window {
            case "5h": "5 小时"
            case "1d": "1 天"
            case "7d": "7 天"
            default: r.window
            }
            out.append(Limit(title: title, percent: r.used / r.limit * 100, resetDate: r.resetAt.flatMap(parseISODate)))
        }
        if let q = quota, q.limit > 0 {
            out.append(Limit(title: "总额度", percent: q.used / q.limit * 100, resetDate: nil))
        }
        if let s = subscription {
            let weeklyReset = s.weeklyWindowStart.flatMap(parseISODate).map { $0.addingTimeInterval(7 * 86400) }
            for (title, used, limit, reset) in [("今日", s.dailyUsageUsd, s.dailyLimitUsd, nil),
                                                ("本周", s.weeklyUsageUsd, s.weeklyLimitUsd, weeklyReset),
                                                ("本月", s.monthlyUsageUsd, s.monthlyLimitUsd, nil)] {
                if let limit, limit > 0 {
                    out.append(Limit(title: title, percent: (used ?? 0) / limit * 100, resetDate: reset))
                }
            }
        }
        var note: String?
        if let balance {
            note = String(format: "余额 $%.2f", balance)
        } else if out.isEmpty, let remaining, remaining >= 0 {
            note = String(format: "剩余 $%.2f", remaining)
        }
        return Usage(limits: out, note: note)
    }
}

/// `cli-chat-proxy.grok.com/v1/billing?format=credits`. Parsed loosely because
/// the key casing is not documented: camelCase and snake_case are both accepted.
func parseGrokBilling(_ data: Data) -> Usage? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let cfg = root["config"] as? [String: Any] ?? root
    func value(_ d: [String: Any]?, _ camel: String) -> Any? {
        let snake = camel.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
        return d?[camel] ?? d?[snake]
    }
    func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        if let d = v as? [String: Any] { return number(d["val"]) }
        return nil
    }
    func date(_ v: Any?) -> Date? {
        if let s = v as? String { return parseISODate(s) ?? Double(s).flatMap { date($0) } }
        if let n = number(v) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return nil
    }

    var percent = number(value(cfg, "creditUsagePercent"))
    if percent == nil, let used = number(value(cfg, "onDemandUsed")), let cap = number(value(cfg, "onDemandCap")), cap > 0 {
        percent = used / cap * 100
    }
    let period = value(cfg, "currentPeriod") as? [String: Any]
    let reset = date(value(period, "end")) ?? date(value(cfg, "billingPeriodEnd"))

    var out: [Limit] = []
    if let percent { out.append(Limit(title: "本期额度", percent: percent, resetDate: reset)) }
    for item in value(cfg, "productUsage") as? [[String: Any]] ?? [] {
        if let name = item["product"] as? String, let p = number(value(item, "usagePercent")) {
            out.append(Limit(title: name, percent: p, resetDate: reset))
        }
    }
    let tier = (value(cfg, "subscriptionTier") ?? value(root, "subscriptionTier")) as? String
    return out.isEmpty && tier == nil ? nil : Usage(limits: out, note: out.isEmpty ? tier : nil)
}

func windowTitle(seconds: Int?) -> String {
    switch seconds {
    case 18000: "5 小时"
    case 604_800: "本周"
    case let s? where s % 86400 == 0: "\(s / 86400) 天"
    case let s?: "\(s / 3600) 小时"
    case nil: "额度"
    }
}

/// Parses RFC 3339 timestamps with any number of fractional digits
/// (the API sends microseconds, which ISO8601DateFormatter rejects).
public func parseISODate(_ s: String) -> Date? {
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: trimmed)
}

/// "3小时50分" style countdown; nil once the time has passed.
public func countdown(to date: Date, now: Date = .now) -> String? {
    let total = Int(date.timeIntervalSince(now))
    guard total > 0 else { return nil }
    let d = total / 86400, h = total % 86400 / 3600, m = total % 3600 / 60
    if d > 0 { return "\(d)天\(h)小时" }
    if h > 0 { return "\(h)小时\(m)分" }
    return "\(max(m, 1))分"
}
