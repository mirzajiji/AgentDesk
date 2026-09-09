// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskSecurity",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskSecurity", targets: ["AgentDeskSecurity"])],
    dependencies: [.package(path: "../AgentDeskCore")],
    targets: [
        .target(name: "AgentDeskSecurity", dependencies: ["AgentDeskCore"]),
        .testTarget(name: "AgentDeskSecurityTests", dependencies: ["AgentDeskSecurity", "AgentDeskCore"])
    ]
)
