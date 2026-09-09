// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeskDesign",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AgentDeskDesign", targets: ["AgentDeskDesign"])],
    targets: [.target(name: "AgentDeskDesign")]
)
