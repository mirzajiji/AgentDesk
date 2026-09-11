import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthRegistrationTests: XCTestCase {
    func testRegistrationBindsCallbackToBrokerAndRejectsPrivateOrAmbiguousValues() throws {
        let origin = URL(string: "https://broker.example")!
        let registration = try JiraOAuthRegistration(brokerOrigin: origin, clientID: "synthetic-client", callback: URL(string: "https://broker.example/callback")!)
        XCTAssertEqual(registration.brokerOrigin, origin)
        for callback in ["https://foreign.example/callback", "https://broker.example:444/callback",
                         "https://broker.example/v1/refresh", "https://broker.example/", "https://broker.example/callback?code=value"] {
            XCTAssertThrowsError(try JiraOAuthRegistration(brokerOrigin: origin, clientID: "synthetic", callback: URL(string: callback)!))
        }
        for address in ["http://broker.example", "https://user:password@broker.example", "https://broker.example/base", "https://broker.example?secret=value"] {
            XCTAssertThrowsError(try JiraOAuthRegistration(brokerOrigin: URL(string: address)!, clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!))
        }
        XCTAssertThrowsError(try JiraOAuthRegistration(brokerOrigin: origin, clientID: "bad\nclient", callback: registration.callback))
    }
}
