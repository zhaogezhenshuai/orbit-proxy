import OrbitCore
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            Group {
                if model.needsSubscription {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        nodeToolbar.zIndex(2)  // keeps its tooltips above the list
                        if model.regions.count > 1 { RegionBar().zIndex(1) }
                        nodeList
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // Notices float over the list instead of pushing the rest of the panel around.
            .overlay(alignment: .bottom) { toast }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.message)
            Divider()
            footer.zIndex(1)
        }
        .frame(width: 380, height: 600)
        .background(ResignFocusOnOutsideClick())
        // Rebuild every row when the language changes; rows don't observe the model themselves.
        .id(model.english)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: model.isOn ? "paperplane.circle.fill" : "paperplane.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(model.isOn ? Color.accentColor : .secondary)
                    .animation(.easeInOut, value: model.isOn)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Orbit").font(.headline)
                        StatusPill(phase: phase)
                    }
                    Text(model.isOn ? model.currentNodeTitle : model.selectedTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { _ in Task { await model.toggle() } }))
                    .toggleStyle(AccentSwitchStyle(width: 36, height: 20)).labelsHidden().disabled(model.busy)
                    .hoverTip(model.isOn ? L("断开连接", "Disconnect") : L("连接", "Connect"), alignment: .bottomTrailing)
            }
            .zIndex(2)  // the toggle's tip hangs over the speed / exit IP row below
            if model.isOn {
                HStack(spacing: 6) {
                    // Fixed widths: speeds change every second and must not squeeze the exit IP.
                    Label(Format.speed(model.up), systemImage: "arrow.up").font(.caption.monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.8).frame(width: 70, alignment: .leading)
                    Label(Format.speed(model.down), systemImage: "arrow.down").font(.caption.monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.8).frame(width: 70, alignment: .leading)
                    Spacer(minLength: 4)
                    ExitIPView().layoutPriority(1)  // take its room before the spacer
                }
                .foregroundStyle(.secondary)
                .zIndex(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .zIndex(3)  // the exit-IP details tip hangs over the controls below
    }

    private var phase: StatusPill.Phase {
        if model.busy { return model.isOn ? .disconnecting : .connecting }
        return model.isOn ? .on : .off
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 8) {
            ModePicker(selection: Binding(get: { model.mode }, set: { m in Task { await model.setMode(m) } }))
                .hoverTip(L("规则：国内直连、国外走代理　全局：全部走代理　直连：全部不走代理",
                            "Rule: China direct, rest proxied · Global: all proxied · Direct: no proxy"), alignment: .bottom)
                .zIndex(2)  // tooltips must draw above the rows below, not under them
            HStack {
                Toggle(L("系统代理", "System Proxy"), isOn: Binding(get: { model.systemProxy }, set: { model.setSystemProxy($0) }))
                    .hoverTip(L("让浏览器等应用通过 Orbit 上网", "Route browsers and other apps through Orbit"), alignment: .bottomLeading)
                Spacer()
                Toggle(L("增强模式 (TUN)", "Enhanced Mode (TUN)"), isOn: Binding(get: { model.tun }, set: { v in Task { await model.setTun(v) } }))
                    .hoverTip(L("接管所有流量（含终端、游戏），需要管理员密码", "Capture all traffic (terminal, games too); needs admin password"),
                              alignment: .bottomTrailing)
            }
            // Small switches, matching the connect switch above.
            .toggleStyle(AccentSwitchStyle(width: 28, height: 16)).font(.callout)
            .zIndex(1)
            if let src = model.activeSource {
                SubscriptionCard(source: src, sources: model.settings.sources, info: model.info ?? SubscriptionInfo(),
                                 updated: model.updatedAt, nodeCount: model.nodes.count,
                                 onSwitch: { id in Task { await model.activateSource(id) } }, onManage: openSettings)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .zIndex(1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "link.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L("还没有节点来源", "No node source yet")).font(.headline)
            Text(L("可以添加订阅地址、导入文件或粘贴节点", "Add a subscription URL, import a file or paste nodes"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("添加节点来源", "Add Node Source")) { openSettings() }.buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var toast: some View {
        if let m = model.message {
            Toast(text: m, style: model.noticeStyle, onClose: model.dismissMessage)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: nodes

    private var nodeToolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜索节点", "Search nodes"), text: $model.search).textFieldStyle(.plain)
                .frame(minWidth: 72)  // status badges must not squeeze it away
            if model.testing {
                if model.diagnosing {
                    DiagnosingBadge(count: model.diagnosingCount)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Text(L("测速中", "Testing") + " \(model.testedCount)/\(model.nodes.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            IconButton(model.sortByDelay ? L("延迟", "Latency") : L("默认", "Default"), systemName: "arrow.up.arrow.down",
                       tip: model.sortByDelay ? L("当前按延迟排序，点击恢复默认顺序", "Sorted by latency; click for default order")
                                              : L("当前为默认顺序，点击按延迟从低到高排序", "Default order; click to sort by latency"),
                       tipAlignment: .bottomTrailing, active: model.sortByDelay) {
                model.toggleSort()
            }
            IconButton(systemName: "speedometer", tip: L("测速全部节点", "Test all nodes"), tipAlignment: .bottomTrailing,
                       spinning: model.testing) {
                Task { await model.testAll() }
            }
            .disabled(model.testing)
            let local = model.activeSource.map { $0.kind != .url } ?? false
            IconButton(systemName: "arrow.clockwise",
                       tip: local ? L("导入的节点不需要更新；要换节点请在设置里编辑来源", "Imported nodes don't update; edit the source in Settings to change them")
                                  : L("更新订阅", "Update subscription"),
                       tipAlignment: .bottomTrailing, rotating: model.updating) {
                Task { await model.updateSubscription() }
            }
            .disabled(model.updating || local)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: model.testing)
    }

    private var nodeList: some View {
        let visible = model.visibleNodes
        return ScrollView {
            LazyVStack(spacing: 2) {
                // Policies don't belong to a region or match a search, so they step aside while filtering.
                if !model.filtering {
                    SectionHeader(title: L("策略", "Policies"))
                    GroupRow(title: L("自动选择", "Auto"),
                             subtitle: model.groupNow[ConfigBuilder.autoGroup] ?? L("按延迟自动挑选最快节点", "Picks the fastest node by latency"),
                             icon: "bolt.fill", selected: model.selected == ConfigBuilder.autoGroup) {
                        Task { await model.select(ConfigBuilder.autoGroup) }
                    }
                    GroupRow(title: L("故障转移", "Fallback"),
                             subtitle: model.groupNow[ConfigBuilder.fallbackGroup] ?? L("按顺序使用第一个可用节点", "Uses the first working node in order"),
                             icon: "arrow.triangle.branch", selected: model.selected == ConfigBuilder.fallbackGroup) {
                        Task { await model.select(ConfigBuilder.fallbackGroup) }
                    }
                }
                SectionHeader(title: L("节点", "Nodes"), trailing: nodeCount(visible))
                ForEach(visible) { node in
                    NodeRow(node: node, delay: model.delays[node.name], repair: model.repairNote(node.name),
                            showServer: model.settings.showServerIP,
                            selected: model.selected == node.name,
                            onTest: { Task { await model.test(node.name) } },
                            onSelect: { Task { await model.select(node.name) } })
                }
                if visible.isEmpty {
                    Text(L("没有匹配的节点", "No matching nodes")).font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    /// "41/47 available" once the shown nodes have been tested, otherwise just how many are shown.
    private func nodeCount(_ list: [ProxyNode]) -> String {
        let tested = list.contains { model.delays[$0.name].map { $0 != .testing } ?? false }
        guard tested, !model.testing else { return "\(list.count)" }
        let ok = list.filter { model.delays[$0.name]?.isOK == true }.count
        return L("\(ok)/\(list.count) 可用", "\(ok)/\(list.count) available")
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "terminal", tip: L("复制终端代理命令（代理地址 127.0.0.1:\(String(model.settings.mixedPort))）",
                                                      "Copy terminal proxy command (proxy at 127.0.0.1:\(String(model.settings.mixedPort)))"),
                       tipAlignment: .topLeading) { model.copyShellExport() }
            IconButton(systemName: "doc.text.magnifyingglass", tip: L("查看内核日志", "View core log"), tipAlignment: .topLeading) { model.openLog() }
            IconButton(systemName: "folder", tip: L("打开配置目录", "Open data folder"), tipAlignment: .topLeading) { model.openDataDir() }
            Spacer()
            IconButton(systemName: "gearshape", tip: L("设置", "Settings"), tipAlignment: .topTrailing) { openSettings() }
            IconButton(systemName: "power", tip: L("退出 Orbit（会断开代理）", "Quit Orbit (disconnects)"), tipAlignment: .topTrailing) { model.quit() }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Ends text editing when the user clicks anywhere in the panel outside a text field. In the menu
/// bar panel a focused search field otherwise keeps its blinking cursor until the panel closes.
struct ResignFocusOnOutsideClick: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.start()
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
                guard let window = self?.view?.window, e.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return e }
                // Clicks on a text field (or its field editor) keep editing; anything else ends it.
                var hit = window.contentView?.hitTest(e.locationInWindow)
                while let v = hit {
                    if v is NSTextField || v === editor { return e }
                    hit = v.superview
                }
                window.makeFirstResponder(nil)
                return e
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Switch that is accent-coloured whenever it's on. The system switch turns grey while its window
/// isn't key (the menu bar panel often isn't), which reads as off.
struct AccentSwitchStyle: ToggleStyle {
    var width: CGFloat = 32
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        AccentSwitchBody(configuration: configuration, width: width, height: height)
    }

    struct AccentSwitchBody: View {
        let configuration: ToggleStyleConfiguration
        let width: CGFloat
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 6) {
                configuration.label
                Capsule()
                    .fill(on ? Color.accentColor : Color.primary.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.1), lineWidth: 0.5))
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .padding(2)
                            .frame(width: height, height: height)
                    }
                    .frame(width: width, height: height)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? L("开", "On") : L("关", "Off"))
        }
    }
}

/// Connection state next to the app name: green when connected, orange while switching.
struct StatusPill: View {
    enum Phase { case on, off, connecting, disconnecting }
    let phase: Phase

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(phase == .off ? Color.secondary : color)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(phase == .off ? 0.1 : 0.15)))
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private var color: Color {
        switch phase {
        case .on: return .green
        case .off: return .secondary
        case .connecting, .disconnecting: return .orange
        }
    }

    private var text: String {
        switch phase {
        case .on: return L("已连接", "Connected")
        case .off: return L("未连接", "Disconnected")
        case .connecting: return L("连接中…", "Connecting…")
        case .disconnecting: return L("断开中…", "Disconnecting…")
        }
    }
}

/// Full-width segmented control for the proxy mode, with a thumb that slides between segments.
struct ModePicker: View {
    @Binding var selection: ProxyMode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProxyMode.allCases, id: \.self) { m in
                Segment(title: m.label, selected: m == selection, ns: ns) { selection = m }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }

    private struct Segment: View {
        let title: String
        let selected: Bool
        let ns: Namespace.ID
        let action: () -> Void
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(scheme == .dark ? Color.white.opacity(0.17) : Color.white)
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        } else if hovering {
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// Notice floating over the bottom of the node list. Info clears itself; errors have a close button.
struct Toast: View {
    let text: String
    let style: NoticeStyle
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch style {
                case .info: Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                case .progress: Spinner(size: 12).padding(.top, 1)
                case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 14)
            Text(text)
                .font(.callout).foregroundStyle(.primary)
                .lineLimit(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if style == .error {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 12, height: 12)
                }
                .buttonStyle(PressableStyle())
                .padding(.top, -3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.45)))
    }

    private var tint: Color { style == .error ? .orange : .accentColor }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            if let trailing { Text(trailing).monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }
}

