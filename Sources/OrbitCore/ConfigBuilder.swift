import Foundation

/// Builds a self-contained mihomo config. It deliberately avoids GEOIP/GEOSITE databases
/// (which mihomo would try to download from GitHub at startup) and uses small `.mrs`
/// rule-sets that ship with the app and refresh through the proxy itself.
public enum ConfigBuilder {
    public static let proxyGroup = "PROXY"
    public static let autoGroup = "AUTO"
    public static let fallbackGroup = "FALLBACK"
    /// First hop for nodes in `chainVia`; it never contains them, so chains can't loop.
    public static let relayGroup = "RELAY"

    /// Provider-inserted pseudo nodes that only carry text (traffic left, expiry, website).
    static let infoNodeFilter = "(?i)剩余|到期|过期|官网|流量|套餐|重置|expire|traffic|remaining"

    struct RuleSet {
        let name: String
        let behavior: String
        let remote: String
    }

    static let ruleSets: [RuleSet] = {
        let base = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo"
        let site: [(String, String)] = [
            ("site-private", "private"), ("site-cn", "cn"), ("site-geolocation-not-cn", "geolocation-!cn"),
            ("site-category-ai-not-cn", "category-ai-!cn"), ("site-google", "google"), ("site-github", "github"),
            ("site-telegram", "telegram"), ("site-category-ads-all", "category-ads-all"), ("site-apple-cn", "apple-cn"),
        ]
        let ip: [(String, String)] = [("ip-private", "private"), ("ip-cn", "cn"), ("ip-telegram", "telegram")]
        return site.map { RuleSet(name: $0.0, behavior: "domain", remote: "\(base)/geosite/\($0.1).mrs") }
            + ip.map { RuleSet(name: $0.0, behavior: "ipcidr", remote: "\(base)/geoip/\($0.1).mrs") }
    }()

