import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

public enum KnowledgeContextError: Error, Equatable, Sendable { case scopeMismatch, invalidCandidate, staleSources, contextTooLarge }

/// Search is only a discovery mechanism. Candidate content is never used as run input.
public struct KnowledgeCandidate: Sendable {
    public let sourceID: String
    public let revision: Int
    public let fingerprint: ActionFingerprint
    public init(sourceID: String, revision: Int, fingerprint: ActionFingerprint) {
        self.sourceID = sourceID; self.revision = revision; self.fingerprint = fingerprint
    }
}
public struct KnowledgeCandidatePage: Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let candidates: [KnowledgeCandidate]
    public let hasMore: Bool
    public init(scope: ProjectScope, environment: EnvironmentID, candidates: [KnowledgeCandidate], hasMore: Bool) {
        self.scope = scope; self.environment = environment; self.candidates = candidates; self.hasMore = hasMore
    }
}
public protocol KnowledgeCandidateSearching: Sendable {
    func candidates(for selection: AgentKnowledgeSelection, in scope: ProjectScope,
                    environment: EnvironmentID) async throws -> KnowledgeCandidatePage
}
extension KnowledgeSearchIndex: KnowledgeCandidateSearching {
    public func candidates(for selection: AgentKnowledgeSelection, in scope: ProjectScope,
                           environment: EnvironmentID) async throws -> KnowledgeCandidatePage {
        try selection.validate()
        let page = try search(selection.query, in: scope, environment: environment,
            kinds: Set(selection.kinds), paths: selection.paths, limit: 32)
        return KnowledgeCandidatePage(scope: page.scope, environment: page.environment,
            candidates: page.hits.map { KnowledgeCandidate(sourceID: $0.sourceID, revision: $0.revision, fingerprint: $0.fingerprint) }, hasMore: page.hasMore)
    }
}

/// Only this service can construct a prepared snapshot. Raw source hashes stay in its in-memory validator.
public struct PreparedKnowledgeContext: Sendable {
    public let selection: AgentKnowledgeSelection
    public let content: RedactedText
    let validate: @Sendable () async throws -> Void
}

