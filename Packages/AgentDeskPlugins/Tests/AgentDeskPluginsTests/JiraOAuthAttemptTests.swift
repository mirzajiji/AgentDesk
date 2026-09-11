import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthAttemptTests: XCTestCase {
    func testCallbackIsScopedAndConsumedOnce() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let connection = UUID(), now = Date(timeIntervalSince1970: 1000)
        let callback = try XCTUnwrap(URL(string: "https://login.example.test/callback"))
        let attempt = try JiraOAuthAttempt(scope: scope, connectionID: connection, clientID: "synthetic-client",
            callback: callback, scopes: ["read:jira-user"], now: now)
        let authorization = await attempt.authorizationURL
        let state = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        var response = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        response.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic-code")]
        let url = try XCTUnwrap(response.url)
        do {
            _ = try await attempt.consume(url, in: scope, connectionID: UUID(), now: now)
            XCTFail("Foreign connection accepted")
        } catch { XCTAssertEqual(error as? JiraOAuthError, .invalidCallback) }
        let secret = try await attempt.consume(url, in: scope, connectionID: connection, now: now)
        XCTAssertEqual(secret.withBytes { String(decoding: $0, as: UTF8.self) }, "synthetic-code")
        XCTAssertFalse(String(describing: secret).contains("synthetic-code"))
        do {
            _ = try await attempt.consume(url, in: scope, connectionID: connection, now: now)
            XCTFail("Callback replay accepted")
        } catch { XCTAssertEqual(error as? JiraOAuthError, .alreadyUsed) }
    }

    func testClockRegressionPermanentlyInvalidatesAttempt() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let connection = UUID(), now = Date(timeIntervalSince1970: 1000)
        let callback = try XCTUnwrap(URL(string: "https://login.example.test/callback"))
        let attempt = try JiraOAuthAttempt(scope: scope, connectionID: connection, clientID: "synthetic-client",
            callback: callback, scopes: ["read:jira-user"], now: now)
        let authorization = await attempt.authorizationURL
        let state = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        var response = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        response.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic-code")]
        let url = try XCTUnwrap(response.url)
        do {
            _ = try await attempt.consume(url, in: scope, connectionID: connection, now: now.addingTimeInterval(-1))
            XCTFail("Backward clock accepted")
        } catch { XCTAssertEqual(error as? JiraOAuthError, .expired) }
        do {
            _ = try await attempt.consume(url, in: scope, connectionID: connection, now: now)
            XCTFail("Invalidated attempt revived")
        } catch { XCTAssertEqual(error as? JiraOAuthError, .alreadyUsed) }
    }

    func testStateDuplicatesAndExpiredCallbacksAreRejected() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let connection = UUID(), now = Date(timeIntervalSince1970: 1000)
        let callback = try XCTUnwrap(URL(string: "https://login.example.test/callback"))
        let attempt = try JiraOAuthAttempt(scope: scope, connectionID: connection, clientID: "synthetic-client",
            callback: callback, scopes: ["read:jira-user"], now: now)
        let authorization = await attempt.authorizationURL
        let state = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        var response = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        for items in [[URLQueryItem(name: "state", value: "wrong"), .init(name: "code", value: "code")],
                      [.init(name: "state", value: state), .init(name: "state", value: state), .init(name: "code", value: "code")]] {
            response.queryItems = items
            do {
                _ = try await attempt.consume(XCTUnwrap(response.url), in: scope, connectionID: connection, now: now)
                XCTFail("Invalid state accepted")
            } catch { XCTAssertEqual(error as? JiraOAuthError, .invalidCallback) }
        }
        response.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "code")]
        do {
            _ = try await attempt.consume(XCTUnwrap(response.url), in: scope, connectionID: connection, now: now.addingTimeInterval(600))
            XCTFail("Expired callback accepted")
        } catch { XCTAssertEqual(error as? JiraOAuthError, .expired) }
    }
}
