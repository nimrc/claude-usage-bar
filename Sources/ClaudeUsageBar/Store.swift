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

    private let claude = ClaudeAPI()
    private let codex = CodexAPI()

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
                let t = try await a.provider == .claude ? claude.refresh(a.refreshToken) : codex.refresh(a.refreshToken)
                a.accessToken = t.accessToken
                a.refreshToken = t.refreshToken ?? a.refreshToken
                a.expiresAt = t.expiresAt
                upsert(a)
            }
            let usage = switch a.provider {
            case .claude: try await claude.usage(accessToken: a.accessToken)
            case .codex: try await codex.usage(accessToken: a.accessToken, accountID: a.id)
            }
            status[id] = Status(usage: usage)
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

    /// Browser OAuth via a loopback redirect. The org/workspace picked in the browser decides which account this is.
    func addAccount(_ provider: Provider) async {
        guard loginServer == nil else { return }
        loginError = nil
        do {
            let pkce = PKCE()
            let account: Account
            switch provider {
            case .claude:
                let (code, redirect) = try await authorize(pkce: pkce, ports: [nil], path: ClaudeOAuth.callbackPath) {
                    ClaudeOAuth.authorizeURL(pkce: pkce, redirectURI: "http://localhost:\($0)\(ClaudeOAuth.callbackPath)")
                }
                let t = try await claude.exchange(code: code, pkce: pkce, redirectURI: redirect)
                guard let refreshToken = t.refreshToken else { throw LoginError("登录未返回 refresh token") }
                let org = try await claude.profile(accessToken: t.accessToken).organization
                account = Account(provider: .claude, id: org.uuid, name: org.name, accessToken: t.accessToken,
                                  refreshToken: refreshToken, expiresAt: t.expiresAt)
            case .codex:
                let (code, redirect) = try await authorize(pkce: pkce, ports: CodexOAuth.ports, path: CodexOAuth.callbackPath) {
                    CodexOAuth.authorizeURL(pkce: pkce, redirectURI: CodexOAuth.redirectURI(port: $0))
                }
                let t = try await codex.exchange(code: code, pkce: pkce, redirectURI: redirect)
                guard let refreshToken = t.refreshToken, let identity = t.idToken.flatMap(CodexIdentity.init(idToken:)) else {
                    throw LoginError("登录未返回完整的 token")
                }
                account = Account(provider: .codex, id: identity.accountID, name: identity.label, accessToken: t.accessToken,
                                  refreshToken: refreshToken, expiresAt: t.expiresAt)
            }
            upsert(account)
            await refresh(account.id)
        } catch is CancellationError {
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Binds the first free port, opens the browser, and returns (code, redirect URI).
    private func authorize(pkce: PKCE, ports: [UInt16?], path: String, url: (UInt16) -> URL) async throws -> (String, String) {
        var bound: (LoopbackServer, UInt16)?
        var lastError: Error?
        for p in ports {
            do {
                let s = try LoopbackServer(port: p, path: path)
                bound = (s, try await s.start())
                break
            } catch {
                lastError = error
            }
        }
        guard let (server, port) = bound else {
            throw LoginError("回调端口被占用：\(lastError?.localizedDescription ?? "")")
        }
        loginServer = server
        defer {
            server.stop()
            loginServer = nil
        }
        let authURL = url(port)
        NSWorkspace.shared.open(authURL)

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
        let redirect = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value ?? ""
        return (String(raw.split(separator: "#").first ?? ""), redirect)
    }

    func cancelLogin() { loginServer?.stop() }

    func move(_ id: String, onto target: String) {
        accounts.move(id: id, onto: target)
        persist()
    }

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
