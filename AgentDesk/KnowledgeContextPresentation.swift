#if os(macOS)
import AgentDeskCore
import Foundation

/// Display formatting only. Approval and dispatch continue using the original sanitized packet.
enum KnowledgeContextPresentation {
    static func text(_ snapshot: String) throws -> String {
        guard snapshot.utf8.count <= 32_768 else { throw CocoaError(.coderReadCorrupt) }
        let packet = try JSONDecoder().decode(Packet.self, from: Data(snapshot.utf8))
        guard packet.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        var sections = ["\(packet.entries.count) selected source\(packet.entries.count == 1 ? "" : "s")"]
        if packet.omittedByLimit { sections.append("Some matching sources were omitted because of the context limit.") }
        for entry in packet.entries {
            let body = try JSONDecoder().decode(KnowledgeValue.self, from: Data(entry.bodyJSON.utf8))
            sections.append("\(entry.kind.capitalized) · version \(entry.revision)\n\(entry.path)\nSource: \(entry.sourceID)\n\n\(render(body))\n\nSanitized fingerprint: \(entry.sanitizedFingerprint)")
        }
        for issue in packet.issues { sections.append("Unavailable selection\n\(issue.sourceID): \(issue.reason.replacingOccurrences(of: "-", with: " "))") }
        for relationship in packet.relationships {
            sections.append("Relationship\n\(relationship.subject.kind.rawValue)/\(relationship.subject.id) · \(relationship.status)\nRequirements: \(relationship.requirementIDs.map(\.rawValue).joined(separator: ", "))")
        }
        sections.append("Workspace: \(packet.scope.workspaceID)\nProject: \(packet.scope.projectID)\nEnvironment: \(packet.environment)")
        return sections.joined(separator: "\n\n──────────\n\n")
    }
    private static func render(_ value: KnowledgeValue, depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        switch value {
        case .null: return indent + "Null"
        case .boolean(let flag): return indent + (flag ? "Yes" : "No")
        case .number(let number): return indent + NSDecimalNumber(decimal: number).stringValue
        case .text(let text): return text.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
        case .array(let items):
            return items.isEmpty ? indent + "None" : items.map { render($0, depth: depth + 1) }.joined(separator: "\n")
        case .object(let fields):
            return fields.isEmpty ? indent + "None" : fields.keys.sorted().map { key in
                let label = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
                return indent + label + ":\n" + render(fields[key]!, depth: depth + 1)
            }.joined(separator: "\n\n")
        }
    }
    private struct Packet: Decodable {
        let schemaVersion: Int; let scope: ProjectScope; let environment: EnvironmentID
        let entries: [Entry]; let issues: [Issue]; let relationships: [Relationship]; let omittedByLimit: Bool
    }
    private struct Entry: Decodable {
        let sourceID: String; let path: String; let kind: String; let revision: Int
        let bodyJSON: String; let sanitizedFingerprint: String
    }
    private struct Issue: Decodable { let sourceID: String; let reason: String }
    private struct Relationship: Decodable {
        let subject: TraceabilitySubject; let status: String; let requirementIDs: [RequirementID]
    }
}
#endif
