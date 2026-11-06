import AppKit
import OrbitCore
import ServiceManagement
import SwiftUI

/// How the panel toast for `AppModel.message` looks: info clears itself, the others stay.
enum NoticeStyle { case info, progress, error }

enum DelayState: Equatable {
    case testing
    case ok(Int)
    case timeout
    case failed

    init(_ r: DelayResult) {
        switch r {
        case .ok(let ms): self = .ok(ms)
        case .timeout: self = .timeout
        case .failed: self = .failed
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let engine: Engine?
    @Published var isOn = false
    @Published var busy = false
    @Published var message: String?
    @Published var noticeStyle: NoticeStyle = .error
    @Published var nodes: [ProxyNode] = []
    @Published var delays: [String: DelayState] = [:]
    @Published var selected: String = ConfigBuilder.autoGroup
    /// What the AUTO / FALLBACK groups currently resolve to.
    @Published var groupNow: [String: String] = [:]
    @Published var mode: ProxyMode = .rule
    @Published var tun = false
    @Published var systemProxy = true
    @Published var info: SubscriptionInfo?
    @Published var updatedAt: Date?
    @Published var up = 0
    @Published var down = 0
    @Published var sortByDelay = false
    @Published var search = ""
    /// Region flag the node list is narrowed to ("" = nodes without a flag); nil shows every region.
    @Published var regionFilter: String?
    @Published var testing = false
    @Published var testedCount = 0
    @Published var diagnosing = false
    @Published var diagnosingCount = 0
    @Published var updating = false
    @Published var english = false
    /// Exit IP of the current connection, looked up after connecting or switching node/mode.
    @Published var exitIP: ExitIP?
    @Published var exitIPLoading = false
    @Published var exitIPFailed = false
    @Published var exitIPCheckedAt: Date?

    /// Short tag for nodes Orbit repaired automatically.
    func repairNote(_ name: String) -> String? {
        guard let s = engine?.settings else { return nil }
        let notes = [s.chainVia.contains(name) ? L("经中转", "Relayed") : nil,
                     s.resolveLocal.contains(name) ? L("本地解析", "Local DNS") : nil].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private var trafficTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var autoUpdateTimer: Timer?
    /// The last timed update failed: try again sooner than a full interval.
    private var retryAfterFailure = false
    private var probeIdleTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var exitIPTask: Task<Void, Never>?
    /// Mode + effective node the current exit IP belongs to; a change triggers a new lookup.
    private var exitIPKey: String?

    init() {
        do {
            // ORBIT_HOME (as in orbitctl) points at another data folder, e.g. for debug snapshots.
            engine = try Engine(store: Store(root: ProcessInfo.processInfo.environment["ORBIT_HOME"].map { URL(fileURLWithPath: $0) }))
        } catch {
            engine = nil
            fail(describe(error))
            return
        }
        let e = engine!
        // A previous crash may have left the system proxy pointing at a dead port.
        // It must finish before an automatic connect turns the proxy on, or it would undo that.
        let port = e.settings.mixedPort
        let cleanup = Task.detached { SystemProxy.disable(port: port) }
        loadFromEngine()
        // Launching never updates or tests by itself; only the auto-update timer or the user does.
        scheduleAutoUpdate()
        if e.settings.connectOnLaunch {
            Task {
                await cleanup.value
                await connect()
            }
        }
    }

    var settings: OrbitSettings { engine?.settings ?? OrbitSettings() }
    var needsSubscription: Bool { engine?.settings.sources.isEmpty ?? true }
    var activeSource: NodeSource? { engine?.activeSource }

    /// Nodes cached for each source, for the source list in settings.
    @Published private(set) var sourceNodeCounts: [String: Int] = [:]

    private func loadFromEngine() {
        guard let e = engine else { return }
        nodes = e.nodes
        info = e.cached?.info
        updatedAt = e.cached?.updated
        sourceNodeCounts = Dictionary(uniqueKeysWithValues: e.settings.sources.map { ($0.id, e.store.loadNodes(source: $0.id)?.nodes.count ?? 0) })
        selected = e.settings.selected
        mode = e.settings.mode
        tun = e.settings.tun
        systemProxy = e.settings.systemProxy
        english = L10n.isEnglish(e.settings.language)
        L10n.english = english
        applyAppearance(e.settings.appearance)
        CoreProcess.adminPrompt = L("Orbit 需要管理员权限以开启增强模式 (TUN)", "Orbit needs administrator access to turn on Enhanced Mode (TUN)")
    }

    // MARK: - Connection

    func toggle() async { isOn ? await disconnect() : await connect() }

    func connect() async {
        guard let e = engine, !busy else { return }
        guard !e.nodes.isEmpty else {
            fail(L("还没有节点，请先点 ↻ 更新订阅", "No nodes yet. Click ↻ to update the subscription first"))
            return
        }
        busy = true
        noticeStyle = .progress
        message = tun ? L("等待管理员授权…", "Waiting for administrator approval…") : L("正在启动…", "Starting…")
        defer { busy = false }
        do {
            try await Task.detached { try await e.start() }.value
            isOn = true
            message = nil
            startMonitoring()
            await refreshGroups()
        } catch {
            isOn = false
            fail(describe(error))
            await Task.detached { e.stop() }.value
        }
    }

    func disconnect() async {
        guard let e = engine else { return }
        busy = true
        defer { busy = false }
        stopMonitoring()
        await Task.detached { e.stop() }.value
        isOn = false
        up = 0
        down = 0
        clearExitIP()
    }

    func restartIfRunning() async {
        guard isOn else { return }
        await disconnect()
        await connect()
    }

    // MARK: - Nodes

    func select(_ name: String) async {
        guard let e = engine else { return }
        selected = name
        e.settings.selected = name
        e.saveSettings()
        guard isOn else { return }
        do { try await e.select(name) } catch { fail(describe(error)) }
        await refreshGroups()
    }

    func setMode(_ m: ProxyMode) async {
        mode = m
        do { try await engine?.setMode(m) } catch { fail(describe(error)) }
        await refreshGroups()
    }

    func setTun(_ on: Bool) async {
        guard let e = engine else { return }
        tun = on
        e.settings.tun = on
        e.saveSettings()
        await restartIfRunning()
    }

    func setSystemProxy(_ on: Bool) {
        guard let e = engine else { return }
        systemProxy = on
        e.settings.systemProxy = on
        e.saveSettings()
        guard isOn else { return }
        let port = e.settings.mixedPort
        Task.detached { on ? SystemProxy.enable(port: port) : SystemProxy.disable(port: port) }
    }

    /// Tests every node. Uses the live core when connected, otherwise a throwaway probe core,
    /// so latency is available before connecting (and never changes the system proxy).
    func testAll() async {
        guard let e = engine, !testing, !nodes.isEmpty else { return }
        testing = true
        testedCount = 0
        probeIdleTask?.cancel()
        defer {
            testing = false
            scheduleProbeShutdown()
        }
        let names = nodes.map(\.name)
        withAnimation(.easeOut(duration: 0.15)) { for n in names { delays[n] = .testing } }
        let api: MihomoAPI
        do {
            api = try await e.testingAPI()
        } catch {
            for n in names { delays[n] = nil }
            fail(L("测速失败：", "Latency test failed: ") + describe(error))
            return
        }
        let url = e.settings.testURL
        let generation = e.coreGeneration
        var results: [String: DelayResult] = [:]
        for await (n, r) in api.measure(names, url: url) {
            withAnimation(.easeOut(duration: 0.25)) { delays[n] = DelayState(r) }
            results[n] = r
            testedCount += 1
        }
        // Connecting or disconnecting during the test cut its connections; those failures say
        // nothing about the nodes, so they mustn't drive repairs.
        guard e.coreGeneration == generation else {
            for (n, r) in results where !r.isOK { delays[n] = nil }
            await refreshGroups()
            return
        }
        await repair(results)
        await refreshGroups()
    }

    /// Every test re-decides the repairs (local DNS, relay) from its own results, then retests
    /// the nodes whose repair changed.
    private func repair(_ results: [String: DelayResult]) async {
        guard let e = engine else { return }
        let candidates = e.reassessCandidates(results)
        guard !candidates.isEmpty else { return }
        diagnosingCount = candidates.count
        diagnosing = true
        defer { diagnosing = false }
        withAnimation(.easeOut(duration: 0.15)) { for n in candidates { delays[n] = .testing } }
        let outcome = await e.reassess(results)
        let changed = Set(outcome.changed)
        for n in candidates where !changed.contains(n) {
            withAnimation(.easeOut(duration: 0.25)) { delays[n] = results[n].map(DelayState.init) }
        }
        if !changed.isEmpty, let api = try? await e.testingAPI() {
            for await (n, r) in api.measure(outcome.changed, url: e.settings.testURL) {
                withAnimation(.easeOut(duration: 0.25)) { delays[n] = DelayState(r) }
            }
        }
        // Dropped repairs aren't announced; the node's latency badge already shows how it does now.
        if !outcome.added.isEmpty {
            flash(L("已修复 \(outcome.added.count) 个节点：", "Repaired \(outcome.added.count) node(s): ")
                  + outcome.added.joined(separator: L("、", ", ")))
        }
    }

    func test(_ name: String) async {
        guard let e = engine, delays[name] != .testing else { return }
        probeIdleTask?.cancel()
        withAnimation { delays[name] = .testing }
        var r = DelayResult.timeout
        if let api = try? await e.testingAPI() {
            for await (_, x) in api.measure([name], url: e.settings.testURL) { r = x }
        }
        withAnimation(.easeOut(duration: 0.25)) { delays[name] = DelayState(r) }
        scheduleProbeShutdown()
    }

    func toggleSort() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sortByDelay.toggle() }
        if sortByDelay && !testing && !delays.values.contains(where: \.isOK) {
            flash(L("还没有测速结果，点测速按钮后即可按延迟排序", "No latency results yet. Click the test button, then nodes sort by latency"))
        }
    }

    private func scheduleProbeShutdown() {
        guard let e = engine else { return }
        probeIdleTask?.cancel()
        probeIdleTask = Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if !Task.isCancelled { e.stopProbe() }
        }
    }

