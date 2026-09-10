#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeTraceabilityModelTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, project: ProjectRecord
        let store: ProjectRequirementStore, bugs: ProjectBugStore
        let environment = EnvironmentID()
        let requirement = RequirementID(rawValue: "synthetic-rule")!
        let subject = TraceabilitySubject(kind: .automatedTest, id: RequirementID(rawValue: "synthetic-test")!)
        var services: NativeTraceabilityServices { .init(store: store, bugs: bugs, environments: [], environmentIssue: nil) }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            project = try await catalog.createProject(in: workspace.id, name: "Traceability")
            store = try await catalog.requirementStore(in: project.scope); bugs = try await catalog.bugStore(in: project.scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func publishRequirement(expected: Int? = nil, status: RequirementStatus = .active) async throws {
            let proposal = try await store.prepare(.init(description: "Synthetic version \((expected ?? 0) + 1)", changeReason: "Reviewed", status: status),
                id: requirement, expectedVersion: expected, in: project.scope)
            _ = try await store.publishReviewed(proposal, in: project.scope)
        }
        func publishTrace(expected: Int? = nil, archived: Bool = false) async throws -> RequirementTraceRecord {
            let proposal = try await store.prepareTrace(subject: subject, title: "Synthetic test link", environment: environment,
                requirements: [.init(id: requirement)], changeReason: "Reviewed link", archived: archived, expectedRevision: expected, in: project.scope)
            return try await store.publishReviewedTrace(proposal, in: project.scope)
        }
    }
    func testInspectorSeparatesCurrentBehaviorFromRecordedVersionsAndImpact() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement(); _ = try await f.publishTrace()
        try await f.publishRequirement(expected: 1)
        let model = ProjectTraceabilityModel(project: f.project, open: { f.services })
        await model.load(); XCTAssertEqual(model.records.count, 1)
        await model.select(f.subject)
        XCTAssertFalse(model.historical)
        XCTAssertEqual(model.references.first?.recorded.version, 1)
        XCTAssertEqual(model.references.first?.current?.version, 2)
        XCTAssertEqual(model.references.first?.status, .potentiallyStale)
        XCTAssertEqual(model.impact?.affectedCounts[.automatedTest], 1)
        model.historical = true
        XCTAssertEqual(model.selected?.requirements.first?.version, 1)
        try await f.publishRequirement(expected: 2, status: .retired)
        await model.select(f.subject)
        XCTAssertNil(model.references.first?.current); XCTAssertEqual(model.references.first?.recorded.version, 1)
        XCTAssertEqual(model.references.first?.status, .unavailable)
        XCTAssertEqual(model.impact?.links.first?.status, .unavailable)
    }
    func testImpactIncludesBugRegistryWithoutStandaloneTraceRecords() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement()
        let draft = BugDraft(title: "Synthetic linked bug", sources: [.init(scope: f.project.scope, origin: .humanStatement, label: "Fixture", capturedAt: Date())], changeReason: "Reviewed")
        let proposal = try await f.bugs.prepare(draft, requirements: [.init(requirement: .init(id: f.requirement))], in: f.project.scope)
        let bug = try await f.bugs.publishReviewed(proposal, in: f.project.scope)
        try await f.publishRequirement(expected: 1)
        let model = ProjectTraceabilityModel(project: f.project, open: { f.services })
        await model.load(); XCTAssertTrue(model.records.isEmpty)
        await model.loadImpact(f.requirement)
        XCTAssertEqual(model.impact?.links.count, 0)
        XCTAssertEqual(model.bugImpact?.links.first?.record.id, bug.id)
        XCTAssertEqual(model.bugImpact?.links.first?.status, .potentiallyStale)
        model.cancel(); XCTAssertNil(model.bugImpact)
    }

    func testFiltersArchiveAndForeignServiceFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement(); _ = try await f.publishTrace()
        let model = ProjectTraceabilityModel(project: f.project, open: { f.services })
        await model.load(); await model.select(f.subject)
        model.filter.kind = .documentation; await model.load(more: true)
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.selected)
        model.filter.kind = nil; await model.load()
        let archived = try await f.publishTrace(expected: 1, archived: true)
        await model.didPublish(archived); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.selectedSubject)
        model.filter.includeArchived = true; await model.load(); XCTAssertEqual(model.records.first?.revision, 2)
        model.cancel(); XCTAssertNil(model.services); XCTAssertNil(model.impact)
        let other = try await f.catalog.createProject(in: f.project.workspaceID, name: "Other")
        let foreignBugs = try await f.catalog.bugStore(in: other.scope)
        let foreign = ProjectTraceabilityModel(project: f.project, open: {
            .init(store: f.store, bugs: foreignBugs, environments: [], environmentIssue: nil)
        })
        await foreign.load(); XCTAssertNil(foreign.services); XCTAssertTrue(foreign.records.isEmpty); XCTAssertNotNil(foreign.error)
    }

    func testEditorUsesExactReviewAndRejectsChangedLatestRequirement() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement()
        let editor = TraceabilityEditorModel(services: f.services)
        editor.identifier = f.subject.id.rawValue; editor.title = "Reviewed test"; editor.reason = "Create links"
        editor.environment = f.environment; editor.links = [.init(requirement: f.requirement.rawValue)]
        await editor.prepare(); XCTAssertEqual(editor.proposal?.candidate.requirements.first?.version, 1)
        await editor.cancelReview()
        let empty = try await f.store.traces(in: f.project.scope); XCTAssertTrue(empty.isEmpty)
        await editor.prepare(); try await f.publishRequirement(expected: 1)
        let stale = await editor.publish(); XCTAssertNil(stale); XCTAssertNotNil(editor.error)
        await editor.prepare(); editor.title = "Unreviewed binding edit"
        let result = await editor.publish(), saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.title, "Reviewed test"); XCTAssertEqual(saved.requirements.first?.version, 2)
        XCTAssertFalse(saved.requirements.first?.historical ?? true)
    }

    func testEditorHistoricalSelectionAndSubjectValidation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement(); try await f.publishRequirement(expected: 1)
        let editor = TraceabilityEditorModel(services: f.services)
        editor.identifier = "historical-case"; editor.title = "Historical reproduction"; editor.reason = "Explicit reproduction"
        editor.environment = f.environment
        editor.links = [.init(requirement: f.requirement.rawValue, historical: true, version: "1")]
        await editor.prepare(); let result = await editor.publish(), saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.requirements.first?.version, 1); XCTAssertTrue(saved.requirements.first?.historical == true)
        let edit = TraceabilityEditorModel(services: f.services, existing: saved)
        edit.identifier = "different-subject"; edit.reason = "Invalid identity change"
        await edit.prepare(); XCTAssertNil(edit.proposal); XCTAssertNotNil(edit.error)
        let bug = TraceabilityEditorModel(services: f.services)
        bug.kind = .bug; bug.identifier = BugID().rawValue; bug.title = "Missing bug"; bug.reason = "Invalid reference"
        bug.environment = f.environment; bug.links = [.init(requirement: f.requirement.rawValue)]
        await bug.prepare(); XCTAssertNil(bug.proposal); XCTAssertNotNil(bug.error)
    }

    func testEditorMasksReviewTextAndDoesNotExposeForeignExistingRecord() async throws {
        let f = try await Fixture(); defer { f.remove() }
        try await f.publishRequirement(); let record = try await f.publishTrace()
        let other = try await f.catalog.createProject(in: f.project.workspaceID, name: "Other")
        let otherStore = try await f.catalog.requirementStore(in: other.scope), otherBugs = try await f.catalog.bugStore(in: other.scope)
        let foreign = TraceabilityEditorModel(services: .init(store: otherStore, bugs: otherBugs, environments: [], environmentIssue: nil), existing: record)
        XCTAssertNil(foreign.existing); XCTAssertTrue(foreign.title.isEmpty); XCTAssertTrue(foreign.identifier.isEmpty)
        await foreign.prepare(); XCTAssertNil(foreign.proposal); XCTAssertNotNil(foreign.error)
        let editor = TraceabilityEditorModel(services: f.services)
        editor.identifier = "sanitized-test"; editor.title = "Authorization: Bearer synthetic-trace-secret-123"
        editor.reason = "Reviewed"; editor.environment = f.environment; editor.links = [.init(requirement: f.requirement.rawValue)]
        await editor.prepare(); XCTAssertNotNil(editor.proposal); XCTAssertTrue(editor.redacted)
        XCTAssertFalse(editor.proposal?.candidate.title.contains("synthetic-trace-secret-123") == true)
    }
}
#endif
