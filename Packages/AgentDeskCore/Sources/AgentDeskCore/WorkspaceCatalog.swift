import Foundation

public enum CatalogError: Error, Equatable, Sendable, LocalizedError {
    case invalidName, duplicateName, invalidConfiguration, unsupportedVersion, scopeMismatch, busy

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a name of 1–100 characters without slashes or control characters."
        case .duplicateName: "That name is already used here. Choose another name."
        case .invalidConfiguration: "A saved configuration is invalid. Your files have been preserved."
        case .unsupportedVersion: "This configuration requires a different version of AgentDesk."
        case .scopeMismatch: "This item does not belong to the selected workspace."
        case .busy: "Another window is saving changes. Try again."
        }
    }
}

public struct WorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: WorkspaceID
    public let name: String
    public let createdAt: Date
}

public struct ProjectRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: ProjectID
    public let workspaceID: WorkspaceID
    public let name: String
    public let createdAt: Date
    public var scope: ProjectScope { ProjectScope(workspaceID: workspaceID, projectID: id) }
}

/// The local Mac's configuration catalog. Remote callers must enter through policy services,
/// not this local administrative interface. All data lives in a caller-authorized container.
public actor WorkspaceCatalog {
    private let root: ConfigurationDirectory

    /// The application creates/authorizes its own storage container before opening the catalog.
    public init(container: URL) throws { root = try ConfigurationDirectory(trustedContainer: container) }

    public func workspaces() throws -> [WorkspaceRecord] {
        try root.withLock { try readWorkspaces() }
    }

    public func workspace(_ id: WorkspaceID) throws -> WorkspaceRecord {
        try root.withLock { try loadWorkspace(id) }
    }

    public func createWorkspace(name: String) throws -> WorkspaceRecord {
        try root.withLock {
            let name = try Self.validName(name)
            try Self.checkDuplicate(name, in: readWorkspaces().map(\.name))
            let record = WorkspaceRecord(schemaVersion: 1, id: WorkspaceID(), name: name, createdAt: Date())
            let stagingName = ".new-\(record.id)"
            let staging = try root.createChild(stagingName)
            var published = false
            defer {
                if !published {
                    staging.remove("workspace.json")
                    staging.remove("Projects", directory: true)
                    root.remove(stagingName, directory: true)
                }
            }
            _ = try staging.createChild("Projects")
            try staging.write(Self.encode(record), to: "workspace.json")
            try root.publishChild(stagingName, as: record.id.rawValue)
            published = true
            return record
        }
    }

    public func renameWorkspace(_ id: WorkspaceID, name: String) throws -> WorkspaceRecord {
        try root.withLock {
            let name = try Self.validName(name)
            let existing = try loadWorkspace(id)
            try Self.checkDuplicate(name, in: readWorkspaces().filter { $0.id != id }.map(\.name))
            let updated = WorkspaceRecord(schemaVersion: 1, id: id, name: name, createdAt: existing.createdAt)
            try root.child(id.rawValue).write(Self.encode(updated), to: "workspace.json", replacing: true)
            return updated
        }
    }

    public func projects(in workspaceID: WorkspaceID) throws -> [ProjectRecord] {
        try root.withLock {
            _ = try loadWorkspace(workspaceID)
            return try readProjects(in: workspaceID)
        }
    }

    public func project(_ scope: ProjectScope) throws -> ProjectRecord {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID)
            return try loadProject(scope)
        }
    }

    public func createProject(in workspaceID: WorkspaceID, name: String) throws -> ProjectRecord {
        try root.withLock {
            let name = try Self.validName(name)
            _ = try loadWorkspace(workspaceID)
            try Self.checkDuplicate(name, in: readProjects(in: workspaceID).map(\.name))
            let record = ProjectRecord(schemaVersion: 1, id: ProjectID(), workspaceID: workspaceID,
                                       name: name, createdAt: Date())
            let parent = try root.child(workspaceID.rawValue).child("Projects")
            let stagingName = ".new-\(record.id)"
            let staging = try parent.createChild(stagingName)
            var published = false
            defer {
                if !published {
                    staging.remove("project.json")
                    parent.remove(stagingName, directory: true)
                }
            }
            try staging.write(Self.encode(record), to: "project.json")
            try parent.publishChild(stagingName, as: record.id.rawValue)
            published = true
            return record
        }
    }

    public func renameProject(_ scope: ProjectScope, name: String) throws -> ProjectRecord {
        try root.withLock {
            let name = try Self.validName(name)
            _ = try loadWorkspace(scope.workspaceID)
            let existing = try loadProject(scope)
            try Self.checkDuplicate(name, in: readProjects(in: scope.workspaceID).filter { $0.id != scope.projectID }.map(\.name))
            let updated = ProjectRecord(schemaVersion: 1, id: existing.id, workspaceID: scope.workspaceID,
                                        name: name, createdAt: existing.createdAt)
            try root.child(scope.workspaceID.rawValue).child("Projects").child(scope.projectID.rawValue)
                .write(Self.encode(updated), to: "project.json", replacing: true)
            return updated
        }
    }

    public func agentStore(in scope: ProjectScope) throws -> ProjectAgentStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID)
            _ = try loadProject(scope)
            return try ProjectAgentStore(scope: scope, workspaceRoot: root,
                                         project: root.child(scope.workspaceID.rawValue).child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func instructionStore(in scope: ProjectScope) throws -> ProjectInstructionStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID)
            _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return try ProjectInstructionStore(scope: scope, root: root, workspace: workspace,
                                                project: workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func executionConfigurationStore(in scope: ProjectScope) throws -> ProjectExecutionConfigurationStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID)
            _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return try ProjectExecutionConfigurationStore(scope: scope, root: root, workspace: workspace,
                                                           project: workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func pluginConfigurationStore<Value: ScopedPluginConfiguration>(
        for type: Value.Type, in scope: ProjectScope
    ) throws -> ProjectPluginConfigurationStore<Value> {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return ProjectPluginConfigurationStore(scope: scope, root: root, workspace: workspace,
                project: try workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func mcpConfigurationStore<Value: ScopedMCPConfiguration>(
        for type: Value.Type, in scope: ProjectScope
    ) throws -> ProjectMCPConfigurationStore<Value> {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return ProjectMCPConfigurationStore(scope: scope, root: root, workspace: workspace,
                project: try workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func bugStore(in scope: ProjectScope) throws -> ProjectBugStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return ProjectBugStore(scope: scope, root: root, workspace: workspace,
                project: try workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func memoryStore(in scope: ProjectScope) throws -> ProjectMemoryStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return ProjectMemoryStore(scope: scope, root: root, workspace: workspace,
                project: try workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func requirementStore(in scope: ProjectScope) throws -> ProjectRequirementStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return ProjectRequirementStore(scope: scope, root: root, workspace: workspace,
                project: try workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    public func skillStore(in scope: ProjectScope) throws -> ProjectSkillStore {
        try root.withLock {
            _ = try loadWorkspace(scope.workspaceID); _ = try loadProject(scope)
            let workspace = try root.child(scope.workspaceID.rawValue)
            return try ProjectSkillStore(scope: scope, root: root, workspace: workspace,
                                         project: workspace.child("Projects").child(scope.projectID.rawValue))
        }
    }

    private func readWorkspaces() throws -> [WorkspaceRecord] {
        var records: [WorkspaceRecord] = []
        for name in try root.names() where !name.hasPrefix(".") {
            guard let id = WorkspaceID(rawValue: name), id.rawValue == name else { throw CatalogError.invalidConfiguration }
            records.append(try loadWorkspace(id))
        }
        try Self.checkStoredDuplicates(records.map(\.name))
        return records.sorted { Self.nameKey($0.name) < Self.nameKey($1.name) }
    }

    private func loadWorkspace(_ id: WorkspaceID) throws -> WorkspaceRecord {
        let record: WorkspaceRecord = try Self.decode(root.child(id.rawValue).read("workspace.json", maximumBytes: 65_536))
        try Self.validate(version: record.schemaVersion, name: record.name, date: record.createdAt)
        guard record.id == id else { throw CatalogError.scopeMismatch }
        return record
    }

    private func readProjects(in workspaceID: WorkspaceID) throws -> [ProjectRecord] {
        let parent = try root.child(workspaceID.rawValue).child("Projects")
        var records: [ProjectRecord] = []
        for name in try parent.names() where !name.hasPrefix(".") {
            guard let id = ProjectID(rawValue: name), id.rawValue == name else { throw CatalogError.invalidConfiguration }
            records.append(try loadProject(ProjectScope(workspaceID: workspaceID, projectID: id)))
        }
        try Self.checkStoredDuplicates(records.map(\.name))
        return records.sorted { Self.nameKey($0.name) < Self.nameKey($1.name) }
    }

    private func loadProject(_ scope: ProjectScope) throws -> ProjectRecord {
        let record: ProjectRecord = try Self.decode(root.child(scope.workspaceID.rawValue).child("Projects")
            .child(scope.projectID.rawValue).read("project.json", maximumBytes: 65_536))
        try Self.validate(version: record.schemaVersion, name: record.name, date: record.createdAt)
        guard record.scope == scope else { throw CatalogError.scopeMismatch }
        return record
    }

    private static func validName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 100, !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CatalogError.invalidName }
        return name
    }

    private static func validate(version: Int, name: String, date: Date) throws {
        guard version == 1 else { throw CatalogError.unsupportedVersion }
        guard (try? validName(name)) == name, date.timeIntervalSince1970.isFinite else { throw CatalogError.invalidConfiguration }
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func checkDuplicate(_ name: String, in names: [String]) throws {
        guard !names.contains(where: { nameKey($0) == nameKey(name) }) else { throw CatalogError.duplicateName }
    }

    private static func checkStoredDuplicates(_ names: [String]) throws {
        guard Set(names.map(nameKey)).count == names.count else { throw CatalogError.invalidConfiguration }
    }

    private static func encode<T: Encodable>(_ record: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Foundation's numeric Date coding preserves subsecond precision across reopening.
        return try encoder.encode(record)
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CatalogError.invalidConfiguration }
    }
}
