import AppKit
import OrbitCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` or launchd's SIGTERM would end the app without applicationWillTerminate, leaving
        // the system proxy pointing at a dead port. Quit normally instead.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src
        if let path = ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT"] {
            Task { await renderSnapshot(to: URL(fileURLWithPath: path)) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the system proxy pointing at a core that is about to disappear.
        model.shutdown()
    }

    /// Debug aid: without connecting, test every node (via the probe core) and render the panel
    /// mid-test and after sorting by latency, plus a tooltip sample, then quit.
    private func renderSnapshot(to url: URL) async {
        let base = url.deletingPathExtension().path
        if ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_LANG"] == "en" {
            L10n.english = true
            model.english = true
        }
        if let theme = ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_THEME"] { applyAppearance(theme) }
        let testTask = Task { await model.testAll() }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-testing.png")
        await testTask.value
        model.toggleSort()
        if let q = ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_SEARCH"] { model.search = q }
        try? await Task.sleep(nanoseconds: 800_000_000)
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-sorted.png")
        // Region filter with every chip shown, and both toast styles over the list.
        model.regionFilter = model.regions.dropFirst(3).first?.flag
        model.fail(L("订阅更新失败：", "Subscription update failed: ") + "The request timed out.")
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-region.png")
        model.regionFilter = nil
        model.flash(L("已修复 2 个节点：🇭🇰 香港 02、🇩🇪 德国 01", "Repaired 2 node(s): 🇭🇰 HK-2, 🇩🇪 DE-01"))
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-toast.png")
        model.dismissMessage()
        // Toolbar while failed nodes are being diagnosed (its widest state, sorted by latency).
        model.testing = true
        model.diagnosing = true
        model.diagnosingCount = 7
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-diagnosing.png")
        model.diagnosing = false
        model.testing = false
        // Tooltips drawn over the text below them, to check they stay readable.
        let tips = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 40) {
                IconButton(systemName: "speedometer", tip: L("测速全部节点", "Test all nodes"), tipAlignment: .bottomLeading) {}
                IconButton(L("延迟", "Latency"), systemName: "arrow.up.arrow.down",
                           tip: L("当前按延迟排序，点击恢复默认顺序", "Sorted by latency; click for default order"),
                           tipAlignment: .bottomTrailing, active: true) {}
            }
            .environment(\.forceTips, true)
            .zIndex(1)
            ForEach(0..<3) { _ in Text("下层文字 Underlying text 下层文字 Underlying text").font(.callout) }
        }
        .padding(12)
        .frame(width: 380, height: 140, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        await snapshot(tips, size: NSSize(width: 380, height: 140), to: base + "-tips.png")
        for (i, tab) in SettingsView.Tab.allCases.enumerated() {
            await snapshot(SettingsView(tab: tab).environmentObject(model), size: NSSize(width: 480, height: 600),
                           to: base + "-settings\(i + 1).png")
        }
        // Source editor sheets.
        await snapshot(SourceEditor(mode: .addURL) {}.environmentObject(model), size: NSSize(width: 460, height: 350), to: base + "-source-url.png")
        await snapshot(SourceEditor(mode: .addPaste) {}.environmentObject(model), size: NSSize(width: 460, height: 370), to: base + "-source-paste.png")
        let bar = MenuBarSpeed.image(up: 12_800, down: 3_355_443)
        if let tiff = bar.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-menubar.png"))
        }
        // Connected header with a sample exit IP (long city name), its details tip and the save-bar buttons.
        model.isOn = true
        model.exitIP = ExitIP(ip: "203.0.113.54", countryCode: "HK", country: L("香港", "Hong Kong"),
                              region: "Tsuen Wan District", city: "Discovery Park Tsuen Wan District",
                              isp: "Hong Kong Telecommunications (HKT) Limited", asn: "AS4760 HKT Limited")
        model.exitIPCheckedAt = Date()
        await snapshot(PanelView().environmentObject(model), size: NSSize(width: 380, height: 600), to: base + "-connected.png")
        // Every tip at once, to check none is drawn under the rows below it.
        await snapshot(PanelView().environmentObject(model).environment(\.forceTips, true),
                       size: NSSize(width: 380, height: 600), to: base + "-connected-tips.png")
        let extra = VStack(alignment: .trailing, spacing: 16) {
            Toggle("", isOn: .constant(true)).toggleStyle(AccentSwitchStyle(width: 36, height: 20)).labelsHidden()
                .hoverTip(L("断开连接", "Disconnect"), alignment: .leading)
                .environment(\.forceTips, true)
            ExitIPView().environmentObject(model).environment(\.forceTips, true).zIndex(1)
            Spacer().frame(height: 110)
            DiagnosingBadge(count: 7).environment(\.forceTips, true).padding(.trailing, 110).zIndex(1)
            HStack {
                Button(L("还原", "Revert")) {}.buttonStyle(BarButtonStyle(prominent: false))
                Button(L("保存", "Save")) {}.buttonStyle(BarButtonStyle(prominent: true))
                Button(L("保存", "Save")) {}.buttonStyle(BarButtonStyle(prominent: true)).disabled(true)
            }
        }
        .padding(12)
        .frame(width: 380, height: 370, alignment: .topTrailing)
        .background(Color(nsColor: .windowBackgroundColor))
        await snapshot(extra, size: NSSize(width: 380, height: 370), to: base + "-exitip.png")
        // Real lookup through a core already listening on the mixed port (e.g. `orbitctl run`),
        // exercising the app's own network policy (ATS), which the CLI doesn't have.
        if ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_LOOKUP"] != nil {
            let line: String
            do {
                let r = try await ExitIP.lookup(proxyPort: model.settings.mixedPort, chinese: !model.english)
                line = "\(r.flag) \(r.ip) \(r.country) \(r.region) \(r.city) | \(r.isp) | \(r.asn)"
            } catch { line = "error: \(error)" }
            try? line.write(toFile: base + "-lookup.txt", atomically: true, encoding: .utf8)
        }
        model.isOn = false
        model.quit()
    }

    private func snapshot<V: View>(_ view: V, size: NSSize, to path: String) async {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isOn && model.settings.menuBarSpeed {
            Image(nsImage: MenuBarSpeed.image(up: model.up, down: model.down))
        } else {
            Image(systemName: model.isOn ? "paperplane.fill" : "paperplane")
        }
    }
}

/// Menu bar icon with live speeds: the plane, then upload over download in small monospaced
/// digits. Fixed width so the menu bar doesn't shift as the numbers change; a template image so
/// it follows the menu bar's light / dark tint.
enum MenuBarSpeed {
    static func image(up: Int, down: Int) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let iconWidth: CGFloat = 16, textWidth: CGFloat = 50, height: CGFloat = 22
        let lines = [("↑", Format.compactSpeed(up)), ("↓", Format.compactSpeed(down))]
        let image = NSImage(size: NSSize(width: iconWidth + 4 + textWidth, height: height), flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = plane.size
                plane.draw(in: NSRect(x: (iconWidth - s.width) / 2, y: (height - s.height) / 2, width: s.width, height: s.height))
            }
            for (i, (arrow, value)) in lines.enumerated() {
                let a = NSAttributedString(string: arrow, attributes: attrs)
                let v = NSAttributedString(string: value, attributes: attrs)
                let y = i == 0 ? height / 2 - 1 : height / 2 - v.size().height + 1
                a.draw(at: NSPoint(x: iconWidth + 4, y: y))
                v.draw(at: NSPoint(x: iconWidth + 4 + textWidth - v.size().width, y: y))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Orbit", id: "settings") {
            SettingsView().environmentObject(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}
