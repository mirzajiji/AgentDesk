// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskPlugins",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskPlugins", targets: ["AgentDeskPlugins"])],
    dependencies: [.package(path: "../AgentDeskCore"), .package(path: "../AgentDeskSecurity")],
    targets: [
        .target(name: "AgentDeskPlugins", dependencies: ["AgentDeskCore", "AgentDeskSecurity"]),
        .testTarget(name: "AgentDeskPluginsTests", dependencies: ["AgentDeskPlugins"])
    ]
)
