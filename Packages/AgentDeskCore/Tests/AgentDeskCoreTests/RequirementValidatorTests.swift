import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class RequirementValidatorTests: XCTestCase {
    private struct Fixture {
        let root: URL, store: ProjectRequirementStore, scope: ProjectScope
        let environment = EnvironmentID()
        let id = RequirementID(rawValue: "synthetic-validation")!
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic validation")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            scope = project.scope; store = try await catalog.requirementStore(in: project.scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func publish(_ rules: [RequirementValidationRule]?, status: RequirementStatus = .active, expected: Int? = nil,
                     environments: [EnvironmentID] = []) async throws -> RequirementVersion {
            let draft = RequirementDraft(description: "Synthetic predicates", changeReason: "Reviewed validation", status: status,
                environmentScope: environments, executableValidationRules: rules)
            let proposal = try await store.prepare(draft, id: id, expectedVersion: expected, in: scope)
            return try await store.publishReviewed(proposal, in: scope)
        }
        func observation(_ value: KnowledgeValue?) -> RequirementObservation {
            RequirementObservation(scope: scope, environment: environment, run: RunID(), agent: AgentID(),
                source: "Synthetic response fixture", capturedAt: Date(timeIntervalSince1970: 1_000), value: value)
        }
        func evaluate(_ value: KnowledgeValue?, historical: Int? = nil) async throws -> RequirementValidationReport {
            try await RequirementValidator(store: store).evaluate(id, observation: observation(value), historicalVersion: historical)
        }
    }
    private func rule(_ id: String, _ operation: RequirementValidationRule.Operation, _ expected: KnowledgeValue? = nil,
                      path: [RequirementValidationRule.Component] = []) -> RequirementValidationRule {
        RequirementValidationRule(id: id, path: path, operation: operation, expected: expected)
    }

    func testPredicatesPreserveExactNumbersNestedValuesAndProvenance() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let exact = KnowledgeValue.number(Decimal(string: "9007199254740993")!)
        let rules = [rule("equal", .equals, exact, path: [.key("id")]),
            rule("minimum", .minimum, exact, path: [.key("id")]), rule("maximum", .maximum, exact, path: [.key("id")]),
            rule("different", .notEquals, .null, path: [.key("id")]), rule("kind", .type, .text("number"), path: [.key("id")]),
            rule("array", .contains, .null, path: [.key("values")]), rule("text", .contains, .text("hello"), path: [.key("text")]),
            rule("exists", .exists, path: [.key("values"), .index(0)]), rule("absent", .absent, path: [.key("unknown")])]
        let version = try await f.publish(rules)
        let observation = f.observation(.object(["id": exact, "values": .array([.null]), "text": .text("hello world")]))
        let result = try await RequirementValidator(store: f.store).evaluate(f.id, observation: observation)
        XCTAssertEqual(result.outcome, .passed); XCTAssertEqual(result.results.count, 9)
        XCTAssertEqual(result.results[0].observed, exact); XCTAssertEqual(result.observation, observation)
        XCTAssertEqual(result.fingerprint, try version.fingerprint); XCTAssertEqual(result.version, 1); XCTAssertFalse(result.historical)
    }

    func testMissingNullAndBlockedEvidenceNeverCollapseIntoOneResult() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish([rule("exists", .exists, path: [.key("value")]),
            rule("null", .equals, .null, path: [.key("value")])])
        let null = try await f.evaluate(.object(["value": .null])); XCTAssertEqual(null.outcome, .passed)
        let missing = try await f.evaluate(.object([:])); XCTAssertEqual(missing.results.map(\.outcome), [.failed, .unavailable])
        XCTAssertEqual(missing.outcome, .unavailable)
        let blocked = try await f.evaluate(nil); XCTAssertEqual(blocked.results.map(\.outcome), [.unavailable, .unavailable])
        let wrongPathType = try await f.evaluate(.array([])); XCTAssertEqual(wrongPathType.outcome, .unavailable)
    }

    func testFailedPredicatesAndIncompatibleComparisonsAreExplicit() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish([rule("equal", .equals, .number(3)), rule("minimum", .minimum, .number(3)),
            rule("maximum", .maximum, .number(1)), rule("absent", .absent), rule("type", .type, .text("text"))])
        let failed = try await f.evaluate(.number(2)); XCTAssertEqual(failed.outcome, .failed)
        XCTAssertTrue(failed.results.allSatisfy { $0.outcome == .failed })
        let incompatible = try await f.evaluate(.text("2")); XCTAssertEqual(incompatible.results[1].outcome, .unavailable)
    }

    func testLatestActiveHistoricalAndRetirementUseExactStoredVersions() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish([rule("state", .equals, .text("first"))])
        _ = try await f.publish([rule("state", .equals, .text("draft"))], status: .draft, expected: 1)
        let active = try await f.evaluate(.text("first")); XCTAssertEqual(active.version, 1); XCTAssertEqual(active.outcome, .passed)
        let historical = try await f.evaluate(.text("draft"), historical: 2)
        XCTAssertTrue(historical.historical); XCTAssertEqual(historical.version, 2); XCTAssertEqual(historical.outcome, .passed)
        _ = try await f.publish([], status: .retired, expected: 2)
        do { _ = try await f.evaluate(.null); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementValidationError, .requirementUnavailable) }
        let original = try await f.evaluate(.text("first"), historical: 1); XCTAssertEqual(original.outcome, .passed)
    }

    func testScopeEnvironmentCancellationAndAbsentRulesFailExplicitly() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        _ = try await f.publish(nil)
        let noRules = try await f.evaluate(.null); XCTAssertEqual(noRules.outcome, .unavailable); XCTAssertTrue(noRules.results.isEmpty)
        do { _ = try await RequirementValidator(store: f.store).evaluate(f.id, observation: other.observation(.null)); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
        _ = try await f.publish([], expected: 1, environments: [EnvironmentID()])
        do { _ = try await f.evaluate(.null); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementValidationError, .requirementUnavailable) }
        let task = Task { try Task.checkCancellation(); return try await f.evaluate(.null) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMalformedRulesCannotBePublishedAndUnknownOperationsCannotDecode() async throws {
        let f = try await Fixture(); defer { f.remove() }
        for invalid in [rule("number", .minimum, .text("3")), rule("extra", .exists, .null),
                        rule("missing", .equals), rule("type", .type, .text("script")),
                        rule("index", .exists, path: [.index(-1)]), rule("../escape", .exists)] {
            do { _ = try await f.publish([invalid]); XCTFail() } catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        }
        do { _ = try await f.publish([rule("duplicate", .exists), rule("duplicate", .absent)]); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        let encoded = try JSONEncoder().encode(rule("safe", .exists))
        let unsupported = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "exists", with: "execute-script")
        XCTAssertThrowsError(try JSONDecoder().decode(RequirementValidationRule.self, from: Data(unsupported.utf8)))
        let all = try await f.store.list(in: f.scope); XCTAssertTrue(all.isEmpty)
    }

    func testInvalidObservationAndUnsupportedValueComparisonsAreNotSuccess() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish([rule("contains", .contains, .text("x"))])
        let result = try await f.evaluate(.boolean(true))
        XCTAssertEqual(result.outcome, .unavailable)
        for invalid in [
            RequirementObservation(scope: f.scope, environment: f.environment, source: "", capturedAt: Date(), value: .null),
            RequirementObservation(scope: f.scope, environment: f.environment, source: "Synthetic", capturedAt: Date(timeIntervalSince1970: -1), value: .null),
            RequirementObservation(scope: f.scope, environment: f.environment, agent: AgentID(), source: "Synthetic", capturedAt: Date(), value: .null)
        ] {
            do { _ = try await RequirementValidator(store: f.store).evaluate(f.id, observation: invalid); XCTFail() }
            catch { XCTAssertTrue(error is RequirementError || error is RequirementValidationError) }
        }
    }

    func testLegacyContentEncodingIsUnchangedAndTypedRulesParticipateInReview() throws {
        let legacy = #"{"acceptanceCriteria":[],"changeReason":"Original","description":"Legacy","environmentScope":[],"expectedBehavior":{},"preconditions":[],"references":[],"rules":[],"status":"active","validationRules":[]}"#
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var draft = try JSONDecoder().decode(RequirementDraft.self, from: Data(legacy.utf8))
        XCTAssertNil(draft.executableValidationRules)
        XCTAssertEqual(String(decoding: try encoder.encode(draft), as: UTF8.self), legacy)
        let old = draft
        draft.executableValidationRules = [rule("null", .equals, .null)]
        XCTAssertEqual(try draft.changes(from: old).map(\.field), ["Executable validation rules"])
        let restored = try JSONDecoder().decode(RequirementDraft.self, from: encoder.encode(draft))
        XCTAssertEqual(restored, draft); try restored.validate()
    }
}
