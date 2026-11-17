import Foundation

/// One Claude organization login. Keyed by organization UUID because every
/// account may share the same email.
public struct Account: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(id: String, name: String, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.id = id
        self.name = name
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct TokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double
}

public struct Profile: Decodable, Sendable {
    public struct Organization: Decodable, Sendable {
        public let uuid: String
        public let name: String
    }
    public let organization: Organization
}

public struct Limit: Decodable, Sendable, Identifiable {
    public struct Scope: Decodable, Sendable {
        public struct Model: Decodable, Sendable { public let displayName: String? }
        public let model: Model?
    }

    public let kind: String
    public let percent: Double
    public let resetsAt: String?
    public let scope: Scope?

    public init(kind: String, percent: Double, resetsAt: String?, scope: Scope? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    public var id: String { "\(kind)/\(scope?.model?.displayName ?? "")" }
    public var resetDate: Date? { resetsAt.flatMap(parseISODate) }

    public var title: String {
        switch kind {
        case "session": "5 小时"
        case "weekly_all": "本周"
        case "weekly_scoped": "本周 · \(scope?.model?.displayName ?? "模型")"
        default: kind
        }
    }
}

public struct Usage: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: String?
    }

    public let limits: [Limit]

    enum CodingKeys: String, CodingKey { case limits, fiveHour, sevenDay }

    public init(limits: [Limit]) { self.limits = limits }

    // `limits` is the current shape; fall back to the flat windows if it is absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let limits = try c.decodeIfPresent([Limit].self, forKey: .limits), !limits.isEmpty {
            self.limits = limits
            return
        }
        var out: [Limit] = []
        for (key, kind) in [(CodingKeys.fiveHour, "session"), (.sevenDay, "weekly_all")] {
            if let w = try c.decodeIfPresent(Window.self, forKey: key), let u = w.utilization {
                out.append(Limit(kind: kind, percent: u, resetsAt: w.resetsAt))
            }
        }
        limits = out
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
