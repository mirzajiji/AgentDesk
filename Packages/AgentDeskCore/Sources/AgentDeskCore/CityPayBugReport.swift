import Foundation

public enum CityPayReportError: Error, Equatable, Sendable { case missingContext, unverifiedFinding, unavailableRequirements, invalidContent, duplicateReviewRequired }

/// Explicit local input: region/component are never inferred from currency, URLs or project names.
public struct CityPayReportContext: Equatable, Sendable {
    public enum Component: String, Sendable { case backend = "Backend", frontend = "Frontend" }
    public enum Region: String, Sendable { case uz = "UZ", geo = "GEO", tr = "TR" }
    public let component: Component
    public let region: Region
    public let area: String
    public let module: String
    public init(component: Component?, region: Region?, area: String, module: String) throws {
        guard let component, let region else { throw CityPayReportError.missingContext }
        for value in [area, module] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 128,
                  !value.contains("\n"), !value.contains("\r"), !value.contains("|") else { throw CityPayReportError.invalidContent }
        }
        self.component = component; self.region = region; self.area = area; self.module = module
    }
}

/// Structured draft content, not authority to create a ticket. Runtime callers must perform duplicate
/// review, verify evidence and redact these source-derived values before releasing the draft.
public struct CityPayBugReport: Encodable, Equatable, Sendable {
    public struct Source: Encodable, Equatable, Sendable { public let id: BugID; public let revision: Int }
    public struct Section: Encodable, Equatable, Sendable {
        public enum Name: String, Encodable, Sendable {
            case environment = "Environment", preconditions = "Preconditions", description = "Description"
            case steps = "Reproduce Steps", actual = "Actual Result", expected = "Expected Result"
            case endpoint = "Endpoint", payload = "Payload", response = "Response", additional = "Additional Information"
        }
        public let name: Name
        public let text: String
    }
    public let title: String
    public let sections: [Section]
    public let sourceID: BugID
    public let sourceRevision: Int
    public let groupedSources: [Source]

