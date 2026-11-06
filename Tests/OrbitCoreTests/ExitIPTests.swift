import XCTest
@testable import OrbitCore

final class ExitIPTests: XCTestCase {
    func testIPAPI() throws {
        let json = #"{"status":"success","country":"日本","countryCode":"JP","regionName":"东京都","city":"东京","isp":"NTT","org":"","as":"AS2914 NTT America, Inc.","query":"203.0.113.7"}"#
        let r = try ExitIP.parseIPAPI(Data(json.utf8))
        XCTAssertEqual(r.ip, "203.0.113.7")
        XCTAssertEqual(r.flag, "🇯🇵")
        XCTAssertEqual(r.city, "东京")
        XCTAssertEqual(r.asn, "AS2914 NTT America, Inc.")
    }

    func testIPAPIFailure() {
        XCTAssertThrowsError(try ExitIP.parseIPAPI(Data(#"{"status":"fail","message":"quota"}"#.utf8)))
    }

    func testIPInfo() throws {
        let json = #"{"ip":"2001:db8::1","city":"Hong Kong","region":"Hong Kong","country":"HK","org":"AS9269 HKBN"}"#
        let r = try ExitIP.parseIPInfo(Data(json.utf8))
        XCTAssertEqual(r.ip, "2001:db8::1")
        XCTAssertEqual(r.flag, "🇭🇰")
        XCTAssertEqual(r.asn, "AS9269 HKBN")
    }

    func testIPWho() throws {
        let json = #"{"ip":"192.0.2.4","success":true,"country":"日本","country_code":"JP","region":"东京都","city":"东京","connection":{"asn":2914,"org":"NTT","isp":"1-1 Street"}}"#
        let r = try ExitIP.parseIPWho(Data(json.utf8))
        XCTAssertEqual(r.isp, "NTT")
        XCTAssertEqual(r.asn, "AS2914 NTT")
    }

    func testRulesRouteLookupsThroughProxy() {
        var s = Settings()
        s.customRules = ["DOMAIN,example.com,DIRECT"]
        let cfg = ConfigBuilder.build(settings: s, nodes: [], store: Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-test")))
        let rules = cfg["rules"] as? [String] ?? []
        XCTAssertEqual(rules.first, "DOMAIN,example.com,DIRECT")
        XCTAssertTrue(rules.contains("DOMAIN,ip-api.com,PROXY"))
        XCTAssertLessThan(rules.firstIndex(of: "DOMAIN,ipinfo.io,PROXY")!, rules.firstIndex(of: "MATCH,PROXY")!)
    }
}
