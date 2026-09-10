import Foundation

/// Pure comparison input, not proof of authorization or of an artifact's existence.
/// The collecting service must resolve these requirement versions from the authoritative store.
public struct BugComparisonInput: Sendable {
    public let record: BugRecord
    public let activeRequirements: [RequirementVersion]
    public let staleRequirements: Bool
    public init(record: BugRecord, activeRequirements: [RequirementVersion]) throws {
        try record.validate()
        guard activeRequirements.count <= 64, Set(activeRequirements.map(\.id)).count == activeRequirements.count else {
            throw BugRegistryError.invalidDocument
        }
        for requirement in activeRequirements {
            try requirement.validate()
            guard requirement.scope == record.scope else { throw BugRegistryError.scopeMismatch }
            guard requirement.content.status == .active,
                  requirement.content.environmentScope.isEmpty || record.content.environment.map({ requirement.content.environmentScope.contains($0) }) == true else {
                throw BugRegistryError.unavailableReference
            }
        }
        let expected = Set(record.requirements.map { $0.requirement.id })
        guard Set(activeRequirements.map(\.id)).isSubset(of: expected) else { throw BugRegistryError.invalidDocument }
        let versions = Dictionary(uniqueKeysWithValues: activeRequirements.map { ($0.id, $0) })
        staleRequirements = try record.requirements.contains { reference in
            guard let active = versions[reference.requirement.id] else { return true }
            let fingerprint = try active.fingerprint
            return active.version != reference.requirement.version || fingerprint != reference.requirement.fingerprint
        }
        self.record = record; self.activeRequirements = activeRequirements
    }
}

public struct BugComparisonResult: Codable, Equatable, Sendable {
    public enum Classification: String, Codable, Sendable {
        case duplicate, possibleDuplicate, related, distinct, blocked, needsEvidence, needsEnvironment, needsRequirementReview
    }
    public let classification: Classification
    /// Field names only. Raw values and unredacted fingerprints do not enter this result.
    public let matchingFields: [String]
    public let differingFields: [String]
    public let reason: String
}

