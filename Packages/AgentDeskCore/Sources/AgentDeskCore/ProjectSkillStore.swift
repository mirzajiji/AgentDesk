import Foundation

/// Workspace/project skill management. Script attachments are inert reviewable text, never executable commands.
public actor ProjectSkillStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let library: SkillLibrary
    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; self.root = root; library = SkillLibrary(scope: scope, workspace: workspace, project: project)
    }
    public func skills(at owner: SkillScope, in requested: ProjectScope, includeArchived: Bool = false) throws -> [SkillSnapshot] {
        try root.withLock { try library.validate(requested); return try library.list(owner).filter { includeArchived || !$0.definition.archived } }
    }
    public func skill(_ reference: SkillReference, in requested: ProjectScope) throws -> SkillSnapshot {
        try root.withLock { try library.validate(requested); try reference.validate(); return try library.read(reference.id, owner: reference.scope, revision: reference.revision) }
    }
    public func save(_ draft: SkillDraft, at owner: SkillScope, in requested: ProjectScope,
                     id: SkillID? = nil, expectedRevision: Int? = nil) throws -> SkillSnapshot {
        try root.withLock {
            try library.validate(requested)
            if let id, try library.read(id, owner: owner).definition.archived { throw SkillError.unavailable }
            return try library.save(draft.validated(), owner: owner, id: id, expectedRevision: expectedRevision, archived: false)
        }
    }
    public func setArchived(_ archived: Bool, for id: SkillID, at owner: SkillScope, in requested: ProjectScope,
                            expectedRevision: Int) throws -> SkillSnapshot {
        try root.withLock {
            try library.validate(requested)
            let existing = try library.read(id, owner: owner)
            return try library.save(existing.draft, owner: owner, id: id, expectedRevision: expectedRevision, archived: archived)
        }
    }
}

