import Foundation

/// Versioned project-local definitions. Archived agents retain their immutable history.
public actor ProjectAgentStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let project: ConfigurationDirectory

    init(scope: ProjectScope, workspaceRoot: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; root = workspaceRoot; self.project = project
    }

    public func agents(in requested: ProjectScope, includeArchived: Bool = false) throws -> [AgentSnapshot] {
        try validate(requested)
        return try root.withLock {
            try readAgents().filter { includeArchived || !$0.definition.archived }
        }
    }

    public func agent(_ id: AgentID, in requested: ProjectScope, revision: Int? = nil) throws -> AgentSnapshot {
        try validate(requested)
        return try root.withLock { try readAgent(id, revision: revision) }
    }

    public func create(_ draft: AgentDraft, in requested: ProjectScope) throws -> AgentSnapshot {
        try validate(requested)
        return try root.withLock {
            let draft = try draft.validated()
            try checkDuplicate(draft.name, excluding: nil)
            let agents = try agentDirectory(create: true)
            let id = AgentID(), stagingName = ".new-\(UUID().uuidString)"
            let directory = try agents.createChild(stagingName)
            let versions = try directory.createChild("Versions")
            var published = false
            defer {
                if !published {
                    if let version = try? versions.child("1") {
                        version.remove("agent.json"); version.remove("instructions.md")
                        versions.remove("1", directory: true)
                    }
                    directory.remove("current.json"); directory.remove("Versions", directory: true)
                    agents.remove(stagingName, directory: true)
                }
            }
            let now = Date()
            let definition = definition(id: id, revision: 1, draft: draft, archived: false, createdAt: now, updatedAt: now)
            try publishVersion(definition, instructions: draft.instructions, in: versions)
            try directory.write(encode(AgentPointer(schemaVersion: 1, id: id, scope: scope, revision: 1)), to: "current.json")
            try agents.publishChild(stagingName, as: id.rawValue)
            published = true
            return AgentSnapshot(definition: definition, instructions: draft.instructions)
        }
    }

    public func update(_ id: AgentID, in requested: ProjectScope, expectedRevision: Int,
                       draft: AgentDraft) throws -> AgentSnapshot {
        try validate(requested)
        return try root.withLock {
            let existing = try readAgent(id)
            guard !existing.definition.archived else { throw AgentConfigurationError.archived }
            return try save(existing, expectedRevision: expectedRevision, draft: draft.validated(), archived: false)
        }
    }

    public func setArchived(_ archived: Bool, for id: AgentID, in requested: ProjectScope,
                            expectedRevision: Int) throws -> AgentSnapshot {
        try validate(requested)
        return try root.withLock {
            let existing = try readAgent(id)
            return try save(existing, expectedRevision: expectedRevision, draft: existing.draft, archived: archived)
        }
    }

    private func save(_ existing: AgentSnapshot, expectedRevision: Int, draft: AgentDraft, archived: Bool) throws -> AgentSnapshot {
        guard existing.definition.revision == expectedRevision else { throw AgentConfigurationError.staleRevision }
        if !archived { try checkDuplicate(draft.name, excluding: existing.id) }
        let directory = try agentDirectory().child(existing.id.rawValue), versions = try directory.child("Versions")
        let revisions = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
            guard let number = Int(name), (1...1_000_000).contains(number), String(number) == name else {
                throw AgentConfigurationError.invalidConfiguration
            }
            return number
        }
        // A failed pointer publication may leave an orphan version. Never overwrite it on retry.
        let revision = (revisions.max() ?? existing.definition.revision) + 1
        guard revision <= 1_000_000 else { throw AgentConfigurationError.invalidConfiguration }
        let definition = definition(id: existing.id, revision: revision, draft: draft, archived: archived,
                                    createdAt: existing.definition.createdAt, updatedAt: Date())
        try publishVersion(definition, instructions: draft.instructions, in: versions)
        try directory.write(encode(AgentPointer(schemaVersion: 1, id: existing.id, scope: scope, revision: revision)),
                            to: "current.json", replacing: true)
        return AgentSnapshot(definition: definition, instructions: draft.instructions)
    }

    private func readAgents() throws -> [AgentSnapshot] {
        let directory: ConfigurationDirectory
        do { directory = try agentDirectory() } catch ScopedFileError.notFound { return [] }
        var result: [AgentSnapshot] = []
        for name in try directory.names() where !name.hasPrefix(".") {
            guard let id = AgentID(rawValue: name), id.rawValue == name else { throw AgentConfigurationError.invalidConfiguration }
            result.append(try readAgent(id))
        }
        let activeNames = result.filter { !$0.definition.archived }.map { nameKey($0.definition.name) }
        guard Set(activeNames).count == activeNames.count else { throw AgentConfigurationError.invalidConfiguration }
        return result.sorted { nameKey($0.definition.name) < nameKey($1.definition.name) }
    }

    private func readAgent(_ id: AgentID, revision requestedRevision: Int? = nil) throws -> AgentSnapshot {
        let directory = try agentDirectory().child(id.rawValue)
        let pointer: AgentPointer = try decode(directory.read("current.json", maximumBytes: 16_384))
        guard pointer.schemaVersion == 1, pointer.id == id, pointer.scope == scope,
              (1...1_000_000).contains(pointer.revision) else { throw AgentConfigurationError.invalidConfiguration }
        let revision = requestedRevision ?? pointer.revision
        guard (1...1_000_000).contains(revision) else { throw AgentConfigurationError.invalidConfiguration }
        let version = try directory.child("Versions").child(String(revision))
        let definition: AgentDefinition = try decode(version.read("agent.json", maximumBytes: 65_536))
        guard definition.schemaVersion == 1, definition.id == id, definition.scope == scope,
              definition.revision == revision, definition.instructionsFile == "instructions.md",
              definition.createdAt.timeIntervalSince1970.isFinite, definition.updatedAt.timeIntervalSince1970.isFinite else {
            throw AgentConfigurationError.invalidConfiguration
        }
        guard let instructions = String(data: try version.read("instructions.md", maximumBytes: 65_536), encoding: .utf8) else {
            throw AgentConfigurationError.invalidInstructions
        }
        let snapshot = AgentSnapshot(definition: definition, instructions: instructions)
        guard try snapshot.draft.validated() == snapshot.draft else { throw AgentConfigurationError.invalidConfiguration }
        return snapshot
    }

    private func publishVersion(_ definition: AgentDefinition, instructions: String, in versions: ConfigurationDirectory) throws {
        let temporary = ".new-\(UUID().uuidString)"
        let staging = try versions.createChild(temporary)
        var published = false
        defer {
            if !published {
                staging.remove("agent.json"); staging.remove("instructions.md")
                versions.remove(temporary, directory: true)
            }
        }
        try staging.write(encode(definition), to: "agent.json")
        try staging.write(Data(instructions.utf8), to: "instructions.md")
        try versions.publishChild(temporary, as: String(definition.revision))
        published = true
    }

    private func definition(id: AgentID, revision: Int, draft: AgentDraft, archived: Bool,
                            createdAt: Date, updatedAt: Date) -> AgentDefinition {
        AgentDefinition(schemaVersion: 1, id: id, scope: scope, revision: revision, name: draft.name,
                        summary: draft.summary, enabled: draft.enabled, archived: archived, profile: draft.profile,
                        createdAt: createdAt, updatedAt: updatedAt, instructionsFile: "instructions.md")
    }

    private func agentDirectory(create: Bool = false) throws -> ConfigurationDirectory {
        do { return try project.child("Agents") }
        catch ScopedFileError.notFound {
            guard create else { throw ScopedFileError.notFound }
            return try project.createChild("Agents")
        }
    }

    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw ScopedFileError.scopeMismatch }
        let record: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard record.schemaVersion == 1, record.scope == scope else { throw ScopedFileError.scopeMismatch }
    }

    private func checkDuplicate(_ name: String, excluding id: AgentID?) throws {
        guard try !readAgents().contains(where: { $0.id != id && !$0.definition.archived && nameKey($0.definition.name) == nameKey(name) }) else {
            throw AgentConfigurationError.duplicateName
        }
    }
    private func nameKey(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AgentConfigurationError.invalidConfiguration }
    }
}

private struct AgentPointer: Codable {
    let schemaVersion: Int
    let id: AgentID
    let scope: ProjectScope
    let revision: Int
}
