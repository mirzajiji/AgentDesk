// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskPersistence",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskPersistence", targets: ["AgentDeskPersistence"])],
    dependencies: [.package(path: "../AgentDeskCore")],
    targets: [
        .target(name: "AgentDeskPersistence", dependencies: ["AgentDeskCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "AgentDeskPersistenceTests", dependencies: ["AgentDeskPersistence", "AgentDeskCore"])
    ]
)