/// Region chips under the search field: All, the biggest regions, and a toggle for the rest.
struct RegionBar: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = false
    private let collapsedCount = 5

    var body: some View {
        let regions = model.regions
        var shown = expanded ? regions : Array(regions.prefix(collapsedCount))
        if let r = model.regionFilter, !shown.contains(where: { $0.flag == r }), let x = regions.first(where: { $0.flag == r }) {
            shown.append(x)  // keep the active filter visible while collapsed
        }
        let hidden = regions.count - shown.count
        return FlowLayout(spacing: 5, lineSpacing: 5) {
            Chip(selected: model.regionFilter == nil, action: { model.regionFilter = nil }) {
                Text(L("全部", "All"))
                Text("\(model.nodes.count)")
            }
            ForEach(shown, id: \.flag) { r in
                Chip(selected: model.regionFilter == r.flag, action: {
                    model.regionFilter = model.regionFilter == r.flag ? nil : r.flag
                }) {
                    FlagIcon(flag: r.flag, size: 12)
                    Text("\(r.count)")
                }
                .hoverTip(regionName(r.flag), alignment: .bottom)
            }
            if hidden > 0 || expanded {
                Chip(selected: false, action: { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }) {
                    Text(expanded ? L("收起", "Less") : L("更多 \(hidden)", "\(hidden) more"))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func regionName(_ flag: String) -> String {
        flag.isEmpty ? L("其他", "Other") : L10n.locale.localizedString(forRegionCode: FlagCheck.code(flag)) ?? FlagCheck.code(flag)
    }
}

struct Chip<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { content() }
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.1 : 0.055)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? r.width, height: r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (s, p) in zip(subviews, r.points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            width = max(width, x - spacing)
        }
        return (points, width, y + lineHeight)
    }
}