public enum BugComparison {
    /// Nil means comparison is eligible, not that a new defect has been verified.
    public static func readiness(_ incoming: BugComparisonInput) -> BugComparisonResult.Classification? {
        if incoming.record.content.assessment == .blocked { return .blocked }
        if incoming.record.content.environment == nil { return .needsEnvironment }
        if incoming.staleRequirements { return .needsRequirementReview }
        if incoming.record.content.assessment != .observed { return .needsEvidence }
        return nil
    }
    public static func compare(_ incoming: BugComparisonInput, with existing: BugComparisonInput) throws -> BugComparisonResult {
        let left = incoming.record, right = existing.record
        guard left.scope == right.scope else { throw BugRegistryError.scopeMismatch }
        guard left.id != right.id else { throw BugRegistryError.invalidDocument }
        func result(_ classification: BugComparisonResult.Classification, _ reason: String,
                    matches: [String] = [], differences: [String] = []) -> BugComparisonResult {
            .init(classification: classification, matchingFields: matches, differingFields: differences, reason: reason)
        }
        if left.content.assessment == .blocked { return result(.blocked, "Downstream behavior was blocked and must not be reported as a verified defect.") }
        guard left.content.environment != nil else { return result(.needsEnvironment, "Choose the observed environment before comparing defects.") }
        if incoming.staleRequirements { return result(.needsRequirementReview, "The incoming finding is not bound to all current active requirements.") }
        guard left.content.assessment == .observed else { return result(.needsEvidence, "The incoming finding lacks an observed behavior assessment.") }

        var matches: [String] = [], differences: [String] = []
        func field(_ name: String, _ equal: Bool) { if equal { matches.append(name) } else { differences.append(name) } }
        let root = normalize(left.content.rootBehavior) == normalize(right.content.rootBehavior)
        let expected = normalize(left.content.expectedBehavior) == normalize(right.content.expectedBehavior)
        let actual = normalize(left.content.actualBehavior) == normalize(right.content.actualBehavior)
        field("rootBehavior", root); field("expectedBehavior", expected); field("actualBehavior", actual)
        field("environment", left.content.environment == right.content.environment)
        let keys = Set(left.content.details.keys).union(right.content.details.keys).sorted()
        for key in keys where detailFields.contains(key) { field(key, left.content.details[key] == right.content.details[key]) }
        // Aggregate unknown keys so one equal value cannot conceal a later difference.
        // Source text must not become a diagnostic field name.
        let unknownKeys = keys.filter { !detailFields.contains($0) }
        if !unknownKeys.isEmpty { field("otherAttributes", unknownKeys.allSatisfy { left.content.details[$0] == right.content.details[$0] }) }
        let leftIDs = Set(left.requirements.map { $0.requirement.id }), rightIDs = Set(right.requirements.map { $0.requirement.id })
        let sharedRequirements = !leftIDs.intersection(rightIDs).isEmpty
        field("requirements", try references(incoming) == references(existing))
        let anchors = anchorFields.filter { key in
            guard let value = left.content.details[key], meaningful(value) else { return false }
            return right.content.details[key] == value
        }
        let overlap = root || !anchors.isEmpty || sharedRequirements
        guard overlap else { return result(.distinct, "No shared root behavior or scoped comparison anchor was found.", matches: matches, differences: differences) }
        guard left.content.environment == right.content.environment else {
            return result(.related, "Similar behavior belongs to a different environment; it is not an exact duplicate.", matches: matches, differences: differences)
        }
        guard right.content.assessment != .blocked else {
            return result(.related, "The existing record describes blocked behavior, not an observed matching defect.", matches: matches, differences: differences)
        }
        if existing.staleRequirements {
            return result(.possibleDuplicate, "The existing record overlaps, but its requirement references need current-behavior review.", matches: matches, differences: differences)
        }
        let exact = try fingerprint(incoming) == fingerprint(existing)
        if exact, right.content.assessment == .observed, !anchors.isEmpty || sharedRequirements {
            return result(.duplicate, "Observed behavior, comparison attributes, environment and current requirements match exactly.", matches: matches, differences: differences)
        }
        if root || ((!anchors.isEmpty || sharedRequirements) && (expected || actual)) {
            return result(.possibleDuplicate, "The records overlap but differences or incomplete comparison anchors require review.", matches: matches, differences: differences)
        }
        return result(.related, "The records share context but describe different behavior.", matches: matches, differences: differences)
    }

    /// Retain only in trusted comparison memory. Do not persist a digest of unredacted secret-bearing content.
    public static func fingerprint(_ input: BugComparisonInput) throws -> ActionFingerprint {
        let value = input.record.content
        return try .canonical(Fingerprint(scope: input.record.scope, environment: value.environment,
            root: normalize(value.rootBehavior), expected: normalize(value.expectedBehavior), actual: normalize(value.actualBehavior),
            details: value.details, requirements: references(input)))
    }
    private static let anchorFields = ["endpoint", "module", "component", "validationField", "scenarioIDs"]
    private static let detailFields = Set(anchorFields + ["stateBefore", "stateAfter", "httpStatus", "applicationError", "persistedState", "region"])
    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    private static func meaningful(_ value: KnowledgeValue) -> Bool {
        switch value {
        case .text(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array): !array.isEmpty
        default: false
        }
    }
    private struct Requirement: Codable, Equatable {
        let role: BugRequirementRequest.Role; let id: RequirementID; let version: Int; let fingerprint: ActionFingerprint
    }
    private static func references(_ input: BugComparisonInput) throws -> [Requirement] {
        let versions = Dictionary(uniqueKeysWithValues: input.activeRequirements.map { ($0.id, $0) })
        return try input.record.requirements.compactMap { reference in
            guard let active = versions[reference.requirement.id] else { return nil }
            return Requirement(role: reference.role, id: active.id, version: active.version, fingerprint: try active.fingerprint)
        }.sorted { "\($0.role.rawValue)/\($0.id)" < "\($1.role.rawValue)/\($1.id)" }
    }
    private struct Fingerprint: Encodable {
        let scope: ProjectScope; let environment: EnvironmentID?
        let root: String; let expected: String; let actual: String
        let details: [String: KnowledgeValue]; let requirements: [Requirement]
    }
}
