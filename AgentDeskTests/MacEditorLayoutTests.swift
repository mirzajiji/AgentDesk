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

    func testRequirementEditorsFitCompactAndLargeLogicalWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic layout")
        let project = try await catalog.createProject(in: workspace.id, name: "Requirement layout")
        let store = try await catalog.requirementStore(in: project.scope)
        assertFitsAndExpands(RequirementEditorView(store: store, existing: nil, environments: [], onPublish: { _ in }))
        assertFitsAndExpands(RequirementJSONEditor(model: RequirementEditorModel(store: store, existing: nil)))
        assertFitsAndExpands(ProjectRequirementsView(project: project, open: {
            NativeRequirementServices(store: store, environments: [], environmentIssue: nil)
        }))
    }

    func testKnowledgeInspectorFitsLongContextAcrossLogicalSizesAndTextScaling() {
        assertFitsAndExpands(KnowledgeContextInspector(snapshot: String(repeating: "Synthetic reviewed source with version and provenance.\n", count: 500)))
    }

    func testTraceabilityEditorsFitCompactAndLargeLogicalWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic trace layout")
        let project = try await catalog.createProject(in: workspace.id, name: "Trace layout")
        let services = NativeTraceabilityServices(store: try await catalog.requirementStore(in: project.scope),
            bugs: try await catalog.bugStore(in: project.scope), environments: [], environmentIssue: nil)
        assertFitsAndExpands(TraceabilityEditorView(services: services, onPublish: { _ in }))
        assertFitsAndExpands(ProjectTraceabilityView(project: project, open: { services }))
    }

    func testBugEditorsFitCompactAndLargeLogicalWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic bug layout")
        let project = try await catalog.createProject(in: workspace.id, name: "Bug layout")
        let store = try await catalog.bugStore(in: project.scope)
        assertFitsAndExpands(BugEditorView(store: store, existing: nil, environments: [], onPublish: { _ in }))
        assertFitsAndExpands(BugJSONEditor(model: BugEditorModel(store: store, existing: nil)))
        assertFitsAndExpands(ProjectBugsView(project: project, open: {
            NativeBugServices(store: store, environments: [], environmentIssue: nil)
        }))
    }

    func testMemoryEditorsFitCompactAndLargeLogicalWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic memory layout")
        let project = try await catalog.createProject(in: workspace.id, name: "Memory layout")
        let store = try await catalog.memoryStore(in: project.scope)
        assertFitsAndExpands(MemoryEditorView(store: store, existing: nil, environments: [], onPublish: { _ in }))
        assertFitsAndExpands(MemoryJSONEditor(model: MemoryEditorModel(store: store, existing: nil)))
        assertFitsAndExpands(ProjectMemoryView(project: project, open: {
            NativeMemoryServices(store: store, environments: [], environmentIssue: nil)
        }))
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
