import Foundation

/// Glue shared by the menu bar app and the CLI: subscription -> config -> core -> system proxy.
/// The app calls it from the main thread and from background tasks at once, so `settings` and
/// `cached` sit behind a lock: concurrent copy-on-write access to them would corrupt memory.
public final class Engine: @unchecked Sendable {
    public let store: Store
    private let lock = NSLock()
    private var _settings: Settings
    private var _cached: Store.CachedNodes?
    public var settings: Settings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
    public private(set) var cached: Store.CachedNodes? {
        get { lock.withLock { _cached } }
        set { lock.withLock { _cached = newValue } }
    }
    public let core: CoreProcess
    /// The TUN core only answers to the one-time secret its launcher made.
    public var api: MihomoAPI { MihomoAPI(port: settings.controllerPort, secret: core.rootSecret ?? settings.secret) }
    /// Bumped whenever the live core starts or stops, so a latency test can tell its results went stale.
    public private(set) var coreGeneration: Int {
        get { lock.withLock { _coreGeneration } }
        set { lock.withLock { _coreGeneration = newValue } }
    }
    private var _coreGeneration = 0

    public init(store: Store = Store(), coreBinary: URL? = nil, bundledRulesets: URL? = nil) throws {
        guard let bin = coreBinary ?? CoreProcess.locateBinary() else { throw CoreError.binaryNotFound }
        self.store = store
        _settings = store.loadSettings()
        core = CoreProcess(store: store, binary: bin)
        store.seedRulesets(from: bundledRulesets ?? Engine.defaultRulesetSeed())
        migrateLegacySubscription()
        cached = settings.activeSource.flatMap { store.loadNodes(source: $0.id) }
        let saved = (try? String(contentsOf: store.settingsFile, encoding: .utf8)) ?? ""
        // First run, or settings from before the LAN password existed: keep the generated values.
        if saved.isEmpty || !saved.contains("\"lanPassword\"") { try? store.save(settings) }
    }

    /// Before sources, the one subscription's nodes lived in nodes.json; they now belong to the
    /// source Settings created from the old URL. Persists that source so its id sticks.
    private func migrateLegacySubscription() {
        let fm = FileManager.default
        let settingsText = (try? String(contentsOf: store.settingsFile, encoding: .utf8)) ?? ""
        if settingsText.contains("\"subscriptionURL\"") && !settingsText.contains("\"sources\"") { saveSettings() }
        if let src = settings.sources.first(where: { $0.id == NodeSource.legacyID }),
           fm.fileExists(atPath: store.legacyNodesFile.path), !fm.fileExists(atPath: store.nodesFile(source: src.id).path) {
            try? fm.moveItem(at: store.legacyNodesFile, to: store.nodesFile(source: src.id))
            try? fm.moveItem(at: store.legacyRawFile, to: store.rawFile(source: src.id))
        }
        try? fm.removeItem(at: store.legacyRawFile)
    }

    static func defaultRulesetSeed() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ruleset"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let r = dir.appendingPathComponent("Resources/ruleset")
            if FileManager.default.fileExists(atPath: r.path) { return r }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    public func saveSettings() { try? store.save(settings) }

    public var nodes: [ProxyNode] { cached?.nodes ?? [] }

    public var activeSource: NodeSource? { settings.activeSource }

    public struct UpdateResult: Sendable {
        public let count: Int
        public let skipped: [String]
        public let info: SubscriptionInfo
        public let format: SubscriptionFormat
    }

    /// Fetches the active source again (URL) or re-reads its stored content (file / pasted).
    @discardableResult
    public func updateSubscription() async throws -> UpdateResult {
        guard let src = activeSource else { throw SubscriptionError.noSource }
        let fetched = try await load(src)
        return try keep(fetched, for: src)
    }