/// Exit IP of the current connection and a refresh button. Click copies the IP; hovering shows
/// everything the lookup returned (location, ISP, ASN).
struct ExitIPView: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let ip = model.exitIP {
                Button(action: model.copyExitIP) {
                    HStack(spacing: 4) {
                        Text(L("出口 IP", "Exit IP")).foregroundStyle(.tertiary)
                        Text(ip.ip).monospacedDigit()
                    }
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .hoverTip(alignment: .bottomTrailing) { ExitIPDetails(ip: ip, mode: model.mode, checkedAt: model.exitIPCheckedAt) }
            } else if model.exitIPLoading {
                Text(L("正在查询出口 IP…", "Checking exit IP…")).lineLimit(1)
            } else if model.exitIPFailed {
                Text(L("出口 IP 查询失败", "Exit IP lookup failed")).foregroundStyle(.orange).lineLimit(1)
            }
            if model.exitIPLoading {
                Spinner(size: 10).frame(width: 14)
            } else {
                Button(action: model.refreshExitIP) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .hoverTip(L("重新查询出口 IP", "Check exit IP again"), alignment: .bottomTrailing)
            }
        }
        .font(.caption)
    }

}

/// Hover card for the exit IP: the address as a heading, then aligned label/value rows.
struct ExitIPDetails: View {
    let ip: ExitIP
    let mode: ProxyMode
    let checkedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !ip.flag.isEmpty { FlagIcon(flag: ip.flag) }
                Text(ip.ip).font(.system(.callout, design: .monospaced).weight(.semibold)).textSelection(.enabled)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                if !place.isEmpty { row(L("位置", "Location"), place) }
                if !ip.isp.isEmpty { row(L("运营商", "ISP"), ip.isp) }
                if !ip.asn.isEmpty { row("ASN", ip.asn) }
            }
            .font(.caption)
            if mode == .direct {
                Text(L("直连模式：这是本机网络的公网 IP", "Direct mode: your own network's public IP"))
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let checkedAt {
                Text(L("查询于 ", "Checked at ") + checkedAt.formatted(date: .omitted, time: .shortened) + L(" · 点击复制 IP", " · Click to copy"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .frame(width: 250, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Country · region · city, skipping parts another part already contains (e.g. 东京都 / 东京).
    private var place: String {
        var parts: [String] = []
        for p in [ip.country, ip.region, ip.city] where !p.isEmpty {
            if parts.contains(where: { $0.contains(p) || p.contains($0) }) {
                if let i = parts.firstIndex(where: { p.contains($0) }), p.count > parts[i].count { parts[i] = p }
                continue
            }
            parts.append(p)
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown while failed nodes are being checked for a fix; orange and pulsing so it reads as a
/// separate, still-running step after the latency test.
struct DiagnosingBadge: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "stethoscope")
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(L("排查 \(count) 个节点…", "Checking \(count)…"))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.35)))
        .fixedSize()
        .onAppear { pulse = true }
        .hoverTip(alignment: .bottomTrailing) {
            // Wrapped at a fixed width: the badge sits mid-toolbar, so a one-line tip would run off the panel.
            Text(L("正在检查失败节点能否通过本地解析或中转恢复，并复查已修复的节点",
                   "Checking whether local DNS or a relay can fix failed nodes, and rechecking repaired ones"))
                .font(.caption).foregroundStyle(.primary)
                .frame(width: 200, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Buttons & feedback

/// Toolbar icon button with hover highlight, press-down scale and a custom tooltip
/// (`.help` tooltips don't appear inside MenuBarExtra panels).
struct IconButton: View {
    var label: String?
    let systemName: String
    let tip: String
    var tipAlignment: Alignment = .bottom
    var active = false
    var spinning = false
    var rotating = false
    let action: () -> Void

    init(_ label: String? = nil, systemName: String, tip: String, tipAlignment: Alignment = .bottom,
         active: Bool = false, spinning: Bool = false, rotating: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemName = systemName
        self.tip = tip
        self.tipAlignment = tipAlignment
        self.active = active
        self.spinning = spinning
        self.rotating = rotating
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if spinning {
                    Spinner(size: 13)
                } else {
                    Image(systemName: systemName)
                        .rotationEffect(.degrees(rotating ? 360 : 0))
                        .animation(rotating ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: rotating)
                }
                if let label { Text(label).font(.caption).lineLimit(1).fixedSize() }
            }
            .frame(minWidth: 16, minHeight: 16)
        }
        .buttonStyle(PressableStyle(active: active))
        .hoverTip(tip, alignment: tipAlignment)
    }
}

struct PressableStyle: ButtonStyle {
    var active = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, active: active, cornerRadius: cornerRadius)
    }

    struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(active ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(active ? Color.accentColor.opacity(pressed ? 0.28 : 0.15)
                              : Color.primary.opacity(pressed ? 0.16 : (hovering ? 0.08 : 0)))
                        .shadow(color: .black.opacity(hovering && !pressed ? 0.12 : 0), radius: 2, y: 1)
                )
                .scaleEffect(pressed ? 0.88 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && enabled }
        }
    }
}

