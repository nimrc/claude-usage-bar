import Foundation

public enum Provider: String, Codable, Sendable {
    case claude, codex
}

/// One login. `id` is the Claude organization UUID or the ChatGPT account id,
/// because several accounts may share one email.
public struct Account: Codable, Identifiable, Sendable, Equatable {
    public var provider: Provider
    public var id: String
    public var name: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(provider: Provider, id: String, name: String, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.provider = provider
        self.id = id
        self.name = name
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case provider, id, name, accessToken, refreshToken, expiresAt }

    // Accounts saved before Codex support have no provider; they are all Claude.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
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
