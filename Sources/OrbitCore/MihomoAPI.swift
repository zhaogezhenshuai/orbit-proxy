import Foundation

public struct ProxyState: Decodable, Sendable {
    public struct History: Decodable, Sendable { public let delay: Int }
    public let name: String
    public let type: String
    public let now: String?
    public let all: [String]?
    public let history: [History]?
    public let alive: Bool?

    public var lastDelay: Int? {
        guard let d = history?.last?.delay else { return nil }
        return d
    }
}

public enum DelayResult: Equatable, Sendable {
    case ok(Int)
    /// No answer within the timeout: the server or its route is down.
    case timeout
    /// The proxy errored right away, e.g. the server refused the connection or the handshake.
    case failed

    public var isOK: Bool { if case .ok = self { return true } else { return false } }
    public var ms: Int? { if case .ok(let v) = self { return v } else { return nil } }
}

public enum APIError: Error, CustomStringConvertible {
    case status(Int, String)
    public var description: String {
        switch self { case .status(let c, let b): return "mihomo API \(c): \(b)" }
    }
}

/// Client for mihomo's RESTful external controller.
public struct MihomoAPI: Sendable {
    public let base: URL
    public let secret: String
    let session: URLSession

    public init(port: Int, secret: String) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 30
        session = URLSession(configuration: c)
    }

    /// Percent-encodes a path segment byte-wise (node names contain emoji, CJK and `/`).
    static func seg(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if b < 0x80 && (c.isLetter || c.isNumber || "-._~".contains(c)) { out.append(c) }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.status(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    public func version() async throws -> String {
        let d = try await request("GET", "/version", timeout: 2)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["version"] as? String ?? "?"
    }

    public func proxies() async throws -> [String: ProxyState] {
        struct R: Decodable { let proxies: [String: ProxyState] }
        return try JSONDecoder().decode(R.self, from: try await request("GET", "/proxies")).proxies
    }

    public func select(group: String, proxy: String) async throws {
        _ = try await request("PUT", "/proxies/\(Self.seg(group))", body: ["name": proxy])
    }

    /// Returns delay in ms, or nil on timeout / failure.
    public func delay(proxy: String, url: String, timeoutMs: Int = 5000) async -> Int? {
        if case .ok(let ms) = await delayResult(proxy: proxy, url: url, timeoutMs: timeoutMs) { return ms }
        return nil
    }

    /// mihomo answers 504 when the test ran out of time and 503 when the proxy itself errored
    /// (connection refused, handshake rejected), which is worth telling apart in the UI.
    public func delayResult(proxy: String, url: String, timeoutMs: Int) async -> DelayResult {
        do {
            let d = try await request("GET", "/proxies/\(Self.seg(proxy))/delay",
                                      query: ["url": url, "timeout": String(timeoutMs)],
                                      timeout: TimeInterval(timeoutMs) / 1000 + 3)
            if let ms = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["delay"] as? Int, ms > 0 { return .ok(ms) }
            return .failed
        } catch APIError.status(503, _) {
            return .failed
        } catch {
            return .timeout
        }
    }

    /// Tests nodes with bounded concurrency. A node that fails gets one more, longer attempt:
    /// mieru handshakes occasionally drop, and one miss shouldn't mark a working node dead.
    public func measure(_ names: [String], url: String, concurrency: Int = 12,
                        timeoutMs: Int = 5000, retryTimeoutMs: Int = 8000) -> AsyncStream<(String, DelayResult)> {
        AsyncStream { cont in
            let task = Task {
                await withTaskGroup(of: (String, DelayResult).self) { g in
                    var pending = names[...]
                    func next() -> Bool {
                        guard let n = pending.popFirst() else { return false }
                        g.addTask {
                            let r = await self.delayResult(proxy: n, url: url, timeoutMs: timeoutMs)
                            if case .ok = r { return (n, r) }
                            return (n, await self.delayResult(proxy: n, url: url, timeoutMs: retryTimeoutMs))
                        }
                        return true
                    }
                    for _ in 0..<concurrency where next() {}
                    for await r in g {
                        cont.yield(r)
                        _ = next()
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Tests every member of a group concurrently inside mihomo. Missing entries failed.
    public func groupDelay(group: String, url: String, timeoutMs: Int = 5000) async throws -> [String: Int] {
        let d = try await request("GET", "/group/\(Self.seg(group))/delay",
                                  query: ["url": url, "timeout": String(timeoutMs)],
                                  timeout: TimeInterval(timeoutMs) / 1000 + 10)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Int]) ?? [:]
    }

    public func patchConfig(_ body: [String: Any]) async throws {
        _ = try await request("PATCH", "/configs", body: body)
    }

    public func reload(path: String) async throws {
        _ = try await request("PUT", "/configs", query: ["force": "true"], body: ["path": path], timeout: 20)
    }

    /// Reloads from config text instead of a file the core would have to read.
    public func reload(payload: String) async throws {
        _ = try await request("PUT", "/configs", query: ["force": "true"], body: ["payload": payload], timeout: 20)
    }

    public func closeAllConnections() async {
        _ = try? await request("DELETE", "/connections")
    }

    public func refreshRuleProvider(_ name: String) async {
        _ = try? await request("PUT", "/providers/rules/\(Self.seg(name))", timeout: 60)
    }

    public func ruleProviderCounts() async -> [String: Int] {
        guard let d = try? await request("GET", "/providers/rules"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = o["providers"] as? [String: [String: Any]] else { return [:] }
        return p.compactMapValues { $0["ruleCount"] as? Int }
    }

    /// Streams `{"up":bytes/s,"down":bytes/s}` once per second until cancelled.
    public func traffic() -> AsyncThrowingStream<(up: Int, down: Int), Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("traffic"))
                    req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = .infinity
                    let (bytes, _) = try await session.bytes(for: req)
                    for try await line in bytes.lines {
                        if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int] {
                            cont.yield((o["up"] ?? 0, o["down"] ?? 0))
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