    /// Checks that a new source yields nodes, then adds it and makes it the active one.
    /// `content` is the file or pasted text for `.file` / `.paste` sources.
    @discardableResult
    public func addSource(_ src: NodeSource, content: Data? = nil) async throws -> UpdateResult {
        if let content { try content.write(to: store.rawFile(source: src.id), options: .atomic) }
        let fetched: FetchedSubscription
        do { fetched = try await load(src) } catch { store.removeFiles(source: src.id); throw error }
        let r: UpdateResult
        do { r = try keep(fetched, for: src, isNew: true) } catch { store.removeFiles(source: src.id); throw error }
        settings.sources.append(src)
        settings.activeSourceID = src.id
        saveSettings()
        return r
    }

    /// Saves edits to a source. A changed URL or User-Agent is fetched, and new `content` (pasted
    /// links) parsed, first; either must yield nodes. Returns that result, or nil when the edit
    /// didn't touch the nodes.
    @discardableResult
    public func editSource(_ src: NodeSource, content: Data? = nil) async throws -> UpdateResult? {
        guard let i = settings.sources.firstIndex(where: { $0.id == src.id }) else { return nil }
        let old = settings.sources[i]
        var result: UpdateResult?
        if let content {
            let fetched = SubscriptionFetcher.parse(content)
            guard !fetched.nodes.isEmpty else { throw SubscriptionError.noNodes(fetched.format) }
            try content.write(to: store.rawFile(source: src.id), options: .atomic)
            settings.sources[i] = src
            result = try keep(fetched, for: src)
        } else if src.kind == .url && (src.url != old.url || src.userAgent != old.userAgent) {
            let fetched = try await load(src)
            guard !fetched.nodes.isEmpty else { throw SubscriptionError.noNodes(fetched.format) }
            settings.sources[i] = src
            result = try keep(fetched, for: src)
        } else {
            settings.sources[i] = src
        }
        saveSettings()
        return result
    }

    /// Switches to another source, using its cached nodes or fetching them if there are none yet.
    /// The caller reloads the running core.
    @discardableResult
    public func activateSource(_ id: String) async throws -> UpdateResult? {
        guard settings.sources.contains(where: { $0.id == id }) else { return nil }
        settings.activeSourceID = id
        saveSettings()
        if let c = store.loadNodes(source: id) {
            cached = c
            keepSelectionValid()
            return nil
        }
        cached = nil
        return try await updateSubscription()
    }

    /// A node from another source can't stay selected; fall back to automatic selection.
    private func keepSelectionValid() {
        let groups = [ConfigBuilder.autoGroup, ConfigBuilder.fallbackGroup]
        guard !groups.contains(settings.selected), !nodes.contains(where: { $0.name == settings.selected }) else { return }
        settings.selected = ConfigBuilder.autoGroup
        saveSettings()
    }

    /// Deletes a source and its files. Removing the active one activates the first remaining source.
    public func removeSource(_ id: String) {
        settings.sources.removeAll { $0.id == id }
        store.removeFiles(source: id)
        if settings.activeSourceID == id {
            settings.activeSourceID = settings.sources.first?.id ?? ""
            cached = settings.activeSource.flatMap { store.loadNodes(source: $0.id) }
            keepSelectionValid()
        }
        saveSettings()
    }

