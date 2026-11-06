import Foundation
import OrbitCore

let usage = """
orbitctl — Orbit 命令行

  orbitctl sub <url>        添加订阅地址并设为当前来源（当前来源是订阅地址时改为修改它）
  orbitctl import <file>    导入节点文件（分享链接 / Clash YAML / sing-box JSON / SIP008）并设为当前来源
  orbitctl sources          列出节点来源（* 为当前来源）
  orbitctl use <序号|名称>  切换当前来源
  orbitctl update           重新拉取（订阅地址）或重新读取（文件、粘贴）当前来源
  orbitctl nodes            列出已解析节点
  orbitctl config           生成并校验 mihomo 配置
  orbitctl run [--system-proxy]
                            前台运行内核（Ctrl-C 退出）
  orbitctl test             启动临时内核并对全部节点测速
  orbitctl select <name>    选择节点（需内核在运行）
  orbitctl ip               经代理端口查询出口 IP（需内核在运行）

环境变量 ORBIT_HOME 可指定数据目录（默认 ~/Library/Application Support/Orbit）。
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func bytes(_ n: Int64?) -> String {
    guard let n else { return "-" }
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
let store = Store(root: ProcessInfo.processInfo.environment["ORBIT_HOME"].map { URL(fileURLWithPath: $0) })
let engine: Engine
do { engine = try Engine(store: store) } catch { fail("\(error)") }

@MainActor var signalSources: [DispatchSourceSignal] = []

/// Keeps the process alive until Ctrl-C, then stops the core and restores the system proxy.
@MainActor func stopOnInterrupt() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { engine.stop(); print("\nstopped"); exit(0) }
        s.resume()
        signalSources.append(s)
    }
}

/// Returns true when the command should keep running (the `run` command).
func run() async -> Bool {
    switch cmd {
    case "sub":
        guard args.count > 1 else { fail("missing url") }
        do {
            let r: Engine.UpdateResult?
            if var src = engine.activeSource, src.kind == .url {
                src.url = args[1]
                r = try await engine.editSource(src)
            } else {
                r = try await engine.addSource(NodeSource(name: NodeSource.defaultName(kind: .url, url: args[1]), kind: .url, url: args[1]))
            }
            print("subscription set" + (r.map { ", nodes: \($0.count) (\($0.format.rawValue))" } ?? ""))
        } catch { fail("\(error)") }

    case "import":
        guard args.count > 1 else { fail("missing file") }
        let url = URL(fileURLWithPath: args[1])
        guard let data = try? Data(contentsOf: url) else { fail("cannot read \(args[1])") }
        let name = url.lastPathComponent
        do {
            let r = try await engine.addSource(NodeSource(name: NodeSource.defaultName(kind: .file, fileName: name), kind: .file, fileName: name),
                                               content: data)
            print("imported \(r.count) nodes (\(r.format.rawValue))")
            for s in r.skipped { print("skipped: \(s)") }
        } catch { fail("\(error)") }

    case "sources":
        for (i, src) in engine.settings.sources.enumerated() {
            let mark = src.id == engine.settings.activeSourceID ? "*" : " "
            let detail = src.kind == .url ? src.url : src.kind == .file ? src.fileName : "pasted"
            print("\(mark) \(i + 1). [\(src.kind.rawValue)] \(src.name)  \(detail)")
        }
        if engine.settings.sources.isEmpty { print("no sources") }

    case "use":
        guard args.count > 1 else { fail("missing source") }
        let all = engine.settings.sources
        guard let src = Int(args[1]).flatMap({ all.indices.contains($0 - 1) ? all[$0 - 1] : nil }) ?? all.first(where: { $0.name == args[1] }) else {
            fail("no such source: \(args[1])")
        }
        do {
            try await engine.activateSource(src.id)
            print("using \(src.name): \(engine.nodes.count) nodes")
        } catch { fail("\(error)") }

    case "update":
        do {
            let r = try await engine.updateSubscription()
            print("nodes: \(r.count) (\(r.format.rawValue))")
            if let s = r.info.status { print("status: \(s)") }
            if r.info.total != nil { print("used: \(bytes(r.info.used)) / \(bytes(r.info.total))") }
            if let e = r.info.expire { print("expire: \(e)") }
            for s in r.skipped { print("skipped: \(s)") }
        } catch { fail("\(error)") }

    case "nodes":
        let byType = Dictionary(grouping: engine.nodes, by: \.type)
        for n in engine.nodes { print("\(n.type.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n.name)  \(n.server):\(n.port)") }
        print("total \(engine.nodes.count): " + byType.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))

    case "config":
        do { try engine.writeConfig() } catch { fail("\(error)") }
        let (ok, out) = engine.testConfig()
        print(engine.store.configFile.path)
        print(ok ? "config OK" : out)
        if !ok { exit(1) }

    case "run":
        if args.contains("--system-proxy") { engine.settings.systemProxy = true } else { engine.settings.systemProxy = false }
        engine.settings.tun = false
        do { try await engine.start() } catch { fail("\(error)") }
        print("mixed proxy on 127.0.0.1:\(engine.settings.mixedPort), controller 127.0.0.1:\(engine.settings.controllerPort)")
        print(engine.shellExport)
        DispatchQueue.main.async { stopOnInterrupt() }
        return true

    case "test":
        let wasRunning = (try? await engine.api.version()) != nil
        if !wasRunning {
            engine.settings.systemProxy = false
            engine.settings.tun = false
            do { try await engine.start() } catch { fail("\(error)") }
        }
        let names = engine.nodes.map(\.name)
        var raw: [String: DelayResult] = [:]
        for await (n, r) in engine.api.measure(names, url: engine.settings.testURL) { raw[n] = r }
        let outcome = await engine.reassess(raw)
        if !outcome.added.isEmpty { print("repaired: \(outcome.added.joined(separator: ", "))") }
        if !outcome.removed.isEmpty { print("unrepaired: \(outcome.removed.joined(separator: ", "))") }
        for await (n, r) in engine.api.measure(outcome.changed, url: engine.settings.testURL) { raw[n] = r }
        engine.stopProbe()
        let results = raw.map { ($0.key, $0.value.ms) }
        for (n, d) in results.sorted(by: { ($0.1 ?? .max) < ($1.1 ?? .max) }) {
            print("\(d.map { String(format: "%5d ms", $0) } ?? "timeout ")  \(n)")
        }
        print("ok \(results.filter { $0.1 != nil }.count)/\(results.count)")
        if !wasRunning { engine.core.stop() }

    case "ip":
        do {
            let r = try await ExitIP.lookup(proxyPort: engine.settings.mixedPort, chinese: true)
            print("\(r.flag) \(r.ip)  \(r.country) \(r.region) \(r.city)  \(r.isp)  \(r.asn)")
        } catch { fail("\(error)") }
    case "select":
        guard args.count > 1 else { fail("missing name") }
        do { try await engine.select(args[1]); print("selected \(args[1])") } catch { fail("\(error)") }

    default:
        print(usage)
    }
    return false
}

Task {
    if !(await run()) { exit(0) }
}
dispatchMain()
