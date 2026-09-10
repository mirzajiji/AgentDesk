import Foundation

/// A bounded data predicate, never a script, SQL expression, shell command or model prompt.
public struct RequirementValidationRule: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable {
        case equals, notEquals, exists, absent, minimum, maximum, contains, type
    }
    public enum Component: Codable, Equatable, Sendable {
        case key(String)
        case index(Int)
    }
    public let schemaVersion: Int
    public let id: String
    public let path: [Component]
    public let operation: Operation
    public let expected: KnowledgeValue?

    public init(id: String, path: [Component], operation: Operation, expected: KnowledgeValue? = nil) {
        schemaVersion = 1; self.id = id; self.path = path; self.operation = operation; self.expected = expected
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, path, operation, expected }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        path = try values.decode([Component].self, forKey: .path)
        operation = try values.decode(Operation.self, forKey: .operation)
        // Presence and JSON null are different: equals-null needs a real null operand.
        expected = values.contains(.expected) ? try values.decode(KnowledgeValue.self, forKey: .expected) : nil
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1, RequirementID(rawValue: id) != nil, path.count <= 16 else {
            throw RequirementError.invalidDocument
        }
        for component in path {
            switch component {
            case .key(let key): try RequirementDraft.checkText(key, maximum: 256)
            case .index(let index): guard (0..<256).contains(index) else { throw RequirementError.invalidDocument }
            }
        }
        var nodes = 0; try expected?.validate(nodes: &nodes)
        switch operation {
        case .exists, .absent:
            guard expected == nil else { throw RequirementError.invalidDocument }
        case .minimum, .maximum:
            guard case .number = expected else { throw RequirementError.invalidDocument }
        case .type:
            guard case .text(let type) = expected,
                  ["null", "boolean", "number", "text", "array", "object"].contains(type) else { throw RequirementError.invalidDocument }
        case .equals, .notEquals, .contains:
            guard expected != nil else { throw RequirementError.invalidDocument }
        }
    }
}
