import Foundation

/// Implementations contain validated non-secret configuration and scoped secret references only.
public protocol ScopedMCPConfiguration: Codable, Sendable {
    var id: UUID { get }
    var scope: ProjectScope { get }
    var environmentID: EnvironmentID { get }
}

public enum MCPStorageError: Error, Equatable, Sendable {
    case scopeMismatch, staleRevision, invalidRecord
}

public struct MCPConfigurationRevision<Value: ScopedMCPConfiguration>: Codable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let configuration: Value
}

public struct MCPConfigurationPage<Value: ScopedMCPConfiguration>: Sendable {
    public let records: [MCPConfigurationRevision<Value>]
    public let nextID: UUID?
}

/// Local administrative storage. Runtime callers must use the policy-authorized MCP service.
public actor ProjectMCPConfigurationStore<Value: ScopedMCPConfiguration> {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory

    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project
    }

    public func read(id: UUID, in requested: ProjectScope, revision: Int? = nil) throws -> MCPConfigurationRevision<Value>? {
        try root.withLock {
            try validate(requested)
            return try load(id: id, revision: revision)
        }
    }

    /// Administrative browsing of published heads only. Orphaned, unpublished revisions remain hidden.
    public func list(in requested: ProjectScope, environmentID: EnvironmentID? = nil,
                     after: UUID? = nil, limit: Int = 50) throws -> MCPConfigurationPage<Value> {
        try root.withLock {
            try validate(requested)
            guard (1...100).contains(limit) else { throw MCPStorageError.invalidRecord }
            let directory: ConfigurationDirectory
            do { directory = try project.child("MCP") }
            catch ScopedFileError.notFound { return .init(records: [], nextID: nil) }
            let names = try directory.names()
            guard names.count <= 10_000 else { throw MCPStorageError.invalidRecord }
            let ids = try names.map { name -> String in
                guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name else {
                    throw MCPStorageError.invalidRecord
                }
                return name
            }.sorted()
            let cursor = after?.uuidString.lowercased()
            var records: [MCPConfigurationRevision<Value>] = []
            for name in ids where cursor.map({ name > $0 }) ?? true {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: name), let record = try load(id: id),
                      environmentID.map({ record.configuration.environmentID == $0 }) ?? true else { continue }
                records.append(record)
                if records.count > limit { break }
            }
            let more = records.count > limit
            if more { records.removeLast() }
            return .init(records: records, nextID: more ? records.last?.configuration.id : nil)
        }
    }

    public func save(_ configuration: Value, in requested: ProjectScope, expectedRevision: Int?) throws -> MCPConfigurationRevision<Value> {
        try root.withLock {
            try validate(requested)
            guard configuration.scope == scope else { throw MCPStorageError.scopeMismatch }
            let existing = try load(id: configuration.id)
            guard existing?.revision == expectedRevision else { throw MCPStorageError.staleRevision }
            let directory = try connection(configuration.id, create: true)
            let versions = try child("Versions", in: directory, create: true)
            let revisions = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
                guard let number = Int(name), (1...1_000_000).contains(number), String(number) == name else {
                    throw MCPStorageError.invalidRecord
                }
                return number
            }
            let next = (revisions.max() ?? 0) + 1
            guard next <= 1_000_000 else { throw MCPStorageError.invalidRecord }
            let value = MCPConfigurationRevision(schemaVersion: 1, revision: next, configuration: configuration)
            let data = try encode(value)
            // Decoding invokes the provider's configuration validation before publication.
            _ = try decode(data) as MCPConfigurationRevision<Value>
            try versions.write(data, to: String(next))
            try directory.write(encode(Pointer(schemaVersion: 1, id: configuration.id, scope: scope, revision: next)),
                                to: "current.json", replacing: existing != nil)
            return value
        }
    }

    private func load(id: UUID, revision: Int? = nil) throws -> MCPConfigurationRevision<Value>? {
        let directory: ConfigurationDirectory
        do { directory = try connection(id) }
        catch ScopedFileError.notFound { if revision != nil { throw ScopedFileError.notFound }; return nil }
        let pointer: Pointer
        do { pointer = try decode(directory.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { if revision != nil { throw ScopedFileError.notFound }; return nil }
        guard pointer.schemaVersion == 1, pointer.id == id, pointer.scope == scope,
              (1...1_000_000).contains(pointer.revision) else { throw MCPStorageError.invalidRecord }
        let selected = revision ?? pointer.revision
        guard (1...1_000_000).contains(selected) else { throw MCPStorageError.invalidRecord }
        let value: MCPConfigurationRevision<Value> = try decode(directory.child("Versions").read(String(selected), maximumBytes: 262_144))
        guard value.schemaVersion == 1, value.revision == selected, value.configuration.id == id,
              value.configuration.scope == scope else { throw MCPStorageError.invalidRecord }
        return value
    }

    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw MCPStorageError.scopeMismatch }
        let owner: WorkspaceRecord = try decode(workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID,
              member.schemaVersion == 1, member.scope == scope else { throw MCPStorageError.scopeMismatch }
    }
    private func connection(_ id: UUID, create: Bool = false) throws -> ConfigurationDirectory {
        try child(id.uuidString.lowercased(), in: child("MCP", in: project, create: create), create: create)
    }
    private func child(_ name: String, in parent: ConfigurationDirectory, create: Bool) throws -> ConfigurationDirectory {
        do { return try parent.child(name) }
        catch ScopedFileError.notFound { guard create else { throw ScopedFileError.notFound }; return try parent.createChild(name) }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw MCPStorageError.invalidRecord }
        _ = try OutputJSON.parse(data)
        return data
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        _ = try OutputJSON.parse(data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private struct Pointer: Codable {
        let schemaVersion: Int
        let id: UUID
        let scope: ProjectScope
        let revision: Int
    }
}
