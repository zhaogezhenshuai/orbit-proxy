import XCTest
@testable import OrbitCore

final class CoreProcessTests: XCTestCase {
    /// The TUN launcher goes through AppleScript's `do shell script` as one multi-line `sh -c`
    /// script; quotes, backslashes, `$` and newlines in it and in its arguments must survive.
    func testInlineScriptSurvivesAppleScriptQuoting() throws {
        let script = #"""
        printf '%s|' "$1" "$2"
        echo "done \"ok\" \\ $#"
        """#
        let args = [script, "orbit-tun", "/Library/Application Support/Orbit's \"dir\"", "a\\b $HOME"]
        let shell = "/bin/sh -c " + args.map(CoreProcess.shellQuote).joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(CoreProcess.appleScriptEscape(shell))\""]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(o.trimmingCharacters(in: .newlines),
                       "/Library/Application Support/Orbit's \"dir\"|a\\b $HOME|done \"ok\" \\ 2")
    }

    func testTunConfigUsesRootRulesetDir() throws {
        let store = Store(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let cfg = ConfigBuilder.build(settings: Settings(), nodes: [], store: store, rulesetDir: CoreProcess.rootRulesetDir)
        let providers = try XCTUnwrap(cfg["rule-providers"] as? [String: [String: Any]])
        XCTAssertFalse(providers.isEmpty)
        for (name, p) in providers { XCTAssertEqual(p["path"] as? String, "ruleset/\(name).mrs") }
    }

    func testLANRequiresPasswordExceptLocally() {
        let store = Store(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var s = Settings()
        XCTAssertNil(ConfigBuilder.build(settings: s, nodes: [], store: store)["authentication"])
        s.allowLAN = true
        s.lanUser = "me"
        s.lanPassword = "pw:1"
        let cfg = ConfigBuilder.build(settings: s, nodes: [], store: store)
        XCTAssertEqual(cfg["authentication"] as? [String], ["me:pw:1"])
        XCTAssertEqual(cfg["skip-auth-prefixes"] as? [String], ["127.0.0.1/8", "::1/128"])
    }

    func testLANCredentialsNormalized() {
        var s = Settings()
        s.lanUser = " a:b c "
        s.lanPassword = "  "
        s.normalizeLANCredentials(fallbackPassword: "keep")
        XCTAssertEqual(s.lanUser, "abc")
        XCTAssertEqual(s.lanPassword, "keep")
        s.lanUser = ":"
        s.normalizeLANCredentials(fallbackPassword: "keep")
        XCTAssertEqual(s.lanUser, "orbit")
        XCTAssertNotEqual(Settings().lanPassword, Settings().lanPassword)
        XCTAssertEqual(Settings.randomPassword().count, 16)
    }
}
