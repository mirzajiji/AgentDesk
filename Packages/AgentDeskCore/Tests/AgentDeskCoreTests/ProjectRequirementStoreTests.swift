import Foundation
import Synchronization
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectRequirementStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, project: ProjectRecord, store: ProjectRequirementStore
        let id = RequirementID(rawValue: "synthetic-review-to-closed")!
        var projectRoot: URL { root.appendingPathComponent("\(project.workspaceID)/Projects/\(project.id)") }
        var directory: URL { projectRoot.appendingPathComponent("Memory/Requirements/\(id)") }
        init(clock: (@Sendable () -> Date)? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic requirements")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic product")
            if let clock {
                let descriptor = try ConfigurationDirectory(trustedContainer: root)
                let owner = try descriptor.child(workspace.id.rawValue)
                store = ProjectRequirementStore(scope: project.scope, root: descriptor, workspace: owner,
                    project: try owner.child("Projects").child(project.id.rawValue), clock: clock)
            } else { store = try await catalog.requirementStore(in: project.scope) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func draft(_ status: RequirementStatus = .active) -> RequirementDraft {
            RequirementDraft(description: "A reviewed synthetic item may close.", changeReason: "Confirm synthetic behavior", status: status,
                preconditions: ["Review is complete"], rules: ["Closed items remain closed"], acceptanceCriteria: ["State becomes closed"],
                validationRules: ["Verify the returned state"], expectedBehavior: ["state": .text("closed"), "identifier": .number(Decimal(string: "9007199254740993")!)],
                references: ["Synthetic specification"])
        }
        func publish(_ draft: RequirementDraft? = nil, expected: Int? = nil) async throws -> RequirementVersion {
            let proposal = try await store.prepare(draft ?? self.draft(), id: id, expectedVersion: expected, in: project.scope)
            return try await store.publishReviewed(proposal, in: project.scope)
        }
    }

    func testPreparationAndCancellationDoNotCreateAuthoritativeFiles() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let empty = try await f.store.resolve(f.id, in: f.project.scope); XCTAssertNil(empty)
        let proposal = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.projectRoot.appendingPathComponent("Memory").path))
        await f.store.cancel(proposal)
        do { _ = try await f.store.publishReviewed(proposal, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testImmutableVersionsReadableJSONAndExplicitHistorySurviveReopen() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.publish(), path = f.directory.appendingPathComponent("requirement.v1.json")
        let original = try Data(contentsOf: path)
        var draft = f.draft(); draft.description = "Updated synthetic behavior"; draft.changeReason = "Reviewed change"
        let second = try await f.publish(draft, expected: 1)
        XCTAssertEqual(second.version, 2); XCTAssertEqual(second.supersedes, 1)
        XCTAssertEqual(second.previousFingerprint, try first.fingerprint)
        XCTAssertEqual(try Data(contentsOf: path), original)
        let reopened = try await f.catalog.requirementStore(in: f.project.scope)
        let active = try await reopened.resolve(f.id, in: f.project.scope)
        let history = try await reopened.resolve(f.id, selection: .historical(version: 1), in: f.project.scope)
        XCTAssertEqual(active, second); XCTAssertEqual(history, first)
        let text = String(decoding: original, as: UTF8.self)
        XCTAssertTrue(text.contains("9007199254740993")); XCTAssertTrue(text.contains("\"createdAt\""))
        let pointer = try JSONSerialization.jsonObject(with: Data(contentsOf: f.directory.appendingPathComponent("current.json"))) as! [String: Any]
        XCTAssertEqual(pointer["currentFile"] as? String, "requirement.v2.json")
        XCTAssertEqual(pointer["activeVersion"] as? Int, 2)
    }

    func testDraftsDoNotReplaceActiveAndRetirementPreventsResurrection() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish()
        _ = try await f.publish(f.draft(.draft), expected: 1)
        let active = try await f.store.resolve(f.id, in: f.project.scope)
        let newest = try await f.store.resolve(f.id, selection: .latestPublished, in: f.project.scope)
        XCTAssertEqual(active?.version, 1); XCTAssertEqual(newest?.version, 2)
        _ = try await f.publish(f.draft(.retired), expected: 2)
        _ = try await f.publish(f.draft(.draft), expected: 3)
        let retired = try await f.store.resolve(f.id, in: f.project.scope); XCTAssertNil(retired)
        let historical = try await f.store.resolve(f.id, selection: .historical(version: 1), in: f.project.scope)
        XCTAssertEqual(historical?.version, 1)
        var next = f.draft(); let environment = EnvironmentID(); next.environmentScope = [environment]
        _ = try await f.publish(next, expected: 4)
        let matched = try await f.store.resolve(f.id, in: f.project.scope, environment: environment)
        let excluded = try await f.store.resolve(f.id, in: f.project.scope, environment: EnvironmentID())
        XCTAssertEqual(matched?.version, 5); XCTAssertNil(excluded)
    }

    func testReviewIsBoundToPayloadStoreAndBaseVersionAndCannotReplay() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        let other = try await f.catalog.requirementStore(in: f.project.scope)
        do { _ = try await other.publishReviewed(first, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        let altered = RequirementProposal(token: first.token, candidate: first.candidate, expiresAt: first.expiresAt.addingTimeInterval(1))
        do { _ = try await f.store.publishReviewed(altered, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        var changed = f.draft(); changed.description = "Unreviewed content substitution"
        let candidate = RequirementVersion(schemaVersion: 1, scope: f.project.scope, id: f.id, version: 1,
            supersedes: nil, previousFingerprint: nil, createdAt: first.candidate.createdAt, content: changed)
        let substituted = RequirementProposal(token: first.token, candidate: candidate, expiresAt: first.expiresAt)
        do { _ = try await f.store.publishReviewed(substituted, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        let competing = try await other.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        _ = try await f.store.publishReviewed(first, in: f.project.scope)
        do { _ = try await f.store.publishReviewed(first, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        do { _ = try await other.publishReviewed(competing, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .staleVersion) }
        let history = try await f.store.history(f.id, in: f.project.scope); XCTAssertEqual(history.count, 1)
    }

    func testExpiredAndRegressedClockReviewsNeverPublish() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let f = try await Fixture(clock: { now.withLock { $0 } }); defer { f.remove() }
        let review = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        now.withLock { $0 = $0.addingTimeInterval(300) }
        do { _ = try await f.store.publishReviewed(review, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        _ = try await f.publish()
        now.withLock { $0 = $0.addingTimeInterval(-1) }
        do { _ = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: 1, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
    }

    func testConcurrentStorePublicationsHaveOneWinner() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let other = try await f.catalog.requirementStore(in: f.project.scope)
        let first = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        let second = try await other.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope)
        let one = Task { () -> Bool in
            do { _ = try await f.store.publishReviewed(first, in: f.project.scope); return true }
            catch { return false }
        }
        let two = Task { () -> Bool in
            do { _ = try await other.publishReviewed(second, in: f.project.scope); return true }
            catch { return false }
        }
        let results = await [one.value, two.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let history = try await f.store.history(f.id, in: f.project.scope)
        XCTAssertEqual(history.map(\.version), [1])
    }

    func testOrphanVersionIsPreservedAndNeverSilentlyAdopted() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish()
        let proposal = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: 1, in: f.project.scope)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let orphan = try encoder.encode(proposal.candidate), path = f.directory.appendingPathComponent("requirement.v2.json")
        try orphan.write(to: path) // Simulates version publication followed by an interrupted pointer update.
        await f.store.cancel(proposal)
        let historical = try await f.store.resolve(f.id, selection: .historical(version: 2), in: f.project.scope)
        XCTAssertNil(historical)
        let next = try await f.publish(expected: 1)
        XCTAssertEqual(next.version, 3); XCTAssertEqual(next.supersedes, 1)
        XCTAssertEqual(try Data(contentsOf: path), orphan)
    }

    func testForeignWorkspaceProjectAndChangedOwnershipFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let other = try await f.catalog.createWorkspace(name: "Other synthetic workspace")
        let foreign = try await f.catalog.createProject(in: other.id, name: "Other product")
        for scope in [foreign.scope, ProjectScope(workspaceID: f.project.workspaceID, projectID: ProjectID())] {
            do { _ = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: scope); XCTFail() }
            catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
        }
        _ = try await f.publish()
        let record = f.projectRoot.appendingPathComponent("project.json")
        let encoder = JSONEncoder(); try encoder.encode(foreign).write(to: record)
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
    }

    func testPointerTraversalAndChangedHistoricalContentAreRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish(); _ = try await f.publish(expected: 1)
        let pointer = f.directory.appendingPathComponent("current.json"), original = try Data(contentsOf: pointer)
        var value = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        value["currentFile"] = "../requirement.v2.json"
        try JSONSerialization.data(withJSONObject: value).write(to: pointer)
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        try original.write(to: pointer)
        let first = f.directory.appendingPathComponent("requirement.v1.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as! [String: Any]
        var content = document["content"] as! [String: Any]; content["description"] = "Unreviewed replacement"; document["content"] = content
        try JSONSerialization.data(withJSONObject: document).write(to: first)
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
    }

    func testSymlinkAndHardLinkStorageAreRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let outside = f.root.appendingPathComponent("SyntheticOutside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let memory = f.projectRoot.appendingPathComponent("Memory")
        try FileManager.default.createSymbolicLink(at: memory, withDestinationURL: outside)
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        try FileManager.default.removeItem(at: memory); _ = try await f.publish()
        let file = f.directory.appendingPathComponent("current.json")
        try FileManager.default.linkItem(at: file, to: outside.appendingPathComponent("linked.json"))
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
    }

    func testCancelledPreparationAndInvalidContentLeaveNoFiles() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let task = Task { try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        var draft = f.draft(); draft.description = ""
        do { _ = try await f.store.prepare(draft, id: f.id, expectedVersion: nil, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
        for invalid in ["../escape", "/absolute", "Upper", "two words", "-start", "end-", "a/b", ""] { XCTAssertNil(RequirementID(rawValue: invalid)) }
    }

    func testListingIsPagedScopedAndIncludesNonactiveHeads() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let empty = try await f.store.list(in: f.project.scope); XCTAssertTrue(empty.isEmpty)
        for name in ["c-item", "a-item", "b-item"] {
            let id = RequirementID(rawValue: name)!
            let proposal = try await f.store.prepare(f.draft(.draft), id: id, expectedVersion: nil, in: f.project.scope)
            _ = try await f.store.publishReviewed(proposal, in: f.project.scope)
        }
        let first = try await f.store.list(in: f.project.scope, limit: 2)
        XCTAssertEqual(first.map(\.id.rawValue), ["a-item", "b-item"])
        let second = try await f.store.list(in: f.project.scope, after: first.last!.id, limit: 2)
        XCTAssertEqual(second.map(\.id.rawValue), ["c-item"])
        do { _ = try await f.store.list(in: ProjectScope(workspaceID: WorkspaceID(), projectID: f.project.id)); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
    }

    func testMalformedPointerDuplicateKeysAndMissingVersionsFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish()
        let path = f.directory.appendingPathComponent("current.json"), original = try Data(contentsOf: path)
        let duplicate = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
        XCTAssertNotEqual(Data(duplicate.utf8), original); try Data(duplicate.utf8).write(to: path)
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        try original.write(to: path)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("requirement.v1.json"))
        do { _ = try await f.store.resolve(f.id, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ScopedFileError, .notFound) }
    }

    func testContentAndPendingReviewLimitsAreEnforcedBeforePublication() async throws {
        let f = try await Fixture(); defer { f.remove() }
        var oversized = f.draft(); oversized.rules = Array(repeating: String(repeating: "x", count: 8_192), count: 128)
        do { _ = try await f.store.prepare(oversized, id: f.id, expectedVersion: nil, in: f.project.scope); XCTFail() } catch {}
        var nested = KnowledgeValue.null
        for _ in 0..<20 { nested = .array([nested]) }
        var deep = f.draft(); deep.expectedBehavior = ["nested": nested]
        XCTAssertThrowsError(try deep.validate())
        for _ in 0..<16 { _ = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope) }
        do { _ = try await f.store.prepare(f.draft(), id: f.id, expectedVersion: nil, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .limitExceeded) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }
}
