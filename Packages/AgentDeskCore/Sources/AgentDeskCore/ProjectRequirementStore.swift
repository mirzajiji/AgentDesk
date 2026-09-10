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
    private var traceProposals: [UUID: TraceabilityProposal] = [:]

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

extension ProjectRequirementStore {
    /// No files are changed until this exact link proposal is reviewed and published.
    public func prepareTrace(subject: TraceabilitySubject, title: String, environment: EnvironmentID,
                             requirements: [RequirementLinkRequest], changeReason: String, archived: Bool = false,
                             expectedRevision: Int? = nil, in requested: ProjectScope) throws -> TraceabilityProposal {
        try root.withLock {
            try validate(requested)
            guard (1...64).contains(requirements.count), Set(requirements.map(\.id)).count == requirements.count else {
                throw RequirementError.invalidDocument
            }
            let now = clock()
            guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw RequirementError.invalidReview }
            traceProposals = traceProposals.filter { $0.value.expiresAt > now }
            guard traceProposals.count < 16 else { throw RequirementError.limitExceeded }
            let existing = try readTrace(subject)
            guard existing?.revision == expectedRevision else { throw RequirementError.staleVersion }
            guard existing == nil || now >= existing!.updatedAt else { throw RequirementError.invalidReview }
            let links = try requirements.map { request -> TracedRequirement in
                let version = try traceVersion(request.id, environment: environment, historical: request.historicalVersion)
                return TracedRequirement(id: version.id, version: version.version, fingerprint: try version.fingerprint,
                                         historical: request.historicalVersion != nil)
            }
            let candidate = RequirementTraceRecord(schemaVersion: 1, scope: scope, subject: subject, title: title,
                environment: environment, revision: (existing?.revision ?? 0) + 1, requirements: links,
                archived: archived, changeReason: changeReason, updatedAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)))
            try candidate.validate(); _ = try encode(candidate)
            let proposal = TraceabilityProposal(token: UUID(), candidate: candidate, expiresAt: now.addingTimeInterval(300),
                previousFingerprint: try existing.map { try ActionFingerprint.canonical($0) })
            traceProposals[proposal.token] = proposal
            return proposal
        }
    }
    public func cancelTrace(_ proposal: TraceabilityProposal) { traceProposals.removeValue(forKey: proposal.token) }

    public func publishReviewedTrace(_ proposal: TraceabilityProposal, in requested: ProjectScope) throws -> RequirementTraceRecord {
        try root.withLock {
            try validate(requested)
            let candidate = proposal.candidate, now = clock()
            guard traceProposals[proposal.token] == proposal, candidate.scope == scope,
                  now >= candidate.updatedAt, now < proposal.expiresAt else { throw RequirementError.invalidReview }
            traceProposals.removeValue(forKey: proposal.token)
            let existing = try readTrace(candidate.subject)
            guard try existing.map({ try ActionFingerprint.canonical($0) }) == proposal.previousFingerprint,
                  candidate.revision == (existing?.revision ?? 0) + 1 else { throw RequirementError.staleVersion }
            // A latest-active proposal cannot silently attach to behavior changed during review.
            for link in candidate.requirements {
                let current = try traceVersion(link.id, environment: candidate.environment, historical: link.historical ? link.version : nil)
                guard current.version == link.version, try current.fingerprint == link.fingerprint else { throw RequirementError.staleVersion }
            }
            let directory = try traceDirectory(candidate.subject.kind, create: true)
            try directory.write(encode(candidate), to: "\(candidate.subject.id).json", replacing: existing != nil)
            return candidate
        }
    }
    public func trace(_ subject: TraceabilitySubject, in requested: ProjectScope) throws -> RequirementTraceRecord? {
        try root.withLock { try validate(requested); return try readTrace(subject) }
    }
    /// A saved creation link never silently pins an ordinary rerun to old behavior.
    public func resolveTrace(_ subject: TraceabilitySubject, in requested: ProjectScope,
                             reproduceLinkedVersions: Bool = false) throws -> [RequirementVersion] {
        try root.withLock {
            try validate(requested)
            guard let record = try readTrace(subject), !record.archived else { throw RequirementValidationError.requirementUnavailable }
            return try record.requirements.map { link in
                let value = try traceVersion(link.id, environment: record.environment,
                                             historical: reproduceLinkedVersions ? link.version : nil)
                if reproduceLinkedVersions, try value.fingerprint != link.fingerprint { throw RequirementError.invalidDocument }
                return value
            }
        }
    }
    public func impact(of id: RequirementID, in requested: ProjectScope) throws -> RequirementImpactReport {
        try root.withLock {
            try validate(requested)
            let history = try read(id)
            let decision = history.first { $0.content.status != .draft }
            let active = decision?.content.status == .active ? decision : nil
            var links: [RequirementImpact] = [], count = 0, bytes = 0
            for kind in TraceabilitySubject.Kind.allCases {
                let directory: ConfigurationDirectory
                do { directory = try traceDirectory(kind) } catch ScopedFileError.notFound { continue }
                for name in try directory.names() where !name.hasPrefix(".") {
                    try Task.checkCancellation(); count += 1
                    guard count <= 1_000 else { throw RequirementError.limitExceeded }
                    guard name.hasSuffix(".json"), let subjectID = RequirementID(rawValue: String(name.dropLast(5))) else { throw RequirementError.invalidDocument }
                    let data = try directory.read(name, maximumBytes: 262_144)
                    bytes += data.count; guard bytes <= 16_777_216 else { throw RequirementError.limitExceeded }
                    let record: RequirementTraceRecord = try decode(data); try record.validate()
                    guard record.scope == scope, record.subject == TraceabilitySubject(kind: kind, id: subjectID) else { throw RequirementError.scopeMismatch }
                    guard !record.archived, let link = record.requirements.first(where: { $0.id == id }) else { continue }
                    guard let pinned = history.first(where: { $0.version == link.version }), try pinned.fingerprint == link.fingerprint else {
                        throw RequirementError.invalidDocument
                    }
                    let applicable = active.map { $0.content.environmentScope.isEmpty || $0.content.environmentScope.contains(record.environment) } ?? false
                    let status: RequirementImpact.Status = !applicable ? .unavailable : active?.version == link.version ? .current : .potentiallyStale
                    links.append(RequirementImpact(record: record, linked: link, activeVersion: active?.version, status: status))
                }
            }
            return RequirementImpactReport(scope: scope, requirement: id, links: links)
        }
    }
    private func traceVersion(_ id: RequirementID, environment: EnvironmentID, historical: Int?) throws -> RequirementVersion {
        let history = try read(id)
        let version: RequirementVersion?
        if let historical {
            guard (1...1_000_000).contains(historical) else { throw RequirementError.invalidDocument }
            version = history.first { $0.version == historical }
        } else {
            let decision = history.first { $0.content.status != .draft }
            version = decision?.content.status == .active ? decision : nil
        }
        guard let version, version.content.environmentScope.isEmpty || version.content.environmentScope.contains(environment) else {
            throw RequirementValidationError.requirementUnavailable
        }
        return version
    }
    private func readTrace(_ subject: TraceabilitySubject) throws -> RequirementTraceRecord? {
        let data: Data
        do { data = try traceDirectory(subject.kind).read("\(subject.id).json", maximumBytes: 262_144) }
        catch ScopedFileError.notFound { return nil }
        let record: RequirementTraceRecord = try decode(data); try record.validate()
        guard record.scope == scope, record.subject == subject else { throw RequirementError.scopeMismatch }
        for link in record.requirements {
            let pinned = try traceVersion(link.id, environment: record.environment, historical: link.version)
            guard try pinned.fingerprint == link.fingerprint else { throw RequirementError.invalidDocument }
        }
        return record
    }
    private func traceDirectory(_ kind: TraceabilitySubject.Kind, create: Bool = false) throws -> ConfigurationDirectory {
        var parent = project
        for component in ["Memory", "Traceability", kind.rawValue] {
            do { parent = try parent.child(component) }
            catch ScopedFileError.notFound {
                guard create else { throw ScopedFileError.notFound }
                parent = try parent.createChild(component)
            }
        }
        return parent
    }
}


