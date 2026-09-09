// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskCore", targets: ["AgentDeskCore"])],
    targets: [
        .target(name: "AgentDeskCore"),
        .testTarget(name: "AgentDeskCoreTests", dependencies: ["AgentDeskCore"])
    ]
)
