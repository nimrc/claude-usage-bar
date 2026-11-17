import SwiftUI
import UsageCore

@main
enum Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--status") {
            Task {
                await printStatus()
                exit(0)
            }
            dispatchMain()
        }
        ClaudeUsageBarApp.main()
    }
}

/// Read-only: uses stored access tokens and never refreshes, so it cannot
/// rotate a refresh token out from under the running menu bar app.
func printStatus() async {
    let accounts = Vault.load()
    if accounts.isEmpty { print("没有账号") }
    for a in accounts {
        print("[\(a.provider.rawValue)] \(a.name)")
        guard a.expiresAt > .now else {
            print("  access token 已过期，等菜单栏 App 刷新")
            continue
        }
        do {
            let usage = switch a.provider {
            case .claude: try await ClaudeAPI().usage(accessToken: a.accessToken)
            case .codex: try await CodexAPI().usage(accessToken: a.accessToken, accountID: a.id)
            }
            for l in usage.limits {
                let reset = l.resetDate.flatMap { countdown(to: $0) } ?? "—"
                print("  \(l.title)\t\(Int(l.percent.rounded()))%\t\(reset)")
            }
        } catch {
            print("  错误：\(error.localizedDescription)")
        }
    }
}

struct ClaudeUsageBarApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsagePanel: View {
    @Bindable var store: Store
    @AppStorage("hideNames") private var hideNames = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 用量").font(.headline)
                Spacer()
                Toggle(isOn: $hideNames) {
                    Image(systemName: hideNames ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("隐藏账号名称")
                if let t = store.lastUpdated {
                    Text(t, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.refreshing)
            }

            if store.accounts.isEmpty {
                Text("还没有账号。点「添加账号」选择 Claude 或 Codex，在浏览器里登录并选择组织。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { account in
                AccountCard(account: account, status: store.status[account.id], store: store, hideName: hideNames)
            }

            if let e = store.loginError {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                if store.isLoggingIn {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器登录…").font(.callout)
                    Button("取消") { store.cancelLogin() }
                } else {
                    Menu("添加账号") {
                        Button("Claude") { Task { await store.addAccount(.claude) } }
                        Button("Codex") { Task { await store.addAccount(.codex) } }
                    }
                    .fixedSize()
                }
                Spacer()
                Toggle("开机启动", isOn: $store.launchAtLogin).toggleStyle(.checkbox)
                Button("退出") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { store.refreshIfStale() }
    }
}

struct AccountCard: View {
    let account: Account
    let status: Store.Status?
    let store: Store
    let hideName: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title
                Spacer()
                Menu {
                    Button("重新登录") { Task { await store.addAccount(account.provider) } }
                    Button("移除", role: .destructive) { store.remove(account.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let usage = status?.usage {
                ForEach(usage.limits) { LimitRow(limit: $0) }
            } else if status == nil {
                ProgressView().controlSize(.small)
            }
            if let e = status?.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(dropTargeted ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .draggable(account.id) {
            title.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            withAnimation(.easeInOut(duration: 0.2)) { store.move(id, onto: account.id) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var title: some View {
        HStack(spacing: 6) {
            ProviderLogo(provider: account.provider)
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .blur(radius: hideName ? 6 : 0)
                .animation(.easeInOut(duration: 0.2), value: hideName)
        }
    }
}

struct LimitRow: View {
    let limit: Limit

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(spacing: 8) {
                Text(limit.title).font(.caption).frame(width: 84, alignment: .leading)
                ProgressView(value: min(limit.percent, 100), total: 100).tint(color)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                Text(limit.resetDate.flatMap { countdown(to: $0, now: ctx.date) } ?? "—")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var color: Color {
        limit.percent >= 90 ? .red : limit.percent >= 70 ? .orange : .green
    }
}

struct ProviderLogo: View {
    let provider: Provider

    // Template SVGs from simple-icons, bundled into Contents/Resources by scripts/bundle.sh.
    private static let images: [Provider: NSImage] = {
        var out: [Provider: NSImage] = [:]
        for (p, file) in [(Provider.claude, "claude"), (.codex, "openai")] {
            if let url = Bundle.main.url(forResource: file, withExtension: "svg"), let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                out[p] = img
            }
        }
        return out
    }()

    var body: some View {
        Group {
            if let img = Self.images[provider] {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: provider == .claude ? "sparkle" : "circle.hexagongrid")
            }
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(provider == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
        .help(provider == .claude ? "Claude" : "Codex")
    }
}
