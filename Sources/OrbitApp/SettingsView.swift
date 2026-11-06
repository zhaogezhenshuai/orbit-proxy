import AppKit
import OrbitCore
import SwiftUI

struct SettingsView: View {
    enum Tab: CaseIterable {
        case general, network, rules, appearance

        var title: String {
            switch self {
            case .general: return L("通用", "General")
            case .network: return L("网络", "Network")
            case .rules: return L("规则", "Rules")
            case .appearance: return L("外观", "Appearance")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .network: return "network"
            case .rules: return "list.bullet.rectangle"
            case .appearance: return "paintbrush"
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @State private var draft = OrbitSettings()
    @State private var rulesText = ""
    @State private var launchAtLogin = false
    @State private var loaded = false
    @State private var justSaved = false
    @State private var tab: Tab
    let height: CGFloat

    init(height: CGFloat = 600, tab: Tab = .general) {
        self.height = height
        _tab = State(initialValue: tab)
    }

    /// The form as it would be saved; compared with the live settings to light up the Save button.
    private var form: OrbitSettings {
        var s = draft
        s.customRules = rulesText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return model.formSettings(s)
    }

    private var dirty: Bool { form != model.settings || launchAtLogin != model.launchAtLogin }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general: general
                case .network: network
                case .rules: rules
                case .appearance: appearance
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .frame(width: 480, height: height)
        .navigationTitle(L("Orbit 设置", "Orbit Settings"))
        .id(model.english)
        .background(WindowCloseGuard(shouldClose: confirmClose))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            reset()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                TabButton(title: t.title, icon: t.icon, selected: tab == t) { tab = t }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var general: some View {
        Form {
            SourcesSection()
            Section(L("启动", "Startup")) {
                Toggle(L("启动 Orbit 时自动连接", "Connect when Orbit starts"), isOn: $draft.connectOnLaunch)
                Toggle(L("登录时启动 Orbit", "Open Orbit at login"), isOn: $launchAtLogin)
            }
            Section(L("关于", "About")) {
                LabeledContent("Orbit", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                VStack(alignment: .leading, spacing: 6) {
                    // GPL-3.0 section 0 "Appropriate Legal Notices" for interactive interfaces.
                    Text(L("Orbit 是自由软件，按 GNU GPL v3 许可发布，不提供任何担保。内核 mihomo、规则集等组件的许可证见「开源许可」。",
                           "Orbit is free software under the GNU GPL v3, with absolutely no warranty. See Open Source Licenses for mihomo, the rule sets and other components."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("开源许可…", "Open Source Licenses…")) { openLicenses() }
                }
            }
        }
    }

    private func openLicenses() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
              FileManager.default.fileExists(atPath: dir.path) else { return }
        NSWorkspace.shared.open(dir)
    }

    private var network: some View {
        Form {
            Section(L("本地端口", "Local Ports")) {
                PortField(title: L("代理端口 (HTTP+SOCKS5)", "Proxy port (HTTP+SOCKS5)"), value: $draft.mixedPort)
                PortField(title: L("控制端口", "Controller port"), value: $draft.controllerPort)
                Toggle(L("允许局域网连接", "Allow LAN connections"), isOn: $draft.allowLAN)
            }
            if draft.allowLAN { lanSection }
            Section(L("测速", "Latency Test")) {
                FieldRow(title: L("测速地址", "Latency test URL"), text: $draft.testURL,
                         note: L("测速时经节点访问这个地址并计时。", "Each test fetches this URL through the node and times it."))
            }
        }
    }

    /// Credentials and address other devices use; this Mac connects without them.
    private var lanSection: some View {
        Section {
            LabeledContent(L("用户名", "User name")) {
                HStack(spacing: 4) {
                    TextField("", text: $draft.lanUser)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(width: 180)
                    lanButtons.hidden()  // keeps both fields the same width and aligned
                }
            }
            LabeledContent(L("密码", "Password")) {
                HStack(spacing: 4) {
                    TextField("", text: $draft.lanPassword)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(width: 180)
                    lanButtons
                }
            }
        } header: {
            Text(L("局域网连接认证", "LAN Authentication"))
        } footer: {
            Text(lanNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lanButtons: some View {
        HStack(spacing: 4) {
            Button { draft.lanPassword = OrbitSettings.randomPassword() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("生成新密码", "Generate a new password"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.lanPassword, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(L("复制密码", "Copy password"))
        }
    }

    private var lanNote: String {
        L("其他设备设置 HTTP 或 SOCKS5 代理，服务器填本机局域网 IP，端口填代理端口，并填写用户名和密码。",
          "On other devices, set an HTTP or SOCKS5 proxy with this Mac's LAN IP and the proxy port, plus the user name and password.")
    }

    private var rules: some View {
        Form {
            Section {
                Toggle(L("屏蔽广告域名", "Block ad domains"), isOn: $draft.blockAds)
            }
            Section {
                TextEditor(text: $rulesText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    .overlay(alignment: .topLeading) {
                        if rulesText.isEmpty {
                            Text("DOMAIN-SUFFIX,example.com,PROXY")
                                .font(.system(.callout, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text(L("自定义规则", "Custom Rules"))
            } footer: {
                Text(L("每行一条 mihomo 规则，优先于内置规则。例：DOMAIN-SUFFIX,example.com,PROXY 或 DOMAIN-KEYWORD,bank,DIRECT",
                       "One mihomo rule per line, applied before the built-in rules. e.g. DOMAIN-SUFFIX,example.com,PROXY or DOMAIN-KEYWORD,bank,DIRECT"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appearance: some View {
        Form {
            Section(L("界面", "Interface")) {
                Picker(L("语言", "Language"), selection: $draft.language) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Picker(L("外观", "Theme"), selection: $draft.appearance) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text(L("浅色", "Light")).tag("light")
                    Text(L("深色", "Dark")).tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section(L("显示", "Display")) {
                Toggle(L("节点列表显示服务器 IP", "Show server IP in node list"), isOn: $draft.showServerIP)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L("菜单栏显示实时网速", "Show live speed in the menu bar"), isOn: $draft.menuBarSpeed)
                    Text(L("连接时在菜单栏图标旁显示上传、下载速度。", "While connected, upload and download speeds appear next to the menu bar icon."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if dirty {
                    Label(L("有未保存的更改", "Unsaved changes"), systemImage: "circle.fill")
                        .labelStyle(DotLabelStyle())
                } else if justSaved {
                    Label(L("已保存", "Saved"), systemImage: "checkmark").foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("还原", "Revert"), action: reset)
                    .buttonStyle(BarButtonStyle(prominent: false))
                    .disabled(!dirty)
                Button(L("保存", "Save"), action: save)
                    .buttonStyle(BarButtonStyle(prominent: true))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.15), value: dirty)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reset() {
        draft = model.settings
        rulesText = draft.customRules.joined(separator: "\n")
        launchAtLogin = model.launchAtLogin
    }

    private func save() {
        guard dirty else { return }
        let s = form
        if launchAtLogin != model.launchAtLogin { model.launchAtLogin = launchAtLogin }
        launchAtLogin = model.launchAtLogin  // registration can fail; show what actually happened
        draft = s
        rulesText = s.customRules.joined(separator: "\n")
        Task { await model.applySettings(s) }
        justSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            justSaved = false
        }
    }

    /// Closing with unsaved changes asks first; Save / Don't Save close the window afterwards.
    private func confirmClose(_ window: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("要保存对设置的更改吗？", "Save changes to settings?")
        alert.informativeText = L("如果不保存，所做的更改将会丢失。", "If you don't save, your changes will be lost.")
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("不保存", "Don't Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.beginSheetModal(for: window) { r in
            switch r {
            case .alertFirstButtonReturn: save(); window.close()
            case .alertSecondButtonReturn: reset(); window.close()
            default: break
            }
        }
        return false
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(Color.accentColor)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// Bottom-bar button. The prominent one takes the accent colour (the same blue as switched-on
/// controls) only while there is something to save, and deepens on hover.
struct BarButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration, prominent: prominent)
    }

    struct BarButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let filled = prominent && enabled
            configuration.label
                .fontWeight(filled ? .semibold : .regular)
                .foregroundStyle(filled ? Color.white : enabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .frame(minWidth: 76, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(filled ? Color.accentColor : Color.primary.opacity(enabled ? (hovering ? 0.12 : 0.07) : 0.04))
                        .brightness(filled ? (configuration.isPressed ? -0.16 : hovering ? -0.08 : 0) : 0)
                )
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(filled ? 0 : 0.1)))
                .opacity(enabled ? 1 : 0.7)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { h in hovering = h }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.15), value: enabled)
        }
    }
}

/// Port number field that updates its binding as you type (so unsaved changes show at once).
private struct PortField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField("", text: Binding(
                get: { String(value) },
                set: { t in if let v = Int(t.filter(\.isNumber).prefix(5)), (1...65535).contains(v) { value = v } }
            ))
            .textFieldStyle(.roundedBorder).labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
        }
    }
}

/// Label above a full-width bordered text field, with an optional note below; for long values
/// like URLs, which right-aligned plain form fields don't show as editable.
struct FieldRow: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            TextField("", text: $text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.roundedBorder).labelsHidden()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Icon-over-title tab in the settings window's top bar.
private struct TabButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17)).frame(height: 20)
                Text(title).font(.caption)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 76, height: 46)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Asks `shouldClose` before the hosting window closes, forwarding every other delegate call to
/// SwiftUI's own window delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: (NSWindow) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.shouldClose = shouldClose
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        if context.coordinator.window == nil {
            DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: ((NSWindow) -> Bool)?
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?

        func attach(to w: NSWindow?) {
            guard let w, window == nil, w.delegate !== self else { return }
            window = w
            original = w.delegate
            w.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose?(sender) ?? true else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to sel: Selector!) -> Bool {
            super.responds(to: sel) || (original?.responds(to: sel) ?? false)
        }

        override func forwardingTarget(for sel: Selector!) -> Any? {
            original?.responds(to: sel) == true ? original : super.forwardingTarget(for: sel)
        }
    }
}

/// Integer input that accepts typing (clamped to `range`), stepper arrows and the scroll wheel
/// while the pointer is over it.
struct IntField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @State private var monitor: Any?
    @State private var scrollAccumulator: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { f in if !f { commit() } }
                .onChange(of: text) { t in
                    // Digits only; values above the limit snap down while typing.
                    let digits = String(t.filter(\.isNumber).prefix(4))
                    if digits != t { text = digits; return }
                    if let v = Int(digits) {
                        if v > range.upperBound { set(range.upperBound) } else if v >= range.lowerBound { value = v }
                    }
                }
            Stepper("", value: Binding(get: { value }, set: { set($0) }), in: range).labelsHidden()
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { v in if Int(text) != v { text = String(v) } }
        .onHover { inside in inside ? startScroll() : stopScroll() }
        .onDisappear(perform: stopScroll)
    }

    private func set(_ v: Int) {
        value = min(max(v, range.lowerBound), range.upperBound)
        text = String(value)
    }

    private func commit() { set(Int(text) ?? value) }

    private func startScroll() {
        guard monitor == nil else { return }
        scrollAccumulator = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            // A mouse wheel notch is one step; trackpads report many small deltas, so accumulate.
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
            scrollAccumulator += dy
            while abs(scrollAccumulator) >= 1 {
                let up = scrollAccumulator > 0
                set(value + (up ? 1 : -1))
                scrollAccumulator += up ? -1 : 1
            }
            return nil  // keep the form from scrolling while adjusting the number
        }
    }

    private func stopScroll() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
