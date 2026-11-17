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
    private let kimi = KimiAPI()
    private let sub2api = Sub2API()
    private let grok = GrokAPI()

    /// Read-only stores (CLI snapshots) never refresh tokens or write the keychain,
    /// so they cannot rotate a refresh token out from under the running app.
    private let readOnly: Bool

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        if !readOnly { Task { await pollLoop() } }
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
            let oauth = a.provider == .claude || a.provider == .codex
            if oauth, !readOnly, a.expiresAt < .now.addingTimeInterval(120) {
                let t = try await a.provider == .claude ? claude.refresh(a.refreshToken) : codex.refresh(a.refreshToken)
                a.accessToken = t.accessToken
                a.refreshToken = t.refreshToken ?? a.refreshToken
                a.expiresAt = t.expiresAt
                upsert(a)
            }
            let usage = switch a.provider {
            case .claude: try await claude.usage(accessToken: a.accessToken)
            case .codex: try await codex.usage(accessToken: a.accessToken, accountID: a.id)
            case .kimi: try await kimi.usage(apiKey: a.accessToken)
            case .sub2api: try await sub2api.usage(baseURL: a.baseURL ?? "", apiKey: a.accessToken).usage
            case .grok: try await grokUsage()
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
            case .kimi, .sub2api:
                return
            case .grok:
                guard let c = GrokCredential.load() else {
                    throw LoginError("未找到 grok CLI 登录（~/.grok/auth.json），先在终端运行 grok login")
                }
                account = Account(provider: .grok, id: "grok:\(c.userID)", name: c.email ?? "Grok",
                                  accessToken: "", refreshToken: "", expiresAt: .distantFuture)
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

    private func grokUsage() async throws -> Usage {
        guard let c = GrokCredential.load() else { throw LoginError("未找到 grok 登录，请在终端运行 grok login") }
        if let e = c.expiresAt, e < .now { throw LoginError("grok 登录已过期，运行一次 grok 即可续期") }
        return try await grok.usage(accessToken: c.accessToken)
    }

    /// Validates the key against the usage endpoint before saving it. Returns whether it was added.
    func addKeyAccount(_ provider: Provider, key rawKey: String, baseURL rawBase: String) async -> Bool {
        loginError = nil
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            loginError = "API key 为空"
            return false
        }
        do {
            let name: String
            var base: String?
            switch provider {
            case .kimi:
                _ = try await kimi.usage(apiKey: key)
                name = "Kimi Code ··\(key.suffix(4))"
            case .sub2api:
                guard let b = Sub2API.normalize(baseURL: rawBase) else {
                    loginError = "地址需要是 https://…（本机部署可用 http://127.0.0.1:端口）"
                    return false
                }
                let plan = try await sub2api.usage(baseURL: b, apiKey: key).planName
                base = b
                name = "\(plan ?? URL(string: b)?.host ?? "sub2api") ··\(key.suffix(4))"
            case .claude, .codex, .grok:
                return false
            }
            let a = Account(provider: provider, id: keyAccountID(provider, key), name: name, accessToken: key,
                            refreshToken: "", expiresAt: .distantFuture, baseURL: base)
            upsert(a)
            await refresh(a.id)
            return true
        } catch {
            loginError = "验证失败：\(error.localizedDescription)"
            return false
        }
    }

    func rename(_ id: String, to alias: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].alias = trimmed.isEmpty || trimmed == accounts[i].name ? nil : trimmed
        persist()
    }

    func move(_ id: String, onto target: String) {
        accounts.move(id: id, onto: target)
        persist()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        status[id] = nil
        persist()
    }

    /// The alias is owned by `rename`: a re-login or a token refresh started before
    /// a rename must not overwrite it.
    private func upsert(_ a: Account) {
        if let i = accounts.firstIndex(where: { $0.id == a.id }) {
            var a = a
            a.alias = accounts[i].alias
            accounts[i] = a
        } else {
            accounts.append(a)
        }
        persist()
    }

    private func persist() {
        guard !readOnly else { return }
        do { try Vault.save(accounts) } catch { loginError = "保存到钥匙串失败：\(error.localizedDescription)" }
    }
}