/// Full-width list row with hover highlight and a subtle press-down.
struct RowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration, selected: selected) }

    struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.14)
                              : Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)))
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

private struct ForceTipsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Debug snapshots only: render tooltips without hovering.
    var forceTips: Bool {
        get { self[ForceTipsKey.self] }
        set { self[ForceTipsKey.self] = newValue }
    }
}

struct HoverTip<Tip: View>: ViewModifier {
    let alignment: Alignment
    @ViewBuilder let tip: () -> Tip
    @Environment(\.forceTips) private var forceTips
    @State private var visible = false
    @State private var pending: Task<Void, Never>?
    @State private var tipHeight: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { visible = true } }
                    }
                } else {
                    withAnimation(.easeIn(duration: 0.1)) { visible = false }
                }
            }
            .overlay(alignment: alignment) {
                if visible || forceTips {
                    tip()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        // Opaque, so text underneath never shows through.
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
                        .fixedSize()
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { tipHeight = g.size.height }
                                .onChange(of: g.size.height) { h in tipHeight = h }
                        })
                        // Push the bubble just outside the anchored edge, whatever its height.
                        .offset(y: alignment.vertical == .top ? -(tipHeight + 6) : tipHeight + 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .allowsHitTesting(false)
                }
            }
            .zIndex(visible || forceTips ? 10 : 0)
    }
}

