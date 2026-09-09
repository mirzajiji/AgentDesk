import Foundation
import XCTest
@testable import AgentDeskCore

final class EntityIDTests: XCTestCase {
    func testIdentityRoundTripUsesCanonicalString() throws {
        let raw = "A6510847-7571-4C45-83F8-3BA23C48880A"
        let identifier = try XCTUnwrap(WorkspaceID(rawValue: raw))
        XCTAssertEqual(identifier.rawValue, raw.lowercased())
        let data = try JSONEncoder().encode(identifier)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(raw.lowercased())\"")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceID.self, from: data), identifier)
    }

    func testInvalidIdentitiesCannotDecodeOrBecomePaths() throws {
        for raw in ["", "company", "../other", "/tmp", "%2e%2e", UUID().uuidString + " ",
                    "00000000-0000-0000-0000-00000000000z"] {
            XCTAssertNil(WorkspaceID(rawValue: raw), raw)
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceID.self, from: JSONEncoder().encode(raw)))
        }
    }

    func testIdentityKindsStayDistinctWhenTypeErased() throws {
        let workspace = WorkspaceID()
        let project = try XCTUnwrap(ProjectID(rawValue: workspace.rawValue))
        XCTAssertNotEqual(AnyHashable(workspace), AnyHashable(project))
        XCTAssertNotEqual(WorkspaceID(), WorkspaceID())
    }

    func testProjectScopeRetainsBothIdentities() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        XCTAssertEqual(try JSONDecoder().decode(ProjectScope.self, from: JSONEncoder().encode(scope)), scope)
        XCTAssertNotEqual(scope, ProjectScope(workspaceID: WorkspaceID(), projectID: scope.projectID))
    }

    func testPathRejectsTraversalAmbiguityAndEncodedEscapes() {
        for path in ["", "/etc/passwd", "../other", "a/../b", "a/./b", "a//b", "a/", ".", "..",
                     "a\\b", "C:/outside", "file:/outside", "%2e%2e/other", "%252e%252e/other", "a\u{0}b", "a\nb",
                     String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try WorkspacePath(workspaceID: WorkspaceID(), relativePath: path), path)
        }
    }

    func testDecodedPathIsValidated() throws {
        let workspace = WorkspaceID()
        let valid = try WorkspacePath(workspaceID: workspace, relativePath: "Projects/specification.json")
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePath.self, from: JSONEncoder().encode(valid)), valid)
        let malformed = Data("{\"workspaceID\":\"\(workspace)\",\"relativePath\":\"../other\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspacePath.self, from: malformed))
    }
}
