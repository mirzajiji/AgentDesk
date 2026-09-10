#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Foundation

struct MemoryReviewChange: Identifiable {
    let field: String
    let before: String?
    let after: String
    var id: String { field }
}

/// Local administrative preview redaction. Its ephemeral context is never written as a run,
/// environment assignment or observed provenance; actual source scopes remain in the draft.
enum MemoryPresentation {
    static func sanitized(_ draft: MemoryDraft, scope: ProjectScope) throws -> (draft: MemoryDraft, changed: Bool) {
        let context = RedactionContext(scope: scope, environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let safe = try redactor.redactJSON(json(draft), in: context)
        let value = try ConfigurationJSON.decode(MemoryDraft.self, from: Data(safe.text.utf8))
        return (value, safe.redactionCount > 0)
    }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Takes already-sanitized drafts; no source metadata or content is omitted from review.
    static func changes(before: MemoryDraft?, after: MemoryDraft) throws -> [MemoryReviewChange] {
        let previous = try before.map(fields) ?? [:]
        let next = try fields(after)
        let order = ["Title", "Content", "Kind", "Topic", "Status", "Tags", "Logical path", "Environments", "Sources", "Structured content", "Reason"]
        let changed = before.map { old in
            Set([
                ("Title", old.title != after.title), ("Content", old.body != after.body),
                ("Kind", old.kind != after.kind), ("Topic", old.topic != after.topic),
                ("Status", old.disposition != after.disposition), ("Tags", old.tags != after.tags),
                ("Logical path", old.knowledgePath != after.knowledgePath),
                ("Environments", old.environmentScope != after.environmentScope),
                ("Sources", old.sources != after.sources), ("Structured content", old.structured != after.structured),
                ("Reason", old.changeReason != after.changeReason)
            ].filter { $0.1 }.map { $0.0 })
        } ?? Set(order)
        return order.compactMap { key in
            guard let value = next[key], changed.contains(key) else { return nil }
            return MemoryReviewChange(field: key, before: previous[key], after: value)
        }
    }
    private static func fields(_ draft: MemoryDraft) throws -> [String: String] {
        let sources = draft.sources.map { source in
            var lines = [source.label, "Origin: \(source.origin.rawValue)", "Captured: \(source.capturedAt.formatted())",
                "Stored timestamp: \(source.capturedAt.timeIntervalSinceReferenceDate) seconds since 2001-01-01 UTC",
                "Workspace: \(source.scope.workspaceID)", "Project: \(source.scope.projectID)"]
            if let value = source.reference { lines.append("Reference: \(value)") }
            if let value = source.environment { lines.append("Environment: \(value)") }
            if let value = source.run { lines.append("Run: \(value)") }
            if let value = source.agent { lines.append("Agent: \(value)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return ["Title": draft.title, "Content": draft.body, "Kind": draft.kind.rawValue.capitalized,
            "Topic": draft.topic.memoryTitle, "Status": draft.disposition.rawValue.capitalized,
            "Tags": try json(draft.tags),
            "Logical path": draft.knowledgePath?.rawValue ?? "None",
            "Environments": draft.environmentScope.isEmpty ? "All project environments" : draft.environmentScope.map(\.rawValue).joined(separator: "\n"),
            "Sources": sources, "Structured content": try json(draft.structured), "Reason": draft.changeReason]
    }
}
#endif
