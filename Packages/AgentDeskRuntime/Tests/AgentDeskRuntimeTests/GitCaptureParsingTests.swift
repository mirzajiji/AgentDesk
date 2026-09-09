import Foundation
import XCTest
@testable import AgentDeskRuntime

final class GitCaptureParsingTests: XCTestCase {
    private let objectHash = String(repeating: "a", count: 40)
    private var headers: String { "# branch.oid \(objectHash)\0# branch.head codex/synthetic\0" }
    func testPorcelainPreservesWhitespaceRenamePathsAndAllChangeKinds() throws {
        let ordinary = "1 .M N... 100644 100644 100644 \(objectHash) \(objectHash) leading space\tand\nnewline.txt\0"
        let renamed = "2 R. N... 100644 100644 100644 \(objectHash) \(objectHash) R100 new name.txt\0old name.txt\0"
        let conflicted = "u UU N... 100644 100644 100644 100644 \(objectHash) \(objectHash) \(objectHash) conflict.txt\0"
        let status = try GitStatusParser.parse(Data((headers + ordinary + renamed + conflicted + "? -untracked.txt\0").utf8))
        XCTAssertEqual(status.head, objectHash); XCTAssertEqual(status.branch, "codex/synthetic"); XCTAssertEqual(status.entries.count, 4)
        XCTAssertTrue(status.entries.contains { $0.path == "leading space\tand\nnewline.txt" && $0.status == ".M" })
        XCTAssertTrue(status.entries.contains { $0.path == "new name.txt" && $0.originalPath == "old name.txt" && $0.kind == .renamed })
        XCTAssertTrue(status.entries.contains { $0.kind == .unmerged }); XCTAssertEqual(status.entries.first?.path, "-untracked.txt")
        let initial = try GitStatusParser.parse(Data("# branch.oid (initial)\0# branch.head main\0".utf8)); XCTAssertNil(initial.head)
    }
    func testMalformedAmbiguousAndForeignPathsFailClosed() throws {
        for tail in ["? ../foreign\0", "? /absolute\0", "? a//b\0", "? a/./b\0", "? a/.GIT/config\0",
                     "? same\0? same\0", "? missing terminator", "garbage\0",
                     "1junk .M N... 100644 100644 100644 \(objectHash) \(objectHash) name\0",
                     "2 R. N... 100644 100644 100644 \(objectHash) \(objectHash) R101 new\0old\0",
                     "2 R. N... 100644 100644 100644 \(objectHash) \(objectHash) R100 new\0",
                     "1 .M N... 100999 100644 100644 \(objectHash) \(objectHash) name\0"] {
            XCTAssertThrowsError(try GitStatusParser.parse(Data((headers + tail).utf8)))
        }
        XCTAssertThrowsError(try GitStatusParser.parse(Data([0xff, 0])))
        XCTAssertThrowsError(try GitStatusParser.parse(Data((headers + "# branch.head duplicate\0").utf8)))
        let many = (0...128).map { "? file\($0)\0" }.joined()
        XCTAssertThrowsError(try GitStatusParser.parse(Data((headers + many).utf8)))
    }
    func testConfigDisablesEveryDeclaredFilterAndRejectsExternalConfigAndHiddenIndexFiles() throws {
        let config = Data("core.repositoryformatversion\n0\0filter.Synthetic.clean\nunsafe command\0filter.Synthetic.process\nunsafe process\0core.fsmonitor\nunsafe monitor\0".utf8)
        let arguments = try GitCaptureConfiguration.overrides(configuration: config)
        for value in ["filter.Synthetic.clean=", "filter.Synthetic.smudge=", "filter.Synthetic.process=", "filter.Synthetic.required=false",
                      "core.fsmonitor=false", "core.hooksPath=/dev/null", "core.attributesFile=/dev/null"] { XCTAssertTrue(arguments.contains(value)) }
        XCTAssertFalse(arguments.contains { $0.contains("unsafe") })
        for config in ["include.path\n/foreign/config\0", "includeif.gitdir:../foreign.path\n/foreign/config\0",
                       "extensions.worktreeconfig\ntrue\0", "core.repositoryformatversion\n1\0", "remote.origin.promisor\ntrue\0"] {
            XCTAssertThrowsError(try GitCaptureConfiguration.overrides(configuration: Data(config.utf8)))
        }
        try GitCaptureConfiguration.validateIndexFlags(Data("H plain.txt\0H with\nnewline\0".utf8))
        for value in ["h hidden.txt\0", "S hidden.txt\0", "H ../foreign\0"] {
            XCTAssertThrowsError(try GitCaptureConfiguration.validateIndexFlags(Data(value.utf8)))
        }
    }
    func testUnifiedPreviewHandlesContextInsertionDeletionAndMissingFinalNewline() throws {
        let changed = try RepositoryTextDiff.render(before: "one\nold\nthree\n", after: "one\nnew\nthree\n", oldLabel: "old", newLabel: "new")
        XCTAssertEqual(changed, "--- old\n+++ new\n@@ -1,3 +1,3 @@\n one\n-old\n+new\n three\n")
        let added = try RepositoryTextDiff.render(before: "", after: "new", oldLabel: "old", newLabel: "new")
        XCTAssertEqual(added, "--- old\n+++ new\n@@ -0,0 +1,1 @@\n+new\n\\ No newline at end of file\n")
        let removed = try RepositoryTextDiff.render(before: "old\n", after: "", oldLabel: "old", newLabel: "new")
        XCTAssertTrue(removed.contains("@@ -1,1 +0,0 @@\n-old\n"))
        XCTAssertEqual(try RepositoryTextDiff.render(before: "same", after: "same", oldLabel: "old", newLabel: "new"), "")
        XCTAssertThrowsError(try RepositoryTextDiff.render(before: "", after: String(repeating: "line\n", count: 1_025), oldLabel: "old", newLabel: "new"))
    }
    @MainActor
    func testCancelledDiffDoesNotReturnEvenForIdenticalContent() async throws {
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try RepositoryTextDiff.render(before: "same", after: "same", oldLabel: "old", newLabel: "new") }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