    /// `rulesetDir` overrides where rule-sets live (the TUN core uses a path relative to its own directory).
    public static func build(settings s: Settings, nodes: [ProxyNode], store: Store, rulesetDir: String? = nil) -> [String: Any] {
        let names = nodes.map(\.name)

        func group(_ name: String, _ type: String, _ members: [String], extra: [String: Any] = [:]) -> [String: Any] {
            var g: [String: Any] = ["name": name, "type": type, "proxies": members]
            g.merge(extra) { a, _ in a }
            return g
        }
        let testing: [String: Any] = [
            "url": s.testURL, "interval": 600, "lazy": true, "timeout": 5000, "exclude-filter": infoNodeFilter,
        ]
        var groups: [[String: Any]] = [
            group(proxyGroup, "select", [autoGroup, fallbackGroup] + names + ["DIRECT"]),
            group(autoGroup, "url-test", names, extra: testing.merging(["tolerance": 80]) { a, _ in a }),
            group(fallbackGroup, "fallback", names, extra: testing),
            ["name": "GLOBAL", "type": "select", "proxies": [proxyGroup, "DIRECT"]],
        ]
        let chained = Set(s.chainVia).intersection(names)
        let direct = names.filter { !chained.contains($0) }
        // A chained node's first hop: same-region nodes when there are any (a nearby relay keeps the
        // detour short; measured ~3 MB/s via a HK relay vs ~0.1 MB/s via JP for a HK node), else any.
        var relayFor: [String: String] = [:]
        if !chained.isEmpty && !direct.isEmpty {
            // Not lazy: the first hop should already be a tested node when a chained node is used.
            let relayTesting = testing.merging(["tolerance": 80, "lazy": false]) { b, _ in b }
            groups.append(group(relayGroup, "url-test", direct, extra: relayTesting))
            let flagOf = Dictionary(nodes.map { ($0.name, $0.flag) }, uniquingKeysWith: { a, _ in a })
            for n in chained.sorted() {
                let flag = flagOf[n] ?? ""
                let local = direct.filter { !flag.isEmpty && flagOf[$0] == flag }
                guard !local.isEmpty else { relayFor[n] = relayGroup; continue }
                let name = "\(relayGroup) \(flag)"
                if !groups.contains(where: { $0["name"] as? String == name }) {
                    groups.append(group(name, "url-test", local, extra: relayTesting))
                }
                relayFor[n] = name
            }
        }
        if names.isEmpty {
            // mihomo rejects empty url-test groups; keep the config loadable with no subscription yet.
            groups[1]["proxies"] = ["DIRECT"]
            groups[2]["proxies"] = ["DIRECT"]
        }

        var providers: [String: Any] = [:]
        for r in ruleSets {
            providers[r.name] = [
                "type": "http", "behavior": r.behavior, "format": "mrs", "url": r.remote,
                "path": "\(rulesetDir ?? store.rulesetDir.path)/\(r.name).mrs",
                "interval": 86400, "proxy": proxyGroup,
            ]
        }

        var rules = s.customRules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // Subscription servers are fetched direct (with a proxy retry), so keep them off the proxy.
        for src in s.sources where src.kind == .url {
            if let host = URL(string: src.url)?.host, !rules.contains("DOMAIN,\(host),DIRECT") { rules.append("DOMAIN,\(host),DIRECT") }
        }
        // Exit-IP lookups must leave through the selected node, whatever the rule sets say.
        rules += ExitIP.hosts.map { "DOMAIN,\($0),\(proxyGroup)" }
        rules += [
            "RULE-SET,site-private,DIRECT",
            "RULE-SET,ip-private,DIRECT,no-resolve",
        ]
        if s.blockAds { rules.append("RULE-SET,site-category-ads-all,REJECT") }
        rules += [
            "RULE-SET,site-category-ai-not-cn,\(proxyGroup)",
            "RULE-SET,site-telegram,\(proxyGroup)",
            "RULE-SET,ip-telegram,\(proxyGroup),no-resolve",
            "RULE-SET,site-google,\(proxyGroup)",
            "RULE-SET,site-github,\(proxyGroup)",
            "RULE-SET,site-apple-cn,DIRECT",
            "RULE-SET,site-geolocation-not-cn,\(proxyGroup)",
            "RULE-SET,site-cn,DIRECT",
            "RULE-SET,ip-cn,DIRECT",
            "MATCH,\(proxyGroup)",
        ]

        let domesticDoH = ["https://223.5.5.5/dns-query", "https://doh.pub/dns-query"]
        var config: [String: Any] = [
            "mixed-port": s.mixedPort,
            "allow-lan": s.allowLAN,
            "bind-address": s.allowLAN ? "*" : "127.0.0.1",
            "mode": s.mode.rawValue,
            "log-level": "info",
            "ipv6": false,
            "unified-delay": true,
            "tcp-concurrent": true,
            "find-process-mode": "off",
            "keep-alive-interval": 15,
            "external-controller": "127.0.0.1:\(s.controllerPort)",
            "secret": s.secret,
            "geodata-mode": false,
            "geo-auto-update": false,
            "profile": ["store-selected": true, "store-fake-ip": true],
            "tun": [
                "enable": s.tun, "stack": "mixed", "auto-route": true, "auto-detect-interface": true,
                "dns-hijack": ["any:53", "tcp://any:53"],
            ],
            "sniffer": [
                "enable": true,
                "sniff": [
                    "HTTP": ["ports": [80, "8080-8880"], "override-destination": true],
                    "TLS": ["ports": [443, 8443]],
                    "QUIC": ["ports": [443, 8443]],
                ],
                "skip-domain": ["+.push.apple.com"],
            ],
            "dns": [
                "enable": true,
                "ipv6": false,
                "enhanced-mode": "fake-ip",
                "fake-ip-range": "198.18.0.1/16",
                "fake-ip-filter": [
                    "rule-set:site-private,site-cn", "+.lan", "+.local", "+.msftconnecttest.com", "+.msftncsi.com",
                    "time.*.com", "ntp.*.com", "+.push.apple.com", "+.stun.*.*", "+.stun.*.*.*",
                ],
                "default-nameserver": ["223.5.5.5", "119.29.29.29"],
                "nameserver": domesticDoH,
                "proxy-server-nameserver": domesticDoH,
                "nameserver-policy": [
                    "rule-set:site-geolocation-not-cn,site-category-ai-not-cn,site-google,site-github,site-telegram":
                        ["https://1.1.1.1/dns-query#\(proxyGroup)", "https://8.8.8.8/dns-query#\(proxyGroup)"],
                ],
            ],
            "proxies": nodes.map { n -> [String: Any] in
                var f = n.fields.mapValues(\.any)
                // Patched-core option (see patches/): the server gets an IP, not a domain.
                if n.type == "mieru" && s.resolveLocal.contains(n.name) { f["resolve-local"] = true }
                if let relay = relayFor[n.name] { f["dialer-proxy"] = relay }
                return f
            },
            "proxy-groups": groups,
            "rule-providers": providers,
            "rules": rules,
        ]
        if s.allowLAN {
            // Other devices must log in; this Mac (system proxy, terminal) doesn't.
            config["authentication"] = ["\(s.lanUser):\(s.lanPassword)"]
            config["skip-auth-prefixes"] = ["127.0.0.1/8", "::1/128"]
        }
        return config
    }

    /// Serialises as JSON, which is valid YAML 1.2 and therefore loads in mihomo without a YAML emitter.
    public static func write(_ config: [String: Any], to url: URL) throws {
        try data(config).write(to: url, options: .atomic)
    }

    public static func data(_ config: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