extension View {
    func hoverTip(_ text: String, alignment: Alignment = .bottom) -> some View {
        modifier(HoverTip(alignment: alignment) { Text(text).font(.caption).foregroundStyle(.primary) })
    }

    func hoverTip<Tip: View>(alignment: Alignment = .bottom, @ViewBuilder _ tip: @escaping () -> Tip) -> some View {
        modifier(HoverTip(alignment: alignment, tip: tip))
    }
}

/// Small rotating arc used for per-node and toolbar loading states.
struct Spinner: View {
    var size: CGFloat = 12
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: max(1.5, size / 7), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// MARK: - Rows

/// The active source: usage, expiry and last update for a subscription; node count for imported
/// nodes. With several sources it also names the active one, as a menu to switch.
struct SubscriptionCard: View {
    let source: NodeSource
    let sources: [NodeSource]
    let info: SubscriptionInfo
    let updated: Date?
    let nodeCount: Int
    let onSwitch: (String) -> Void
    let onManage: () -> Void

    private var usage: (used: Int64, total: Int64)? {
        guard let used = info.used, let total = info.total, total > 0 else { return nil }
        return (used, total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if sources.count > 1 || usage == nil {
                HStack(spacing: 8) {
                    if sources.count > 1 { sourceMenu } else { sourceName }
                    Spacer(minLength: 4)
                    if usage == nil {
                        Text(L("\(nodeCount) 个节点", "\(nodeCount) nodes")).monospacedDigit()
                    }
                    if let updated { updatedLabel(updated) }
                }
            }
            if let usage {
                HStack(spacing: 8) {
                    Text("\(Format.bytes(usage.used)) / \(Format.bytes(usage.total))").monospacedDigit().layoutPriority(1)
                    UsageBar(fraction: min(1, Double(usage.used) / Double(usage.total))).frame(minWidth: 30)
                    if let e = info.expire {
                        Text(L("\(e.formatted(date: .numeric, time: .omitted)) 到期", "Exp. \(e.formatted(date: .numeric, time: .omitted))"))
                            .layoutPriority(1)
                    }
                    if sources.count <= 1, let updated { updatedLabel(updated) }
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .hoverTip(alignment: .bottom) { details }
    }

    private var sourceName: some View {
        Label(source.name, systemImage: source.kind.icon).truncationMode(.tail)
    }

    /// Source name as a small menu button. SwiftUI's Menu can't be drawn at caption size, so this
    /// pops up a native menu instead.
    private var sourceMenu: some View {
        Button {
            var items: [PopUpMenu.Item?] = sources.map { s in
                PopUpMenu.Item(title: s.name, checked: s.id == source.id) { onSwitch(s.id) }
            }
            items.append(nil)
            items.append(PopUpMenu.Item(title: L("管理节点来源…", "Manage Sources…"), action: onManage))
            PopUpMenu.show(items)
        } label: {
            HStack(spacing: 3) {
                Label(source.name, systemImage: source.kind.icon).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(cornerRadius: 4))
        .padding(.horizontal, -6).padding(.vertical, -4)  // PressableStyle's own padding; keep the text aligned
    }

    private func updatedLabel(_ date: Date) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold))
            RelativeTimeText(date: date, unitsStyle: .abbreviated)
        }
        .layoutPriority(1)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name).fontWeight(.semibold)
            if let usage {
                Text(L("已用流量 ", "Data used ") + "\(Format.bytes(usage.used)) / \(Format.bytes(usage.total))"
                     + " (\((Double(usage.used) / Double(usage.total)).formatted(.percent.precision(.fractionLength(1)))))")
            }
            if let e = info.expire { Text(L("到期 ", "Expires ") + e.formatted(Date.FormatStyle(date: .long).locale(L10n.locale))) }
            if let updated {
                RelativeTimeText(date: updated, prefix: source.kind == .url ? L("订阅更新于 ", "Subscription updated ") : L("导入于 ", "Imported "))
            }
        }
        .font(.caption).foregroundStyle(.primary)
    }
}