extension ProjectRequirementStore {
    /// Bug publication and requirement validation share the root descriptor lock: a requirement edit
    /// cannot slip between reference validation and the immutable bug-version write.
    func withBugReferences(_ requests: [BugRequirementRequest], in requested: ProjectScope,
                           environment: EnvironmentID?, body: @Sendable ([BugRequirementReference]) throws -> BugRecord) throws -> BugRecord {
        try root.withLock {
            try validate(requested)
            guard requests.count <= 64 else { throw BugRegistryError.limitExceeded }
            var identities = Set<String>()
            let references = try requests.map { request -> BugRequirementReference in
                try Task.checkCancellation()
                guard identities.insert("\(request.role.rawValue)/\(request.requirement.id)").inserted else { throw BugRegistryError.invalidDocument }
                let history = try read(request.requirement.id)
                let version: RequirementVersion?
                if let number = request.requirement.historicalVersion {
                    guard (1...1_000_000).contains(number) else { throw BugRegistryError.invalidDocument }
                    version = history.first { $0.version == number }
                } else {
                    let decision = history.first { $0.content.status != .draft }
                    version = decision?.content.status == .active ? decision : nil
                }
                guard let version, version.content.environmentScope.isEmpty || environment.map({ version.content.environmentScope.contains($0) }) == true else {
                    throw BugRegistryError.unavailableReference
                }
                return BugRequirementReference(role: request.role, requirement: TracedRequirement(id: version.id, version: version.version,
                    fingerprint: try version.fingerprint, historical: request.requirement.historicalVersion != nil))
            }
            return try body(references)
        }
    }
}
