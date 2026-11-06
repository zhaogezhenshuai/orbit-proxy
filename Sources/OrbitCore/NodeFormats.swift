import Foundation
import Yams

/// What a subscription body or imported file turned out to be.
public enum SubscriptionFormat: String, Sendable {
    /// One share link per line (`vless://…`), plain or base64.
    case shareLinks
    /// Clash / mihomo YAML with a `proxies:` list.
    case clash
    /// sing-box JSON with an `outbounds` list.
    case singBox
    /// Shadowsocks SIP008 JSON (`servers`).
    case sip008
    /// A web page, usually a login page or a wrong address.
    case html
    case unknown
}

/// Turns a subscription body or imported file into nodes, whatever its format.
public enum NodeFormats {
    public struct Parsed: Sendable {
        public var format: SubscriptionFormat
        public var nodes: [ProxyNode]
        public var skipped: [String]
        /// `STATUS=` line some share-link lists start with.
        public var status: String?
    }

    public static func parse(_ data: Data) -> Parsed {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
        var result: Parsed
        if text.hasPrefix("{") || text.hasPrefix("["), let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            result = parseJSON(json)
        } else if looksLikeClash(text) {
            result = parseClash(text)
        } else if text.lowercased().hasPrefix("<!doctype html") || text.lowercased().hasPrefix("<html") {
            result = Parsed(format: .html, nodes: [], skipped: [])
        } else {
            result = parseShareLinks(text)
        }
        result.nodes = uniqueNames(sanitize(result.nodes, skipped: &result.skipped))
        return result
    }

    /// Outbound types Orbit hands to the core. Others (ssh, tailscale, zerotier…) can read local
    /// files or join networks, which a subscription shouldn't be able to make the core do.
    static let allowedTypes: Set<String> = [
        "ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "wireguard",
        "mieru", "anytls", "socks5", "http", "snell",
    ]
    /// Per-node keys a subscription may not set: Orbit decides how nodes are dialed itself.
    static let strippedKeys = ["dialer-proxy", "interface-name", "routing-mark"]

    static func sanitize(_ nodes: [ProxyNode], skipped: inout [String]) -> [ProxyNode] {
        var out: [ProxyNode] = []
        for var node in nodes {
            guard allowedTypes.contains(node.type) else {
                skipped.append("unsupported type: \(node.type)")
                continue
            }
            for k in strippedKeys { node.fields[k] = nil }
            out.append(node)
        }
        return out
    }

    /// Names of the core's built-in policies and Orbit's own groups; a node can't use them.
    static let reservedNames: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL",
        ConfigBuilder.proxyGroup, ConfigBuilder.autoGroup, ConfigBuilder.fallbackGroup, ConfigBuilder.relayGroup,
        "TRIAL-RELAY",
    ]

    /// Repeated names get " 2", " 3"…, skipping any name already taken; mihomo rejects the whole
    /// config if two proxies (or a proxy and a group) share a name.
    static func uniqueNames(_ nodes: [ProxyNode]) -> [ProxyNode] {
        var taken = reservedNames
        let original = Set(nodes.map(\.name))
        var seen = Set<String>()
        return nodes.map { node in
            var node = node
            let base = node.name
            if seen.contains(base) || taken.contains(base) {
                var n = 2
                // Avoid names other nodes carry as given, so a later "A 2" keeps its own name.
                while taken.contains("\(base) \(n)") || original.contains("\(base) \(n)") { n += 1 }
                node.name = "\(base) \(n)"
            }
            seen.insert(base)
            taken.insert(node.name)
            return node
        }
    }

    // MARK: - Share links

    static func parseShareLinks(_ text: String) -> Parsed {
        let body = !text.contains("://") ? (Base64.decodeString(text) ?? text) : text
        var result = Parsed(format: .shareLinks, nodes: [], skipped: [])
        var sawLink = false
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("STATUS=") {
                result.status = String(line.dropFirst("STATUS=".count))
                continue
            }
            guard line.contains("://") else { continue }
            sawLink = true
            do { result.nodes += try ShareLinkParser.parse(line: line) } catch { result.skipped.append("\(error)") }
        }
        if !sawLink { result.format = .unknown }
        return result
    }

    // MARK: - Clash YAML

    static func looksLikeClash(_ text: String) -> Bool {
        text.hasPrefix("proxies:") || text.contains("\nproxies:")
    }

    static func parseClash(_ text: String) -> Parsed {
        var result = Parsed(format: .clash, nodes: [], skipped: [])
        guard let root = try? Yams.compose(yaml: text), let proxies = root["proxies"]?.sequence else { return result }
        for item in proxies {
            guard case .object(let f)? = JSONValue(yaml: item), f["name"]?.stringValue?.isEmpty == false,
                  f["type"]?.stringValue != nil, f["server"]?.stringValue != nil else {
                result.skipped.append("clash: entry without name / type / server")
                continue
            }
            result.nodes.append(ProxyNode(f))
        }
        return result
    }

    // MARK: - JSON (sing-box, SIP008)

    static func parseJSON(_ json: Any) -> Parsed {
        let root = json as? [String: Any]
        if let servers = root?["servers"] as? [[String: Any]] {
            return Parsed(format: .sip008, nodes: servers.compactMap(sip008), skipped: [])
        }
        let outbounds = (root?["outbounds"] as? [[String: Any]]) ?? (json as? [[String: Any]]) ?? []
        guard root?["outbounds"] != nil || !outbounds.isEmpty else { return Parsed(format: .unknown, nodes: [], skipped: []) }
        var result = Parsed(format: .singBox, nodes: [], skipped: [])
        for o in outbounds {
            let type = o["type"] as? String ?? ""
            // Groups and built-ins carry no server.
            if ["direct", "block", "dns", "selector", "urltest"].contains(type) { continue }
            if let n = singBox(o) { result.nodes.append(n) } else { result.skipped.append("sing-box: unsupported \(type)") }
        }
        return result
    }

    static func sip008(_ s: [String: Any]) -> ProxyNode? {
        guard let server = s["server"] as? String, let port = int(s["server_port"]),
              let method = s["method"] as? String, let password = s["password"] as? String else { return nil }
        let name = (s["remarks"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(server):\(port)"
        return ProxyNode(["name": .string(name), "type": "ss", "server": .string(server), "port": .int(port),
                          "cipher": .string(method), "password": .string(password), "udp": true])
    }

    /// sing-box outbound → mihomo proxy, for the protocols both support.
    static func singBox(_ o: [String: Any]) -> ProxyNode? {
        let types = ["shadowsocks": "ss", "vmess": "vmess", "vless": "vless", "trojan": "trojan", "hysteria2": "hysteria2",
                     "tuic": "tuic", "anytls": "anytls", "socks": "socks5", "http": "http"]
        guard let sbType = o["type"] as? String, let type = types[sbType],
              let server = o["server"] as? String, let port = int(o["server_port"]) else { return nil }
        let name = (o["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(server):\(port)"
        var f: [String: JSONValue] = ["name": .string(name), "type": .string(type), "server": .string(server),
                                      "port": .int(port), "udp": true]
        func copy(_ from: String, _ to: String) { if let v = o[from] as? String, !v.isEmpty { f[to] = .string(v) } }
        switch sbType {
        case "shadowsocks":
            guard o["method"] != nil else { return nil }
            copy("method", "cipher")
            copy("password", "password")
        case "vmess":
            copy("uuid", "uuid")
            f["alterId"] = .int(int(o["alter_id"]) ?? 0)
            f["cipher"] = .string((o["security"] as? String) ?? "auto")
        case "vless":
            copy("uuid", "uuid")
            copy("flow", "flow")
        case "tuic":
            copy("uuid", "uuid")
            copy("password", "password")
            copy("congestion_control", "congestion-controller")
            copy("udp_relay_mode", "udp-relay-mode")
        case "hysteria2":
            copy("password", "password")
            if let obfs = o["obfs"] as? [String: Any] {
                if let t = obfs["type"] as? String { f["obfs"] = .string(t) }
                if let p = obfs["password"] as? String { f["obfs-password"] = .string(p) }
            }
        case "socks", "http":
            copy("username", "username")
            copy("password", "password")
        default:
            copy("password", "password")
        }
        if let tls = o["tls"] as? [String: Any], tls["enabled"] as? Bool == true {
            // vmess / vless take `servername`; the rest take `sni`.
            let sniKey = ["vmess", "vless"].contains(type) ? "servername" : "sni"
            if ["vmess", "vless", "http", "socks5"].contains(type) { f["tls"] = true }
            if let sni = tls["server_name"] as? String, !sni.isEmpty { f[sniKey] = .string(sni) }
            if tls["insecure"] as? Bool == true { f["skip-cert-verify"] = true }
            if let alpn = tls["alpn"] as? [String] { f["alpn"] = .array(alpn.map { .string($0) }) }
            if let utls = tls["utls"] as? [String: Any], utls["enabled"] as? Bool == true, let fp = utls["fingerprint"] as? String {
                f["client-fingerprint"] = .string(fp)
            }
            if let r = tls["reality"] as? [String: Any], r["enabled"] as? Bool == true, let key = r["public_key"] as? String {
                var opts: [String: JSONValue] = ["public-key": .string(key)]
                if let sid = r["short_id"] as? String { opts["short-id"] = .string(sid) }
                f["reality-opts"] = .object(opts)
                if f["client-fingerprint"] == nil { f["client-fingerprint"] = "chrome" }
            }
        }
        if let t = o["transport"] as? [String: Any], let net = t["type"] as? String {
            switch net {
            case "ws", "httpupgrade":
                f["network"] = "ws"
                var opts: [String: JSONValue] = ["path": .string((t["path"] as? String) ?? "/")]
                let host = (t["headers"] as? [String: Any])?["Host"] as? String ?? t["host"] as? String
                if let host { opts["headers"] = .object(["Host": .string(host)]) }
                if net == "httpupgrade" { opts["v2ray-http-upgrade"] = true }
                f["ws-opts"] = .object(opts)
            case "grpc":
                f["network"] = "grpc"
                f["grpc-opts"] = .object(["grpc-service-name": .string((t["service_name"] as? String) ?? "")])
            case "http":
                f["network"] = "h2"
                var opts: [String: JSONValue] = ["path": .string((t["path"] as? String) ?? "/")]
                if let hosts = t["host"] as? [String] { opts["host"] = .array(hosts.map { .string($0) }) }
                f["h2-opts"] = .object(opts)
            default:
                return nil  // quic etc. have no mihomo equivalent
            }
        }
        return ProxyNode(f)
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

extension JSONValue {
    /// Converts a YAML node, typing only plain scalars that are unambiguous: `true`/`false`, integers
    /// without leading zeros and decimals. Everything else stays a string, so values like a
    /// Reality short-id `0123` or a password `yes` survive unchanged (YAML 1.1 would turn those
    /// into a number / boolean).
    init?(yaml node: Node) {
        switch node {
        case .scalar(let s):
            guard s.style == .plain else { self = .string(s.string); return }
            let v = s.string
            if v == "true" || v == "false" { self = .bool(v == "true") }
            else if v == "null" || v == "~" || v.isEmpty { self = .null }
            else if v.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let i = Int(v) { self = .int(i) }
            else if v.range(of: #"^-?(0|[1-9][0-9]*)\.[0-9]+$"#, options: .regularExpression) != nil, let d = Double(v) { self = .double(d) }
            else { self = .string(v) }
        case .sequence(let seq):
            self = .array(seq.compactMap { JSONValue(yaml: $0) })
        case .mapping(let map):
            var o: [String: JSONValue] = [:]
            for (k, v) in map {
                guard let key = k.scalar?.string, let value = JSONValue(yaml: v) else { continue }
                o[key] = value
            }
            self = .object(o)
        case .alias:
            return nil
        }
    }
}
