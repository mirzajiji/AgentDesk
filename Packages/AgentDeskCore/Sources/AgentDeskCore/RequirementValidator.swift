import Foundation

public struct RequirementObservation: Equatable, Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let run: RunID?
    public let agent: AgentID?
    public let source: String
    public let capturedAt: Date
    /// Nil means evidence is unavailable; `.null` is an observed JSON null.
    public let value: KnowledgeValue?
    public init(scope: ProjectScope, environment: EnvironmentID, run: RunID? = nil, agent: AgentID? = nil,
                source: String, capturedAt: Date, value: KnowledgeValue?) {
        self.scope = scope; self.environment = environment; self.run = run; self.agent = agent
        self.source = source; self.capturedAt = capturedAt; self.value = value
    }
}

public enum RequirementValidationOutcome: String, Codable, Sendable { case passed, failed, unavailable }

public struct RequirementRuleResult: Equatable, Sendable {
    public let rule: RequirementValidationRule
    public let outcome: RequirementValidationOutcome
    public let observed: KnowledgeValue?
    public let reason: String
}

/// In-memory observed evidence and deterministic interpretation. Callers must redact before persistence/display.
public struct RequirementValidationReport: Equatable, Sendable {
    public let observation: RequirementObservation
    public let requirement: RequirementID
    public let version: Int
    public let fingerprint: ActionFingerprint
    public let historical: Bool
    public let results: [RequirementRuleResult]
    public var outcome: RequirementValidationOutcome {
        // Incomplete evidence cannot support a fully verified result.
        if results.isEmpty || results.contains(where: { $0.outcome == .unavailable }) { return .unavailable }
        return results.contains(where: { $0.outcome == .failed }) ? .failed : .passed
    }
}

public enum RequirementValidationError: Error, Equatable, Sendable {
    case requirementUnavailable, invalidObservation
}

public struct RequirementValidator: Sendable {
    private let store: ProjectRequirementStore
    public init(store: ProjectRequirementStore) { self.store = store }

    /// Normal validation resolves latest active. Historical reproduction must name a version explicitly.
    public func evaluate(_ id: RequirementID, observation: RequirementObservation,
                         historicalVersion: Int? = nil) async throws -> RequirementValidationReport {
        try Task.checkCancellation()
        guard observation.scope == store.scope else { throw RequirementError.scopeMismatch }
        try RequirementDraft.checkText(observation.source, maximum: 1_024)
        guard observation.capturedAt.timeIntervalSince1970.isFinite,
              observation.capturedAt.timeIntervalSince1970 >= 0,
              observation.agent == nil || observation.run != nil else { throw RequirementValidationError.invalidObservation }
        var nodes = 0; try observation.value?.validate(nodes: &nodes)
        let selection: RequirementSelection = historicalVersion.map { .historical(version: $0) } ?? .latestActive
        guard let requirement = try await store.resolve(id, selection: selection, in: observation.scope,
                                                       environment: observation.environment) else {
            throw RequirementValidationError.requirementUnavailable
        }
        try Task.checkCancellation()
        var results: [RequirementRuleResult] = []
        for rule in requirement.content.executableValidationRules ?? [] {
            try Task.checkCancellation(); try rule.validate()
            results.append(Self.evaluate(rule, root: observation.value))
        }
        return RequirementValidationReport(observation: observation, requirement: id, version: requirement.version,
            fingerprint: try requirement.fingerprint, historical: historicalVersion != nil, results: results)
    }

    private enum Lookup { case found(KnowledgeValue), missing, incompatible, unavailable }
    private static func lookup(_ path: [RequirementValidationRule.Component], in root: KnowledgeValue?) -> Lookup {
        guard var value = root else { return .unavailable }
        for component in path {
            switch (component, value) {
            case (.key(let key), .object(let object)):
                guard let next = object[key] else { return .missing }; value = next
            case (.index(let index), .array(let array)):
                guard array.indices.contains(index) else { return .missing }; value = array[index]
            default: return .incompatible
            }
        }
        return .found(value)
    }
    private static func evaluate(_ rule: RequirementValidationRule, root: KnowledgeValue?) -> RequirementRuleResult {
        let lookup = lookup(rule.path, in: root)
        func result(_ outcome: RequirementValidationOutcome, _ observed: KnowledgeValue?, _ reason: String) -> RequirementRuleResult {
            RequirementRuleResult(rule: rule, outcome: outcome, observed: observed, reason: reason)
        }
        switch lookup {
        case .unavailable: return result(.unavailable, nil, "Observation unavailable")
        case .incompatible: return result(.unavailable, nil, "Path cannot be traversed through the observed value type")
        case .missing:
            if rule.operation == .absent { return result(.passed, nil, "Path is absent") }
            if rule.operation == .exists { return result(.failed, nil, "Required path is absent") }
            return result(.unavailable, nil, "Expected comparison value is absent")
        case .found(let observed):
            let passed: Bool
            switch rule.operation {
            case .exists: passed = true
            case .absent: passed = false
            case .equals: passed = observed == rule.expected
            case .notEquals: passed = observed != rule.expected
            case .minimum, .maximum:
                guard case .number(let number) = observed, case .number(let limit) = rule.expected else {
                    return result(.unavailable, observed, "Numeric comparison requires an observed number")
                }
                passed = rule.operation == .minimum ? number >= limit : number <= limit
            case .contains:
                switch (observed, rule.expected) {
                case (.array(let values), .some(let expected)): passed = values.contains(expected)
                case (.text(let value), .text(let expected)): passed = value.contains(expected)
                default: return result(.unavailable, observed, "Contains requires an array, or text with a text operand")
                }
            case .type:
                let type: String
                switch observed {
                case .null: type = "null"
                case .boolean: type = "boolean"
                case .number: type = "number"
                case .text: type = "text"
                case .array: type = "array"
                case .object: type = "object"
                }
                passed = rule.expected == .text(type)
            }
            return result(passed ? .passed : .failed, observed, passed ? "Predicate satisfied" : "Predicate not satisfied")
        }
    }
}
