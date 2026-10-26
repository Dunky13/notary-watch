// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotaryWatch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NotaryWatch", targets: ["NotaryWatch"])],
    targets: [
        .target(name: "NotaryCore"),
        .executableTarget(name: "NotaryWatch", dependencies: ["NotaryCore"]),
        .testTarget(name: "NotaryCoreTests", dependencies: ["NotaryCore"]),
    ]
)
