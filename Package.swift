// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LidLidCompatibility",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LidLidCompatibility", targets: ["LidLidCompatibility"]),
        .executable(name: "LidLidSleepService", targets: ["LidLidSleepService"])
    ],
    targets: [
        .target(name: "LidOnceCore"),
        .target(name: "LidLidServiceCore"),
        .target(name: "LidLidServiceProtocol"),
        .target(name: "LidLidServiceAuth", dependencies: ["LidLidServiceProtocol"]),
        .target(name: "LidOnceSystem", dependencies: ["LidLidServiceProtocol"]),
        .executableTarget(
            name: "LidLidCompatibility",
            dependencies: ["LidOnceCore", "LidOnceSystem", "LidLidServiceProtocol"]
        ),
        .executableTarget(
            name: "LidLidSleepService",
            dependencies: ["LidLidServiceCore", "LidLidServiceProtocol", "LidLidServiceAuth", "LidOnceSystem"]
        ),
        .testTarget(
            name: "LidLidServiceTests",
            dependencies: ["LidLidServiceCore", "LidLidServiceProtocol", "LidLidServiceAuth"]
        )
    ]
)
