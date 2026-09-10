#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Foundation

struct BugReviewField: Identifiable {
    let id: String
    let title: String
    let before: String?
    let after: String
}

enum BugPresentation {
    /// This local preview context is not persisted as an execution or source claim.
    static func sanitized(_ draft: BugDraft, scope: ProjectScope) throws -> (draft: BugDraft, changed: Bool) {
        let context = RedactionContext(scope: scope, environmentID: draft.environment ?? EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let safe = try redactor.redactJSON(json(draft), in: context)
        return (try ConfigurationJSON.decode(BugDraft.self, from: Data(safe.text.utf8)), safe.redactionCount > 0)
    }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func fields(before: BugDraft? = nil, after: BugDraft) throws -> [BugReviewField] {
        let old = try before.map(document) ?? [:], new = try document(after)
        let names = ["title": "Title", "origin": "Origin", "assessment": "Assessment", "status": "Status",
            "environment": "Environment", "rootBehavior": "Root behavior", "expectedBehavior": "Expected behavior",
            "actualBehavior": "Actual behavior", "reproduction": "Reproduction steps", "details": "Structured details",
            "sources": "Sources", "evidence": "Evidence references", "ticket": "External ticket association",
            "relationships": "Bug relationships", "coveredBy": "Coverage subjects", "changeReason": "Version reason",
            "comparisonReview": "Previous comparison decision"]
        let order = ["title", "origin", "assessment", "status", "environment", "rootBehavior", "expectedBehavior",
            "actualBehavior", "reproduction", "ticket", "relationships", "details", "sources", "evidence", "coveredBy", "comparisonReview", "changeReason"]
        return order.compactMap { key in
            let previous = old[key], next = new[key]
            guard before == nil || previous != next else { return nil }
            return .init(id: key, title: names[key] ?? key, before: before == nil ? nil : previous ?? "None", after: next ?? "None")
        }
    }
    private static func document(_ draft: BugDraft) throws -> [String: String] {
        let values = try ConfigurationJSON.decode([String: KnowledgeValue].self, from: Data(json(draft).utf8))
        return try values.mapValues { value in
            if case .text(let text) = value { return text }
            return try json(value)
        }
    }
}

extension BugRelationship.Kind {
    var title: String {
        switch self { case .duplicateOf: "Duplicate of"; case .blockedBy: "Blocked by"; case .relatedTo: "Related to"; case .regressionOf: "Regression of" }
    }
    var inverseTitle: String {
        switch self { case .duplicateOf: "Duplicated by"; case .blockedBy: "Blocks"; case .relatedTo: "Related from"; case .regressionOf: "Has regression" }
    }
}
#endif
