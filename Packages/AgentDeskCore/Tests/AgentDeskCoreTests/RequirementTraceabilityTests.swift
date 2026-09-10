import Foundation
import Synchronization
import XCTest
@testable import AgentDeskCore

@MainActor
final class RequirementTraceabilityTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, store: ProjectRequirementStore, scope: ProjectScope
        let environment = EnvironmentID()
        let id = RequirementID(rawValue: "synthetic-requirement")!
        var subject: TraceabilitySubject { .init(kind: .automatedTest, id: RequirementID(rawValue: "synthetic-test")!) }
        var projectRoot: URL { root.appendingPathComponent("\(scope.workspaceID)/Projects/\(scope.projectID)") }
        var tracePath: URL { projectRoot.appendingPathComponent("Memory/Traceability/automatedTest/synthetic-test.json") }
        init(clock: (@Sendable () -> Date)? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic traceability")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            scope = project.scope
            if let clock {
                let descriptor = try ConfigurationDirectory(trustedContainer: root)
                let owner = try descriptor.child(workspace.id.rawValue)
                store = ProjectRequirementStore(scope: scope, root: descriptor, workspace: owner,
                    project: try owner.child("Projects").child(project.id.rawValue), clock: clock)
            } else { store = try await catalog.requirementStore(in: scope) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func requirement(_ status: RequirementStatus = .active, expected: Int? = nil, environments: [EnvironmentID] = []) async throws -> RequirementVersion {
            let proposal = try await store.prepare(RequirementDraft(description: "Synthetic behavior", changeReason: "Reviewed version",
                status: status, environmentScope: environments), id: id, expectedVersion: expected, in: scope)
            return try await store.publishReviewed(proposal, in: scope)
        }
        func prepare(subject: TraceabilitySubject? = nil, expected: Int? = nil, historical: Int? = nil, archived: Bool = false) async throws -> TraceabilityProposal {
            try await store.prepareTrace(subject: subject ?? self.subject, title: "Synthetic linked record", environment: environment,
                requirements: [.init(id: id, historicalVersion: historical)], changeReason: "Reviewed link", archived: archived,
                expectedRevision: expected, in: scope)
        }
        func publish(subject: TraceabilitySubject? = nil, expected: Int? = nil, historical: Int? = nil, archived: Bool = false) async throws -> RequirementTraceRecord {
            let proposal = try await prepare(subject: subject, expected: expected, historical: historical, archived: archived)
            return try await store.publishReviewedTrace(proposal, in: scope)
        }
    }

    func testReviewCancellationAndReopeningPreserveExactCreationReference() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let version = try await f.requirement()
        let cancelled = try await f.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.tracePath.path))
        await f.store.cancelTrace(cancelled)
        do { _ = try await f.store.publishReviewedTrace(cancelled, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        let record = try await f.publish()
        XCTAssertEqual(record.requirements.first?.fingerprint, try version.fingerprint)
        let reopened = try await f.catalog.requirementStore(in: f.scope)
        let loaded = try await reopened.trace(f.subject, in: f.scope)
        XCTAssertEqual(loaded, record)
        XCTAssertTrue(String(decoding: try Data(contentsOf: f.tracePath), as: UTF8.self).contains("synthetic-test"))
    }

    func testNativeBrowsePagesByIdentityAndFiltersCurrentAuthoritativeLinks() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement()
        let first = try await f.publish()
        let document = TraceabilitySubject(kind: .documentation, id: RequirementID(rawValue: "api-guide")!)
        let proposal = try await f.store.prepareTrace(subject: document, title: "Café API guide", environment: f.environment,
            requirements: [.init(id: f.id)], changeReason: "Reviewed guide", in: f.scope)
        _ = try await f.store.publishReviewedTrace(proposal, in: f.scope)
        let page = try await f.store.traces(in: f.scope, limit: 1)
        XCTAssertEqual(page.map(\.subject), [first.subject])
        let next = try await f.store.traces(in: f.scope, after: first.subject, limit: 1)
        XCTAssertEqual(next.map(\.subject), [document])
        let accent = try await f.store.traces(in: f.scope, query: "CAFE")
        XCTAssertEqual(accent.map(\.subject), [document])
        let byRequirement = try await f.store.traces(in: f.scope, query: f.id.rawValue)
        XCTAssertEqual(byRequirement.count, 2)
        let foreignEnvironment = try await f.store.traces(in: f.scope, environment: EnvironmentID()); XCTAssertTrue(foreignEnvironment.isEmpty)
        _ = try await f.publish(expected: 1, archived: true)
        let active = try await f.store.traces(in: f.scope); XCTAssertEqual(active.map(\.subject), [document])
        let archived = try await f.store.traces(in: f.scope, kinds: [.automatedTest], includeArchived: true)
        XCTAssertEqual(archived.first?.revision, 2)
        do { _ = try await f.store.traces(in: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID())); XCTFail() } catch { }
        do { _ = try await f.store.traces(in: f.scope, query: String(repeating: "x", count: 1_025)); XCTFail() } catch { }
    }

    func testNativeBrowseDoesNotTreatTamperedLinksAsAnEmptyGraph() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement(); _ = try await f.publish()
        try Data("{}".utf8).write(to: f.tracePath)
        do { _ = try await f.store.traces(in: f.scope); XCTFail("Corrupt metadata must remain distinguishable from an empty graph") } catch { }
    }

    func testStaleLinksKeepProvenanceWhileNormalRerunsUseLatestActive() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement(); let initial = try await f.publish()
        _ = try await f.requirement(.draft, expected: 1)
        let draftImpact = try await f.store.impact(of: f.id, in: f.scope)
        XCTAssertEqual(draftImpact.links.map(\.status), [.current]); XCTAssertTrue(draftImpact.affectedCounts.isEmpty)
        _ = try await f.requirement(.active, expected: 2)
        let impact = try await f.store.impact(of: f.id, in: f.scope)
        XCTAssertEqual(impact.links.map(\.status), [.potentiallyStale]); XCTAssertEqual(impact.affectedCounts[.automatedTest], 1)
        XCTAssertEqual(impact.links.first?.linked.version, 1); XCTAssertEqual(impact.links.first?.activeVersion, 3)
        let normal = try await f.store.resolveTrace(f.subject, in: f.scope)
        let historical = try await f.store.resolveTrace(f.subject, in: f.scope, reproduceLinkedVersions: true)
        XCTAssertEqual(normal.map(\.version), [3]); XCTAssertEqual(historical.map(\.version), [1])
        let unchanged = try await f.store.trace(f.subject, in: f.scope); XCTAssertEqual(unchanged, initial)
    }

    func testImpactCountsCoverAllSubjectKindsAndArchiveIsReviewed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement()
        for kind in TraceabilitySubject.Kind.allCases { _ = try await f.publish(subject: .init(kind: kind, id: f.subject.id)) }
        _ = try await f.requirement(.active, expected: 1)
        let impact = try await f.store.impact(of: f.id, in: f.scope)
        for kind in TraceabilitySubject.Kind.allCases { XCTAssertEqual(impact.affectedCounts[kind], 1) }
        _ = try await f.publish(expected: 1, historical: 1, archived: true)
        let archived = try await f.store.impact(of: f.id, in: f.scope)
        XCTAssertNil(archived.affectedCounts[.automatedTest]); XCTAssertEqual(archived.links.count, 4)
        do { _ = try await f.store.resolveTrace(f.subject, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementValidationError, .requirementUnavailable) }
    }

    func testChangedRequirementAndConcurrentEditorsRejectStaleReview() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement(); let stale = try await f.prepare()
        _ = try await f.requirement(.active, expected: 1)
        do { _ = try await f.store.publishReviewedTrace(stale, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .staleVersion) }
        let first = try await f.prepare(), second = try await f.prepare()
        _ = try await f.store.publishReviewedTrace(first, in: f.scope)
        do { _ = try await f.store.publishReviewedTrace(second, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .staleVersion) }
        do { _ = try await f.store.publishReviewedTrace(first, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
    }

    func testScopeEnvironmentRetirementAndHistoricalSelectionAreEnforced() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        _ = try await f.requirement(); let proposal = try await f.prepare()
        do { _ = try await other.store.publishReviewedTrace(proposal, in: other.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        _ = try await f.store.publishReviewedTrace(proposal, in: f.scope)
        do { _ = try await f.store.impact(of: f.id, in: other.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
        _ = try await f.requirement(.retired, expected: 1)
        let retired = try await f.store.impact(of: f.id, in: f.scope); XCTAssertEqual(retired.links.first?.status, .unavailable)
        do { _ = try await f.store.resolveTrace(f.subject, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementValidationError, .requirementUnavailable) }
        let historical = try await f.store.resolveTrace(f.subject, in: f.scope, reproduceLinkedVersions: true)
        XCTAssertEqual(historical.map(\.version), [1])
        _ = try await f.requirement(.active, expected: 2, environments: [EnvironmentID()])
        do { _ = try await f.prepare(expected: 1); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementValidationError, .requirementUnavailable) }
    }

    func testExpiredReviewMalformedRequestsAndCancellationWriteNothing() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 1_000))
        let f = try await Fixture(clock: { now.withLock { $0 } }); defer { f.remove() }
        _ = try await f.requirement(); let proposal = try await f.prepare()
        now.withLock { $0 = Date(timeIntervalSince1970: 1_301) }
        do { _ = try await f.store.publishReviewedTrace(proposal, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        for requests: [RequirementLinkRequest] in [[], [.init(id: f.id), .init(id: f.id)]] {
            do { _ = try await f.store.prepareTrace(subject: f.subject, title: "Synthetic", environment: f.environment,
                requirements: requests, changeReason: "Reviewed", in: f.scope); XCTFail() }
            catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        }
        let task = Task { try Task.checkCancellation(); return try await f.prepare() }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.tracePath.path))
    }

    func testTamperedLinkFingerprintAndForeignScopeFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement(); _ = try await f.publish()
        let original = try Data(contentsOf: f.tracePath)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var links = try XCTUnwrap(json["requirements"] as? [[String: Any]])
        links[0]["fingerprint"] = String(repeating: "0", count: 64); json["requirements"] = links
        try JSONSerialization.data(withJSONObject: json).write(to: f.tracePath)
        do { _ = try await f.store.impact(of: f.id, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        do { _ = try await f.store.resolveTrace(f.subject, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["scope"] = ["workspaceID": WorkspaceID().rawValue, "projectID": f.scope.projectID.rawValue]
        try JSONSerialization.data(withJSONObject: json).write(to: f.tracePath)
        do { _ = try await f.store.trace(f.subject, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
    }

    func testSymlinkAndHardLinkTraceFilesAreRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.requirement(); _ = try await f.publish()
        let outside = f.root.appendingPathComponent("synthetic-external.json")
        try FileManager.default.copyItem(at: f.tracePath, to: outside)
        try FileManager.default.removeItem(at: f.tracePath)
        try FileManager.default.createSymbolicLink(at: f.tracePath, withDestinationURL: outside)
        do { _ = try await f.store.trace(f.subject, in: f.scope); XCTFail() } catch { XCTAssertTrue(error is ScopedFileError) }
        try FileManager.default.removeItem(at: f.tracePath)
        try FileManager.default.linkItem(at: outside, to: f.tracePath)
        do { _ = try await f.store.trace(f.subject, in: f.scope); XCTFail() } catch { XCTAssertTrue(error is ScopedFileError) }
    }
}
