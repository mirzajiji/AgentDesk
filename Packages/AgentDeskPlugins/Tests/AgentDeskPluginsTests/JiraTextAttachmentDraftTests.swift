import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraTextAttachmentDraftTests: XCTestCase {
    func testMultipartPreservesTextAndRejectsHeaderInjectionAndForeignScope() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        func clean(_ text: String) throws -> RedactedText { try redactor.redactText(text, in: context) }
        let content = try clean("First line\n\nLast line")
        let draft = try JiraTextAttachmentDraft(identifier: "SYN-1", filename: clean("evidence.txt"), content: content)
        let repeated = try JiraTextAttachmentDraft(identifier: "SYN-1", filename: clean("evidence.txt"), content: content)
        XCTAssertEqual(draft.body, repeated.body)
        XCTAssertLessThanOrEqual(draft.boundary.utf8.count, 70)
        let body = String(decoding: draft.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"evidence.txt\"\r\n"))
        XCTAssertTrue(body.contains("\r\n\r\nFirst line\n\nLast line\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(draft.boundary)--\r\n"))
        for name in ["../evidence.txt", "a/b", "a\\b", "x\r\nHeader:value", "\"evil\"", "", ".", ".."] {
            XCTAssertThrowsError(try JiraTextAttachmentDraft(identifier: "SYN-1", filename: clean(name), content: content))
        }
        let foreign = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())
        let foreignName = try ContentRedactor(context: foreign).redactText("evidence.txt", in: foreign)
        XCTAssertThrowsError(try JiraTextAttachmentDraft(identifier: "SYN-1", filename: foreignName, content: content))
        let renamed = try JiraTextAttachmentDraft(identifier: "SYN-1", filename: clean("other.txt"), content: content)
        XCTAssertNotEqual(draft.body, renamed.body)
    }
}
