import Foundation

public struct RequirementChange: Equatable, Sendable, Identifiable {
    public let field: String
    public let before: String?
    public let after: String
    public var id: String { field }
}

extension RequirementDraft {
    /// Deterministic field-level review of every persisted content field; no generated summary.
    public func changes(from previous: RequirementDraft?) throws -> [RequirementChange] {
        try validate(); try previous?.validate()
        let current = try reviewFields(), old = try previous?.reviewFields()
        return current.enumerated().compactMap { index, field in
            let prior = old?[index].1
            guard prior != field.1 else { return nil }
            return RequirementChange(field: field.0, before: prior, after: field.1)
        }
    }
    private func reviewFields() throws -> [(String, String)] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func lines(_ values: [String]) throws -> String { String(decoding: try encoder.encode(values), as: UTF8.self) }
        return [
            ("Status", status.rawValue), ("Description", description),
            ("Preconditions", try lines(preconditions)), ("Rules", try lines(rules)),
            ("Acceptance criteria", try lines(acceptanceCriteria)), ("Validation descriptions", try lines(validationRules)),
            ("Executable validation rules", String(decoding: try encoder.encode(executableValidationRules ?? []), as: UTF8.self)),
            ("Expected behavior", String(decoding: try encoder.encode(expectedBehavior), as: UTF8.self)),
            ("Environment scope", environmentScope.isEmpty ? "All project environments" : environmentScope.map(\.rawValue).joined(separator: "\n")),
            ("References", try lines(references)), ("Change reason", changeReason)
        ]
    }
}
