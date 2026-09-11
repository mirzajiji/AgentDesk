// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "JiraOAuthBroker", platforms: [.macOS(.v15)],
    products: [.library(name: "JiraOAuthBroker", targets: ["JiraOAuthBroker"]),
               .executable(name: "jira-oauth-broker", targets: ["JiraOAuthBrokerService"])],
    dependencies: [.package(path: "../../Packages/AgentDeskSecurity")],
    targets: [.target(name: "JiraOAuthBroker", dependencies: ["AgentDeskSecurity"]),
              .executableTarget(name: "JiraOAuthBrokerService", dependencies: ["JiraOAuthBroker", "AgentDeskSecurity"]),
              .testTarget(name: "JiraOAuthBrokerTests", dependencies: ["JiraOAuthBroker"])])
