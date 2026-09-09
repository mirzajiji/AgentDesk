import Foundation

/// An authorized scope, not an authorization grant. Integrations must pass policy before access.
public actor KeychainSecretStore: SecretStore {
    public nonisolated let scope: SecretScope
    private let backend: any KeychainBackend
    private static let service = "com.mirza.AgentDesk.secrets.v1"

    public init(scope: SecretScope) { self.scope = scope; backend = SystemKeychainBackend() }
    init(scope: SecretScope, backend: any KeychainBackend) { self.scope = scope; self.backend = backend }

    public func set(_ value: SecretValue, for reference: SecretReference) throws {
        try validate(reference)
        try value.withBytes { try backend.set($0, service: Self.service, account: reference.account) }
    }

    public func get(_ reference: SecretReference) throws -> SecretValue? {
        try validate(reference)
        guard let data = try backend.get(service: Self.service, account: reference.account) else { return nil }
        return try SecretValue(data)
    }

    public func delete(_ reference: SecretReference) throws {
        try validate(reference)
        try backend.delete(service: Self.service, account: reference.account)
    }

    public func exists(_ reference: SecretReference) throws -> Bool {
        try validate(reference)
        return try backend.exists(service: Self.service, account: reference.account)
    }

    private func validate(_ reference: SecretReference) throws {
        try Task.checkCancellation()
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
    }
}

protocol KeychainBackend: Sendable {
    func set(_ data: Data, service: String, account: String) throws
    func get(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
    func exists(service: String, account: String) throws -> Bool
}
