import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraIssueReadTests: XCTestCase {
    func testRequestRejectsPathInjectionAndRequiresBothScopes() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let token = try tokens()
        let now = Date(timeIntervalSince1970: 1000)
        for identifier in ["", "../other", "KEY/1", "KEY?fields=*all", "KEY#fragment", "KEY%2f1", "KEY\r\n1", String(repeating: "A", count: 129)] {
            XCTAssertThrowsError(try JiraIssueRead.make(identifier: identifier, resource: resource, tokens: token, now: now))
        }
        let request = try JiraIssueRead.make(identifier: "OLD-123", resource: resource, tokens: token, now: now)
        XCTAssertEqual(request.url?.path, resource.apiOrigin.path + "/rest/api/3/issue/OLD-123")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["fields"])
        XCTAssertThrowsError(try JiraIssueRead.make(identifier: "A-1", resource: .init(id: UUID(), scopes: []), tokens: token, now: now))
        XCTAssertThrowsError(try JiraIssueRead.make(identifier: "A-1", resource: resource, tokens: tokens(scopes: ["read:jira-user"]), now: now))
    }

    func testReadPreservesMovedIdentityAndRedactsEvidenceWithinScope() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let configuration = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [IssueProtocol.self])
        let redactor = try ContentRedactor(context: context)
        let evidence = try await JiraIssueRead.load(identifier: "OLD-123", configuration: configuration, resource: resource,
            tokens: tokens(), context: context, redactor: redactor, now: Date(timeIntervalSince1970: 1000), transport: transport)
        XCTAssertEqual(evidence.requestedIdentifier, "OLD-123")
        XCTAssertEqual(evidence.resolvedKey, "NEW-123")
        XCTAssertEqual(evidence.issueID, "123")
        XCTAssertEqual(evidence.content.context, context)
        XCTAssertTrue(evidence.content.text.contains("Synthetic issue"))
        XCTAssertFalse(evidence.content.text.contains("synthetic-private-value"))
        let foreign = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: environment, runID: RunID())
        do {
            _ = try await JiraIssueRead.load(identifier: "OLD-123", configuration: configuration, resource: resource,
                tokens: tokens(), context: foreign, redactor: redactor, now: Date(timeIntervalSince1970: 1000), transport: transport)
            XCTFail("Foreign context accepted")
        } catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
        await transport.close()
    }

    private func tokens(scopes: Set<String> = ["read:jira-work"]) throws -> JiraOAuthTokens {
        try .init(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: scopes)
    }
}

private final class IssueProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"123","key":"NEW-123","fields":{"summary":"Synthetic issue","description":{"type":"doc","version":1,"content":[]},"password":"synthetic-private-value"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
