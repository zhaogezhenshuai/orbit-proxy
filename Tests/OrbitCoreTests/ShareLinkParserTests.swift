import XCTest
@testable import OrbitCore

final class ShareLinkParserTests: XCTestCase {
    func testShadowrocketMieru() throws {
        let line = "mierus://u-1:p-1@203.0.113.10?profile=%F0%9F%87%BA%F0%9F%87%B8US01&port=8444&protocol=TCP&traffic-pattern=dGVzdA==#%F0%9F%87%BA%F0%9F%87%B8US01"
        let nodes = try ShareLinkParser.parse(line: line)
        XCTAssertEqual(nodes.count, 1)
        let n = nodes[0]
        XCTAssertEqual(n.name, "🇺🇸US01")
        XCTAssertEqual(n.flag, "🇺🇸")
        XCTAssertEqual(n.fields["type"], "mieru")
        XCTAssertEqual(n.fields["port"], .int(8444))
        XCTAssertEqual(n.fields["transport"], "TCP")
        XCTAssertEqual(n.fields["username"], "u-1")
        XCTAssertEqual(n.fields["password"], "p-1")
        XCTAssertEqual(n.fields["traffic-pattern"], "dGVzdA==")
    }

    func testMieruMultiPortAndRange() throws {
        let nodes = try ShareLinkParser.parse(line: "mierus://a:b@192.0.2.4?port=2000-2010&protocol=TCP&port=3000&protocol=UDP#x")
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].fields["port-range"], "2000-2010")
        XCTAssertEqual(nodes[1].fields["port"], .int(3000))
        XCTAssertEqual(nodes[1].fields["transport"], "UDP")
        XCTAssertNotEqual(nodes[0].name, nodes[1].name)
    }

    func testShadowrocketVlessReality() throws {
        // base64("auto:test-uuid@198.51.100.20:8080")
        let auth = Data("auto:test-uuid@198.51.100.20:8080".utf8).base64EncodedString()
        let line = "vless://\(auth)?tfo=1&remark=%F0%9F%87%AD%F0%9F%87%B0HK&tls=1&xtls=2&sni=apple.com&pbk=PUBKEY&sid=ab12&fp=chrome"
        let n = try XCTUnwrap(ShareLinkParser.parse(line: line).first)
        XCTAssertEqual(n.name, "🇭🇰HK")
        XCTAssertEqual(n.fields["server"], "198.51.100.20")
        XCTAssertEqual(n.fields["port"], .int(8080))
        XCTAssertEqual(n.fields["uuid"], "test-uuid")
        XCTAssertEqual(n.fields["flow"], "xtls-rprx-vision")
        XCTAssertEqual(n.fields["tls"], true)
        XCTAssertEqual(n.fields["servername"], "apple.com")
        XCTAssertEqual(n.fields["client-fingerprint"], "chrome")
        XCTAssertEqual(n.fields["reality-opts"], .object(["public-key": "PUBKEY", "short-id": "ab12"]))
        XCTAssertEqual(n.fields["network"], "tcp")
    }

    func testStandardVlessWS() throws {
        let line = "vless://uuid-1@example.com:443?encryption=none&security=tls&sni=example.com&type=ws&host=cdn.example.com&path=%2Fray#WS%20node"
        let n = try XCTUnwrap(ShareLinkParser.parse(line: line).first)
        XCTAssertEqual(n.name, "WS node")
        XCTAssertEqual(n.fields["network"], "ws")
        XCTAssertEqual(n.fields["ws-opts"], .object(["path": "/ray", "headers": .object(["Host": "cdn.example.com"])]))
        XCTAssertNil(n.fields["reality-opts"])
    }

    func testV2rayNVmess() throws {
        let json = #"{"v":"2","ps":"vm","add":"192.0.2.1","port":"8443","id":"uuid-2","aid":"0","net":"ws","host":"h.com","path":"/p","tls":"tls","sni":"h.com"}"#
        let n = try XCTUnwrap(ShareLinkParser.parse(line: "vmess://" + Data(json.utf8).base64EncodedString()).first)
        XCTAssertEqual(n.name, "vm")
        XCTAssertEqual(n.fields["port"], .int(8443))
        XCTAssertEqual(n.fields["tls"], true)
        XCTAssertEqual(n.fields["network"], "ws")
    }

    func testSIP002AndLegacySS() throws {
        let user = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        let a = try XCTUnwrap(ShareLinkParser.parse(line: "ss://\(user)@192.0.2.2:8388#ss1").first)
        XCTAssertEqual(a.fields["cipher"], "aes-256-gcm")
        XCTAssertEqual(a.fields["password"], "pw")
        let legacy = Data("chacha20-ietf-poly1305:pw2@192.0.2.3:443".utf8).base64EncodedString()
        let b = try XCTUnwrap(ShareLinkParser.parse(line: "ss://\(legacy)#old").first)
        XCTAssertEqual(b.fields["server"], "192.0.2.3")
        XCTAssertEqual(b.fields["password"], "pw2")
    }

    func testHysteria2AndTrojan() throws {
        let h = try XCTUnwrap(ShareLinkParser.parse(line: "hysteria2://secret@192.0.2.5:443?sni=a.com&insecure=1#hy").first)
        XCTAssertEqual(h.fields["password"], "secret")
        XCTAssertEqual(h.fields["skip-cert-verify"], true)
        let t = try XCTUnwrap(ShareLinkParser.parse(line: "trojan://pass@192.0.2.55:443?sni=b.com#tj").first)
        XCTAssertEqual(t.fields["sni"], "b.com")
        XCTAssertNil(t.fields["network"])
    }

    func testSubscriptionBodyWithStatusLine() {
        let body = "STATUS=used 1GB\nmierus://a:b@192.0.2.4?port=1&protocol=TCP#n\nmierus://a:b@192.0.2.6?port=2&protocol=TCP#n\nfoo://bar"
        let r = SubscriptionFetcher.parse(Data(Data(body.utf8).base64EncodedString().utf8))
        XCTAssertEqual(r.info.status, "used 1GB")
        XCTAssertEqual(r.nodes.map(\.name), ["n", "n 2"])
        XCTAssertEqual(r.skipped.count, 1)
    }

    func testUserInfoHeader() {
        let i = SubscriptionFetcher.parseUserInfo("upload=100; download=200; total=1000; expire=1858037585")
        XCTAssertEqual(i.used, 300)
        XCTAssertEqual(i.total, 1000)
        XCTAssertNotNil(i.expire)
    }
}
