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
        print(a.name)
        guard a.expiresAt > .now else {
            print("  access token 已过期，等菜单栏 App 刷新")
            continue
        }
        do {
            for l in try await ClaudeAPI().usage(accessToken: a.accessToken).limits {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude 用量").font(.headline)
                Spacer()
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
                Text("还没有账号。点「添加账号」，在浏览器里登录并选择组织。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { account in
                AccountCard(account: account, status: store.status[account.id], store: store)
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
                    Button("添加账号") { Task { await store.addAccount() } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name).font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("重新登录") { Task { await store.addAccount() } }
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
