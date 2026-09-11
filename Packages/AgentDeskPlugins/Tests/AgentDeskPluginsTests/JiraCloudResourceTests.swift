import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCloudResourceTests: XCTestCase {
    func testSelectsOnlyConfiguredSiteAndBuildsFixedGateway() throws {
        let id = UUID()
        let response = try payload([
            ["id": UUID().uuidString, "url": "https://other.atlassian.net", "scopes": ["write:jira-work"]],
            ["id": id.uuidString, "url": "https://synthetic.atlassian.net/", "scopes": ["read:jira-work"]]
        ])
        let resource = try JiraCloudResource.select(response, site: URL(string: "https://synthetic.atlassian.net")!)
        XCTAssertEqual(resource.id, id)
        XCTAssertEqual(resource.scopes, ["read:jira-work"])
        XCTAssertEqual(resource.apiOrigin.absoluteString, "https://api.atlassian.com/ex/jira/" + id.uuidString.lowercased())
        XCTAssertThrowsError(try JiraCloudResource.select(response, site: URL(string: "https://missing.atlassian.net")!)) {
            XCTAssertEqual($0 as? JiraServiceError, .accessDenied)
        }
    }
    func testAmbiguousAndUnsafeResourcesFailClosed() throws {
        let site = URL(string: "https://synthetic.atlassian.net")!
        let valid: [String: Any] = ["id": UUID().uuidString, "url": site.absoluteString, "scopes": ["read:jira-work"]]
        XCTAssertThrowsError(try JiraCloudResource.select(payload([valid, valid]), site: site))
        for url in ["http://synthetic.atlassian.net", "https://user@synthetic.atlassian.net", "https://synthetic.atlassian.net/path", "https://synthetic.atlassian.net?secret=value"] {
            XCTAssertThrowsError(try JiraCloudResource.select(payload([["id": UUID().uuidString, "url": url, "scopes": []]]), site: site))
        }
        XCTAssertThrowsError(try JiraCloudResource.select(payload([["id": "../other", "url": site.absoluteString, "scopes": []]]), site: site))
    }
    private func payload(_ items: [[String: Any]]) throws -> JiraHTTPResponse {
        .init(status: 200, body: try JSONSerialization.data(withJSONObject: items))
    }
}