/// Native pop-up menu at the pointer, built from closures.
@MainActor
enum PopUpMenu {
    struct Item {
        var title: String
        var checked = false
        var action: () -> Void
    }

    private final class Target: NSObject {
        let actions: [() -> Void]
        init(_ actions: [() -> Void]) { self.actions = actions }
        @objc func run(_ sender: NSMenuItem) { actions[sender.tag]() }
    }

    /// `nil` items are separators.
    static func show(_ items: [Item?]) {
        let menu = NSMenu()
        let target = Target(items.compactMap { $0?.action })
        var i = 0
        for item in items {
            guard let item else { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: item.title, action: #selector(Target.run(_:)), keyEquivalent: "")
            m.target = target
            m.tag = i
            m.state = item.checked ? .on : .off
            menu.addItem(m)
            i += 1
        }
        // Blocks until the menu closes, so `target` lives long enough.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }
}

/// "13 hours ago" that keeps itself current. The panel's views stay alive between openings and
/// only re-render when the model changes, so a plain formatted string would freeze at "now".
struct RelativeTimeText: View {
    let date: Date
    var prefix = ""
    var unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .full

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(prefix + text(at: ctx.date))
        }
    }

    private func text(at now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = unitsStyle
        f.locale = L10n.locale
        return f.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// Usage bar: accent below 80 %, orange from 80 %, red from 95 %.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, g.size.width * fraction))
            }
        }
        .frame(height: 5)
    }

    private var color: Color { fraction >= 0.95 ? .red : fraction >= 0.8 ? .orange : .accentColor }
}

