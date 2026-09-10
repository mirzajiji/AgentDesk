import Foundation

/// Trusted local administrative boundary. Agent proposals require native review before publication.
/// Readers select latest active behavior by default; history is an explicit choice.
public actor ProjectRequirementStore {
    public nonisolated let scope: ProjectScope
    private let root: ConfigurationDirectory
    private let workspace: ConfigurationDirectory
    private let project: ConfigurationDirectory
    private let clock: @Sendable () -> Date
    private var proposals: [UUID: RequirementProposal] = [:]

    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory,
         project: ConfigurationDirectory, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope; self.root = root; self.workspace = workspace; self.project = project; self.clock = clock
    }

    public func resolve(_ id: RequirementID, selection: RequirementSelection = .latestActive,
                        in requested: ProjectScope, environment: EnvironmentID? = nil) throws -> RequirementVersion? {
        try root.withLock {
            try validate(requested)
            let history = try read(id)
            let value: RequirementVersion?
            switch selection {
            case .latestPublished: value = history.first
            case .latestActive:
                let lastDecision = history.first { $0.content.status != .draft }
                value = lastDecision?.content.status == .active ? lastDecision : nil
            case .historical(let version):
                guard (1...1_000_000).contains(version) else { throw RequirementError.invalidDocument }
                value = history.first { $0.version == version }
            }
            if let environment, let value, !value.content.environmentScope.isEmpty,
               !value.content.environmentScope.contains(environment) { return nil }
            return value
        }
    }

    public func history(_ id: RequirementID, in requested: ProjectScope) throws -> [RequirementVersion] {
        try root.withLock { try validate(requested); return try read(id) }
    }

    /// Administrative listing includes draft/retired heads. Execution uses resolve's latest-active default.
    public func list(in requested: ProjectScope, after: RequirementID? = nil, limit: Int = 50) throws -> [RequirementVersion] {
        try root.withLock {
            try validate(requested)
            guard (1...100).contains(limit) else { throw RequirementError.limitExceeded }
            let directory: ConfigurationDirectory
            do { directory = try project.child("Memory").child("Requirements") }
            catch ScopedFileError.notFound { return [] }
            var result: [RequirementVersion] = []
            for name in try directory.names() where !name.hasPrefix(".") {
                guard let id = RequirementID(rawValue: name) else { throw RequirementError.invalidDocument }
                if let after, name <= after.rawValue { continue }
                if let current = try read(id).first { result.append(current) }
                if result.count == limit { break }
            }
            return result
        }
    }

    /// No authoritative files are written while preparing or cancelling a review.
    public func prepare(_ draft: RequirementDraft, id: RequirementID, expectedVersion: Int?,
                        in requested: ProjectScope) throws -> RequirementProposal {
        try root.withLock {
            try validate(requested); try draft.validate()
            let now = clock()
            guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw RequirementError.invalidReview }
            proposals = proposals.filter { $0.value.expiresAt > now }
            guard proposals.count < 16 else { throw RequirementError.limitExceeded }
            let current = try read(id).first
            guard current?.version == expectedVersion else { throw RequirementError.staleVersion }
            guard current == nil || now >= current!.createdAt else { throw RequirementError.invalidReview }
            let version = try nextVersion(id)
            let candidate = RequirementVersion(schemaVersion: 1, scope: scope, id: id, version: version,
                supersedes: current?.version, previousFingerprint: try current?.fingerprint,
                createdAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)), content: draft)
            try candidate.validate(); _ = try encode(candidate)
            let proposal = RequirementProposal(token: UUID(), candidate: candidate, expiresAt: now.addingTimeInterval(300))
            proposals[proposal.token] = proposal
            return proposal
        }
    }

    public func cancel(_ proposal: RequirementProposal) { proposals.removeValue(forKey: proposal.token) }

    /// Call only after the native user reviews this exact proposal. Tokens cannot be reused or transferred between stores.
    public func publishReviewed(_ proposal: RequirementProposal, in requested: ProjectScope) throws -> RequirementVersion {
        try root.withLock {
            try validate(requested)
            let now = clock(), candidate = proposal.candidate
            guard proposals[proposal.token] == proposal, candidate.scope == scope,
                  now >= candidate.createdAt, now < proposal.expiresAt else { throw RequirementError.invalidReview }
            proposals.removeValue(forKey: proposal.token)
            let data = try encode(candidate)
            let history = try read(candidate.id, reserving: data.count), current = history.first
            guard current?.version == candidate.supersedes, try current?.fingerprint == candidate.previousFingerprint,
                  try nextVersion(candidate.id) == candidate.version else { throw RequirementError.staleVersion }
            guard history.count < 1_024 else { throw RequirementError.limitExceeded }
            let directory = try directory(candidate.id, create: true)
            // Exclusive publication preserves an orphan version if pointer replacement fails.
            try directory.write(data, to: Self.file(candidate.version))
            let active: Int?
            switch candidate.content.status {
            case .active: active = candidate.version
            case .retired: active = nil
            case .draft:
                let lastDecision = history.first { $0.content.status != .draft }
                active = lastDecision?.content.status == .active ? lastDecision?.version : nil
            }
            let pointer = Pointer(schemaVersion: 1, scope: scope, requirementId: candidate.id,
                currentVersion: candidate.version, currentFile: Self.file(candidate.version),
                fingerprint: try candidate.fingerprint, activeVersion: active)
            try directory.write(encode(pointer), to: "current.json", replacing: current != nil)
            return candidate
        }
    }

    private func read(_ id: RequirementID, reserving bytesToReserve: Int = 0) throws -> [RequirementVersion] {
        let directory: ConfigurationDirectory
        do { directory = try self.directory(id) } catch ScopedFileError.notFound { return [] }
        let pointer: Pointer
        do { pointer = try decode(directory.read("current.json", maximumBytes: 16_384)) }
        catch ScopedFileError.notFound { return [] }
        guard pointer.schemaVersion == 1, pointer.scope == scope, pointer.requirementId == id,
              (1...1_000_000).contains(pointer.currentVersion), pointer.currentFile == Self.file(pointer.currentVersion) else {
            throw RequirementError.invalidDocument
        }
        var version: Int? = pointer.currentVersion, fingerprint: ActionFingerprint? = pointer.fingerprint
        var result: [RequirementVersion] = [], bytes = bytesToReserve
        while let number = version {
            try Task.checkCancellation()
            guard result.count < 1_024 else { throw RequirementError.limitExceeded }
            let data = try directory.read(Self.file(number), maximumBytes: 262_144)
            bytes += data.count; guard bytes <= 16_777_216 else { throw RequirementError.limitExceeded }
            let record: RequirementVersion = try decode(data); try record.validate()
            guard record.id == id, record.scope == scope, record.version == number, try record.fingerprint == fingerprint else {
                throw RequirementError.invalidDocument
            }
            if let later = result.last, later.createdAt < record.createdAt { throw RequirementError.invalidDocument }
            result.append(record); version = record.supersedes; fingerprint = record.previousFingerprint
        }
        let lastDecision = result.first { $0.content.status != .draft }
        guard pointer.activeVersion == (lastDecision?.content.status == .active ? lastDecision?.version : nil) else {
            throw RequirementError.invalidDocument
        }
        return result
    }

    private func nextVersion(_ id: RequirementID) throws -> Int {
        let directory: ConfigurationDirectory
        do { directory = try self.directory(id) } catch ScopedFileError.notFound { return 1 }
        var largest = 0
        for name in try directory.names() where name != "current.json" && !name.hasPrefix(".") {
            guard name.hasPrefix("requirement.v"), name.hasSuffix(".json"),
                  let version = Int(name.dropFirst(13).dropLast(5)), (1...1_000_000).contains(version),
                  name == Self.file(version) else { throw RequirementError.invalidDocument }
            largest = max(largest, version)
        }
        guard largest < 1_000_000 else { throw RequirementError.limitExceeded }
        return largest + 1
    }

    private func directory(_ id: RequirementID, create: Bool = false) throws -> ConfigurationDirectory {
        var parent = project
        for name in ["Memory", "Requirements", id.rawValue] {
            do { parent = try parent.child(name) }
            catch ScopedFileError.notFound {
                guard create else { throw ScopedFileError.notFound }
                parent = try parent.createChild(name)
            }
        }
        return parent
    }
    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw RequirementError.scopeMismatch }
        let owner: WorkspaceRecord = try ConfigurationJSON.decode(WorkspaceRecord.self, from: workspace.read("workspace.json", maximumBytes: 65_536))
        let member: ProjectRecord = try ConfigurationJSON.decode(ProjectRecord.self, from: project.read("project.json", maximumBytes: 65_536))
        guard owner.schemaVersion == 1, owner.id == scope.workspaceID, member.schemaVersion == 1, member.scope == scope else {
            throw RequirementError.scopeMismatch
        }
    }
    private static func file(_ version: Int) -> String { "requirement.v\(version).json" }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value); _ = try OutputJSON.parse(data)
        return data
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            _ = try OutputJSON.parse(data)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch is CancellationError { throw CancellationError() }
        catch { throw RequirementError.invalidDocument }
    }
    private struct Pointer: Codable {
        let schemaVersion: Int
        let scope: ProjectScope
        let requirementId: RequirementID
        let currentVersion: Int
        let currentFile: String
        let fingerprint: ActionFingerprint
        let activeVersion: Int?
    }
}
