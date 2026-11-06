import XCTest
@testable import OrbitCore

final class NodeFormatsTests: XCTestCase {
    func testClashKeepsAmbiguousScalarsAsStrings() throws {
        let yaml = """
        proxies:
          - {name: a, type: vless, server: 192.0.2.4, port: 443, uuid: u, reality-opts: {public-key: k, short-id: 0123}}
          - name: b
            type: trojan
            server: b.example.com
            port: 443
            password: yes
          - name: c
            type: ss
        """
        let p = NodeFormats.parse(Data(yaml.utf8))
        XCTAssertEqual(p.format, .clash)
        XCTAssertEqual(p.nodes.count, 2)
        XCTAssertEqual(p.skipped.count, 1)
        XCTAssertEqual(p.nodes[0].fields["port"], .int(443))
        XCTAssertEqual(p.nodes[0].fields["reality-opts"], .object(["public-key": "k", "short-id": "0123"]))
        XCTAssertEqual(p.nodes[1].fields["password"], "yes")
    }

    func testSingBox() throws {
        let json = #"{"outbounds":[{"type":"selector","tag":"p"},{"type":"trojan","tag":"t","server":"s","server_port":443,"password":"pw","tls":{"enabled":true,"server_name":"sni"},"transport":{"type":"ws","path":"/x","headers":{"Host":"h"}}}]}"#
        let p = NodeFormats.parse(Data(json.utf8))
        XCTAssertEqual(p.format, .singBox)
        XCTAssertEqual(p.nodes.count, 1)
        let f = p.nodes[0].fields
        XCTAssertEqual(f["type"], "trojan")
        XCTAssertEqual(f["sni"], "sni")
        XCTAssertEqual(f["network"], "ws")
        XCTAssertEqual(f["ws-opts"], .object(["path": "/x", "headers": .object(["Host": "h"])]))
    }

    func testSIP008AndHTML() {
        let sip = #"{"version":1,"servers":[{"server":"a","server_port":1,"method":"aes-128-gcm","password":"p","remarks":"r"}]}"#
        XCTAssertEqual(NodeFormats.parse(Data(sip.utf8)).nodes.first?.fields["cipher"], "aes-128-gcm")
        XCTAssertEqual(NodeFormats.parse(Data("<!DOCTYPE html><html></html>".utf8)).format, .html)
        XCTAssertEqual(NodeFormats.parse(Data("hello".utf8)).format, .unknown)
    }

    func testDuplicateNamesAcrossFormats() {
        let yaml = "proxies:\n  - {name: x, type: ss, server: a, port: 1, cipher: c, password: p}\n  - {name: x, type: ss, server: b, port: 1, cipher: c, password: p}\n"
        XCTAssertEqual(NodeFormats.parse(Data(yaml.utf8)).nodes.map(\.name), ["x", "x 2"])
    }

    func testRegionFromName() {
        let cases: [(String, String)] = [
            ("🇯🇵 东京 01", "🇯🇵"), ("香港 01", "🇭🇰"), ("HK-02", "🇭🇰"), ("IEPL Tokyo", "🇯🇵"), ("US01 高速", "🇺🇸"),
            ("印度尼西亚 1", "🇮🇩"), ("印度 1", "🇮🇳"), ("中国香港 IPLC", "🇭🇰"), ("BONUS node", ""), ("深港专线", "🇭🇰"),
            ("IEPL-🇸🇬 Singapore", "🇸🇬"), ("剩余流量：10GB", ""),
        ]
        for (name, flag) in cases {
            XCTAssertEqual(ProxyNode(["name": .string(name)]).flag, flag, name)
        }
        XCTAssertEqual(ProxyNode(["name": "香港 01"]).leadingFlag, "")
    }

    func testLegacySettingsMigrate() throws {
        let json = #"{"subscriptionURL":"https://sub.example.com/s/abc","userAgent":"UA","autoUpdateHours":0,"mixedPort":7891}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.sources.count, 1)
        XCTAssertEqual(s.activeSource?.url, "https://sub.example.com/s/abc")
        XCTAssertEqual(s.activeSource?.name, "sub.example.com")
        XCTAssertEqual(s.activeSource?.userAgent, "UA")
        XCTAssertEqual(s.activeSource?.autoUpdateHours, 0)
        XCTAssertEqual(s.mixedPort, 7891)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
    }
}
