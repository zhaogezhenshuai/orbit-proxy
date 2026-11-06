// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Orbit", targets: ["OrbitApp"]),
        .executable(name: "orbitctl", targets: ["orbitctl"]),
    ],
    targets: [
        // Yams (YAML parser) is vendored so that builds don't need GitHub; see Vendor/Yams/README.md.
        .target(name: "CYaml", path: "Vendor/Yams/Sources/CYaml", cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "Yams", dependencies: ["CYaml"], path: "Vendor/Yams/Sources/Yams", cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "OrbitCore", dependencies: ["Yams"]),
        .executableTarget(name: "OrbitApp", dependencies: ["OrbitCore"]),
        .executableTarget(name: "orbitctl", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
    ]
)