    /// Shows a transient notice that clears itself.
    func flash(_ text: String) {
        noticeStyle = .info
        message = text
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled, message == text { withAnimation { message = nil } }
        }
    }

    /// Shows an error that stays until dismissed or replaced.
    func fail(_ text: String) {
        flashTask?.cancel()
        noticeStyle = .error
        message = text
    }

    func dismissMessage() {
        flashTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { message = nil }
    }

    /// Regions present in the subscription, most nodes first (ties keep subscription order).
    var regions: [(flag: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for n in nodes {
            if counts[n.flag] == nil { order.append(n.flag) }
            counts[n.flag, default: 0] += 1
        }
        return order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map { ($0.element, counts[$0.element]!) }
    }

    var filtering: Bool { regionFilter != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var visibleNodes: [ProxyNode] {
        var list = nodes
        if let r = regionFilter { list = list.filter { $0.flag == r } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.type.contains(q.lowercased()) } }
        if sortByDelay {
            func key(_ n: ProxyNode) -> Int {
                switch delays[n.name] { case .ok(let d): return d; case .timeout, .failed: return Int.max - 1; default: return Int.max }
            }
            list.sort { key($0) < key($1) }
        }
        return list
    }

    /// The selected node or group, named the same way as when connected.
    var selectedTitle: String {
        if selected == ConfigBuilder.autoGroup { return L("自动选择", "Auto") }
        if selected == ConfigBuilder.fallbackGroup { return L("故障转移", "Fallback") }
        return selected
    }

    var currentNodeTitle: String {
        if selected == ConfigBuilder.autoGroup { return L("自动选择", "Auto") + " · \(groupNow[ConfigBuilder.autoGroup] ?? "…")" }
        if selected == ConfigBuilder.fallbackGroup { return L("故障转移", "Fallback") + " · \(groupNow[ConfigBuilder.fallbackGroup] ?? "…")" }
        return selected
    }

    func refreshGroups() async {
        guard let e = engine, isOn, let all = try? await e.api.proxies() else { return }
        for g in [ConfigBuilder.autoGroup, ConfigBuilder.fallbackGroup, ConfigBuilder.proxyGroup] {
            if let now = all[g]?.now { groupNow[g] = now }
        }
        for n in nodes where delays[n.name] == nil || delays[n.name] == .testing {
            if let h = all[n.name]?.history, let last = h.last {
                delays[n.name] = last.delay > 0 ? .ok(last.delay) : .timeout
            }
        }
        // Only look up again when traffic actually leaves somewhere else, never on a timer.
        let key = "\(mode.rawValue)|\(currentNodeTitle)"
        if key != exitIPKey && !currentNodeTitle.hasSuffix("…") {
            exitIPKey = key
            refreshExitIP()
        }
    }

    // MARK: - Exit IP

    func refreshExitIP() {
        guard let e = engine, isOn else { return }
        exitIPTask?.cancel()
        exitIPLoading = true
        exitIPFailed = false
        let port = e.settings.mixedPort
        let chinese = !english
        exitIPTask = Task {
            let r = try? await ExitIP.lookup(proxyPort: port, chinese: chinese)
            guard !Task.isCancelled, isOn else { return }
            exitIPLoading = false
            if let r {
                exitIP = r
                exitIPCheckedAt = Date()
            } else {
                exitIP = nil
                exitIPFailed = true
            }
        }
    }

    private func clearExitIP() {
        exitIPTask?.cancel()
        exitIPKey = nil
        exitIP = nil
        exitIPLoading = false
        exitIPFailed = false
    }

    func copyExitIP() {
        guard let ip = exitIP?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
        flash(L("已复制出口 IP：", "Copied exit IP: ") + ip)
    }

    // MARK: - Subscription

    /// `manual`: the user clicked update, which is also when a full latency test follows.
    /// Timer-driven updates refresh the node list quietly and keep existing results.
    func updateSubscription(manual: Bool = true) async {
        guard let e = engine else { return }
        guard !updating else { return }
        updating = true
        defer {
            updating = false
            scheduleAutoUpdate()
        }
        do {
            let r = try await e.updateSubscription()
            flash(L("已更新 \(r.count) 个节点", "Updated \(r.count) nodes")
                  + (r.skipped.isEmpty ? "" : L("，跳过 \(r.skipped.count) 个", ", skipped \(r.skipped.count)")))
            await nodesChanged()
            if manual { Task { await testAll() } }
        } catch is CancellationError {
            // The source was deleted while it was being fetched.
        } catch {
            fail(L("订阅更新失败：", "Subscription update failed: ") + describe(error))
            if !manual { retryAfterFailure = true }
        }
    }

    // MARK: - Sources

    /// Adds a source and switches to it, then tests its nodes (like a manual update). Throws so the
    /// sheet that added it can show what went wrong.
    func addSource(_ src: NodeSource, content: Data? = nil) async throws {
        guard let e = engine else { return }
        let r = try await e.addSource(src, content: content)
        flash(L("已添加「\(src.name)」，共 \(r.count) 个节点", "Added “\(src.name)” with \(r.count) nodes"))
        await nodesChanged()
        Task { await testAll() }
    }

    func editSource(_ src: NodeSource, content: Data? = nil) async throws {
        guard let e = engine else { return }
        let fetched = try await e.editSource(src, content: content)
        if fetched != nil && src.id == e.settings.activeSourceID {
            await nodesChanged()
            Task { await testAll() }
        } else {
            loadFromEngine()
            scheduleAutoUpdate()
        }
    }

    func activateSource(_ id: String) async {
        guard let e = engine, id != e.settings.activeSourceID else { return }
        updating = true
        defer { updating = false }
        do {
            try await e.activateSource(id)
            flash(L("已切换到「\(e.activeSource?.name ?? "")」，共 \(e.nodes.count) 个节点",
                    "Switched to “\(e.activeSource?.name ?? "")” with \(e.nodes.count) nodes"))
        } catch {
            fail(L("切换节点来源失败：", "Couldn't switch source: ") + describe(error))
        }
        await nodesChanged()
    }

    func removeSource(_ id: String) async {
        guard let e = engine else { return }
        let wasActive = id == e.settings.activeSourceID
        e.removeSource(id)
        if wasActive { await nodesChanged() } else { loadFromEngine() }
    }

    /// Stored content of a pasted source, for editing it.
    func pastedText(_ src: NodeSource) -> String {
        guard let e = engine, let d = try? Data(contentsOf: e.store.rawFile(source: src.id)) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// After the node list in use changed: drop stale results and filters, keep the selection valid,
    /// and hand the new list to a running core.
    private func nodesChanged() async {
        guard let e = engine else { return }
        loadFromEngine()
        let names = Set(nodes.map(\.name))
        delays = delays.filter { names.contains($0.key) }
        if let r = regionFilter, !nodes.contains(where: { $0.flag == r }) { regionFilter = nil }
        groupNow = [:]
        if isOn {
            do { try await e.reload() } catch { fail(describe(error)) }
            await refreshGroups()
        }
        scheduleAutoUpdate()
    }

    /// `form` with every field the settings window doesn't edit taken from the live settings, which
    /// the panel (mode, node, TUN…) or a latency test may have changed while the window was open.
    func formSettings(_ form: OrbitSettings) -> OrbitSettings {
        let live = settings
        var s = form
        s.mode = live.mode
        s.selected = live.selected
        s.secret = live.secret
        s.systemProxy = live.systemProxy
        s.tun = live.tun
        s.resolveLocal = live.resolveLocal
        s.chainVia = live.chainVia
        // Sources are managed in place (add / switch / remove apply at once), not through Save.
        s.sources = live.sources
        s.activeSourceID = live.activeSourceID
        s.customRules = form.customRules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.normalizeLANCredentials(fallbackPassword: live.lanPassword)
        return s
    }

    func applySettings(_ form: OrbitSettings) async {
        guard let e = engine else { return }
        let old = e.settings
        let new = formSettings(form)
        e.settings = new
        e.saveSettings()
        loadFromEngine()
        if new.language != old.language { refreshExitIP() }
        if isOn {
            if new.mixedPort != old.mixedPort || new.controllerPort != old.controllerPort || new.tun != old.tun {
                SystemProxy.disable(port: old.mixedPort)
                await disconnect()
                await connect()
            } else {
                do { try await e.reload() } catch { fail(describe(error)) }
            }
        }
        scheduleAutoUpdate()
    }

    /// One-shot timer for the next automatic update, re-armed after every update. An overdue
    /// subscription waits a full interval from now, so opening the app never triggers an update.
    private func scheduleAutoUpdate() {
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = nil
        guard let e = engine, let src = e.activeSource, src.kind == .url, src.autoUpdateHours > 0 else { return }
        let interval = Double(src.autoUpdateHours) * 3600
        var next = (e.cached?.updated ?? .distantPast).addingTimeInterval(interval)
        if next <= Date() { next = Date().addingTimeInterval(interval) }
        if retryAfterFailure {
            retryAfterFailure = false
            next = min(next, Date().addingTimeInterval(min(interval, 1800)))
        }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.updateSubscription(manual: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoUpdateTimer = timer
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard let e = engine else { return }
        trafficTask?.cancel()
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await t in e.api.traffic() {
                        await MainActor.run { self?.up = t.up; self?.down = t.down }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                if !e.core.isRunning {
                    await MainActor.run {
                        self.isOn = false
                        self.fail(L("内核已退出：", "Core exited: ") + (e.core.tailLog(lines: 3)))
                    }
                    SystemProxy.disable(port: e.settings.mixedPort)
                    return
                }
                await self.refreshGroups()
            }
        }
    }

    private func stopMonitoring() {
        trafficTask?.cancel()
        pollTask?.cancel()
    }

    // MARK: - Misc

    func copyShellExport() {
        guard let e = engine else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.shellExport, forType: .string)
        flash(L("已复制终端代理命令，粘贴到终端即可让命令行走代理", "Copied the proxy command. Paste it into a terminal to proxy command-line tools"))
    }

    func openLog() {
        guard let e = engine else { return }
        NSWorkspace.shared.open(e.core.logFile)
    }

    func openDataDir() {
        guard let e = engine else { return }
        NSWorkspace.shared.activateFileViewerSelecting([e.store.configFile])
    }

    var launchAtLogin: Bool {
        // Registered but waiting for the user's approval in System Settings still counts as on.
        get { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { fail(L("开机启动设置失败：", "Couldn't change launch at login: ") + error.localizedDescription) }
            if newValue && SMAppService.mainApp.status == .requiresApproval {
                fail(L("请在「系统设置 → 通用 → 登录项」里允许 Orbit", "Allow Orbit in System Settings → General → Login Items"))
                SMAppService.openSystemSettingsLoginItems()
            }
            objectWillChange.send()
        }
    }

    func quit() {
        stopMonitoring()
        engine?.stop()
        NSApp.terminate(nil)
    }

    func shutdown() {
        engine?.stop()
    }
}

extension DelayState {
    var isOK: Bool { if case .ok = self { return true } else { return false } }
}

/// SwiftUI also declares a `Settings` scene.
typealias OrbitSettings = OrbitCore.Settings
