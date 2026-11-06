import Foundation

/// The public address traffic leaves from, as seen by an IP lookup service.
public struct ExitIP: Equatable, Sendable {
    public var ip: String
    public var countryCode: String = ""
    public var country: String = ""
    public var region: String = ""
    public var city: String = ""
    public var isp: String = ""
    /// e.g. "AS2914 NTT America, Inc."
    public var asn: String = ""

    public init(ip: String, countryCode: String = "", country: String = "", region: String = "",
                city: String = "", isp: String = "", asn: String = "") {
        self.ip = ip
        self.countryCode = countryCode
        self.country = country
        self.region = region
        self.city = city
        self.isp = isp
        self.asn = asn
    }

    public var flag: String {
        let base: UInt32 = 0x1F1E6 - 65
        let scalars = countryCode.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : ""
    }

    /// Lookup services queried through the proxy, tried in order; ConfigBuilder routes their domains
    /// to PROXY so rule mode can't send the query direct. Several, because free services rate-limit
    /// busy shared exit IPs (common on proxy nodes).
    public static let hosts = ["ip-api.com", "ipwho.is", "api.ip.sb", "ipinfo.io"]

    /// Queries the exit IP through the local mixed port. `chinese` picks the place-name language
    /// where the service supports it. Each call uses a fresh session so a node switch is never
    /// hidden by a reused connection.
    public static func lookup(proxyPort: Int, chinese: Bool, timeout: TimeInterval = 6) async throws -> ExitIP {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort,
        ]
        cfg.httpAdditionalHeaders = ["User-Agent": "Orbit"]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let lang = chinese ? "zh-CN" : "en"
        // ip-api.com is HTTP-only on its free tier (the app allows it via an ATS exception).
        let providers: [(String, (Data) throws -> ExitIP)] = [
            ("http://ip-api.com/json/?lang=\(lang)&fields=status,country,countryCode,regionName,city,isp,org,as,query", parseIPAPI),
            ("https://ipwho.is/?lang=\(lang)&fields=success,ip,country,country_code,region,city,connection", parseIPWho),
            ("https://api.ip.sb/geoip", parseIPSB),
            ("https://ipinfo.io/json", parseIPInfo),
        ]
        var lastError: Error = BadResponse()
        for (url, parse) in providers {
            do {
                let (d, resp) = try await session.data(from: URL(string: url)!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw BadResponse() }
                return try parse(d)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    struct BadResponse: Error {}

    static func parseIPAPI(_ data: Data) throws -> ExitIP {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["status"] as? String == "success", let ip = o["query"] as? String, !ip.isEmpty else { throw BadResponse() }
        return ExitIP(ip: ip, countryCode: o["countryCode"] as? String ?? "", country: o["country"] as? String ?? "",
                      region: o["regionName"] as? String ?? "", city: o["city"] as? String ?? "",
                      isp: o["isp"] as? String ?? "", asn: o["as"] as? String ?? "")
    }

    static func parseIPWho(_ data: Data) throws -> ExitIP {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["success"] as? Bool == true, let ip = o["ip"] as? String, !ip.isEmpty else { throw BadResponse() }
        let conn = o["connection"] as? [String: Any] ?? [:]
        let org = conn["org"] as? String ?? ""
        let asn = (conn["asn"] as? Int).map { "AS\($0)" + (org.isEmpty ? "" : " \(org)") } ?? ""
        // ipwho.is' "isp" is often a street address; the org name reads better.
        return ExitIP(ip: ip, countryCode: o["country_code"] as? String ?? "", country: o["country"] as? String ?? "",
                      region: o["region"] as? String ?? "", city: o["city"] as? String ?? "", isp: org, asn: asn)
    }

    static func parseIPSB(_ data: Data) throws -> ExitIP {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = o["ip"] as? String, !ip.isEmpty else { throw BadResponse() }
        let org = o["asn_organization"] as? String ?? ""
        let asn = (o["asn"] as? Int).map { "AS\($0)" + (org.isEmpty ? "" : " \(org)") } ?? ""
        return ExitIP(ip: ip, countryCode: o["country_code"] as? String ?? "", country: o["country"] as? String ?? "",
                      region: o["region"] as? String ?? "", city: o["city"] as? String ?? "",
                      isp: o["isp"] as? String ?? "", asn: asn)
    }

    static func parseIPInfo(_ data: Data) throws -> ExitIP {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = o["ip"] as? String, !ip.isEmpty else { throw BadResponse() }
        let cc = o["country"] as? String ?? ""
        return ExitIP(ip: ip, countryCode: cc, country: Locale.current.localizedString(forRegionCode: cc) ?? cc,
                      region: o["region"] as? String ?? "", city: o["city"] as? String ?? "",
                      asn: o["org"] as? String ?? "")
    }
}
