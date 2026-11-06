import XCTest
@testable import OrbitCore

final class RobustnessTests: XCTestCase {
    func testPluginWithBareEqualsDoesNotCrash() throws {
        let auth = Data("aes-128-gcm:pw".utf8).base64EncodedString()
        let nodes = try ShareLinkParser.parse(line: "ss://\(auth)@192.0.2.9:8388?plugin=obfs-local;=;obfs=http#x")
        XCTAssertEqual(nodes.count, 1)
    }

    func testUniqueNamesNeverCollide() {
        let nodes = ["A", "A", "A 2", "DIRECT", "PROXY"].map { ProxyNode(["name": .string($0), "type": "ss"]) }
        let names = NodeFormats.uniqueNames(nodes).map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names[0], "A")
        XCTAssertEqual(names[2], "A 2")
        XCTAssertFalse(names.contains("DIRECT"))
        XCTAssertFalse(names.contains("PROXY"))
    }

    func testSanitizeDropsRiskyTypesAndKeys() {
        var skipped: [String] = []
        let nodes = [
            ProxyNode(["name": "a", "type": "ssh", "server": "192.0.2.1", "private-key": "/etc/hosts"]),
            ProxyNode(["name": "b", "type": "vless", "server": "192.0.2.2", "dialer-proxy": "x", "interface-name": "en0"]),
        ]
        let out = NodeFormats.sanitize(nodes, skipped: &skipped)
        XCTAssertEqual(out.map(\.name), ["b"])
        XCTAssertNil(out[0].fields["dialer-proxy"])
        XCTAssertNil(out[0].fields["interface-name"])
        XCTAssertEqual(skipped.count, 1)
    }

    func testSettingsSurviveBadValues() throws {
        let json = #"""
        {"mode": "turbo", "mixedPort": "x", "selected": "n1",
         "sources": [{"id": "s1", "name": "ok", "kind": "url", "url": "https://example.com/s", "newField": 1},
                     {"id": "s2", "name": "bad", "kind": "carrier-pigeon"},
                     {"id": "s3", "kind": "paste"}],
         "activeSourceID": "s1"}
        """#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.mode, .rule)
        XCTAssertEqual(s.mixedPort, 7890)
        XCTAssertEqual(s.selected, "n1")
        XCTAssertEqual(s.sources.map(\.id), ["s1", "s3"])
        XCTAssertEqual(s.sources[0].userAgent, SubscriptionFetcher.defaultUserAgent)
        XCTAssertEqual(s.activeSourceID, "s1")
    }

    func testBrokenSettingsFileIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(root: dir)
        try Data("{not json".utf8).write(to: store.settingsFile)
        _ = store.loadSettings()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("settings.json.broken-") })
    }

    func testPortInUse() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        Darwin.listen(fd, 1)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertTrue(CoreProcess.portInUse(port))
        close(fd)
        XCTAssertFalse(CoreProcess.portInUse(port))
    }
}