    private func load(_ src: NodeSource) async throws -> FetchedSubscription {
        switch src.kind {
        case .url:
            // https only: a plain-http subscription could be read or rewritten on the way.
            guard let url = URL(string: src.url.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https" else {
                throw SubscriptionError.invalidURL
            }
            // Try direct first; if the provider is unreachable, retry through our own core.
            let fetched: FetchedSubscription
            do {
                fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: src.userAgent)
            } catch {
                guard core.isRunning else { throw error }
                fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: src.userAgent, proxyPort: settings.mixedPort)
            }
            return fetched
        case .file, .paste:
            let data = try Data(contentsOf: store.rawFile(source: src.id))
            return SubscriptionFetcher.parse(data)
        }
    }

    /// Stores what a source yielded; becomes the node list in use if it's the active source.
    /// `isNew`: the source is being added and isn't in `settings.sources` yet.
    private func keep(_ fetched: FetchedSubscription, for src: NodeSource, isNew: Bool = false) throws -> UpdateResult {
        guard !fetched.nodes.isEmpty else { throw SubscriptionError.noNodes(fetched.format) }
        // The source may have been deleted while it was being fetched; don't bring its files back.
        guard isNew || settings.sources.contains(where: { $0.id == src.id }) else { throw CancellationError() }
        if src.kind == .url { try fetched.raw.write(to: store.rawFile(source: src.id), options: .atomic) }
        let c = Store.CachedNodes(nodes: fetched.nodes, info: fetched.info, updated: Date())
        try store.save(c, source: src.id)
        if isNew || src.id == settings.activeSourceID {
            cached = c
            keepSelectionValid()
        }
        return UpdateResult(count: fetched.nodes.count, skipped: fetched.skipped, info: fetched.info, format: fetched.format)
    }

    public func writeConfig() throws {
        let cfg = ConfigBuilder.build(settings: settings, nodes: nodes, store: store)
        try ConfigBuilder.write(cfg, to: store.configFile)
    }

    /// Config for the TUN core: rule-sets relative to its root-owned working directory.
    func rootConfig() throws -> Data {
        var cfg = ConfigBuilder.build(settings: settings, nodes: nodes, store: store, rulesetDir: CoreProcess.rootRulesetDir)
        cfg["secret"] = nil  // the launcher gives the TUN core its own one-time secret
        return try ConfigBuilder.data(cfg)
    }

    /// Validates the generated config with `mihomo -t` before handing it to the running core.
    public func testConfig() -> (Bool, String) {
        let p = Process()
        p.executableURL = core.binary
        p.arguments = ["-t", "-d", store.homeDir.path, "-f", store.configFile.path]
        var env = ProcessInfo.processInfo.environment
        env["SAFE_PATHS"] = store.rulesetDir.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (false, "cannot run core") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus == 0, out)
    }

    public func start() async throws {
        probe.stop()
        coreGeneration += 1
        try writeConfig()
        try core.start(asRoot: settings.tun, rootConfig: settings.tun ? rootConfig() : nil,
                       ports: [settings.mixedPort, settings.controllerPort])
        try await core.waitUntilReady(api: api)
        await applySelection()
        if settings.systemProxy { SystemProxy.enable(port: settings.mixedPort) }
        Task { await self.refreshEmptyRuleProviders() }
    }

    public func stop() {
        coreGeneration += 1
        SystemProxy.disable(port: settings.mixedPort)
        core.stop()
        probe.stop()
    }

    // MARK: - Latency probe

    /// Listener-less core used to measure latency while disconnected, so testing never touches the system proxy.
    public lazy var probe = CoreProcess(store: store, binary: core.binary, profile: "probe")
    var probeAPI: MihomoAPI { MihomoAPI(port: settings.controllerPort + 1, secret: settings.secret) }

    /// Where latency tests should run: the live core when connected, otherwise the probe (started on demand).
    public func testingAPI() async throws -> MihomoAPI {
        if core.isRunning { return api }
        return try await startProbe(probeConfig())
    }

    /// The full config minus listeners and rule-providers; every node, group and repair still applies.
    func probeConfig() -> [String: Any] {
        var s = settings
        s.controllerPort += 1
        s.tun = false
        var cfg = ConfigBuilder.build(settings: s, nodes: nodes, store: store)
        for key in ["mixed-port", "rule-providers", "sniffer", "tun"] { cfg[key] = nil }
        cfg["rules"] = ["MATCH,DIRECT"]
        // resolve-local nodes need a resolver; the full DNS policy depends on rule-providers.
        let doh = ["https://223.5.5.5/dns-query", "https://doh.pub/dns-query"]
        cfg["dns"] = ["enable": true, "ipv6": false, "default-nameserver": ["223.5.5.5", "119.29.29.29"], "nameserver": doh]
        return cfg
    }

    func startProbe(_ cfg: [String: Any]) async throws -> MihomoAPI {
        try ConfigBuilder.write(cfg, to: probe.configFile)
        if probe.isRunning, (try? await probeAPI.version()) != nil {
            try await probeAPI.reload(path: probe.configFile.path)
        } else {
            try probe.start(asRoot: false, ports: [settings.controllerPort + 1])
            try await probe.waitUntilReady(api: probeAPI)
        }
        return probeAPI
    }

    public func stopProbe() { probe.stop() }

    // MARK: - Repairs

    /// What a latency test changed in the saved repairs.
    public struct RepairOutcome: Sendable {
        /// Nodes that work again thanks to a new repair.
        public var added: [String] = []
        /// Nodes whose repair was dropped: they work without it now, or don't work at all.
        public var removed: [String] = []
        public var changed: [String] { added + removed }
    }

    var repairedNodes: Set<String> { Set(settings.chainVia).union(settings.resolveLocal) }

    /// Nodes `reassess` looks at: every failed node plus every node carrying a repair.
    public func reassessCandidates(_ results: [String: DelayResult]) -> [String] {
        let repaired = repairedNodes
        return nodes.map(\.name).filter { n in
            guard let r = results[n] else { return false }
            return !r.isOK || repaired.contains(n)
        }
    }

    /// Re-decides every repair from this test alone, so a one-off timeout never sticks:
    /// - Repaired nodes are also tested as-is (no repair). If that works the repair is dropped;
    ///   if only the repaired form works it stays; if neither works it's dropped.
    /// - Failed nodes without a working repair are diagnosed:
    ///   - The server accepts us but can't resolve domains (requests error at once, a bare IP gets
    ///     through): mieru nodes get `resolve-local`, so Orbit resolves and sends the server an IP.
    ///   - The server is unreachable from this network (its IP is blocked locally) but answers when
    ///     dialed from another node: the node gets `dialer-proxy` through the RELAY group.
    /// `results` are this test's results for the nodes as configured (repairs applied). Repairs are
    /// saved by node name, so they also cover nodes added by later subscription updates.
    public func reassess(_ results: [String: DelayResult]) async -> RepairOutcome {
        let candidates = reassessCandidates(results)
        let generation = coreGeneration
        // The probe's own traffic would be captured and proxied under TUN, which skews every trial.
        guard !candidates.isEmpty, !(core.isRunning && settings.tun) else { return RepairOutcome() }
        let repaired = repairedNodes
        let byName = Dictionary(nodes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // One probe config holds "<name> ⇢" (no repair) copies of repaired nodes and "<name> ⛓"
        // (via TRIAL-RELAY) copies of every candidate, so the live config stays untouched.
        let relays = results.filter { $0.value.isOK && !settings.chainVia.contains($0.key) }
            .sorted { ($0.value.ms ?? .max) < ($1.value.ms ?? .max) }.prefix(3).map(\.key)
        var cfg = probeConfig()
        var proxies = cfg["proxies"] as? [[String: Any]] ?? []
        for n in candidates {
            guard var p = proxies.first(where: { $0["name"] as? String == n }) else { continue }
            p["dialer-proxy"] = nil
            p["resolve-local"] = nil
            if repaired.contains(n) {
                var copy = p
                copy["name"] = n + Self.plainSuffix
                proxies.append(copy)
            }
            p["name"] = n + Self.trialSuffix
            p["dialer-proxy"] = Self.trialRelay
            proxies.append(p)
        }
        cfg["proxies"] = proxies
        var groups = cfg["proxy-groups"] as? [[String: Any]] ?? []
        groups.append(["name": Self.trialRelay, "type": "select", "proxies": relays.isEmpty ? ["DIRECT"] : relays])
        cfg["proxy-groups"] = groups
        guard let probeAPI = try? await startProbe(cfg) else { return RepairOutcome() }

        // How each candidate does without any repair.
        var plain: [String: DelayResult] = [:]
        for n in candidates where !repaired.contains(n) { plain[n] = results[n] }
        let repairedCandidates = candidates.filter { repaired.contains($0) }
        for await (n, r) in probeAPI.measure(repairedCandidates.map { $0 + Self.plainSuffix }, url: settings.testURL) {
            plain[String(n.dropLast(Self.plainSuffix.count))] = r
        }

        var keep = Set<String>()       // repaired form is the only one that works
        var diagnose: [String] = []     // nothing works yet
        for n in candidates where !(plain[n]?.isOK ?? false) {
            if repaired.contains(n) && results[n]?.isOK == true { keep.insert(n) } else { diagnose.append(n) }
        }

        var dns: [String] = []
        let dnsCandidates = diagnose.filter { plain[$0] == .failed && byName[$0]?.type == "mieru" }
        await withTaskGroup(of: (String, DelayResult).self) { g in
            for n in dnsCandidates {
                let proxy = repaired.contains(n) ? n + Self.plainSuffix : n
                g.addTask { (n, await probeAPI.delayResult(proxy: proxy, url: "http://1.1.1.1", timeoutMs: 6000)) }
            }
            for await (n, r) in g { if r.isOK { dns.append(n) } }
        }

        var chained: [String] = []
        let chainCandidates = diagnose.filter { !dns.contains($0) }
        if !chainCandidates.isEmpty, !relays.isEmpty {
            for await (n, r) in probeAPI.measure(chainCandidates.map { $0 + Self.trialSuffix }, url: settings.testURL) where r.isOK {
                chained.append(String(n.dropLast(Self.trialSuffix.count)))
            }
        }

        let candidateSet = Set(candidates)
        // Nodes that weren't candidates (tested OK as-is) keep whatever they had, i.e. nothing.
        let newDNS = settings.resolveLocal.filter { !candidateSet.contains($0) || keep.contains($0) } + dns
        let newChain = settings.chainVia.filter { !candidateSet.contains($0) || keep.contains($0) } + chained
        let after = Set(newDNS).union(newChain)
        var outcome = RepairOutcome()
        outcome.added = dns + chained
        outcome.removed = repaired.filter { candidateSet.contains($0) && !after.contains($0) }.sorted()
        guard newDNS != settings.resolveLocal || newChain != settings.chainVia else { return outcome }
        // Connecting or disconnecting mid-test makes these trials meaningless; keep the old repairs.
        guard coreGeneration == generation else { return RepairOutcome() }
        settings.resolveLocal = newDNS
        settings.chainVia = newChain
        saveSettings()
        if core.isRunning { try? await reload() }
        return outcome
    }

    static let plainSuffix = " ⇢"
    static let trialSuffix = " ⛓"
    static let trialRelay = "TRIAL-RELAY"

    /// Pushes a regenerated config into the running core (subscription update, rule changes).
    public func reload() async throws {
        try writeConfig()
        let (ok, out) = testConfig()
        guard ok else { throw CoreError.notReady(out.split(separator: "\n").suffix(4).joined(separator: "\n")) }
        if core.runningAsRoot {
            // The root core only reads from its own directory; hand it the config inline.
            try await api.reload(payload: String(decoding: rootConfig(), as: UTF8.self))
        } else {
            try await api.reload(path: store.configFile.path)
        }
        await applySelection()
    }

    public func applySelection() async {
        try? await api.select(group: "GLOBAL", proxy: ConfigBuilder.proxyGroup)
        try? await api.select(group: ConfigBuilder.proxyGroup, proxy: settings.selected)
    }

    public func select(_ name: String) async throws {
        try await api.select(group: ConfigBuilder.proxyGroup, proxy: name)
        settings.selected = name
        saveSettings()
        await api.closeAllConnections()
    }

    public func setMode(_ mode: ProxyMode) async throws {
        settings.mode = mode
        saveSettings()
        if core.isRunning {
            try await api.patchConfig(["mode": mode.rawValue])
            await api.closeAllConnections()
        }
    }

    /// Rule-sets that are missing locally are fetched through PROXY once a node is up.
    func refreshEmptyRuleProviders() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for (name, count) in await api.ruleProviderCounts() where count == 0 {
            await api.refreshRuleProvider(name)
        }
    }

    /// Terminal snippet for tools that ignore the system proxy.
    public var shellExport: String {
        let p = settings.mixedPort
        return "export https_proxy=http://127.0.0.1:\(p) http_proxy=http://127.0.0.1:\(p) all_proxy=socks5://127.0.0.1:\(p)"
    }
}
