import Foundation

/// Project-authorized access to this project's instructions and its own workspace's shared set.
public actor ProjectInstructionStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory

    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory, project: ConfigurationDirectory) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project
    }

    public func bundle(at level: InstructionLevel, in requested: ProjectScope,
                       revision: Int? = nil) throws -> InstructionBundleSnapshot? {
        try root.withLock { try validate(requested); return try read(level, revision: revision) }
    }

    public func save(_ draft: InstructionBundleDraft, at level: InstructionLevel, in requested: ProjectScope,
                     expectedRevision: Int?) throws -> InstructionBundleSnapshot {
        try root.withLock {
            try validate(requested)
            _ = try draft.resolvedDocuments()
            let existing = try read(level)
            guard existing?.revision == expectedRevision else { throw InstructionError.staleRevision }
            let directory = try instructions(level, create: true)
            let versions: ConfigurationDirectory
            do { versions = try directory.child("Versions") }
            catch ScopedFileError.notFound { versions = try directory.createChild("Versions") }
            let revisions = try versions.names().filter { !$0.hasPrefix(".") }.map { name -> Int in
                guard let revision = Int(name), (1...1_000_000).contains(revision), String(revision) == name else {
                    throw InstructionError.invalidBundle
                }
                return revision
            }
            let revision = (revisions.max() ?? 0) + 1
            guard revision <= 1_000_000 else { throw InstructionError.invalidBundle }
            let snapshot = InstructionBundleSnapshot(workspaceID: scope.workspaceID,
                projectID: level == .project ? scope.projectID : nil, revision: revision, createdAt: Date(), draft: draft)
            let temporary = ".new-\(UUID().uuidString)"
            let staging = try versions.createChild(temporary)
            var published = false
            defer {
                if !published {
                    for document in draft.documents { staging.remove("\(document.id).md") }
                    staging.remove("instructions.json"); versions.remove(temporary, directory: true)
                }
            }
            try staging.write(encode(Manifest(snapshot)), to: "instructions.json")
            for document in draft.documents { try staging.write(Data(document.text.utf8), to: "\(document.id).md") }
            try versions.publishChild(temporary, as: String(revision))
            published = true
            try directory.write(encode(Pointer(schemaVersion: 1, workspaceID: snapshot.workspaceID,
                projectID: snapshot.projectID, revision: revision)), to: "current.json", replacing: existing != nil)
            return snapshot
        }
    }

    public func preview(for agent: AgentSnapshot, in requested: ProjectScope) throws -> ComposedInstructions {
        try root.withLock {
            try validate(requested)
            return try InstructionComposer.compose(scope: scope, agent: agent, workspace: read(.workspace), project: read(.project))
        }
    }

    private func read(_ level: InstructionLevel, revision requestedRevision: Int? = nil) throws -> InstructionBundleSnapshot? {
        let directory: ConfigurationDirectory
        do { directory = try instructions(level) }
        catch ScopedFileError.notFound {
            guard requestedRevision == nil else { throw ScopedFileError.notFound }
            return nil
        }
        let pointer: Pointer
        do { pointer = try decode(directory.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound {
            guard requestedRevision == nil else { throw ScopedFileError.notFound }
            // No pointer means no committed set. A later save preserves any orphan versions.
            return nil
        }
        guard pointer.schemaVersion == 1, pointer.workspaceID == scope.workspaceID,
              pointer.projectID == (level == .project ? scope.projectID : nil),
              (1...1_000_000).contains(pointer.revision) else { throw InstructionError.invalidBundle }
        let revision = requestedRevision ?? pointer.revision
        guard (1...1_000_000).contains(revision) else { throw InstructionError.invalidBundle }
        let version = try directory.child("Versions").child(String(revision))
        let manifest: Manifest = try decode(version.read("instructions.json", maximumBytes: 262_144))
        guard manifest.schemaVersion == 1, manifest.workspaceID == pointer.workspaceID,
              manifest.projectID == pointer.projectID, manifest.revision == revision,
              manifest.createdAt.timeIntervalSince1970.isFinite, manifest.documents.count <= 64 else {
            throw InstructionError.invalidBundle
        }
        var documents: [InstructionDocument] = []
        for entry in manifest.documents {
            guard entry.file == "\(entry.id).md" else { throw ScopedFileError.invalidPath }
            guard let text = String(data: try version.read(entry.file, maximumBytes: 65_536), encoding: .utf8) else {
                throw InstructionError.invalidBundle
            }
            documents.append(InstructionDocument(id: entry.id, title: entry.title, text: text, includes: entry.includes))
        }
        let draft = InstructionBundleDraft(documents: documents, roots: manifest.roots)
        _ = try draft.resolvedDocuments()
        return InstructionBundleSnapshot(workspaceID: manifest.workspaceID, projectID: manifest.projectID,
                                         revision: manifest.revision, createdAt: manifest.createdAt, draft: draft)
    }

    private func instructions(_ level: InstructionLevel, create: Bool = false) throws -> ConfigurationDirectory {
        let parent = level == .workspace ? workspace : project
        do { return try parent.child("Instructions") }
        catch ScopedFileError.notFound {
            guard create else { throw ScopedFileError.notFound }
            return try parent.createChild("Instructions")
        }
    }

    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw ScopedFileError.scopeMismatch }
        let owner: WorkspaceRecord = try decode(workspace.read("workspace.json", maximumBytes: 65_536))
        let project: ProjectRecord = try decode(project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID,
              project.schemaVersion == 1, project.scope == scope else { throw ScopedFileError.scopeMismatch }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw InstructionError.invalidBundle }
    }
}

private struct Pointer: Codable {
    let schemaVersion: Int
    let workspaceID: WorkspaceID
    let projectID: ProjectID?
    let revision: Int
}

private struct Manifest: Codable {
    struct Entry: Codable {
        let id: InstructionID
        let title: String
        let file: String
        let includes: [InstructionID]
    }
    let schemaVersion: Int
    let workspaceID: WorkspaceID
    let projectID: ProjectID?
    let revision: Int
    let createdAt: Date
    let roots: [InstructionID]
    let documents: [Entry]

    init(_ snapshot: InstructionBundleSnapshot) {
        schemaVersion = 1; workspaceID = snapshot.workspaceID; projectID = snapshot.projectID
        revision = snapshot.revision; createdAt = snapshot.createdAt; roots = snapshot.draft.roots
        documents = snapshot.draft.documents.map { Entry(id: $0.id, title: $0.title, file: "\($0.id).md", includes: $0.includes) }
    }
}
