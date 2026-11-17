import SwiftUI
import UsageCore

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Task {
                await snapshot(to: args[i + 1])
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--status") {
            Task {
                await printStatus()
                exit(0)
            }
            RunLoop.main.run()
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
        print("[\(a.provider.rawValue)] \(a.displayName)")
        guard a.expiresAt > .now else {
            print("  access token 已过期，等菜单栏 App 刷新")
            continue
        }
        do {
            let usage = switch a.provider {
            case .claude: try await ClaudeAPI().usage(accessToken: a.accessToken)
            case .codex: try await CodexAPI().usage(accessToken: a.accessToken, accountID: a.id)
            case .kimi: try await KimiAPI().usage(apiKey: a.accessToken)
            case .sub2api: try await Sub2API().usage(baseURL: a.baseURL ?? "", apiKey: a.accessToken).usage
            case .grok:
                if let c = GrokCredential.load() {
                    try await GrokAPI().usage(accessToken: c.accessToken)
                } else {
                    throw LoginError("未找到 grok 登录")
                }
            }
            for l in usage.limits {
                let reset = l.resetDate.flatMap { countdown(to: $0) } ?? "—"
                print("  \(l.title)\t\(Int(l.percent.rounded()))%\t\(reset)")
            }
            if let note = usage.note { print("  \(note)") }
        } catch {
            print("  错误：\(error.localizedDescription)")
        }
    }
}

/// Renders the panel with live usage to a PNG and prints its size, using the
/// saved display settings (compact, hidden names). Read-only like `--status`.
@MainActor func snapshot(to path: String) async {
    _ = NSApplication.shared
    let store = Store(readOnly: true)
    await store.refreshAll()
    let host = NSHostingView(rootView: UsagePanel(store: store))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = host
    // The list height is measured on the first layout pass; let it settle before capturing.
    for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
    }
    let size = host.fittingSize
    window.setContentSize(size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("panel \(Int(size.width))x\(Int(size.height)) pt, screen \(Int(NSScreen.main?.visibleFrame.height ?? 0)) pt")
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
    @AppStorage("compact") private var compact = false
    @State private var keyForm: Provider?
    @State private var listHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0

    /// Leaves room for the header and footer so the panel never outgrows the screen.
    private var maxListHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 160 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack {
                Text("AI 用量").font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { compact.toggle() }
                } label: {
                    Image(systemName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .buttonStyle(.borderless)
                .help(compact ? "展开显示" : "紧凑显示")
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
                Text("还没有账号。点「添加账号」选择服务商。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: compact ? 6 : 10) {
                    ForEach(store.accounts) { account in
                        AccountCard(account: account, status: store.status[account.id], store: store,
                                    hideName: hideNames, compact: compact)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, maxListHeight))

            if let provider = keyForm {
                KeyForm(provider: provider, store: store) { keyForm = nil }
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
                        Button("Kimi Code…") { keyForm = .kimi }
                        Button("Grok（读取 grok CLI 登录）") { Task { await store.addAccount(.grok) } }
                        Button("sub2api…") { keyForm = .sub2api }
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
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .background(WindowHeight(height: panelHeight))
        .onAppear { store.refreshIfStale() }
    }
}

struct AccountCard: View {
    let account: Account
    let status: Store.Status?
    let store: Store
    let hideName: Bool
    let compact: Bool
    @State private var dropTargeted = false
    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var collapsed: Bool { compact && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title
                Spacer(minLength: 4)
                if collapsed { summary }
                menu
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard compact, !editing else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
            if !collapsed { details }
        }
        .padding(compact ? 8 : 10)
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

    private var menu: some View {
        Menu {
            Button("重命名…") {
                draft = account.displayName
                editing = true
            }
            if account.provider == .claude || account.provider == .codex {
                Button("重新登录") { Task { await store.addAccount(account.provider) } }
            }
            Button("移除", role: .destructive) { store.remove(account.id) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var details: some View {
        if let usage = status?.usage {
            ForEach(usage.limits) { LimitRow(limit: $0) }
            if let note = usage.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } else if status == nil {
            ProgressView().controlSize(.small)
        }
        if let e = status?.error {
            Text(e).font(.caption).foregroundStyle(.red)
        }
    }

    /// Collapsed row: the first two windows (5-hour and weekly for most providers) as mini bars.
    @ViewBuilder private var summary: some View {
        if let usage = status?.usage {
            if usage.limits.isEmpty, let note = usage.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(usage.limits.prefix(2)) { MiniBar(limit: $0) }
        } else if status == nil {
            ProgressView().controlSize(.mini)
        }
        if let e = status?.error {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
        }
    }

    private var title: some View {
        HStack(spacing: 6) {
            ProviderLogo(provider: account.provider)
            if editing {
                TextField(account.name, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused, editing { commitRename() }
                    }
            } else {
                // Hidden names are replaced, not only blurred: a blur filter is skipped by
                // offscreen captures (--snapshot) and can leave text guessable.
                Text(hideName ? "••••••••••" : account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .blur(radius: hideName ? 4 : 0)
                    .animation(.easeInOut(duration: 0.2), value: hideName)
                    .help(account.alias == nil || hideName ? "" : account.name)
            }
        }
    }

    private func commitRename() {
        store.rename(account.id, to: draft)
        editing = false
    }
}

/// MenuBarExtra windows grow with their content but do not shrink back, so a
/// switch to compact mode would leave an empty, screen-tall panel. Pin the
/// window to the content height, keeping its top edge under the menu bar.
struct WindowHeight: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            var frame = window.frame
            let delta = height - window.contentRect(forFrameRect: frame).height
            guard abs(delta) > 0.5 else { return }
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true)
        }
    }
}

struct LimitRow: View {
    let limit: Limit

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(spacing: 8) {
                Text(limit.title).font(.caption).frame(width: 84, alignment: .leading)
                UsageBar(percent: limit.percent, tint: limit.tint)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                Text(limit.resetDate.flatMap { countdown(to: $0, now: ctx.date) } ?? "—")
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}

struct MiniBar: View {
    let limit: Limit

    var body: some View {
        HStack(spacing: 3) {
            UsageBar(percent: limit.percent, tint: limit.tint).frame(width: 40)
            Text("\(Int(limit.percent.rounded()))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 32, alignment: .trailing)
        }
        .help("\(limit.title) · \(limit.resetDate.flatMap { countdown(to: $0) }.map { "\($0)后重置" } ?? "无重置时间")")
    }
}

/// Drawn in SwiftUI rather than NSProgressIndicator so it keeps its color in
/// inactive and offscreen windows.
struct UsageBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: percent > 0 ? max(g.size.width * min(percent, 100) / 100, 5) : 0)
            }
        }
        .frame(height: 5)
    }
}