struct GroupRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
    }
}

struct NodeRow: View {
    let node: ProxyNode
    let delay: DelayState?
    let repair: String?
    var showServer = true
    let selected: Bool
    let onTest: () -> Void
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                FlagIcon(flag: node.flag).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName).font(.callout).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(node.type.uppercased()).fontWeight(.semibold).foregroundStyle(.secondary)
                        if showServer, !node.server.isEmpty {
                            Text(node.server).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if let repair {
                            Text(repair).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    .font(.system(size: 10.5))
                }
                Spacer()
                if hovering && delay != .testing {
                    IconButton(systemName: "speedometer", tip: L("测速此节点", "Test this node"), tipAlignment: .bottomTrailing, action: onTest)
                        .transition(.opacity)
                }
                DelayBadge(state: delay)
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .zIndex(hovering ? 1 : 0)
        .contextMenu {
            Button(L("测速", "Test Latency"), action: onTest)
            Button(L("复制名称", "Copy Name")) { copy(node.name) }
            if !node.server.isEmpty {
                Button(L("复制地址", "Copy Address")) { copy(node.port.isEmpty ? node.server : "\(node.server):\(node.port)") }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var displayName: String {
        // Only a leading emoji is dropped; a region read from the name stays part of it.
        node.leadingFlag.isEmpty ? node.name : String(node.name.dropFirst(node.leadingFlag.count)).trimmingCharacters(in: .whitespaces)
    }
}

struct DelayBadge: View {
    let state: DelayState?

    var body: some View {
        Group {
            switch state {
            case .testing:
                Spinner(size: 11).frame(width: 58)
            case .ok(let ms):
                pill("\(ms) ms", color(ms))
            case .timeout:
                pill(L("超时", "Timeout"), .red)
                    .hoverTip(L("两次测试都没有响应，服务器可能已下线", "No response in two tries; the server may be down"), alignment: .topTrailing)
            case .failed:
                pill(L("失败", "Failed"), .red)
                    .hoverTip(L("服务器拒绝连接或握手失败，节点不可用", "Server refused the connection or handshake"), alignment: .topTrailing)
            case nil:
                Text("—").font(.caption).foregroundStyle(.tertiary).frame(width: 58)
            }
        }
        .frame(width: 58, alignment: .trailing)
    }

    private func pill(_ text: String, _ c: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.14)))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func color(_ ms: Int) -> Color {
        ms < 300 ? .green : ms < 800 ? .orange : .red
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .binary) }
    static func speed(_ n: Int) -> String { bytes(Int64(n)) + "/s" }

    /// Short speed for the menu bar: "512 B/s", "9.6 K/s", "120 K/s", "3.2 M/s".
    static func compactSpeed(_ n: Int) -> String {
        let k = Double(n) / 1024
        if k < 1 { return "\(n) B/s" }
        if k < 1000 { return String(format: k < 10 ? "%.1f K/s" : "%.0f K/s", k) }
        let m = k / 1024
        return String(format: m < 10 ? "%.1f M/s" : "%.0f M/s", m)
    }
}
