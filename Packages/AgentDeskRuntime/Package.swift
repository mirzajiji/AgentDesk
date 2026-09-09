// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskRuntime",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskRuntime", targets: ["AgentDeskRuntime"])],
    dependencies: [.package(path: "../AgentDeskCore"), .package(path: "../AgentDeskPersistence"), .package(path: "../AgentDeskSecurity")],
    targets: [
        .target(name: "AgentDeskRuntime", dependencies: ["AgentDeskCore", "AgentDeskPersistence", "AgentDeskSecurity"]),
        .testTarget(name: "AgentDeskRuntimeTests", dependencies: ["AgentDeskRuntime", "AgentDeskCore", "AgentDeskPersistence", "AgentDeskSecurity"])
    ]
)
