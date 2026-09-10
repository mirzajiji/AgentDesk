import Foundation

/// Files are accessed only while the catalog root lock is held, including requirement-reference publication.
struct BugRegistryFiles: Sendable {
    let scope: ProjectScope
    let root: ConfigurationDirectory
    let workspace: ConfigurationDirectory
    let project: ConfigurationDirectory
    let clock: @Sendable () -> Date
    func candidate(_ draft: BugDraft, requirements: [BugRequirementReference], id: BugID, expected: Int?) throws -> BugRecord {
        let current = try read(id).first, now = try instant()
        guard current?.revision == expected else { throw BugRegistryError.staleRevision }
        guard current == nil || now >= current!.updatedAt else { throw BugRegistryError.invalidReview }
        let timestamp = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let record = BugRecord(schemaVersion: 1, scope: scope, id: id, revision: try nextRevision(id),
            supersedes: current?.revision, previousFingerprint: try current?.fingerprint,
            createdAt: current?.createdAt ?? timestamp, updatedAt: timestamp, content: draft, requirements: requirements)
        try record.validate(); try validateRelationships(record); _ = try encode(record); return record
    }
    func publish(_ candidate: BugRecord) throws -> BugRecord {
        try candidate.validate(); try validateRelationships(candidate)
        let data = try encode(candidate)
        let history = try read(candidate.id, reserving: data.count), current = history.first
        guard current?.revision == candidate.supersedes, try current?.fingerprint == candidate.previousFingerprint,
              try nextRevision(candidate.id) == candidate.revision else { throw BugRegistryError.staleRevision }
        guard history.count < 1_024 else { throw BugRegistryError.limitExceeded }
        let folder = try directory(candidate.id, create: true)
        try folder.write(data, to: Self.file(candidate.revision))
        let pointer = Pointer(schemaVersion: 1, scope: scope, id: candidate.id, revision: candidate.revision, fingerprint: try candidate.fingerprint)
        try folder.write(encode(pointer), to: "current.json", replacing: current != nil)
        return candidate
    }
    func read(_ id: BugID, reserving: Int = 0) throws -> [BugRecord] {
        let folder: ConfigurationDirectory, pointer: Pointer
        do { folder = try directory(id); pointer = try decode(folder.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { return [] }
        guard pointer.schemaVersion == 1, pointer.scope == scope, pointer.id == id,
              (1...1_000_000).contains(pointer.revision) else { throw BugRegistryError.invalidDocument }
        var revision: Int? = pointer.revision, fingerprint: ActionFingerprint? = pointer.fingerprint
        var records: [BugRecord] = [], bytes = reserving
        while let number = revision {
            try Task.checkCancellation()
            guard records.count < 1_024 else { throw BugRegistryError.limitExceeded }
            let data = try folder.read(Self.file(number), maximumBytes: 262_144)
            bytes += data.count; guard bytes <= 16_777_216 else { throw BugRegistryError.limitExceeded }
            let record: BugRecord = try decode(data); try record.validate()
            guard record.scope == scope, record.id == id, record.revision == number,
                  try record.fingerprint == fingerprint else { throw BugRegistryError.invalidDocument }
            if let later = records.last {
                guard later.createdAt == record.createdAt, later.updatedAt >= record.updatedAt else { throw BugRegistryError.invalidDocument }
            }
            records.append(record); revision = record.supersedes; fingerprint = record.previousFingerprint
        }
        return records
    }
    private func validateRelationships(_ candidate: BugRecord) throws {
        for link in candidate.content.relationships {
            guard try read(link.target).first != nil else { throw BugRegistryError.unavailableReference }
            guard link.kind != .relatedTo else { continue }
            var pending = [link.target], seen = Set<BugID>()
            while let id = pending.popLast() {
                guard id != candidate.id else { throw BugRegistryError.invalidDocument }
                guard seen.insert(id).inserted else { continue }
                guard seen.count <= 64 else { throw BugRegistryError.limitExceeded }
                guard let record = try read(id).first else { throw BugRegistryError.unavailableReference }
                pending += record.content.relationships.filter { $0.kind == link.kind }.map(\.target)
            }
        }
    }
    private func nextRevision(_ id: BugID) throws -> Int {
        let folder: ConfigurationDirectory
        do { folder = try directory(id) } catch ScopedFileError.notFound { return 1 }
        var largest = 0
        for name in try folder.names() where name != "current.json" && !name.hasPrefix(".") {
            guard name.hasPrefix("bug.v"), name.hasSuffix(".json"), let revision = Int(name.dropFirst(5).dropLast(5)),
                  (1...1_000_000).contains(revision), name == Self.file(revision) else { throw BugRegistryError.invalidDocument }
            largest = max(largest, revision)
        }
        guard largest < 1_000_000 else { throw BugRegistryError.limitExceeded }
        return largest + 1
    }
    private func directory(_ id: BugID, create: Bool = false) throws -> ConfigurationDirectory {
        var folder = project
        for name in ["Memory", "Bugs", id.rawValue] {
            do { folder = try folder.child(name) }
            catch ScopedFileError.notFound {
                guard create else { throw ScopedFileError.notFound }
                folder = try folder.createChild(name)
            }
        }
        return folder
    }
    func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw BugRegistryError.scopeMismatch }
        let owner: WorkspaceRecord = try ConfigurationJSON.decode(WorkspaceRecord.self, from: workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try ConfigurationJSON.decode(ProjectRecord.self, from: project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID, member.schemaVersion == 1, member.scope == scope else { throw BugRegistryError.scopeMismatch }
    }
    private func instant() throws -> Date {
        let value = clock()
        guard value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 >= 0 else { throw BugRegistryError.invalidReview }
        return value
    }
    private static func file(_ revision: Int) -> String { "bug.v\(revision).json" }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        // Default Codable dates retain exact source instants, including fractional seconds.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw BugRegistryError.limitExceeded }
        _ = try OutputJSON.parse(data); return data
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        _ = try OutputJSON.parse(data)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    private struct Pointer: Codable {
        let schemaVersion: Int
        let scope: ProjectScope
        let id: BugID
        let revision: Int
        let fingerprint: ActionFingerprint
    }
}
