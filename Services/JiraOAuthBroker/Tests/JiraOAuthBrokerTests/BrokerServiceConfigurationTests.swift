import Foundation
import XCTest
@testable import JiraOAuthBroker

final class BrokerServiceConfigurationTests: XCTestCase {
    private let environment = ["AGENTDESK_JIRA_CLIENT_ID": "synthetic-client",
        "AGENTDESK_JIRA_CALLBACK": "https://broker.example/callback", "AGENTDESK_JIRA_PORT": "8765"]
    func testSeparateSecretInputAndStrictPublicConfiguration() throws {
        let config = try BrokerServiceConfiguration(environment: environment, secretInput: Data("synthetic-secret\r\n".utf8))
        XCTAssertEqual(config.port, 8765)
        XCTAssertEqual(config.clientSecret.withBytes { String(decoding: $0, as: UTF8.self) }, "synthetic-secret")
        XCTAssertFalse(String(reflecting: config).contains("synthetic-secret"))
        for secret in ["", "secret\nsecond", "secret ", String(repeating: "x", count: 32_769)] {
            XCTAssertThrowsError(try BrokerServiceConfiguration(environment: environment, secretInput: Data(secret.utf8)))
        }
        for (key, value) in [("AGENTDESK_JIRA_PORT", "0"), ("AGENTDESK_JIRA_PORT", "65536"),
                             ("AGENTDESK_JIRA_PORT", "+80"), ("AGENTDESK_JIRA_CLIENT_ID", ""),
                             ("AGENTDESK_JIRA_CALLBACK", "http://broker.example/callback"),
                             ("AGENTDESK_JIRA_CALLBACK", "https://broker.example/v1/attempts"),
                             ("AGENTDESK_JIRA_CALLBACK", "https://broker.example/callback?secret=x")] {
            var invalid = environment; invalid[key] = value
            XCTAssertThrowsError(try BrokerServiceConfiguration(environment: invalid, secretInput: Data("synthetic".utf8)))
        }
        XCTAssertThrowsError(try BrokerServiceConfiguration(environment: [:], secretInput: Data("synthetic".utf8)))
    }
}
