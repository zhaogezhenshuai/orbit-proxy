import Foundation

/// Sets macOS HTTP/HTTPS/SOCKS proxies through `networksetup`, which admin users can run without sudo.
public enum SystemProxy {
    static let bypass = [
        "localhost", "127.0.0.1", "::1", "*.local", "169.254/16", "10.0.0.0/8", "172.16.0.0/12",
        "192.168.0.0/16", "timestamp.apple.com", "sequoia.apple.com", "seed-sequoia.siri.apple.com",
    ]

    @discardableResult
    static func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    /// Enabled services backed by real hardware (skips VPN services such as other proxy apps' tunnels).
    public static func services() -> [String] {
        let hw = run(["-listallhardwareports"]).1
            .split(separator: "\n").filter { $0.hasPrefix("Hardware Port: ") }
            .map { String($0.dropFirst("Hardware Port: ".count)) }
        let all = run(["-listallnetworkservices"]).1.split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") }
        let matched = all.filter { hw.contains($0) }
        return matched.isEmpty ? all : matched
    }

    public static func enable(port: Int) {
        for s in services() {
            run(["-setwebproxy", s, "127.0.0.1", String(port)])
            run(["-setsecurewebproxy", s, "127.0.0.1", String(port)])
            run(["-setsocksfirewallproxy", s, "127.0.0.1", String(port)])
            run(["-setproxybypassdomains", s] + bypass)
        }
    }

    /// Turns proxies off only on services that still point at our port, so another tool's settings survive.
    public static func disable(port: Int) {
        for s in services() {
            let web = run(["-getwebproxy", s]).1
            guard web.contains("Server: 127.0.0.1") && web.contains("Port: \(port)") else { continue }
            run(["-setwebproxystate", s, "off"])
            run(["-setsecurewebproxystate", s, "off"])
            run(["-setsocksfirewallproxystate", s, "off"])
        }
    }

    public static func isEnabled(port: Int) -> Bool {
        guard let s = services().first else { return false }
        let web = run(["-getwebproxy", s]).1
        return web.contains("Enabled: Yes") && web.contains("Port: \(port)")
    }
}
