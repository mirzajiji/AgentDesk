// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskMCP",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskMCP", targets: ["AgentDeskMCP"])],
    dependencies: [.package(path: "../AgentDeskCore")],
    targets: [
        .target(name: "AgentDeskMCP", dependencies: ["AgentDeskCore"]),
        .testTarget(name: "AgentDeskMCPTests", dependencies: ["AgentDeskMCP"])
    ]
)
