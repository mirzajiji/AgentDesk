import AgentDeskCore
import Foundation

public enum SecretStoreError: Error, Equatable, Sendable {
    case invalidScope, scopeMismatch, invalidValue, invalidResult, keychain(Int32)
}

public struct SecretScope: Codable, Hashable, Sendable {
    public let workspaceID: WorkspaceID
    public let projectID: ProjectID?
    public let environmentID: EnvironmentID?

    public init(workspaceID: WorkspaceID, projectID: ProjectID? = nil, environmentID: EnvironmentID? = nil) throws {
        guard environmentID == nil || projectID != nil else { throw SecretStoreError.invalidScope }
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.environmentID = environmentID
    }

    private enum CodingKeys: CodingKey { case workspaceID, projectID, environmentID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspaceID: values.decode(WorkspaceID.self, forKey: .workspaceID),
                      projectID: values.decodeIfPresent(ProjectID.self, forKey: .projectID),
                      environmentID: values.decodeIfPresent(EnvironmentID.self, forKey: .environmentID))
    }
}

/// Serializable identity only. Configuration never contains a SecretValue.
public struct SecretReference: Codable, Hashable, Sendable {
    public let scope: SecretScope
    public let id: UUID
    public init(scope: SecretScope, id: UUID = UUID()) { self.scope = scope; self.id = id }

    var account: String {
        [scope.workspaceID.rawValue, scope.projectID?.rawValue ?? "workspace",
         scope.environmentID?.rawValue ?? "all-environments", id.uuidString.lowercased()].joined(separator: "/")
    }
}

/// Deliberately not Codable. Diagnostics hide content; authorized adapters must explicitly reveal bytes.
public struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let bytes: Data
    public init(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 65_536 else { throw SecretStoreError.invalidValue }
        self.bytes = bytes
    }
    public var description: String { "<redacted secret>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    public func withBytes<T>(_ operation: (Data) throws -> T) rethrows -> T { try operation(bytes) }
}

public protocol SecretStore: Sendable {
    var scope: SecretScope { get }
    func set(_ value: SecretValue, for reference: SecretReference) async throws
    func get(_ reference: SecretReference) async throws -> SecretValue?
    func delete(_ reference: SecretReference) async throws
    func exists(_ reference: SecretReference) async throws -> Bool
}