/// Trusted local read boundary. The runtime must authorize reads before constructing or calling it.
public struct KnowledgeContextService: Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    private let memory: ProjectMemoryStore
    private let requirements: ProjectRequirementStore
    private let search: any KnowledgeCandidateSearching

    public init(memory: ProjectMemoryStore, requirements: ProjectRequirementStore,
                environment: EnvironmentID, search: any KnowledgeCandidateSearching) throws {
        guard memory.scope == requirements.scope else { throw KnowledgeContextError.scopeMismatch }
        self.scope = memory.scope; self.memory = memory; self.requirements = requirements
        self.environment = environment; self.search = search
    }
    public func prepare(_ selection: AgentKnowledgeSelection, redactor: ContentRedactor) async throws -> PreparedKnowledgeContext {
        try Task.checkCancellation(); try selection.validate()
        guard redactor.context.scope == scope, redactor.context.environmentID == environment else { throw KnowledgeContextError.scopeMismatch }
        let page = try await search.candidates(for: selection, in: scope, environment: environment)
        guard page.scope == scope, page.environment == environment else { throw KnowledgeContextError.scopeMismatch }
        guard page.candidates.count <= 32, Set(page.candidates.map(\.sourceID)).count == page.candidates.count else {
            throw KnowledgeContextError.invalidCandidate
        }
        var requests: [(String, KnowledgeCandidate?)] = [], traces: [TraceStamp] = [], relationships: [Relationship] = []
        var omitted = page.hasMore
        // Explicit relationships have priority, but never bypass path/classification/environment selection.
        for subject in selection.relationships {
            try Task.checkCancellation()
            guard let trace = try await requirements.trace(subject, in: scope), !trace.archived,
                  trace.environment == environment else {
                relationships.append(Relationship(subject: subject, revision: nil, status: "unavailable", requirementIDs: [])); continue
            }
            traces.append(TraceStamp(subject: subject, fingerprint: try .canonical(trace)))
            relationships.append(Relationship(subject: subject, revision: trace.revision, status: "current-active-resolution",
                requirementIDs: trace.requirements.map(\.id)))
            for link in trace.requirements {
                if requests.count < 64 { requests.append(("requirement/\(link.id)", nil)) } else { omitted = true }
            }
        }
        requests += page.candidates.map { ($0.sourceID, $0) }
        var entries: [Entry] = [], issues: [Issue] = [], stamps: [Stamp] = [], seen = Set<String>()
        var bytes = 0
        for (id, candidate) in requests {
            try Task.checkCancellation()
            guard seen.insert(id).inserted else { continue }
            guard let document = try await resolve(id) else { issues.append(Issue(sourceID: id, reason: "unavailable")); continue }
            guard selection.paths.permits(document.path), selection.kinds.contains(document.kind) else {
                issues.append(Issue(sourceID: id, reason: "excluded")); continue
            }
            if let candidate, candidate.revision != document.revision || candidate.fingerprint != document.fingerprint {
                issues.append(Issue(sourceID: id, reason: "stale-index")); continue
            }
            // Strip source-history digests: the run records a fingerprint of sanitized bytes instead.
            guard var object = try JSONSerialization.jsonObject(with: Data(document.bodyJSON.utf8)) as? [String: Any] else {
                throw KnowledgeContextError.invalidCandidate
            }
            object.removeValue(forKey: "previousFingerprint")
            let body = try redactor.redactJSON(String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self), in: redactor.context).text
            let entry = Entry(sourceID: id, path: document.path, kind: document.kind, revision: document.revision,
                sanitizedFingerprint: try ActionFingerprint(bytes: Data(body.utf8)), bodyJSON: body)
            let size = try JSONEncoder().encode(entry).count
            guard entries.count < selection.maximumRecords, bytes + size <= selection.maximumBytes else { omitted = true; continue }
            entries.append(entry); bytes += size
            stamps.append(Stamp(sourceID: id, fingerprint: document.fingerprint))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func encodeSnapshot() throws -> RedactedText {
            let snapshot = Snapshot(scope: scope, environment: environment, entries: entries, issues: issues,
                relationships: relationships, omittedByLimit: omitted)
            return try redactor.redactJSON(String(decoding: encoder.encode(snapshot), as: UTF8.self), in: redactor.context)
        }
        var safe = try encodeSnapshot()
        // The entire packet, including provenance and omission diagnostics, obeys the byte limit.
        while safe.text.utf8.count > selection.maximumBytes, !entries.isEmpty {
            entries.removeLast(); stamps.removeLast(); omitted = true
            safe = try encodeSnapshot()
        }
        guard safe.text.utf8.count <= selection.maximumBytes else { throw KnowledgeContextError.contextTooLarge }
        let sourceStamps = stamps, traceStamps = traces
        try await validate(sourceStamps, traces: traceStamps)
        return PreparedKnowledgeContext(selection: selection, content: safe, validate: {
            try await self.validate(sourceStamps, traces: traceStamps)
        })
    }

    private func resolve(_ id: String) async throws -> KnowledgeIndexDocument? {
        let document: KnowledgeIndexDocument
        if id.hasPrefix("requirement/"), let key = RequirementID(rawValue: String(id.dropFirst(12))) {
            guard let value = try await requirements.resolve(key, in: scope, environment: environment) else { return nil }
            document = try KnowledgeIndexDocument(requirement: value)
        } else if id.hasPrefix("memory/"), let key = MemoryID(rawValue: String(id.dropFirst(7))) {
            guard let value = try await memory.record(key, in: scope), value.content.disposition == .active else { return nil }
            document = try KnowledgeIndexDocument(memory: value)
        } else { throw KnowledgeContextError.invalidCandidate }
        guard document.scope == scope else { throw KnowledgeContextError.scopeMismatch }
        guard document.environments.isEmpty || document.environments.contains(environment) else { return nil }
        return document
    }
    private func validate(_ stamps: [Stamp], traces: [TraceStamp]) async throws {
        for stamp in stamps {
            try Task.checkCancellation()
            guard let document = try await resolve(stamp.sourceID), document.fingerprint == stamp.fingerprint else {
                throw KnowledgeContextError.staleSources
            }
        }
        for stamp in traces {
            try Task.checkCancellation()
            guard let trace = try await requirements.trace(stamp.subject, in: scope), !trace.archived,
                  trace.environment == environment, try ActionFingerprint.canonical(trace) == stamp.fingerprint else {
                throw KnowledgeContextError.staleSources
            }
        }
    }
    private struct Stamp: Sendable { let sourceID: String; let fingerprint: ActionFingerprint }
    private struct TraceStamp: Sendable { let subject: TraceabilitySubject; let fingerprint: ActionFingerprint }
    private struct Entry: Encodable {
        let sourceID: String; let path: KnowledgePath; let kind: KnowledgeRecordKind; let revision: Int
        let sanitizedFingerprint: ActionFingerprint; let bodyJSON: String
    }
    private struct Issue: Encodable { let sourceID: String; let reason: String }
    private struct Relationship: Encodable {
        let subject: TraceabilitySubject; let revision: Int?; let status: String; let requirementIDs: [RequirementID]
    }
    private struct Snapshot: Encodable {
        let schemaVersion = 1
        let scope: ProjectScope; let environment: EnvironmentID
        let entries: [Entry]; let issues: [Issue]; let relationships: [Relationship]; let omittedByLimit: Bool
    }
}
