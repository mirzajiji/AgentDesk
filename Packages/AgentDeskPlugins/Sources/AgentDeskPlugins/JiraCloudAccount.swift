import Foundation

public enum JiraServiceError: Error, Equatable, Sendable {
    case authenticationRequired, accessDenied, notFound, rateLimited, unavailable, invalidResponse, inactiveAccount
}

/// Validated authenticated identity. Raw profile responses are not retained.
public struct JiraCloudAccount: Equatable, Sendable {
    public let accountID: String
    public let displayName: String

    static func decode(_ response: JiraHTTPResponse) throws -> JiraCloudAccount {
        try JiraResponseStatus.validate(response.status)
        struct Profile: Decodable {
            let accountId: String
            let displayName: String
            let active: Bool
        }
        let profile: Profile
        do { profile = try JSONDecoder().decode(Profile.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard profile.active else { throw JiraServiceError.inactiveAccount }
        guard !profile.accountId.isEmpty, profile.accountId.utf8.count <= 256,
              !profile.displayName.isEmpty, profile.displayName.utf8.count <= 1024,
              !profile.accountId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !profile.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JiraServiceError.invalidResponse
        }
        return JiraCloudAccount(accountID: profile.accountId, displayName: profile.displayName)
    }
}

enum JiraResponseStatus {
    static func validate(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401: throw JiraServiceError.authenticationRequired
        case 403: throw JiraServiceError.accessDenied
        case 404: throw JiraServiceError.notFound
        case 429: throw JiraServiceError.rateLimited
        case 500...599: throw JiraServiceError.unavailable
        default: throw JiraServiceError.invalidResponse
        }
    }
}
