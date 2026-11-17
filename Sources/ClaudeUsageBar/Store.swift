import AppKit
import Observation
import ServiceManagement
import UsageCore

struct LoginError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor @Observable
final class Store {
    struct Status {
        var usage: Usage?
        var error: String?
    }

    private(set) var accounts: [Account] = Vault.load()
    private(set) var status: [String: Status] = [:]
    private(set) var refreshing = false
    private(set) var lastUpdated: Date?
    private(set) var loginServer: LoopbackServer?
    var loginError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                loginError = "开机启动设置失败：\(error.localizedDescription)"
            }
        }
    }

    var isLoggingIn: Bool { loginServer != nil }

    private let api = ClaudeAPI()

    init() {
        Task { await pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshAll()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    func refreshIfStale() {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 60 { return }
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for a in accounts {
                group.addTask { await self.refresh(a.id) }
            }
        }
        lastUpdated = .now
    }

    private func refresh(_ id: String) async {
        guard var a = accounts.first(where: { $0.id == id }) else { return }
        do {
            if a.expiresAt < .now.addingTimeInterval(120) {
                let t = try await api.refresh(a.refreshToken)
                a.accessToken = t.accessToken
                a.refreshToken = t.refreshToken ?? a.refreshToken
                a.expiresAt = .now.addingTimeInterval(t.expiresIn)
                upsert(a)
            }
            status[id] = Status(usage: try await api.usage(accessToken: a.accessToken))
        } catch let e as APIError {
            if e.status == 401 {
                // Access token revoked early; force a refresh on the next poll.
                a.expiresAt = .distantPast
                upsert(a)
            }
            status[id, default: Status()].error = e.needsLogin ? "授权失效，请在 ⋯ 菜单里重新登录" : e.localizedDescription
        } catch {
            status[id, default: Status()].error = error.localizedDescription
        }
    }

    /// Browser OAuth via a loopback redirect. The org picked in the browser decides which account this is.
    func addAccount() async {
        guard loginServer == nil else { return }
        loginError = nil
        do {
            let server = try LoopbackServer()
            loginServer = server
            defer {
                server.stop()
                loginServer = nil
            }
            let port = try await server.start()
            let redirect = "http://localhost:\(port)/callback"
            let pkce = PKCE()
            NSWorkspace.shared.open(pkce.authorizeURL(redirectURI: redirect))

            let timeout = Task {
                try await Task.sleep(for: .seconds(300))
                server.stop()
            }
            defer { timeout.cancel() }
            let query = try await server.callback()

            if let err = query["error"] {
                throw LoginError("登录失败：\(query["error_description"] ?? err)")
            }
            guard query["state"] == pkce.state, let raw = query["code"] else {
                throw LoginError("登录回调参数不匹配")
            }
            let code = String(raw.split(separator: "#").first ?? "")
            let t = try await api.exchange(code: code, pkce: pkce, redirectURI: redirect)
            guard let refreshToken = t.refreshToken else { throw LoginError("登录未返回 refresh token") }
            let org = try await api.profile(accessToken: t.accessToken).organization
            let account = Account(
                id: org.uuid, name: org.name, accessToken: t.accessToken,
                refreshToken: refreshToken, expiresAt: .now.addingTimeInterval(t.expiresIn))
            upsert(account)
            await refresh(account.id)
        } catch is CancellationError {
        } catch {
            loginError = error.localizedDescription
        }
    }

    func cancelLogin() { loginServer?.stop() }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        status[id] = nil
        persist()
    }

    private func upsert(_ a: Account) {
        if let i = accounts.firstIndex(where: { $0.id == a.id }) { accounts[i] = a } else { accounts.append(a) }
        persist()
    }

    private func persist() {
        do { try Vault.save(accounts) } catch { loginError = "保存到钥匙串失败：\(error.localizedDescription)" }
    }
}
