import Foundation

/// One outbound proxy in mihomo's schema (`name`, `type`, `server`, `port`, ...).
public struct ProxyNode: Codable, Equatable, Sendable, Identifiable {
    public var fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue]) { self.fields = fields }

    public var id: String { name }
    public var name: String {
        get { fields["name"]?.stringValue ?? "" }
        set { fields["name"] = .string(newValue) }
    }
    public var type: String { fields["type"]?.stringValue ?? "" }
    public var server: String { fields["server"]?.stringValue ?? "" }
    public var port: String { fields["port"]?.stringValue ?? fields["port-range"]?.stringValue ?? "" }

    /// Flag emoji the name starts with (regional indicator pair), if any.
    public var leadingFlag: String {
        let scalars = Array(name.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return "" }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Region flag used to group nodes: the leading emoji, else one worked out from the name
    /// ("香港 01" → 🇭🇰); "" when the region can't be told.
    public var flag: String {
        let f = leadingFlag
        return f.isEmpty ? Region.flag(inName: name) : f
    }
}

public enum ShareLinkError: Error, CustomStringConvertible {
    case unsupported(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return "unsupported scheme: \(s)"
        case .malformed(let s): return "malformed link: \(s)"
        }
    }
}

/// Parses share links in both the de-facto standard formats (v2rayN / SIP002 / Xray)
/// and Shadowrocket's own variants (base64 `method:uuid@host:port` authority,
/// `obfs=`/`peer=`/`xtls=` params, `mierus://` with repeated port/protocol pairs).
public enum ShareLinkParser {
    public static func parse(line raw: String) throws -> [ProxyNode] {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = line.range(of: "://") else { throw ShareLinkError.malformed(line) }
        let scheme = line[..<sep.lowerBound].lowercased()
        switch scheme {
        case "mierus", "mieru": return try parseMieru(line)
        case "vless": return [try parseV(line, type: "vless")]
        case "vmess": return [try parseVmess(line)]
        case "trojan": return [try parseTrojan(line)]
        case "ss": return [try parseSS(line)]
        case "hysteria2", "hy2": return [try parseHysteria2(line)]
        case "tuic": return [try parseTuic(line)]
        case "anytls": return [try parseAnyTLS(line)]
        case "socks", "socks5", "http", "https": return [try parsePlain(line, scheme: scheme)]
        default: throw ShareLinkError.unsupported(scheme)
        }
    }

    // MARK: - Generic URL splitting (tolerant of raw unicode, unlike URLComponents)

    struct Link {
        var scheme = ""
        var user: String?
        var password: String?
        var host = ""
        var port: Int?
        var query: [String: [String]] = [:]
        var fragment = ""
        var rawAuthority = ""

        func q(_ keys: String...) -> String? {
            for k in keys { if let v = query[k]?.first, !v.isEmpty { return v } }
            return nil
        }
        func flag(_ keys: String...) -> Bool {
            for k in keys { if let v = query[k]?.first { return ["1", "true", "yes"].contains(v.lowercased()) } }
            return false
        }
    }

