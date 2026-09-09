import CryptoKit
import Foundation

public enum AuthorizationError: Error, Equatable, Sendable {
    case invalidInput, scopeMismatch, missingAuthority, denied, approvalRequired, invalidApproval
    case stalePolicy, staleSequence, expired, alreadyUsed, missingApproval, clockRegression
}

/// A digest of a resolved resource or prepared, nonsecret payload; never an execution credential.
public struct ActionFingerprint: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64, rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
    public init(bytes: Data) throws {
        guard bytes.count <= 16_777_216 else { throw AuthorizationError.invalidInput }
        rawValue = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let valid = Self(rawValue: value) else { throw AuthorizationError.invalidInput }
        self = valid
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    public static func canonical<T: Encodable>(_ value: T) throws -> Self {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try Self(bytes: encoder.encode(value))
    }
}

/// Application-owned classifications. An authenticated adapter selects this from its concrete operation;
/// a model/mobile caller cannot supply its own risk classification or authority.
public enum PolicyOperation: String, Codable, CaseIterable, Sendable {
    case readEvidence, runReadOnlyAgent, writeProject, readSecret, updateSecret
    case changeConfiguration, runShell, externalMutation, destructiveAction

    public var isMutation: Bool {
        ![.readEvidence, .runReadOnlyAgent, .readSecret].contains(self)
    }
}

public struct PolicyAction: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let runID: RunID?
    public let agentID: AgentID?
    public let operation: PolicyOperation
    public let resource: ActionFingerprint
    public let payload: ActionFingerprint

    public init(id: UUID = UUID(), scope: ProjectScope, environmentID: EnvironmentID, runID: RunID? = nil,
                agentID: AgentID? = nil, operation: PolicyOperation, resource: ActionFingerprint, payload: ActionFingerprint) throws {
        schemaVersion = 1; self.id = id; self.scope = scope; self.environmentID = environmentID
        self.runID = runID; self.agentID = agentID; self.operation = operation; self.resource = resource; self.payload = payload
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1, agentID == nil || runID != nil,
              operation != .runReadOnlyAgent || (agentID != nil && runID != nil) else { throw AuthorizationError.invalidInput }
    }
    public var fingerprint: ActionFingerprint { get throws { try validate(); return try .canonical(self) } }
    private enum CodingKeys: CodingKey { case schemaVersion, id, scope, environmentID, runID, agentID, operation, resource, payload }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(UUID.self, forKey: .id)
        scope = try c.decode(ProjectScope.self, forKey: .scope); environmentID = try c.decode(EnvironmentID.self, forKey: .environmentID)
        runID = try c.decodeIfPresent(RunID.self, forKey: .runID); agentID = try c.decodeIfPresent(AgentID.self, forKey: .agentID)
        operation = try c.decode(PolicyOperation.self, forKey: .operation)
        resource = try c.decode(ActionFingerprint.self, forKey: .resource); payload = try c.decode(ActionFingerprint.self, forKey: .payload)
        try validate()
    }
}

public enum PolicyDisposition: String, Codable, Sendable { case allow, approval, deny }
public struct PolicyRule: Codable, Equatable, Sendable {
    public let operation: PolicyOperation
    public let disposition: PolicyDisposition
    public init(_ operation: PolicyOperation, _ disposition: PolicyDisposition) { self.operation = operation; self.disposition = disposition }
}
public enum PolicyLevel: String, Codable, Sendable { case workspace, project, environment }

/// Human-readable configuration. An omitted operation denies access; duplicate rules are invalid.
public struct PolicyDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UUID
    public let level: PolicyLevel
    public let workspaceID: WorkspaceID
    public let projectID: ProjectID?
    public let environmentID: EnvironmentID?
    public let rules: [PolicyRule]

    public init(revision: UUID = UUID(), level: PolicyLevel, workspaceID: WorkspaceID, projectID: ProjectID? = nil,
                environmentID: EnvironmentID? = nil, rules: [PolicyRule]) throws {
        schemaVersion = 1; self.revision = revision; self.level = level; self.workspaceID = workspaceID
        self.projectID = projectID; self.environmentID = environmentID; self.rules = rules
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1, rules.count <= PolicyOperation.allCases.count,
              Set(rules.map(\.operation)).count == rules.count else { throw AuthorizationError.invalidInput }
        switch level {
        case .workspace: guard projectID == nil, environmentID == nil else { throw AuthorizationError.invalidInput }
        case .project: guard projectID != nil, environmentID == nil else { throw AuthorizationError.invalidInput }
        case .environment: guard projectID != nil, environmentID != nil else { throw AuthorizationError.invalidInput }
        }
    }
    public func disposition(for operation: PolicyOperation) -> PolicyDisposition { rules.first { $0.operation == operation }?.disposition ?? .deny }
    private enum CodingKeys: CodingKey { case schemaVersion, revision, level, workspaceID, projectID, environmentID, rules }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); revision = try c.decode(UUID.self, forKey: .revision)
        level = try c.decode(PolicyLevel.self, forKey: .level); workspaceID = try c.decode(WorkspaceID.self, forKey: .workspaceID)
        projectID = try c.decodeIfPresent(ProjectID.self, forKey: .projectID); environmentID = try c.decodeIfPresent(EnvironmentID.self, forKey: .environmentID)
        rules = try c.decode([PolicyRule].self, forKey: .rules); try validate()
    }
}

/// Every level must bind the same exact context. Effective rules can only become more restrictive.
public struct PolicySnapshot: Codable, Equatable, Sendable {
    public enum Environment: String, Codable, Sendable { case development, test, production }
    public let workspace: PolicyDocument
    public let project: PolicyDocument
    public let environment: PolicyDocument
    public let environmentKind: Environment
    public let workspaceLocked: Bool
    public var scope: ProjectScope { ProjectScope(workspaceID: workspace.workspaceID, projectID: project.projectID!) }
    public var environmentID: EnvironmentID { environment.environmentID! }
    public init(workspace: PolicyDocument, project: PolicyDocument, environment: PolicyDocument,
                environmentKind: Environment, workspaceLocked: Bool = false) throws {
        self.workspace = workspace; self.project = project; self.environment = environment
        self.environmentKind = environmentKind; self.workspaceLocked = workspaceLocked
        try validate()
    }
    public func validate() throws {
        try workspace.validate(); try project.validate(); try environment.validate()
        guard workspace.level == .workspace, project.level == .project, environment.level == .environment,
              workspace.workspaceID == project.workspaceID, workspace.workspaceID == environment.workspaceID,
              project.projectID == environment.projectID else { throw AuthorizationError.scopeMismatch }
    }
    public var fingerprint: ActionFingerprint { get throws { try validate(); return try .canonical(self) } }
    private enum CodingKeys: CodingKey { case workspace, project, environment, environmentKind, workspaceLocked }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspace: c.decode(PolicyDocument.self, forKey: .workspace), project: c.decode(PolicyDocument.self, forKey: .project),
                      environment: c.decode(PolicyDocument.self, forKey: .environment), environmentKind: c.decode(Environment.self, forKey: .environmentKind),
                      workspaceLocked: c.decode(Bool.self, forKey: .workspaceLocked))
    }
}