    public static func prepare(_ input: BugComparisonInput, context: CityPayReportContext,
                               sanitizeJSON: (String) throws -> String = { $0 }) throws -> CityPayBugReport {
        guard BugComparison.readiness(input) == nil else { throw CityPayReportError.unverifiedFinding }
        guard !input.activeRequirements.isEmpty else { throw CityPayReportError.unavailableRequirements }
        // Sanitize structured fields before flattening them into prose, preserving secret field names
        // for the runtime's central redactor. The default is for trusted local Core consumers only.
        let bug = try JSONDecoder().decode(BugDraft.self, from: Data(sanitizeJSON(json(input.record.content)).utf8))
        try bug.validate(in: input.record.scope, id: input.record.id)
        guard !bug.title.contains("\n"), !bug.title.contains("\r"), bug.title.utf8.count <= 256 else { throw CityPayReportError.invalidContent }
        var sections: [Section] = []
        func add(_ name: Section.Name, _ text: String?) {
            if let text, !text.isEmpty { sections.append(.init(name: name, text: text)) }
        }
        func value(_ key: String) throws -> String? {
            guard let value = bug.details[key] else { return nil }
            if case .text(let text) = value { return text }
            return try json(value)
        }
        add(.environment, context.region.rawValue)
        add(.preconditions, try value("preconditions"))
        add(.description, bug.rootBehavior)
        add(.steps, bug.reproduction.isEmpty ? "Reproduction actions were not supplied." : bug.reproduction.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        var actual = [bug.actualBehavior]
        for key in ["httpStatus", "applicationError", "stateBefore", "stateAfter", "persistedState"] {
            if let text = try value(key) { actual.append("\(key): \(text)") }
        }
        if bug.details["persistedState"] == nil { actual.append("Persistence was not supplied as observed evidence.") }
        add(.actual, actual.joined(separator: "\n"))
        let expected = try input.activeRequirements.sorted { $0.id.rawValue < $1.id.rawValue }.map { requirement in
            let content = try JSONDecoder().decode(RequirementDraft.self, from: Data(sanitizeJSON(json(requirement.content)).utf8))
            try content.validate()
            var lines = ["\(requirement.id) v\(requirement.version): \(content.description)"]
            lines += content.rules + content.acceptanceCriteria
            if !content.expectedBehavior.isEmpty { lines.append(try json(KnowledgeValue.object(content.expectedBehavior))) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        add(.expected, expected)
        add(.endpoint, try value("endpoint")); add(.payload, try value("payload")); add(.response, try value("response"))
        // Retain supplied status, concurrency, identifiers and other observations without synthesizing them.
        let represented = Set(["preconditions", "httpStatus", "applicationError", "stateBefore", "stateAfter", "persistedState", "endpoint", "payload", "response"])
        var additional = try bug.details.keys.filter { !represented.contains($0) }.sorted().map { "\($0): \(try value($0) ?? "")" }
        additional.append("Source: \(input.record.id), revision \(input.record.revision)")
        additional += bug.evidence.map { "Evidence: \($0.artifact), run \($0.run), agent \($0.agent)" }
        add(.additional, additional.joined(separator: "\n"))
        return .init(title: "[\(context.component.rawValue) - \(context.region.rawValue)] \(context.area) - \(context.module) | \(bug.title)",
            sections: sections, sourceID: input.record.id, sourceRevision: input.record.revision, groupedSources: [])
    }
    /// Groups supplied observations only when root, expected behavior, current requirements and
    /// structured comparison anchors agree. Individual payloads/results remain labeled by source.
    public static func prepareGroup(_ inputs: [BugComparisonInput], context: CityPayReportContext, problem: String,
                                    sanitizeJSON: (String) throws -> String = { $0 }) throws -> CityPayBugReport {
        guard (2...16).contains(inputs.count), Set(inputs.map { $0.record.id }).count == inputs.count,
              let first = inputs.first, !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              problem.utf8.count <= 256, !problem.contains("\n"), !problem.contains("\r") else { throw CityPayReportError.invalidContent }
        let anchors = ["endpoint", "module", "component", "validationField", "region"]
        guard anchors.dropLast().contains(where: { key in
            if case .text(let value) = first.record.content.details[key] { return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }) else { throw CityPayReportError.invalidContent }
        let requirements = first.activeRequirements.sorted { $0.id.rawValue < $1.id.rawValue }
        for input in inputs {
            guard input.record.scope == first.record.scope, input.record.content.environment == first.record.content.environment else {
                throw BugRegistryError.scopeMismatch
            }
            guard input.record.content.rootBehavior == first.record.content.rootBehavior,
                  input.record.content.expectedBehavior == first.record.content.expectedBehavior,
                  input.activeRequirements.sorted(by: { $0.id.rawValue < $1.id.rawValue }) == requirements,
                  anchors.allSatisfy({ input.record.content.details[$0] == first.record.content.details[$0] }) else {
                throw CityPayReportError.invalidContent
            }
        }
        let reports = try inputs.map { try prepare($0, context: context, sanitizeJSON: sanitizeJSON) }
        let order: [Section.Name] = [.environment, .preconditions, .description, .steps, .actual, .expected, .endpoint, .payload, .response, .additional]
        let sections = order.compactMap { name -> Section? in
            let values = reports.compactMap { report -> (BugID, String)? in
                guard let section = report.sections.first(where: { $0.name == name }) else { return nil }
                return (report.sourceID, section.text)
            }
            guard let initial = values.first else { return nil }
            if [.environment, .description, .expected, .endpoint].contains(name), values.allSatisfy({ $0.1 == initial.1 }) {
                return .init(name: name, text: initial.1)
            }
            return .init(name: name, text: values.map { "Finding \($0.0)\n\($0.1)" }.joined(separator: "\n\n"))
        }
        return .init(title: "[\(context.component.rawValue) - \(context.region.rawValue)] \(context.area) - \(context.module) | \(problem)",
            sections: sections, sourceID: first.record.id, sourceRevision: first.record.revision,
            groupedSources: inputs.map { .init(id: $0.record.id, revision: $0.record.revision) })
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
