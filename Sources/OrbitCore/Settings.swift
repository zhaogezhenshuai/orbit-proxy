import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case rule, global, direct

    public var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }
}

/// Where nodes come from. Several can be kept; one is active at a time.
public struct NodeSource: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A subscription URL, fetched again on update.
        case url
        /// An imported file; its content is copied into the data folder.
        case file
        /// Share links pasted by hand.
        case paste
    }

    /// The source created from a pre-sources settings file.
    public static let legacyID = "default"

    public var id: String = UUID().uuidString
    public var name: String
    public var kind: Kind
    /// `.url` only.
    public var url: String = ""
    public var userAgent: String = SubscriptionFetcher.defaultUserAgent
    /// `.url` only: hours between automatic updates; 0 turns them off.
    public var autoUpdateHours: Int = 12
    /// `.file` only: the imported file's name, for display.
    public var fileName: String = ""

    public init(id: String = UUID().uuidString, name: String, kind: Kind, url: String = "",
                userAgent: String = SubscriptionFetcher.defaultUserAgent, autoUpdateHours: Int = 12, fileName: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.userAgent = userAgent
        self.autoUpdateHours = autoUpdateHours
        self.fileName = fileName
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, url, userAgent, autoUpdateHours, fileName }

    /// Lenient like `Settings`: fields added later, or a bad value in one of them, fall back to
    /// defaults. Only a missing id or an unknown kind make the source unusable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        userAgent = (try? c.decodeIfPresent(String.self, forKey: .userAgent)) ?? SubscriptionFetcher.defaultUserAgent
        autoUpdateHours = (try? c.decodeIfPresent(Int.self, forKey: .autoUpdateHours)) ?? 12
        fileName = (try? c.decodeIfPresent(String.self, forKey: .fileName)) ?? ""
    }

    /// A short default name: the subscription's host, or the file name without extension.
    public static func defaultName(kind: Kind, url: String = "", fileName: String = "") -> String {
        switch kind {
        case .url: return URL(string: url.trimmingCharacters(in: .whitespaces))?.host ?? url
        case .file: return (fileName as NSString).deletingPathExtension
        case .paste: return ""
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var sources: [NodeSource] = []
    /// `id` of the source whose nodes are in use.
    public var activeSourceID: String = ""
    public var mode: ProxyMode = .rule
    /// Node name or group (`AUTO`) the PROXY selector should point at.
    public var selected: String = ConfigBuilder.autoGroup
    public var mixedPort: Int = 7890
    public var controllerPort: Int = 9097
    public var secret: String = UUID().uuidString
    public var systemProxy: Bool = true
    public var tun: Bool = false
    public var allowLAN: Bool = false
    /// Credentials other devices need for the proxy port when `allowLAN` is on; this Mac skips them.
    public var lanUser: String = "orbit"
    public var lanPassword: String = Settings.randomPassword()
    public var blockAds: Bool = false
    public var testURL: String = "https://www.gstatic.com/generate_204"
    /// Extra mihomo rules (e.g. `DOMAIN-SUFFIX,example.com,PROXY`), placed before the built-in ones.
    public var customRules: [String] = []
    public var connectOnLaunch: Bool = false
    /// Nodes whose server can't resolve domains itself; Orbit resolves for them (found by latency tests).
    public var resolveLocal: [String] = []
    /// Nodes blocked from this network that work when dialed through another node (the RELAY group).
    public var chainVia: [String] = []
    /// UI language: "system" (Chinese if the system prefers Chinese, else English), "zh" or "en".
    public var language: String = "system"
    /// Appearance: "system", "light" or "dark".
    public var appearance: String = "system"
    /// Show each node's server address under its name.
    public var showServerIP: Bool = true
    /// Show live upload / download speed next to the menu bar icon while connected.
    public var menuBarSpeed: Bool = false

    public init() {}

    public var activeSource: NodeSource? { sources.first { $0.id == activeSourceID } }

    /// 16 letters and digits, without look-alikes (0/O, 1/l/I), so it can be typed on a phone.
    public static func randomPassword() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    /// LAN credentials made valid for mihomo's `user:password` list: no colon or spaces in the
    /// user name, and never empty (an empty password would let anyone in).
    public mutating func normalizeLANCredentials(fallbackPassword: String) {
        lanUser = lanUser.filter { $0 != ":" && !$0.isWhitespace }
        if lanUser.isEmpty { lanUser = "orbit" }
        lanPassword = lanPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if lanPassword.isEmpty { lanPassword = fallbackPassword }
    }

    /// Keys of the single-subscription settings that came before sources.
    private enum LegacyKeys: String, CodingKey { case subscriptionURL, userAgent, autoUpdateHours }

    public init(from decoder: Decoder) throws {
        // Decode leniently: a missing field or a bad value (say an unknown mode) falls back to its
        // default instead of failing the whole file, which would reset every setting.
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(ProxyMode.self, forKey: .mode)) ?? d.mode
        selected = (try? c.decodeIfPresent(String.self, forKey: .selected)) ?? d.selected
        mixedPort = (try? c.decodeIfPresent(Int.self, forKey: .mixedPort)) ?? d.mixedPort
        controllerPort = (try? c.decodeIfPresent(Int.self, forKey: .controllerPort)) ?? d.controllerPort
        secret = (try? c.decodeIfPresent(String.self, forKey: .secret)) ?? d.secret
        systemProxy = (try? c.decodeIfPresent(Bool.self, forKey: .systemProxy)) ?? d.systemProxy
        tun = (try? c.decodeIfPresent(Bool.self, forKey: .tun)) ?? d.tun
        allowLAN = (try? c.decodeIfPresent(Bool.self, forKey: .allowLAN)) ?? d.allowLAN
        lanUser = (try? c.decodeIfPresent(String.self, forKey: .lanUser)) ?? d.lanUser
        lanPassword = (try? c.decodeIfPresent(String.self, forKey: .lanPassword)) ?? d.lanPassword
        blockAds = (try? c.decodeIfPresent(Bool.self, forKey: .blockAds)) ?? d.blockAds
        testURL = (try? c.decodeIfPresent(String.self, forKey: .testURL)) ?? d.testURL
        customRules = (try? c.decodeIfPresent([String].self, forKey: .customRules)) ?? d.customRules
        connectOnLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch)) ?? d.connectOnLaunch
        resolveLocal = (try? c.decodeIfPresent([String].self, forKey: .resolveLocal)) ?? d.resolveLocal
        chainVia = (try? c.decodeIfPresent([String].self, forKey: .chainVia)) ?? d.chainVia
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? d.language
        showServerIP = (try? c.decodeIfPresent(Bool.self, forKey: .showServerIP)) ?? d.showServerIP
        appearance = (try? c.decodeIfPresent(String.self, forKey: .appearance)) ?? d.appearance
        menuBarSpeed = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarSpeed)) ?? d.menuBarSpeed
        // One unreadable source mustn't take the others with it.
        sources = ((try? c.decodeIfPresent([Failable<NodeSource>].self, forKey: .sources)) ?? []).compactMap(\.value)
        activeSourceID = (try? c.decodeIfPresent(String.self, forKey: .activeSourceID)) ?? d.activeSourceID
        if !c.contains(.sources) {
            // Older settings had one subscription URL; it becomes the first (active) source.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let url = try legacy.decodeIfPresent(String.self, forKey: .subscriptionURL) ?? ""
            if !url.isEmpty {
                sources = [NodeSource(id: NodeSource.legacyID, name: NodeSource.defaultName(kind: .url, url: url), kind: .url, url: url,
                                      userAgent: try legacy.decodeIfPresent(String.self, forKey: .userAgent) ?? SubscriptionFetcher.defaultUserAgent,
                                      autoUpdateHours: try legacy.decodeIfPresent(Int.self, forKey: .autoUpdateHours) ?? 12)]
                activeSourceID = NodeSource.legacyID
            }
        }
    }
}

