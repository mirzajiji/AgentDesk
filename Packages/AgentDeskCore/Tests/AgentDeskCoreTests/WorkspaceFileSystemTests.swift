import Darwin
import Foundation
import XCTest
@testable import AgentDeskCore

final class WorkspaceFileSystemTests: XCTestCase {
    private struct Fixture {
        let container: URL
        let first = WorkspaceID()
        let second = WorkspaceID()
        var firstRoot: URL { container.appendingPathComponent(first.rawValue) }
        var secondRoot: URL { container.appendingPathComponent(second.rawValue) }

        init() throws {
            container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: container) }
        func path(_ name: String) throws -> WorkspacePath {
            try WorkspacePath(workspaceID: first, relativePath: name)
        }
    }

    @MainActor
    func testReadsNestedFileAndEmptyFileWithinScope() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let folder = fixture.firstRoot.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let content = Data("Synthetic project instructions".utf8)
        try content.write(to: folder.appendingPathComponent("instructions.md"))
        try Data().write(to: fixture.firstRoot.appendingPathComponent("empty.md"))
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        let actual = try await storage.read(fixture.path("Projects/instructions.md"))
        XCTAssertEqual(actual, content)
        let empty = try await storage.read(fixture.path("empty.md"), maximumBytes: 0)
        XCTAssertTrue(empty.isEmpty)
    }

    @MainActor
    func testReadsMultipleChunksAtExactLimit() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let content = Data((0..<40_000).map { UInt8($0 % 251) })
        try content.write(to: fixture.firstRoot.appendingPathComponent("chunks.bin"))
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        let actual = try await storage.read(fixture.path("chunks.bin"), maximumBytes: content.count)
        XCTAssertEqual(actual, content)
    }

    @MainActor
    func testInvalidLimitAndDirectoryReadsAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.firstRoot.appendingPathComponent("folder"),
                                                withIntermediateDirectories: false)
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        for limit in [-1, 67_108_865] {
            do {
                _ = try await storage.read(fixture.path("missing"), maximumBytes: limit)
                XCTFail("Accepted invalid read limit")
            } catch { XCTAssertEqual(error as? ScopedFileError, .sizeLimit) }
        }
        do {
            _ = try await storage.read(fixture.path("folder"))
            XCTFail("Read a directory as a file")
        } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
    }

    @MainActor
    func testRejectsReferenceFromAnotherWorkspace() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try Data("Second workspace".utf8).write(to: fixture.secondRoot.appendingPathComponent("private.md"))
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        do {
            _ = try await storage.read(WorkspacePath(workspaceID: fixture.second, relativePath: "private.md"))
            XCTFail("Cross-workspace read succeeded")
        } catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
    }

    @MainActor
    func testRejectsSymlinkFileAndDirectoryEscapes() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try Data("Other workspace".utf8).write(to: fixture.secondRoot.appendingPathComponent("private.md"))
        try FileManager.default.createSymbolicLink(at: fixture.firstRoot.appendingPathComponent("file.md"),
                                                  withDestinationURL: fixture.secondRoot.appendingPathComponent("private.md"))
        try FileManager.default.createSymbolicLink(at: fixture.firstRoot.appendingPathComponent("linked"),
                                                  withDestinationURL: fixture.secondRoot)
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        for path in ["file.md", "linked/private.md"] {
            do {
                _ = try await storage.read(fixture.path(path))
                XCTFail("Followed a symlink")
            } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        }
    }

    @MainActor
    func testRejectsHardLinkToAnotherWorkspace() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.secondRoot.appendingPathComponent("private.md")
        try Data("Other workspace".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: fixture.firstRoot.appendingPathComponent("linked.md"))
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        do {
            _ = try await storage.read(fixture.path("linked.md"))
            XCTFail("Read multiply linked content")
        } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
    }

    @MainActor
    func testRejectsWorkspaceRootSymlink() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.firstRoot)
        try FileManager.default.createSymbolicLink(at: fixture.firstRoot, withDestinationURL: fixture.secondRoot)
        XCTAssertThrowsError(try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first))
    }

    @MainActor
    func testOpenRootCannotBeRedirectedByLaterSymlinkReplacement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try Data("First".utf8).write(to: fixture.firstRoot.appendingPathComponent("same.md"))
        try Data("Second".utf8).write(to: fixture.secondRoot.appendingPathComponent("same.md"))
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        try FileManager.default.moveItem(at: fixture.firstRoot, to: fixture.container.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: fixture.firstRoot, withDestinationURL: fixture.secondRoot)
        let content = try await storage.read(fixture.path("same.md"))
        XCTAssertEqual(String(decoding: content, as: UTF8.self), "First")
    }

    @MainActor
    func testMissingOversizedAndSpecialFilesFailWithoutBlocking() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        do {
            _ = try await storage.read(fixture.path("missing.md"))
            XCTFail("Missing file read succeeded")
        } catch { XCTAssertEqual(error as? ScopedFileError, .notFound) }
        try Data(repeating: 1, count: 20_000).write(to: fixture.firstRoot.appendingPathComponent("large.bin"))
        do {
            _ = try await storage.read(fixture.path("large.bin"), maximumBytes: 100)
            XCTFail("Size limit ignored")
        } catch { XCTAssertEqual(error as? ScopedFileError, .sizeLimit) }
        let fifo = fixture.firstRoot.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        do {
            _ = try await storage.read(fixture.path("pipe"))
            XCTFail("Read a non-regular file")
        } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
    }

    @MainActor
    func testCancelledReadFailsBeforeAccess() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let storage = try WorkspaceFileSystem(container: fixture.container, workspaceID: fixture.first)
        let reference = try fixture.path("missing.md")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await storage.read(reference)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled read succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
