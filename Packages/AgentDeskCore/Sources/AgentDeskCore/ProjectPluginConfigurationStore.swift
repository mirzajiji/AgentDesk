import Foundation

/// Implementations contain validated non-secret configuration and scoped secret references only.
public protocol ScopedPluginConfiguration: Codable, Sendable {
    var id: UUID { get }
    var scope: ProjectScope { get }
    var environmentID: EnvironmentID { get }
}

public enum PluginStorageError: Error, Equatable, Sendable {
    case scopeMismatch, staleRevision, invalidRecord
}

public struct PluginConfigurationRevision<Value: ScopedPluginConfiguration>: Codable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let configuration: Value
}

/// Local administrative storage. Runtime callers must use the policy-authorized plugin service.
public actor ProjectPluginConfigurationStore<Value: ScopedPluginConfiguration> {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory

    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project
    }

    public func read(id: UUID, in requested: ProjectScope, revision: Int? = nil) throws -> PluginConfigurationRevision<Value>? {
        try root.withLock {
            try validate(requested)
            return try load(id: id, revision: revision)
        }
    }

    public func save(_ configuration: Value, in requested: ProjectScope, expectedRevision: Int?) throws -> PluginConfigurationRevision<Value> {
        try root.withLock {
            try validate(requested)
            guard configuration.scope == scope else { throw PluginStorageError.scopeMismatch }
            let existing = try load(id: configuration.id)
            guard existing?.revision == expectedRevision else { throw PluginStorageError.staleRevision }
            let directory = try connection(configuration.id, create: true)
            let versions = try child("Versions", in: directory, create: true)
            let revisions = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
                guard let number = Int(name), (1...1_000_000).contains(number), String(number) == name else {
                    throw PluginStorageError.invalidRecord
                }
                return number
            }
            let next = (revisions.max() ?? 0) + 1
            guard next <= 1_000_000 else { throw PluginStorageError.invalidRecord }
            let value = PluginConfigurationRevision(schemaVersion: 1, revision: next, configuration: configuration)
            let data = try encode(value)
            // Decoding invokes the provider's configuration validation before publication.
            _ = try decode(data) as PluginConfigurationRevision<Value>
            try versions.write(data, to: String(next))
            try directory.write(encode(Pointer(schemaVersion: 1, id: configuration.id, scope: scope, revision: next)),
                                to: "current.json", replacing: existing != nil)
            return value
        }
    }

    private func load(id: UUID, revision: Int? = nil) throws -> PluginConfigurationRevision<Value>? {
        let directory: ConfigurationDirectory
        do { directory = try connection(id) }
        catch ScopedFileError.notFound { if revision != nil { throw ScopedFileError.notFound }; return nil }
        let pointer: Pointer
        do { pointer = try decode(directory.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { if revision != nil { throw ScopedFileError.notFound }; return nil }
        guard pointer.schemaVersion == 1, pointer.id == id, pointer.scope == scope,
              (1...1_000_000).contains(pointer.revision) else { throw PluginStorageError.invalidRecord }
        let selected = revision ?? pointer.revision
        guard (1...1_000_000).contains(selected) else { throw PluginStorageError.invalidRecord }
        let value: PluginConfigurationRevision<Value> = try decode(directory.child("Versions").read(String(selected), maximumBytes: 262_144))
        guard value.schemaVersion == 1, value.revision == selected, value.configuration.id == id,
              value.configuration.scope == scope else { throw PluginStorageError.invalidRecord }
        return value
    }

    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw PluginStorageError.scopeMismatch }
        let owner: WorkspaceRecord = try decode(workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID,
              member.schemaVersion == 1, member.scope == scope else { throw PluginStorageError.scopeMismatch }
    }
    private func connection(_ id: UUID, create: Bool = false) throws -> ConfigurationDirectory {
        try child(id.uuidString.lowercased(), in: child("Plugins", in: project, create: create), create: create)
    }
    private func child(_ name: String, in parent: ConfigurationDirectory, create: Bool) throws -> ConfigurationDirectory {
        do { return try parent.child(name) }
        catch ScopedFileError.notFound { guard create else { throw ScopedFileError.notFound }; return try parent.createChild(name) }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw PluginStorageError.invalidRecord }
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