/// Decodes an array element to nil instead of failing the whole array.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// On-disk state kept under ~/Library/Application Support/Orbit.
public struct Store {
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Orbit", isDirectory: true)
        }
        for dir in [self.root, rulesetDir, sourcesDir, homeDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// Node cache of the single subscription before sources existed; migrated on first start.
    public var legacyNodesFile: URL { root.appendingPathComponent("nodes.json") }
    public var legacyRawFile: URL { root.appendingPathComponent("subscription.raw") }
    /// Per-source files: `<id>.raw` (fetched body or imported content) and `<id>.json` (parsed nodes).
    public var sourcesDir: URL { root.appendingPathComponent("sources", isDirectory: true) }
    public func rawFile(source id: String) -> URL { sourcesDir.appendingPathComponent("\(id).raw") }
    public func nodesFile(source id: String) -> URL { sourcesDir.appendingPathComponent("\(id).json") }
    public var configFile: URL { root.appendingPathComponent("config.yaml") }
    public var rulesetDir: URL { root.appendingPathComponent("ruleset", isDirectory: true) }
    public var logFile: URL { root.appendingPathComponent("core.log") }
    /// mihomo's working dir (cache.db etc). The TUN core runs as root in its own root-owned
    /// directory instead (see `CoreProcess.rootDir`).
    public var homeDir: URL { root.appendingPathComponent("core", isDirectory: true) }

    /// A file that can't be read at all (not JSON, say) is kept as `settings.json.broken-<time>`
    /// before defaults replace it, so the sources it listed can still be recovered by hand.
    public func loadSettings() -> Settings {
        guard let d = try? Data(contentsOf: settingsFile), !d.isEmpty else { return Settings() }
        let backup = { try? FileManager.default.copyItem(at: settingsFile, to: root.appendingPathComponent("settings.json.broken-\(Int(Date().timeIntervalSince1970))")) }
        guard let s = try? JSONDecoder().decode(Settings.self, from: d) else {
            backup()
            return Settings()
        }
        // Some source couldn't be read and will be gone after the next save: keep the original.
        let listed = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["sources"] as? [Any]
        if let listed, listed.count > s.sources.count { backup() }
        return s
    }

    public func save(_ s: Settings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: settingsFile, options: .atomic)
    }

    public struct CachedNodes: Codable {
        public var nodes: [ProxyNode]
        public var info: SubscriptionInfo
        public var updated: Date
    }

    public func loadNodes(source id: String) -> CachedNodes? {
        guard let d = try? Data(contentsOf: nodesFile(source: id)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(CachedNodes.self, from: d)
    }

    public func save(_ nodes: CachedNodes, source id: String) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(nodes).write(to: nodesFile(source: id), options: .atomic)
    }

    public func removeFiles(source id: String) {
        try? FileManager.default.removeItem(at: rawFile(source: id))
        try? FileManager.default.removeItem(at: nodesFile(source: id))
    }

    /// Copies bundled rule-set files into place if they're missing, so the first start
    /// doesn't depend on reaching GitHub.
    public func seedRulesets(from bundled: URL?) {
        guard let bundled, let files = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "mrs" {
            let dest = rulesetDir.appendingPathComponent(f.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: f, to: dest)
            }
        }
    }
}
