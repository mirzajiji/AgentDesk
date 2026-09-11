import Foundation

/// Selects the configured site from the authorization server's accessible resources.
/// Resource URLs are compared locally; they are never used as bearer-token destinations.
struct JiraCloudResource: Equatable, Sendable {
    let id: UUID
    let scopes: Set<String>

    static func select(_ response: JiraHTTPResponse, site: URL) throws -> JiraCloudResource {
        try JiraResponseStatus.validate(response.status)
        struct Resource: Decodable {
            let id: String
            let url: URL
            let scopes: [String]
        }
        func canonical(_ url: URL) throws -> String {
            guard url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
                  url.port == nil || url.port == 443 else { throw JiraServiceError.invalidResponse }
            return host.lowercased()
        }
        let expected = try canonical(site)
        let resources: [Resource]
        do { resources = try JSONDecoder().decode([Resource].self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard resources.count <= 1000 else { throw JiraServiceError.invalidResponse }
        var selected: JiraCloudResource?
        for resource in resources {
            guard try canonical(resource.url) == expected else { continue }
            guard selected == nil, let id = UUID(uuidString: resource.id), resource.scopes.count <= 64,
                  resource.scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }) else {
                throw JiraServiceError.invalidResponse
            }
            selected = JiraCloudResource(id: id, scopes: Set(resource.scopes))
        }
        guard let selected else { throw JiraServiceError.accessDenied }
        return selected
    }

    var apiOrigin: URL {
        URL(string: "https://api.atlassian.com/ex/jira/" + id.uuidString.lowercased())!
    }
}