extension Limit {
    var tint: Color { percent >= 90 ? .red : percent >= 70 ? .orange : .green }
}

struct ProviderLogo: View {
    let provider: Provider

    // Template SVGs (simple-icons, lobe-icons), bundled into Contents/Resources by scripts/bundle.sh.
    private static let images: [Provider: NSImage] = {
        var out: [Provider: NSImage] = [:]
        for (p, file) in [(Provider.claude, "claude"), (.codex, "openai"), (.kimi, "kimi"), (.grok, "grok")] {
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
                Image(systemName: provider == .sub2api ? "server.rack" : "circle.hexagongrid").resizable().scaledToFit()
            }
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(provider == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
        .help(provider.displayName)
    }
}

/// Inline form for API-key providers; the key is checked against the usage endpoint before saving.
struct KeyForm: View {
    let provider: Provider
    let store: Store
    let done: () -> Void
    @State private var key = ""
    @State private var baseURL = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider)
                Text("添加 \(provider.displayName)").font(.subheadline.weight(.semibold))
            }
            if provider == .sub2api {
                TextField("部署地址，例如 https://sub2api.example.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField(provider == .kimi ? "Kimi Code API key（sk-kimi-…）" : "分组 API key（sk-…）", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", action: done)
                Button("保存") {
                    saving = true
                    Task {
                        if await store.addKeyAccount(provider, key: key, baseURL: baseURL) { done() }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || key.isEmpty || (provider == .sub2api && baseURL.isEmpty))
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
