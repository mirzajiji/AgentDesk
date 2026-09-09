import Foundation

/// Local administrative configuration store. Policy-authorized runtime callers consume frozen previews.
/// Every save publishes a complete immutable JSON version before replacing the current pointer.
public actor ProjectExecutionConfigurationStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory
    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project
    }
    public func configuration(at level: ExecutionConfigurationLevel, in requested: ProjectScope,
                              revision: Int? = nil) throws -> ExecutionConfigurationSnapshot? {
        try root.withLock { try validate(requested); return try read(level, revision: revision) }
    }
    public func save(_ draft: ExecutionConfigurationDraft, at level: ExecutionConfigurationLevel, in requested: ProjectScope,
                     expectedRevision: Int?) throws -> ExecutionConfigurationSnapshot {
        try root.withLock {
            try validate(requested); try draft.validate(at: level, in: scope)
            let existing = try read(level)
            guard existing?.revision == expectedRevision else { throw ExecutionConfigurationError.staleRevision }
            let directory = try configurationDirectory(level, create: true)
            let versions: ConfigurationDirectory
            do { versions = try directory.child("Versions") }
            catch ScopedFileError.notFound { versions = try directory.createChild("Versions") }
            let revisions = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
                guard let revision = Int(name), (1...1_000_000).contains(revision), String(revision) == name else { throw ExecutionConfigurationError.invalidConfiguration }
                return revision
            }
            let revision = (revisions.max() ?? 0) + 1
            guard revision <= 1_000_000 else { throw ExecutionConfigurationError.invalidConfiguration }
            let snapshot = ExecutionConfigurationSnapshot(schemaVersion: 1, workspaceID: scope.workspaceID,
                projectID: level == .project ? scope.projectID : nil, revision: revision, createdAt: Date(), draft: draft)
            let data = try encode(snapshot)
            // Ensure saved documents fit the same bounded decoder used on reopen.
            _ = try OutputJSON.parse(data)
            let temporary = ".new-\(UUID().uuidString)", staging = try versions.createChild(temporary)
            var published = false
            defer { if !published { staging.remove("execution.json"); versions.remove(temporary, directory: true) } }
            try staging.write(data, to: "execution.json")
            try versions.publishChild(temporary, as: String(revision)); published = true
            try directory.write(encode(Pointer(schemaVersion: 1, workspaceID: snapshot.workspaceID, projectID: snapshot.projectID, revision: revision)),
                                to: "current.json", replacing: existing != nil)
            return snapshot
        }
    }
    public func preview(for agent: AgentSnapshot, in requested: ProjectScope, environmentID: EnvironmentID? = nil,
                        workflow: ExecutionSettings? = nil, run: ExecutionSettings? = nil) throws -> EffectiveExecutionConfiguration {
        try root.withLock {
            try validate(requested)
            return try ExecutionConfigurationComposer.compose(scope: scope, agent: agent, workspace: read(.workspace), project: read(.project),
                                                               environmentID: environmentID, workflow: workflow, run: run)
        }
    }
    private func read(_ level: ExecutionConfigurationLevel, revision requestedRevision: Int? = nil) throws -> ExecutionConfigurationSnapshot? {
        let directory: ConfigurationDirectory
        do { directory = try configurationDirectory(level) }
        catch ScopedFileError.notFound { if requestedRevision != nil { throw ScopedFileError.notFound }; return nil }
        let pointer: Pointer
        do { pointer = try decode(directory.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { if requestedRevision != nil { throw ScopedFileError.notFound }; return nil }
        guard pointer.schemaVersion == 1, pointer.workspaceID == scope.workspaceID,
              pointer.projectID == (level == .project ? scope.projectID : nil), (1...1_000_000).contains(pointer.revision) else {
            throw ExecutionConfigurationError.invalidConfiguration
        }
        let revision = requestedRevision ?? pointer.revision
        guard (1...1_000_000).contains(revision) else { throw ExecutionConfigurationError.invalidConfiguration }
        let snapshot: ExecutionConfigurationSnapshot = try decode(directory.child("Versions").child(String(revision)).read("execution.json", maximumBytes: 262_144))
        guard snapshot.schemaVersion == 1, snapshot.workspaceID == pointer.workspaceID, snapshot.projectID == pointer.projectID,
              snapshot.revision == revision, snapshot.createdAt.timeIntervalSince1970.isFinite else { throw ExecutionConfigurationError.invalidConfiguration }
        try snapshot.draft.validate(at: level, in: scope)
        return snapshot
    }
    private func configurationDirectory(_ level: ExecutionConfigurationLevel, create: Bool = false) throws -> ConfigurationDirectory {
        let parent = level == .workspace ? workspace : project
        do { return try parent.child("Execution") }
        catch ScopedFileError.notFound { guard create else { throw ScopedFileError.notFound }; return try parent.createChild("Execution") }
    }
    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw ExecutionConfigurationError.scopeMismatch }
        let owner: WorkspaceRecord = try decode(workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID, member.schemaVersion == 1, member.scope == scope else { throw ExecutionConfigurationError.scopeMismatch }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { _ = try OutputJSON.parse(data); return try JSONDecoder().decode(T.self, from: data) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ExecutionConfigurationError.invalidConfiguration }
    }
    private struct Pointer: Codable {
        let schemaVersion: Int
        let workspaceID: WorkspaceID
        let projectID: ProjectID?
        let revision: Int
    }
}
