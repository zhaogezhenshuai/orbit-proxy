import Foundation

public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Date?
    /// Free-form status line some providers put at the top of the node list (e.g. `STATUS=...`).
    public var status: String?

    public init() {}

    public var used: Int64? {
        guard upload != nil || download != nil else { return nil }
        return (upload ?? 0) + (download ?? 0)
    }
}

public struct FetchedSubscription: Sendable {
    public var nodes: [ProxyNode]
    public var info: SubscriptionInfo
    public var skipped: [String]
    public var format: SubscriptionFormat
    /// Raw body, kept so the source can be re-parsed without fetching again.
    public var raw: Data
}

public enum SubscriptionError: Error, CustomStringConvertible {
    case http(Int)
    case noSource
    case invalidURL
    /// Nothing usable in what was fetched or imported; `format` says what it looked like.
    case noNodes(SubscriptionFormat)

    public var description: String {
        switch self {
        case .http(let c): return "subscription HTTP \(c)"
        case .noSource: return "no node source"
        case .invalidURL: return "invalid subscription URL (only https:// is supported)"
        case .noNodes(let f): return "no usable nodes (format: \(f.rawValue))"
        }
    }
}

public enum SubscriptionFetcher {
    /// Orbit's own User-Agent. "clash.meta" asks providers for the Clash Meta format, which
    /// carries most protocols; some providers only send their full list to particular clients,
    /// which is what `userAgentPresets` are for.
    public static let defaultUserAgent = "Orbit/1.0 (mihomo; clash.meta)"

    /// User-Agents of common clients, offered next to the field so a source can match the one its
    /// provider expects. Named only to say which client's format is requested.
    public static let userAgentPresets: [(name: String, value: String)] = [
        ("Orbit", defaultUserAgent),
        ("Clash Meta", "clash.meta"),
        ("Shadowrocket", "Shadowrocket/2070 CFNetwork/1410.0.3 Darwin/22.6.0"),
        ("v2rayN", "v2rayN/7.0"),
    ]

    public static func fetch(url: URL, userAgent: String = defaultUserAgent, proxyPort: Int? = nil) async throws -> FetchedSubscription {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        if let proxyPort {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort,
            ]
        } else {
            config.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: config, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        // 3xx here is a redirect HTTPSOnlyRedirects refused.
        if let code = http?.statusCode, code >= 300 { throw SubscriptionError.http(code) }
        var result = parse(data)
        var header = http?.value(forHTTPHeaderField: "subscription-userinfo")
        if header == nil {
            // Some providers only send usage info to Clash clients; a HEAD request is enough to get it.
            var head = URLRequest(url: url, timeoutInterval: 10)
            head.httpMethod = "HEAD"
            head.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
            if let (_, r) = try? await session.data(for: head) {
                header = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "subscription-userinfo")
            }
        }
        if let header {
            let h = parseUserInfo(header)
            result.info.upload = h.upload ?? result.info.upload
            result.info.download = h.download ?? result.info.download
            result.info.total = h.total ?? result.info.total
            result.info.expire = h.expire ?? result.info.expire
        }
        return result
    }

    public static func parse(_ data: Data) -> FetchedSubscription {
        let p = NodeFormats.parse(data)
        var info = SubscriptionInfo()
        info.status = p.status
        return FetchedSubscription(nodes: p.nodes, info: info, skipped: p.skipped, format: p.format, raw: data)
    }

    public static func parseUserInfo(_ header: String) -> SubscriptionInfo {
        var info = SubscriptionInfo()
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Int64(kv[1]) else { continue }
            switch kv[0] {
            case "upload": info.upload = v
            case "download": info.download = v
            case "total": info.total = v
            case "expire": info.expire = v > 0 ? Date(timeIntervalSince1970: TimeInterval(v)) : nil
            default: break
            }
        }
        return info
    }
}

/// Refuses redirects off https, so a provider (or anyone on the path) can't move the fetch to
/// plain http where the subscription could be read or rewritten.
final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}