/// Shared only inside Core, under the caller's catalog root lock. It never opens another project's scope.
struct SkillLibrary {
    let scope: ProjectScope
    let workspace: ConfigurationDirectory
    let project: ConfigurationDirectory
    func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw SkillError.scopeMismatch }
        let owner: WorkspaceRecord = try decode(workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID, member.schemaVersion == 1, member.scope == scope else { throw SkillError.scopeMismatch }
    }
    func resolve(_ references: [SkillReference]) throws -> [SkillSnapshot] {
        try SkillReference.validate(references, in: scope)
        return try references.map { reference in
            let current = try read(reference.id, owner: reference.scope)
            guard current.definition.enabled, !current.definition.archived else { throw SkillError.unavailable }
            let pinned = try read(reference.id, owner: reference.scope, revision: reference.revision)
            guard pinned.definition.enabled, !pinned.definition.archived else { throw SkillError.unavailable }
            return pinned
        }
    }
    func list(_ owner: SkillScope) throws -> [SkillSnapshot] {
        let directory: ConfigurationDirectory
        do { directory = try skills(owner) } catch ScopedFileError.notFound { return [] }
        let result = try directory.names().filter { !$0.hasPrefix(".") }.map { name -> SkillSnapshot in
            guard let id = SkillID(rawValue: name), id.rawValue == name else { throw SkillError.invalidBundle }
            return try read(id, owner: owner)
        }
        let names = result.filter { !$0.definition.archived }.map { nameKey($0.definition.name) }
        guard Set(names).count == names.count else { throw SkillError.invalidBundle }
        return result.sorted { nameKey($0.definition.name) < nameKey($1.definition.name) }
    }
    func read(_ id: SkillID, owner: SkillScope, revision requested: Int? = nil) throws -> SkillSnapshot {
        let directory = try skills(owner).child(id.rawValue)
        let pointer: Pointer = try decode(directory.read("current.json", maximumBytes: 16_384))
        guard pointer.schemaVersion == 1, pointer.id == id, pointer.scope == owner, (1...1_000_000).contains(pointer.revision) else { throw SkillError.invalidBundle }
        let revision = requested ?? pointer.revision
        guard (1...1_000_000).contains(revision) else { throw SkillError.invalidBundle }
        let version = try directory.child("Versions").child(String(revision))
        let definition: SkillDefinition = try decode(version.read("skill.json", maximumBytes: 32_768))
        guard definition.schemaVersion == 1, definition.id == id, definition.scope == owner, definition.revision == revision,
              definition.instructionsFile == "instructions.md", definition.files.count <= 16,
              definition.createdAt.timeIntervalSince1970.isFinite, definition.updatedAt.timeIntervalSince1970.isFinite else { throw SkillError.invalidBundle }
        let instructions = try text(version.read("instructions.md", maximumBytes: 65_536), fingerprint: definition.instructionsFingerprint)
        let attachments = try definition.files.map { file -> SkillAttachment in
            let candidate = SkillAttachment(kind: file.kind, name: file.name, text: "")
            try candidate.validate()
            guard file.relativeFile == candidate.relativeFile else { throw SkillError.invalidBundle }
            let directory = try version.child(file.kind == .example ? "examples" : "scripts")
            return try SkillAttachment(kind: file.kind, name: file.name,
                                       text: text(directory.read(file.name, maximumBytes: 65_536), fingerprint: file.fingerprint))
        }
        let snapshot = SkillSnapshot(definition: definition, instructions: instructions, attachments: attachments)
        guard try snapshot.draft.validated() == snapshot.draft else { throw SkillError.invalidBundle }
        return snapshot
    }
    func save(_ draft: SkillDraft, owner: SkillScope, id requestedID: SkillID?, expectedRevision: Int?, archived: Bool) throws -> SkillSnapshot {
        try owner.validate(in: scope)
        let existing = try requestedID.map { try read($0, owner: owner) }
        guard existing?.definition.revision == expectedRevision else { throw SkillError.staleRevision }
        if !archived, try list(owner).contains(where: { $0.id != requestedID && !$0.definition.archived && nameKey($0.definition.name) == nameKey(draft.name) }) { throw SkillError.duplicateName }
        let parent = try skills(owner, create: true), id = requestedID ?? SkillID(), temporary = ".new-\(UUID().uuidString)"
        let directory = try requestedID == nil ? parent.createChild(temporary) : parent.child(id.rawValue)
        let versions = try requestedID == nil ? directory.createChild("Versions") : directory.child("Versions")
        var published = false
        defer {
            if requestedID == nil && !published {
                if let version = try? versions.child("1") { cleanup(version, draft: draft); versions.remove("1", directory: true) }
                directory.remove("current.json"); directory.remove("Versions", directory: true); parent.remove(temporary, directory: true)
            }
        }
        let prior = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
            guard let value = Int(name), (1...1_000_000).contains(value), String(value) == name else { throw SkillError.invalidBundle }
            return value
        }
        let revision = (prior.max() ?? 0) + 1
        guard revision <= 1_000_000 else { throw SkillError.invalidBundle }
        let now = Date()
        let definition = try SkillDefinition(schemaVersion: 1, id: id, scope: owner, revision: revision, name: draft.name,
            summary: draft.summary, enabled: draft.enabled, archived: archived, requiredPermissions: draft.requiredPermissions,
            instructionsFile: "instructions.md", instructionsFingerprint: ActionFingerprint(bytes: Data(draft.instructions.utf8)),
            files: draft.attachments.map { try .init(kind: $0.kind, name: $0.name, relativeFile: $0.relativeFile, fingerprint: ActionFingerprint(bytes: Data($0.text.utf8))) },
            createdAt: existing?.definition.createdAt ?? now, updatedAt: now)
        let stagingName = ".new-\(UUID().uuidString)", staging = try versions.createChild(stagingName)
        var versionPublished = false
        defer { if !versionPublished { cleanup(staging, draft: draft); versions.remove(stagingName, directory: true) } }
        try staging.write(encode(definition), to: "skill.json")
        try staging.write(Data(draft.instructions.utf8), to: "instructions.md")
        for kind in [SkillAttachment.Kind.example, .script] where draft.attachments.contains(where: { $0.kind == kind }) {
            let folder = try staging.createChild(kind == .example ? "examples" : "scripts")
            for file in draft.attachments where file.kind == kind { try folder.write(Data(file.text.utf8), to: file.name) }
        }
        try versions.publishChild(stagingName, as: String(revision)); versionPublished = true
        try directory.write(encode(Pointer(schemaVersion: 1, id: id, scope: owner, revision: revision)), to: "current.json", replacing: existing != nil)
        if requestedID == nil { try parent.publishChild(temporary, as: id.rawValue) }
        published = true
        return SkillSnapshot(definition: definition, instructions: draft.instructions, attachments: draft.attachments)
    }
    private func cleanup(_ directory: ConfigurationDirectory, draft: SkillDraft) {
        directory.remove("skill.json"); directory.remove("instructions.md")
        for (kind, name) in [(SkillAttachment.Kind.example, "examples"), (.script, "scripts")] {
            if let folder = try? directory.child(name) { for file in draft.attachments where file.kind == kind { folder.remove(file.name) } }
            directory.remove(name, directory: true)
        }
    }
    private func skills(_ owner: SkillScope, create: Bool = false) throws -> ConfigurationDirectory {
        try owner.validate(in: scope)
        let directory = owner.projectID == nil ? workspace : project
        do { return try directory.child("Skills") }
        catch ScopedFileError.notFound { guard create else { throw ScopedFileError.notFound }; return try directory.createChild("Skills") }
    }
    private func text(_ data: Data, fingerprint: ActionFingerprint) throws -> String {
        guard try ActionFingerprint(bytes: data) == fingerprint, let text = String(data: data, encoding: .utf8) else { throw SkillError.invalidBundle }
        return text
    }
    private func nameKey(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { _ = try OutputJSON.parse(data); return try JSONDecoder().decode(T.self, from: data) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SkillError.invalidBundle }
    }
    private struct Pointer: Codable { let schemaVersion: Int; let id: SkillID; let scope: SkillScope; let revision: Int }
}