    static func split(_ line: String) throws -> Link {
        var link = Link()
        guard let sep = line.range(of: "://") else { throw ShareLinkError.malformed(line) }
        link.scheme = line[..<sep.lowerBound].lowercased()
        var rest = String(line[sep.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            link.fragment = pct(String(rest[rest.index(after: hash)...]))
            rest = String(rest[..<hash])
        }
        if let qm = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: qm)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = pct(String(kv[0]))
                let v = kv.count > 1 ? pct(String(kv[1])) : ""
                link.query[k, default: []].append(v)
            }
            rest = String(rest[..<qm])
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        link.rawAuthority = rest
        var hostPort = rest
        if let at = rest.lastIndex(of: "@") {
            let userInfo = String(rest[..<at])
            hostPort = String(rest[rest.index(after: at)...])
            if let colon = userInfo.firstIndex(of: ":") {
                link.user = pct(String(userInfo[..<colon]))
                link.password = pct(String(userInfo[userInfo.index(after: colon)...]))
            } else {
                link.user = pct(userInfo)
            }
        }
        (link.host, link.port) = splitHostPort(hostPort)
        return link
    }

    static func splitHostPort(_ s: String) -> (String, Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            return (host, after.hasPrefix(":") ? Int(after.dropFirst()) : nil)
        }
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (s, nil)
    }

    static func pct(_ s: String) -> String { s.removingPercentEncoding ?? s }

    // MARK: - mieru

    static func parseMieru(_ line: String) throws -> [ProxyNode] {
        let l = try split(line)
        guard !l.host.isEmpty, let user = l.user, let pass = l.password else { throw ShareLinkError.malformed(line) }
        let base = !l.fragment.isEmpty ? l.fragment : (l.q("profile") ?? l.host)
        let ports = l.query["port"] ?? []
        let protos = l.query["protocol"] ?? []
        guard !ports.isEmpty, ports.count == protos.count else { throw ShareLinkError.malformed(line) }
        return ports.enumerated().map { i, port in
            var f: [String: JSONValue] = [
                "name": .string(ports.count > 1 ? "\(base) \(port)/\(protos[i])" : base),
                "type": "mieru", "server": .string(l.host),
                "transport": .string(protos[i].uppercased()),
                "username": .string(user), "password": .string(pass), "udp": true,
            ]
            if port.contains("-") { f["port-range"] = .string(port) } else { f["port"] = .int(Int(port) ?? 0) }
            if let v = l.q("multiplexing") { f["multiplexing"] = .string(v) }
            if let v = l.q("handshake-mode") { f["handshake-mode"] = .string(v) }
            if let v = l.q("traffic-pattern") { f["traffic-pattern"] = .string(v) }
            return ProxyNode(f)
        }
    }

    // MARK: - VLESS / VMess (shared transport + TLS handling)

    /// Shadowrocket encodes the authority as base64("method:uuid@host:port").
    static func decodeShadowrocketAuthority(_ l: inout Link) {
        guard l.user == nil, l.port == nil, let decoded = Base64.decodeString(l.rawAuthority),
              decoded.contains("@") else { return }
        if let parsed = try? split("x://" + decoded) {
            // "auto:uuid" -> method=auto, uuid as password
            l.user = parsed.password ?? parsed.user
            l.query["_method", default: []].append(parsed.password == nil ? "" : (parsed.user ?? ""))
            l.host = parsed.host
            l.port = parsed.port
        }
    }

    static func parseV(_ line: String, type: String) throws -> ProxyNode {
        var l = try split(line)
        decodeShadowrocketAuthority(&l)
        guard let uuid = l.user, !l.host.isEmpty, let port = l.port else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": .string(type), "server": .string(l.host), "port": .int(port),
            "uuid": .string(uuid), "udp": true,
        ]
        if type == "vless" {
            f["encryption"] = .string(l.q("encryption") ?? "none")
            if let flow = l.q("flow") { f["flow"] = .string(flow.lowercased()) }
            else if let x = l.q("xtls") { f["flow"] = x == "2" ? "xtls-rprx-vision" : "xtls-rprx-direct" }
        } else {
            f["alterId"] = .int(Int(l.q("alterId", "aid") ?? "0") ?? 0)
            f["cipher"] = .string(l.q("_method").flatMap { $0.isEmpty ? nil : $0 } ?? l.q("scy", "cipher") ?? "auto")
        }
        applyTLS(l, into: &f)
        applyTransport(l, into: &f)
        return ProxyNode(f)
    }

    static func applyTLS(_ l: Link, into f: inout [String: JSONValue]) {
        let security = l.q("security")?.lowercased()
        let pbk = l.q("pbk", "publicKey")
        let tls = security == "tls" || security == "reality" || security == "xtls" || l.flag("tls") || pbk != nil
        guard tls else { return }
        f["tls"] = true
        if let sni = l.q("sni", "peer", "serverName", "servername") { f["servername"] = .string(sni) }
        if l.flag("allowInsecure", "insecure", "skip-cert-verify") { f["skip-cert-verify"] = true }
        if let fp = l.q("fp", "fingerprint") { f["client-fingerprint"] = .string(fp) }
        if let alpn = l.q("alpn") { f["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
        if let pbk {
            var r: [String: JSONValue] = ["public-key": .string(pbk)]
            if let sid = l.q("sid", "shortId") { r["short-id"] = .string(sid) }
            f["reality-opts"] = .object(r)
            if f["client-fingerprint"] == nil { f["client-fingerprint"] = "chrome" }
        }
    }

    static func applyTransport(_ l: Link, into f: inout [String: JSONValue]) {
        // Standard: type=ws|grpc|h2|http|httpupgrade ; Shadowrocket: obfs=websocket|grpc|h2|http
        var net = (l.q("type") ?? l.q("obfs") ?? "tcp").lowercased()
        if net == "websocket" { net = "ws" }
        if net == "none" { net = "tcp" }
        let host = l.q("host") ?? obfsHost(l.q("obfsParam"))
        let path = l.q("path")
        switch net {
        case "ws", "httpupgrade":
            f["network"] = "ws"
            var o: [String: JSONValue] = ["path": .string(path ?? "/")]
            if let host { o["headers"] = .object(["Host": .string(host)]) }
            if net == "httpupgrade" { o["v2ray-http-upgrade"] = true }
            f["ws-opts"] = .object(o)
        case "grpc":
            f["network"] = "grpc"
            f["grpc-opts"] = .object(["grpc-service-name": .string(l.q("serviceName") ?? path ?? "")])
        case "h2":
            f["network"] = "h2"
            var o: [String: JSONValue] = ["path": .string(path ?? "/")]
            if let host { o["host"] = .array([.string(host)]) }
            f["h2-opts"] = .object(o)
        case "http":
            f["network"] = "http"
            var o: [String: JSONValue] = ["path": .array([.string(path ?? "/")])]
            if let host { o["headers"] = .object(["Host": .array([.string(host)])]) }
            f["http-opts"] = .object(o)
        default:
            f["network"] = "tcp"
        }
    }

    /// Shadowrocket's obfsParam may be a bare host or a JSON object like {"Host":"x"}.
    static func obfsHost(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("{"), let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return (obj["Host"] ?? obj["host"]) as? String
        }
        return s
    }

    static func name(_ l: Link) -> String {
        if !l.fragment.isEmpty { return l.fragment }
        return l.q("remarks", "remark", "name") ?? "\(l.host):\(l.port.map(String.init) ?? "")"
    }

    static func parseVmess(_ line: String) throws -> ProxyNode {
        let body = String(line.dropFirst("vmess://".count))
        // v2rayN: vmess://base64(json)
        if let json = Base64.decodeString(body), let d = json.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            func s(_ k: String) -> String? {
                if let v = o[k] as? String, !v.isEmpty { return v }
                if let v = o[k] as? Int { return String(v) }
                return nil
            }
            var l = Link()
            l.host = s("add") ?? ""
            l.port = s("port").flatMap(Int.init)
            l.user = s("id")
            l.fragment = s("ps") ?? ""
            for (k, v) in ["aid": s("aid"), "scy": s("scy"), "type": s("net"), "host": s("host"),
                           "path": s("path"), "sni": s("sni"), "alpn": s("alpn"), "fp": s("fp")] {
                if let v { l.query[k] = [v] }
            }
            if s("tls") == "tls" { l.query["security"] = ["tls"] }
            if s("net") == "grpc", let p = s("path") { l.query["serviceName"] = [p] }
            guard l.user != nil, l.port != nil else { throw ShareLinkError.malformed(line) }
            var f: [String: JSONValue] = [
                "name": .string(name(l)), "type": "vmess", "server": .string(l.host), "port": .int(l.port!),
                "uuid": .string(l.user!), "alterId": .int(Int(l.q("aid") ?? "0") ?? 0),
                "cipher": .string(l.q("scy") ?? "auto"), "udp": true,
            ]
            applyTLS(l, into: &f)
            applyTransport(l, into: &f)
            return ProxyNode(f)
        }
        return try parseV(line, type: "vmess")
    }

    // MARK: - Others

    static func parseTrojan(_ line: String) throws -> ProxyNode {
        let l = try split(line)
        guard let pass = l.user, !l.host.isEmpty else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": "trojan", "server": .string(l.host),
            "port": .int(l.port ?? 443), "password": .string(pass), "udp": true,
        ]
        if let sni = l.q("sni", "peer") { f["sni"] = .string(sni) }
        if l.flag("allowInsecure", "insecure") { f["skip-cert-verify"] = true }
        if let fp = l.q("fp") { f["client-fingerprint"] = .string(fp) }
        if let alpn = l.q("alpn") { f["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
        var t: [String: JSONValue] = [:]
        applyTransport(l, into: &t)
        if let net = t["network"], net != "tcp" { f.merge(t) { a, _ in a } }
        return ProxyNode(f)
    }

    static func parseSS(_ line: String) throws -> ProxyNode {
        var l = try split(line)
        var method: String?, password: String?
        if l.port == nil, let decoded = Base64.decodeString(l.rawAuthority) {
            // legacy: ss://base64(method:pass@host:port)#name
            let inner = try split("ss://" + decoded)
            method = inner.user; password = inner.password
            l.host = inner.host; l.port = inner.port
        } else if let u = l.user {
            if let p = l.password { method = u; password = p }
            else if let d = Base64.decodeString(u), let c = d.firstIndex(of: ":") {
                method = String(d[..<c]); password = String(d[d.index(after: c)...])
            }
        }
        guard let method, let password, let port = l.port else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": "ss", "server": .string(l.host), "port": .int(port),
            "cipher": .string(method), "password": .string(password), "udp": true,
        ]
        if let plugin = l.q("plugin") {
            let parts = plugin.split(separator: ";").map(String.init)
            var opts: [String: JSONValue] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                guard let k = kv.first else { continue }  // "=" alone splits into nothing
                if kv.count == 2 { opts[k == "obfs" ? "mode" : (k == "obfs-host" ? "host" : k)] = .string(kv[1]) }
                else if k == "tls" { opts["tls"] = true }
            }
            let pname = parts.first ?? ""
            f["plugin"] = .string(pname.contains("obfs") ? "obfs" : pname)
            f["plugin-opts"] = .object(opts)
        }
        return ProxyNode(f)
    }

    static func parseHysteria2(_ line: String) throws -> ProxyNode {
        let l = try split(line)
        guard !l.host.isEmpty else { throw ShareLinkError.malformed(line) }
        let auth = [l.user, l.password].compactMap { $0 }.joined(separator: ":")
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": "hysteria2", "server": .string(l.host),
            "port": .int(l.port ?? 443), "password": .string(auth),
        ]
        if let sni = l.q("sni", "peer") { f["sni"] = .string(sni) }
        if l.flag("insecure", "allowInsecure") { f["skip-cert-verify"] = true }
        if let o = l.q("obfs") { f["obfs"] = .string(o) }
        if let o = l.q("obfs-password") { f["obfs-password"] = .string(o) }
        if let p = l.q("mport", "ports") { f["ports"] = .string(p) }
        return ProxyNode(f)
    }

    static func parseTuic(_ line: String) throws -> ProxyNode {
        let l = try split(line)
        guard let uuid = l.user, !l.host.isEmpty else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": "tuic", "server": .string(l.host), "port": .int(l.port ?? 443),
            "uuid": .string(uuid), "password": .string(l.password ?? ""), "udp-relay-mode": "native",
        ]
        if let sni = l.q("sni") { f["sni"] = .string(sni) }
        if let cc = l.q("congestion_control", "congestion-control") { f["congestion-controller"] = .string(cc) }
        if let alpn = l.q("alpn") { f["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
        if l.flag("allow_insecure", "insecure", "allowInsecure") { f["skip-cert-verify"] = true }
        return ProxyNode(f)
    }

    static func parseAnyTLS(_ line: String) throws -> ProxyNode {
        let l = try split(line)
        guard let pass = l.user, !l.host.isEmpty else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": "anytls", "server": .string(l.host),
            "port": .int(l.port ?? 443), "password": .string(pass), "udp": true,
        ]
        if let sni = l.q("sni", "peer") { f["sni"] = .string(sni) }
        if l.flag("insecure", "allowInsecure") { f["skip-cert-verify"] = true }
        if let fp = l.q("fp") { f["client-fingerprint"] = .string(fp) }
        return ProxyNode(f)
    }

    static func parsePlain(_ line: String, scheme: String) throws -> ProxyNode {
        var l = try split(line)
        if l.port == nil, let d = Base64.decodeString(l.rawAuthority) { l = try split("\(scheme)://" + d) }
        guard !l.host.isEmpty, let port = l.port else { throw ShareLinkError.malformed(line) }
        var f: [String: JSONValue] = [
            "name": .string(name(l)), "type": .string(scheme.hasPrefix("socks") ? "socks5" : "http"),
            "server": .string(l.host), "port": .int(port),
        ]
        if let u = l.user { f["username"] = .string(u) }
        if let p = l.password { f["password"] = .string(p) }
        if scheme == "https" { f["tls"] = true }
        return ProxyNode(f)
    }
}

public enum Base64 {
    public static func decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { return nil }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    public static func decodeString(_ s: String) -> String? {
        decode(s).flatMap { String(data: $0, encoding: .utf8) }
    }
}
