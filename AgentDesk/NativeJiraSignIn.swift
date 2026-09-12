#if os(macOS)
import AgentDeskCore
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation

protocol NativeJiraLogin: Sendable {
    func signIn(validateConfiguration: @escaping @Sendable () async throws -> Void,
                openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws
    func refresh(validateConfiguration: @escaping @Sendable () async throws -> Void) async throws
    func close() async
}
actor NativeJiraLoginSession: NativeJiraLogin {
    private let login: JiraOAuthLogin
    init(configuration: JiraConnectionConfiguration, registration: JiraOAuthRegistration, store: any SecretStore) throws {
        login = try JiraOAuthLogin(configuration: configuration, registration: registration, store: store)
    }
    func signIn(validateConfiguration: @escaping @Sendable () async throws -> Void,
                openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws {
        _ = try await login.signIn(validateConfiguration: { try await validateConfiguration() },
                               openBrowser: { try await openBrowser($0) })
    }
    func refresh(validateConfiguration: @escaping @Sendable () async throws -> Void) async throws {
        _ = try await login.refresh(validateConfiguration: { try await validateConfiguration() })
    }
    func close() async { await login.close() }
}

/// Prevents two native windows from writing the same grant concurrently.
actor NativeJiraLoginOwnership {
    static let shared = NativeJiraLoginOwnership()
    private var active: Set<UUID> = []
    func acquire(_ id: UUID) throws {
        guard active.insert(id).inserted else { throw JiraServiceError.unavailable }
    }
    func release(_ id: UUID) { active.remove(id) }
}

/// Publisher-controlled bundle values only; workspace content cannot select an OAuth broker.
enum NativeJiraRegistration {
    static func load(from bundle: Bundle = .main) throws -> JiraOAuthRegistration? {
        guard let value = bundle.object(forInfoDictionaryKey: "AgentDeskJiraOAuthRegistration") else { return nil }
        return try decode(value)
    }
    static func decode(_ value: Any) throws -> JiraOAuthRegistration {
        guard let fields = value as? [String: String], Set(fields.keys) == ["brokerOrigin", "clientID", "callback"],
              let origin = fields["brokerOrigin"].flatMap(URL.init(string:)),
              let callback = fields["callback"].flatMap(URL.init(string:)), let client = fields["clientID"] else {
            throw JiraOAuthError.invalidConfiguration
        }
        return try JiraOAuthRegistration(brokerOrigin: origin, clientID: client, callback: callback)
    }
}
#endif
