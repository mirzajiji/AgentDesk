import Foundation

/// Native project-memory boundary. Runtime callers still need policy authorization and input redaction.
public actor ProjectMemoryStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory
    private let clock: @Sendable () -> Date
    private var proposals: [UUID: MemoryProposal] = [:]
    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory,
         project: ConfigurationDirectory, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project; self.clock = clock
    }
    /// Intake can only create nonauthoritative active notes/inbox items, never confirm or overwrite knowledge.
    public func capture(_ draft: MemoryDraft, in requested: ProjectScope) throws -> MemoryRecord {
        try root.withLock {
            try validate(requested); try draft.validate(in: scope)
            guard draft.kind != .confirmed, draft.disposition == .active else { throw RequirementError.invalidReview }
            let candidate = try candidate(draft, id: MemoryID(), expected: nil)
            return try publish(candidate)
        }
    }
    public func prepare(_ draft: MemoryDraft, id: MemoryID? = nil, expectedRevision: Int? = nil,
                        in requested: ProjectScope) throws -> MemoryProposal {
        try root.withLock {
            try validate(requested); try draft.validate(in: scope)
            let now = try instant()
            proposals = proposals.filter { $0.value.expiresAt > now }
            guard proposals.count < 16 else { throw RequirementError.limitExceeded }
            let value = try candidate(draft, id: id ?? MemoryID(), expected: expectedRevision)
            let proposal = MemoryProposal(token: UUID(), candidate: value, expiresAt: now.addingTimeInterval(300))
            proposals[proposal.token] = proposal
            return proposal
        }
    }
    public func cancel(_ proposal: MemoryProposal) { proposals.removeValue(forKey: proposal.token) }
    public func publishReviewed(_ proposal: MemoryProposal, in requested: ProjectScope) throws -> MemoryRecord {
        try root.withLock {
            try validate(requested)
            let now = try instant()
            guard proposals[proposal.token] == proposal, proposal.candidate.scope == scope,
                  now >= proposal.candidate.updatedAt, now < proposal.expiresAt else { throw RequirementError.invalidReview }
            proposals.removeValue(forKey: proposal.token)
            return try publish(proposal.candidate)
        }
    }
    public func record(_ id: MemoryID, in requested: ProjectScope) throws -> MemoryRecord? {
        try root.withLock { try validate(requested); return try read(id).first }
    }
    public func history(_ id: MemoryID, in requested: ProjectScope) throws -> [MemoryRecord] {
        try root.withLock { try validate(requested); return try read(id) }
    }
    public func list(in requested: ProjectScope, kinds: Set<MemoryKind> = Set(MemoryKind.allCases),
                     environment: EnvironmentID? = nil, includeInactive: Bool = false,
                     after: MemoryID? = nil, limit: Int = 50) throws -> [MemoryRecord] {
        try root.withLock {
            try validate(requested)
            guard (1...100).contains(limit) else { throw RequirementError.limitExceeded }
            let parent: ConfigurationDirectory
            do { parent = try project.child("Memory").child("Knowledge") } catch ScopedFileError.notFound { return [] }
            var results: [MemoryRecord] = []
            for name in try parent.names() where !name.hasPrefix(".") {
                try Task.checkCancellation()
                guard let id = MemoryID(rawValue: name), id.rawValue == name else { throw RequirementError.invalidDocument }
                if let after, name <= after.rawValue { continue }
                guard let record = try read(id).first, kinds.contains(record.content.kind),
                      includeInactive || record.content.disposition == .active else { continue }
                if let environment, !record.content.environmentScope.isEmpty,
                   !record.content.environmentScope.contains(environment) { continue }
                results.append(record); if results.count == limit { break }
            }
            return results
        }
    }
    private func candidate(_ draft: MemoryDraft, id: MemoryID, expected: Int?) throws -> MemoryRecord {
        let current = try read(id).first, now = try instant()
        guard current?.revision == expected else { throw RequirementError.staleVersion }
        guard current == nil || now >= current!.updatedAt else { throw RequirementError.invalidReview }
        let timestamp = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let record = MemoryRecord(schemaVersion: 1, scope: scope, id: id, revision: try nextRevision(id),
            supersedes: current?.revision, previousFingerprint: try current?.fingerprint,
            createdAt: current?.createdAt ?? timestamp, updatedAt: timestamp, content: draft)
        try record.validate(); _ = try encode(record); return record
    }
    private func publish(_ candidate: MemoryRecord) throws -> MemoryRecord {
        try candidate.validate(); let data = try encode(candidate)
        let history = try read(candidate.id, reserving: data.count), current = history.first
        guard current?.revision == candidate.supersedes, try current?.fingerprint == candidate.previousFingerprint,
              try nextRevision(candidate.id) == candidate.revision else { throw RequirementError.staleVersion }
        guard history.count < 1_024 else { throw RequirementError.limitExceeded }
        let folder = try directory(candidate.id, create: true)
        try folder.write(data, to: Self.file(candidate.revision))
        let pointer = Pointer(schemaVersion: 1, scope: scope, id: candidate.id, revision: candidate.revision, fingerprint: try candidate.fingerprint)
        try folder.write(encode(pointer), to: "current.json", replacing: current != nil)
        return candidate
    }
    private func read(_ id: MemoryID, reserving: Int = 0) throws -> [MemoryRecord] {
        let folder: ConfigurationDirectory, pointer: Pointer
        do { folder = try directory(id); pointer = try decode(folder.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { return [] }
        guard pointer.schemaVersion == 1, pointer.scope == scope, pointer.id == id,
              (1...1_000_000).contains(pointer.revision) else { throw RequirementError.invalidDocument }
        var revision: Int? = pointer.revision, fingerprint: ActionFingerprint? = pointer.fingerprint
        var records: [MemoryRecord] = [], bytes = reserving
        while let number = revision {
            try Task.checkCancellation()
            guard records.count < 1_024 else { throw RequirementError.limitExceeded }
            let data = try folder.read(Self.file(number), maximumBytes: 262_144)
            bytes += data.count; guard bytes <= 16_777_216 else { throw RequirementError.limitExceeded }
            let record: MemoryRecord = try decode(data); try record.validate()
            guard record.scope == scope, record.id == id, record.revision == number,
                  try record.fingerprint == fingerprint else { throw RequirementError.invalidDocument }
            if let later = records.last {
                guard later.createdAt == record.createdAt, later.updatedAt >= record.updatedAt else { throw RequirementError.invalidDocument }
            }
            records.append(record); revision = record.supersedes; fingerprint = record.previousFingerprint
        }
        return records
    }
    private func nextRevision(_ id: MemoryID) throws -> Int {
        let folder: ConfigurationDirectory
        do { folder = try directory(id) } catch ScopedFileError.notFound { return 1 }
        var largest = 0
        for name in try folder.names() where name != "current.json" && !name.hasPrefix(".") {
            guard name.hasPrefix("entry.v"), name.hasSuffix(".json"), let revision = Int(name.dropFirst(7).dropLast(5)),
                  (1...1_000_000).contains(revision), name == Self.file(revision) else { throw RequirementError.invalidDocument }
            largest = max(largest, revision)
        }
        guard largest < 1_000_000 else { throw RequirementError.limitExceeded }
        return largest + 1
    }
    private func directory(_ id: MemoryID, create: Bool = false) throws -> ConfigurationDirectory {
        var folder = project
        for name in ["Memory", "Knowledge", id.rawValue] {
            do { folder = try folder.child(name) }
            catch ScopedFileError.notFound {
                guard create else { throw ScopedFileError.notFound }
                folder = try folder.createChild(name)
            }
        }
        return folder
    }
    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw RequirementError.scopeMismatch }
        let owner: WorkspaceRecord = try ConfigurationJSON.decode(WorkspaceRecord.self, from: workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try ConfigurationJSON.decode(ProjectRecord.self, from: project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID, member.schemaVersion == 1, member.scope == scope else { throw RequirementError.scopeMismatch }
    }
    private func instant() throws -> Date {
        let value = clock()
        guard value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 >= 0 else { throw RequirementError.invalidReview }
        return value
    }
    private static func file(_ revision: Int) -> String { "entry.v\(revision).json" }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        // Default Codable dates retain exact source instants, including fractional seconds.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw RequirementError.limitExceeded }
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
        let id: MemoryID
        let revision: Int
        let fingerprint: ActionFingerprint
    }
}
