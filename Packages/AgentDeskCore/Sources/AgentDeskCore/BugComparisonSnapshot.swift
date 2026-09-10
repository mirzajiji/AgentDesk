import Foundation

/// A bounded authoritative inventory captured under the catalog lock. This contains private source
/// data; runtime consumers must authorize the read and redact before display, persistence or Codex.
public struct BugComparisonSnapshot: Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let records: [BugComparisonInput]
    public let fingerprint: ActionFingerprint
    init(scope: ProjectScope, environment: EnvironmentID, records: [BugComparisonInput]) throws {
        struct Binding: Encodable {
            let scope: ProjectScope; let environment: EnvironmentID; let records: [Entry]
        }
        struct Entry: Encodable {
            let record: BugRecord; let activeRequirements: [RequirementVersion]
        }
        let bytes = try JSONEncoder().encode(Binding(scope: scope, environment: environment,
            records: records.map { Entry(record: $0.record, activeRequirements: $0.activeRequirements) }))
        guard bytes.count <= 16_777_216 else { throw BugRegistryError.limitExceeded }
        self.scope = scope; self.environment = environment; self.records = records
        // Canonical encoding makes dictionary order irrelevant when validating later reads.
        fingerprint = try .canonical(Binding(scope: scope, environment: environment,
            records: records.map { Entry(record: $0.record, activeRequirements: $0.activeRequirements) }))
    }
}
