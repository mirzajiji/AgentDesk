import Foundation

/// UUID-backed identities cannot be confused with display names or filesystem paths.
public struct EntityID<Entity: Sendable>: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    public init() { rawValue = UUID().uuidString.lowercased() }

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 36, let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a UUID identity")
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WorkspaceEntity: Sendable {}
public enum ProjectEntity: Sendable {}
public enum EnvironmentEntity: Sendable {}
public enum RunEntity: Sendable {}
public enum AgentEntity: Sendable {}
public enum SkillEntity: Sendable {}

public typealias WorkspaceID = EntityID<WorkspaceEntity>
public typealias ProjectID = EntityID<ProjectEntity>
public typealias EnvironmentID = EntityID<EnvironmentEntity>
public typealias RunID = EntityID<RunEntity>
public typealias AgentID = EntityID<AgentEntity>
public typealias SkillID = EntityID<SkillEntity>

public struct ProjectScope: Hashable, Codable, Sendable {
    public let workspaceID: WorkspaceID
    public let projectID: ProjectID

    public init(workspaceID: WorkspaceID, projectID: ProjectID) {
        self.workspaceID = workspaceID
        self.projectID = projectID
    }
}
