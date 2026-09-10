#if os(macOS)
import AgentDeskCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentDesk

@MainActor
final class MacEditorLayoutTests: XCTestCase {
    // Logical content sizes, including a small floating window and large desktop windows.
    // These are proposals to the actual SwiftUI views, not simulated physical displays.
    private let viewports: [CGSize] = [
        .init(width: 600, height: 480), .init(width: 900, height: 600),
        .init(width: 1280, height: 720), .init(width: 1440, height: 900),
        .init(width: 1920, height: 1080), .init(width: 2560, height: 1440),
        .init(width: 3840, height: 2160)
    ]

    func testAgentAndSkillEditorsFitCompactWindowsAndExpandOnLargeDesktops() {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        assertFitsAndExpands(AgentEditorView(existing: nil, skills: [], save: { _ in }))
        assertFitsAndExpands(SkillEditorView(scope: scope, existing: nil, save: { _, _ in }))
    }

    func testExecutionFormsFitCompactWindowsAndExpandOnLargeDesktops() {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environments = (0..<20).map { index in
            ProjectEnvironment(scope: scope, name: "Synthetic environment \(index) with a long descriptive name")
        }
        for level in [ExecutionConfigurationLevel.workspace, .project] {
            let draft = ExecutionConfigurationDraft(settings: .init(modelIdentifier: "synthetic-model"),
                environments: level == .project ? environments : [])
            assertFitsAndExpands(ExecutionDocumentEditor(scope: scope,
                request: .init(level: level, revision: nil, draft: draft), save: { _ in }))
        }
    }

    func testAdvancedEditorFitsCompactWindowsWithLongScrollableJSON() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let draft = ExecutionConfigurationDraft(settings: .init(allowedModelIdentifiers:
            (0..<40).map { "synthetic-model-\($0)-with-a-long-name" }))
        let text = try ExecutionDraftEditing.json(draft)
        assertFitsAndExpands(AdvancedExecutionEditor(edit: .init(text: text), scope: scope,
            level: .workspace, apply: { _ in }))
    }

    private func assertFitsAndExpands<Content: View>(_ content: Content,
        file: StaticString = #filePath, line: UInt = #line) {
        for scale: CGFloat in [1, 2] {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let host = NSHostingController(rootView: content
                    .environment(\.displayScale, scale).environment(\.dynamicTypeSize, textSize))
                var firstSize: CGSize?
                for viewport in viewports {
                    let fitted = host.sizeThatFits(in: viewport)
                    let context = "viewport=\(viewport), scale=\(scale), text=\(textSize), fitted=\(fitted)"
                    XCTAssertGreaterThan(fitted.width, 0, context, file: file, line: line)
                    XCTAssertGreaterThan(fitted.height, 0, context, file: file, line: line)
                    XCTAssertLessThanOrEqual(fitted.width, viewport.width + 1, context, file: file, line: line)
                    XCTAssertLessThanOrEqual(fitted.height, viewport.height + 1, context, file: file, line: line)
                    if let firstSize {
                        XCTAssertGreaterThan(fitted.width, firstSize.width, context, file: file, line: line)
                        XCTAssertGreaterThan(fitted.height, firstSize.height, context, file: file, line: line)
                    } else { firstSize = fitted }
                }
            }
        }
    }
}
#endif
