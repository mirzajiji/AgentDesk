#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class GitRepositoryCaptureTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context = RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("GitCapture-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: file(name)) }
        @discardableResult
        func git(_ arguments: [String]) async throws -> Data {
            let options = ["-c", "user.name=AgentDesk Synthetic Tests", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null"]
            let result = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(), arguments: options + arguments, directory: root,
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                              "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(10), maximumBytes: 262_144)
            if result.status != 0 {
                let diagnostic = try ContentRedactor(context: context).redactText(String(decoding: result.stderr, as: UTF8.self), in: context)
                XCTFail("Synthetic Git fixture failed: \(diagnostic.text)")
                throw RepositoryCaptureError.commandFailed
            }
            return result.stdout
        }
        func initialize(commit: Bool = true) async throws {
            try await git(["init", "-b", "main"])
            if commit {
                try write("base.txt", "one\noriginal\nthree\n")
                try write("delete.txt", "delete contents\n")
                try write("rename.txt", "rename contents\n")
                try await git(["add", "--all"])
                try await git(["commit", "--no-gpg-sign", "-m", "Synthetic baseline"])
            }
        }
        func capture(redactor: ContentRedactor? = nil) throws -> GitRepositoryCapture {
            try GitRepositoryCapture(root: root, context: context, redactor: redactor ?? ContentRedactor(context: context))
        }
    }
    private func summaries(_ evidence: RepositoryEvidence) throws -> [[String: Any]] {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(evidence.snapshot.text.utf8)) as? [String: Any])
        return try XCTUnwrap(value["files"] as? [[String: Any]])
    }

    func testDirtyBaselineAddModifyDeleteRenameAndUntrackedFilesArePreservedAndCompared() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        try fixture.write("base.txt", "one\npreexisting line\nthree\n")
        try fixture.write("preexisting.tmp", "preexisting untracked\n")
        let beforeStatus = try await fixture.git(["status", "--porcelain=v2", "-z"])
        let beforeIndex = try Data(contentsOf: fixture.file(".git/index")), capture = try fixture.capture()
        let baseline = try await capture.captureBaseline()
        XCTAssertTrue(try summaries(baseline).allSatisfy { $0["comparison"] as? String == "baseline" && $0["preexistingDirty"] as? Bool == true })
        let unchangedStatus = try await fixture.git(["status", "--porcelain=v2", "-z"])
        XCTAssertEqual(unchangedStatus, beforeStatus); XCTAssertEqual(try Data(contentsOf: fixture.file(".git/index")), beforeIndex)
        try fixture.write("base.txt", "one\nrun line\nthree\n")
        try FileManager.default.removeItem(at: fixture.file("delete.txt"))
        try await fixture.git(["mv", "rename.txt", "new name\tand\nline.txt"])
        try fixture.write("added.txt", "added contents\n"); try await fixture.git(["add", "added.txt"])
        let result = try await capture.captureChanges(), files = try summaries(result)
        XCTAssertEqual(files.first { $0["path"] as? String == "base.txt" }?["comparison"] as? String, "changedSinceBaseline")
        XCTAssertEqual(files.first { $0["path"] as? String == "preexisting.tmp" }?["comparison"] as? String, "unchangedPreexisting")
        XCTAssertTrue(files.contains { $0["kind"] as? String == "renamed" && $0["originalPath"] as? String == "rename.txt" })
        XCTAssertTrue(result.diff.text.contains("-preexisting line\n+run line"))
        XCTAssertTrue(result.diff.text.contains("-delete contents")); XCTAssertTrue(result.diff.text.contains("+added contents"))
        XCTAssertEqual(try String(contentsOf: fixture.file("preexisting.tmp"), encoding: .utf8), "preexisting untracked\n")
    }
    func testUnbornRepositoryAndStagedVersusWorkingContentHaveDistinctPreviews() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize(commit: false)
        try fixture.write("new.txt", "staged version\n"); try await fixture.git(["add", "new.txt"])
        try fixture.write("new.txt", "working version\n")
        let result = try await fixture.capture().captureBaseline()
        XCTAssertTrue(result.diff.text.contains("HEAD to index")); XCTAssertTrue(result.diff.text.contains("+staged version"))
        XCTAssertTrue(result.diff.text.contains("Index to working tree")); XCTAssertTrue(result.diff.text.contains("-staged version\n+working version"))
        XCTAssertEqual(try summaries(result).first?["status"] as? String, "AM")
    }
    func testConfiguredSecretsInPathsAndMultilineContentsAreRedactedBeforeDiffRendering() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        let secret = "synthetic-line-one\nsynthetic-line-two", nameSecret = "synthetic-private-filename"
        let references = [SecretReference(scope: try SecretScope(workspaceID: fixture.context.scope.workspaceID)),
                          SecretReference(scope: try SecretScope(workspaceID: fixture.context.scope.workspaceID))]
        let values = [references[0]: try SecretValue(Data(secret.utf8)), references[1]: try SecretValue(Data(nameSecret.utf8))]
        let redactor = try await ContentRedactor.load(context: fixture.context, references: references) { values[$0] }
        try fixture.write(nameSecret + ".txt", "public before\n" + secret + "\npublic after\n")
        let result = try await fixture.capture(redactor: redactor).captureBaseline()
        for text in [result.snapshot.text, result.diff.text, String(decoding: try JSONEncoder().encode(result.diff), as: UTF8.self)] {
            XCTAssertFalse(text.contains(nameSecret)); XCTAssertFalse(text.contains("synthetic-line-one")); XCTAssertFalse(text.contains("synthetic-line-two"))
        }
        XCTAssertTrue(result.diff.text.contains("public before")); XCTAssertTrue(result.diff.text.contains("public after"))
        XCTAssertEqual(result.diff.classification, .confidential)
    }
    func testExternalFiltersDiffDriversAndFsmonitorDoNotRun() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        try fixture.write(".gitattributes", "*.txt filter=synthetic diff=synthetic\n")
        try await fixture.git(["add", ".gitattributes"]); try await fixture.git(["commit", "--no-gpg-sign", "-m", "Synthetic attributes"])
        let marker = fixture.file("SHOULD_NOT_EXECUTE")
        let command = "touch '" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        for key in ["filter.synthetic.clean", "filter.synthetic.smudge", "filter.synthetic.process", "diff.synthetic.command", "diff.synthetic.textconv", "core.fsmonitor"] {
            try await fixture.git(["config", key, command])
        }
        try await fixture.git(["config", "filter.synthetic.required", "true"])
        try fixture.write("base.txt", "changed without conversion\n")
        let result = try await fixture.capture().captureBaseline()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertTrue(result.diff.text.contains("+changed without conversion"))
    }
    func testUnsupportedIncludesAlternatesHiddenIndexAndMetadataLinksFailClosed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        try await fixture.git(["config", "include.path", fixture.file("synthetic-outside-config").path])
        do { _ = try await fixture.capture().captureBaseline(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .unsupportedRepository) }
        try await fixture.git(["config", "--unset", "include.path"])
        try fixture.write(".git/objects/info/alternates", fixture.root.path)
        do { _ = try await fixture.capture().captureBaseline(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .unsupportedRepository) }
        try FileManager.default.removeItem(at: fixture.file(".git/objects/info/alternates"))
        try await fixture.git(["update-index", "--assume-unchanged", "base.txt"])
        do { _ = try await fixture.capture().captureBaseline(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .unsupportedRepository) }
        try await fixture.git(["update-index", "--no-assume-unchanged", "base.txt"])
        try FileManager.default.createSymbolicLink(at: fixture.file(".git/unsafe-link"), withDestinationURL: fixture.root)
        do { _ = try await fixture.capture().captureBaseline(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .unsafeFile) }
    }
    func testBinaryLargeAndSymlinkFilesHaveExplicitLimitsWithoutFollowingTargets() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let foreign = try Fixture(); defer { foreign.cleanup() }
        try await fixture.initialize(); try foreign.write("private.txt", "foreign data must never be read")
        try Data([0, 1, 2, 255]).write(to: fixture.file("binary.bin"))
        try fixture.write("large.txt", String(repeating: "x", count: 65_537))
        try FileManager.default.createSymbolicLink(at: fixture.file("link"), withDestinationURL: foreign.file("private.txt"))
        let capture = try fixture.capture(), result = try await capture.captureBaseline(), files = try summaries(result)
        XCTAssertEqual(Set(files.compactMap { $0["workingTreeKind"] as? String }), ["binary", "tooLarge", "symlink"])
        XCTAssertTrue(result.diff.text.contains("preview unavailable")); XCTAssertFalse(result.diff.text.contains("foreign data"))
        let again = try await capture.captureChanges()
        XCTAssertEqual(try summaries(again).first { $0["path"] as? String == "large.txt" }?["comparison"] as? String, "indeterminate")
        try FileManager.default.linkItem(at: foreign.file("private.txt"), to: fixture.file("hardlink"))
        do { _ = try await capture.captureChanges(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .unsafeFile) }
    }
    func testChangedBranchReplacedRootMissingBaselineAndCancellationAreExplicit() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        let capture = try fixture.capture()
        do { _ = try await capture.captureChanges(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .missingBaseline) }
        _ = try await capture.captureBaseline(); try await fixture.git(["checkout", "-b", "synthetic-other"])
        do { _ = try await capture.captureChanges(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .changedBaseline) }
        let cancelledCapture = try fixture.capture()
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await cancelledCapture.captureBaseline() }
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let moved = fixture.root.appendingPathExtension("moved"); defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        do { _ = try await capture.captureChanges(); XCTFail() } catch { XCTAssertEqual(error as? RepositoryCaptureError, .changedDuringCapture) }
    }
    func testRestoredTrackedAndRemovedUntrackedFilesKeepBaselineEvidence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try await fixture.initialize()
        try fixture.write("base.txt", "preexisting edit\n"); try fixture.write("preexisting.tmp", "temporary baseline contents\n")
        let capture = try fixture.capture(); _ = try await capture.captureBaseline()
        try fixture.write("base.txt", "one\noriginal\nthree\n"); try FileManager.default.removeItem(at: fixture.file("preexisting.tmp"))
        let result = try await capture.captureChanges(), files = try summaries(result)
        XCTAssertEqual(files.count, 2); XCTAssertTrue(files.allSatisfy { $0["comparison"] as? String == "noLongerInStatus" })
        XCTAssertTrue(result.diff.text.contains("-preexisting edit")); XCTAssertTrue(result.diff.text.contains("-temporary baseline contents"))
        XCTAssertTrue(result.diff.text.contains("+original"))
    }
    func testCapturedEvidencePublishesAndReopensThroughTheScopedStore() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let storage = try Fixture(); defer { storage.cleanup() }
        try await fixture.initialize(); try fixture.write("base.txt", "password=synthetic-git-password\npublic line\n")
        let evidence = try await fixture.capture().captureBaseline(), database = storage.file("operations.sqlite"), agent = AgentID()
        let operational = try OperationalStore(database: database, workspaceID: fixture.context.scope.workspaceID)
        _ = try await operational.createRun(in: fixture.context.scope, id: fixture.context.runID, at: Date(timeIntervalSince1970: 10))
        let store = try EvidenceStore(database: database, context: fixture.context, agentID: agent)
        let redactor = try ContentRedactor(context: fixture.context)
        _ = try await store.register(snapshot: redactor.redactJSON("{}", in: fixture.context), agentRevision: 1,
                                     configurationFingerprint: ActionFingerprint(bytes: Data("synthetic configuration".utf8)))
        let snapshot = try await store.publishArtifact(evidence.snapshot, kind: .repositorySnapshot, source: .repository, basis: .observed, format: .json)
        let diff = try await store.publishArtifact(evidence.diff, kind: .diff, source: .repository, basis: .observed, format: .diff)
        let reopened = try EvidenceStore(database: database, context: fixture.context, agentID: agent)
        let savedSnapshot = try await reopened.artifact(snapshot.id), savedDiff = try await reopened.artifact(diff.id)
        XCTAssertEqual(savedSnapshot?.text, evidence.snapshot.text); XCTAssertEqual(savedDiff?.text, evidence.diff.text)
        XCTAssertFalse(savedDiff?.text.contains("synthetic-git-password") ?? true); XCTAssertEqual(savedDiff?.classification, .confidential)
        let report = try await reopened.recover(); XCTAssertTrue(report.unavailable.isEmpty); XCTAssertTrue(report.orphanIDs.isEmpty)
    }
}
#endif
