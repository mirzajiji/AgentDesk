#if os(macOS)
import AgentDeskCore
import Foundation

struct AgentKnowledgeEditing {
    var enabled = false
    var include = ""
    var exclude = ""
    var query = ""
    var requirements = true
    var confirmed = true
    var notes = false
    var inbox = false
    var maximumRecords = 12
    var maximumBytes = 24_576
    var relationships = ""

    init(_ selection: AgentKnowledgeSelection? = nil) {
        guard let selection else { return }
        enabled = true; include = selection.paths.include.joined(separator: "\n")
        exclude = selection.paths.exclude.joined(separator: "\n"); query = selection.query
        requirements = selection.kinds.contains(.requirement); confirmed = selection.kinds.contains(.confirmed)
        notes = selection.kinds.contains(.note); inbox = selection.kinds.contains(.inbox)
        maximumRecords = selection.maximumRecords; maximumBytes = selection.maximumBytes
        relationships = selection.relationships.map { "\($0.kind.rawValue)/\($0.id)" }.joined(separator: "\n")
    }
    func selection() throws -> AgentKnowledgeSelection? {
        guard enabled else { return nil }
        func lines(_ text: String) -> [String] {
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let subjects = try lines(relationships).map { line -> TraceabilitySubject in
            let parts = line.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let kind = TraceabilitySubject.Kind(rawValue: String(parts[0])),
                  let id = RequirementID(rawValue: String(parts[1])) else { throw AgentConfigurationError.invalidConfiguration }
            return TraceabilitySubject(kind: kind, id: id)
        }
        let choices: [(Bool, KnowledgeRecordKind)] = [(requirements, .requirement), (confirmed, .confirmed), (notes, .note), (inbox, .inbox)]
        return try AgentKnowledgeSelection(paths: .init(include: lines(include), exclude: lines(exclude)), query: query,
            kinds: choices.filter(\.0).map(\.1), maximumRecords: maximumRecords, maximumBytes: maximumBytes, relationships: subjects)
    }
}
#endif
