#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct WorkspaceBrowserView: View {
    @ObservedObject var model: WorkspaceBrowserModel
    @Binding var command: NativeCommandAction?
    @State private var commandError: String?
    @State private var editor: CatalogEditor?
    @State private var selectedProject: ProjectRecord?
    @State private var setupProject: ProjectRecord?
    @State private var runProject: ProjectRecord?
    @State private var requirementsProject: ProjectRecord?
    @State private var memoryProject: ProjectRecord?

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry") { Task { await model.reload() } }
                }
                .padding().background(.orange.opacity(0.1))
                .accessibilityIdentifier("catalog.error")
            }
            if model.isLoading && model.workspaces.isEmpty {
                ProgressView("Opening workspaces…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.workspaces.isEmpty {
                VStack {
                    DeskEmptyState("No workspaces yet", systemImage: "square.stack.3d.up",
                                   message: "Create a workspace for your projects. Everything is stored locally on this Mac.",
                                   accessibilityIdentifier: "empty.workspaces")
                    Button("Create Workspace", systemImage: "plus") { editor = .newWorkspace }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workspace.create.empty")
                        .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { model.selectedWorkspace }, set: { id in
                        Task { await model.select(id) }
                    })) {
                        ForEach(model.workspaces) { workspace in
                            Label(workspace.name, systemImage: "square.stack.3d.up")
                                .tag(workspace.id)
                                .accessibilityIdentifier("workspace.row.\(workspace.name)")
                                .contextMenu {
                                    Button("Rename Workspace") { editor = .renameWorkspace(workspace) }
                                }
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    .accessibilityLabel("Workspaces")
                    Divider()
                    projectPane
                }
            }
        }
        .task(id: command) {
            guard let action = command else { return }
            defer { if command == action { command = nil } }
            do {
                switch action {
                case .settings: break
                case .createWorkspace: editor = .newWorkspace
                case .switchWorkspace(let id), .createProject(let id):
                    let workspace = try await model.resolveWorkspace(id)
                    try Task.checkCancellation()
                    try await model.selectCommandWorkspace(id)
                    try Task.checkCancellation()
                    guard model.selectedWorkspace == id else { return }
                    if case .createProject = action { editor = .newProject(workspace) }
                case .agents(let scope), .setup(let scope), .run(let scope), .requirements(let scope), .memory(let scope):
                    _ = try await model.resolveProject(scope)
                    try Task.checkCancellation()
                    try await model.selectCommandWorkspace(scope.workspaceID)
                    try Task.checkCancellation()
                    guard model.selectedWorkspace == scope.workspaceID else { return }
                    let project = try await model.resolveProject(scope)
                    try Task.checkCancellation()
                    guard model.selectedWorkspace == scope.workspaceID else { return }
                    switch action {
                    case .agents: selectedProject = project
                    case .setup: setupProject = project
                    case .requirements: requirementsProject = project
                    case .memory: memoryProject = project
                    case .run:
                        if !NativeRunRegistry.shared.focus(scope) { runProject = project }
                    default: break
                    }
                }
            } catch is CancellationError { return }
            catch { commandError = WorkspaceBrowserModel.message(for: error) }
        }
        .alert("Command unavailable", isPresented: Binding(get: { commandError != nil }, set: { if !$0 { commandError = nil } })) {
            Button("OK") { commandError = nil }
        } message: { Text(commandError ?? "") }
        .toolbar {
            ToolbarItemGroup {
                Button("New Workspace", systemImage: "plus") { editor = .newWorkspace }
                    .accessibilityIdentifier("workspace.create")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                if let workspace = model.currentWorkspace {
                    Button("New Project", systemImage: "folder.badge.plus") { editor = .newProject(workspace) }
                        .accessibilityIdentifier("project.create")
                }
            }
        }
        .sheet(item: $selectedProject) { project in
            ProjectAgentsView(project: project, openStore: { try await model.agentStore(for: project) },
                              openInstructions: { try await model.instructionStore(for: project) },
                              openSkills: { try await model.skillStore(for: project) })
        }
        .sheet(item: $setupProject) { project in
            ProjectSetupView(project: project, open: { try await model.executionServices(for: project) })
        }
        .sheet(item: $requirementsProject) { project in
            ProjectRequirementsView(project: project, open: { try await model.requirementServices(for: project) })
        }
        .sheet(item: $memoryProject) { project in
            ProjectMemoryView(project: project, open: { try await model.memoryServices(for: project) })
        }
        .sheet(item: $runProject) { project in
            ProjectRunConsoleView(project: project, open: { try await model.executionServices(for: project) })
        }
        .sheet(item: $editor) { item in
            CatalogNameEditor(editor: item) { name in
                switch item {
                case .newWorkspace: try await model.createWorkspace(name: name)
                case .newProject(let workspace): try await model.createProject(workspaceID: workspace.id, name: name)
                case .renameWorkspace(let workspace): try await model.renameWorkspace(workspace.id, name: name)
                case .renameProject(let project): try await model.renameProject(project.scope, name: name)
                }
            }
        }
    }

    private func projectSummary(_ project: ProjectRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(.tint).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                    .accessibilityIdentifier("project.name.\(project.name)")
                Text("Local project").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func projectActions(_ project: ProjectRecord) -> some View {
        HStack {
            projectKnowledgeActions(project)
            projectExecutionActions(project)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func compactProjectActions(_ project: ProjectRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            projectActions(project)
            VStack(alignment: .leading, spacing: 8) {
                HStack { projectKnowledgeActions(project) }
                HStack { projectExecutionActions(project) }
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                projectKnowledgeActions(project)
                projectExecutionActions(project)
            }
        }
    }

    private func projectKnowledgeActions(_ project: ProjectRecord) -> some View {
        Group {
            Button("Agents") { selectedProject = project }
                .accessibilityIdentifier("project.agents.\(project.name)")
            Button("Requirements") { requirementsProject = project }
                .accessibilityIdentifier("project.requirements.\(project.name)")
            Button("Memory") { memoryProject = project }
                .accessibilityIdentifier("project.memory.\(project.name)")
        }
    }

    private func projectExecutionActions(_ project: ProjectRecord) -> some View {
        Group {
            Button("Setup") { setupProject = project }
                .accessibilityIdentifier("project.setup.\(project.name)")
            Button("Run") { if !NativeRunRegistry.shared.focus(project.scope) { runProject = project } }
                .accessibilityIdentifier("project.run.\(project.name)")
            Button("Rename") { editor = .renameProject(project) }
                .accessibilityIdentifier("project.rename.\(project.name)")
        }
    }

    private var projectPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let workspace = model.currentWorkspace {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(workspace.name).font(.largeTitle).bold()
                        Text("Workspace · Stored on this Mac").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rename", systemImage: "pencil") { editor = .renameWorkspace(workspace) }
                        .accessibilityIdentifier("workspace.rename")
                }
                if model.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "folder")
                    } description: {
                        Text("Add your first project to \(workspace.name).")
                    } actions: {
                        Button("Create Project") { editor = .newProject(workspace) }
                            .accessibilityIdentifier("project.create.empty")
                    }
                } else {
                    Text("Projects").font(.headline)
                    List(model.projects) { project in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                projectSummary(project).fixedSize(horizontal: true, vertical: false)
                                Spacer()
                                projectActions(project)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                projectSummary(project)
                                compactProjectActions(project)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .listStyle(.inset)
                    Text("Set up a repository and execution permissions for each project.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum CatalogEditor: Identifiable {
    case newWorkspace, newProject(WorkspaceRecord), renameWorkspace(WorkspaceRecord), renameProject(ProjectRecord)
    var id: String {
        switch self {
        case .newWorkspace: "new-workspace"
        case .newProject(let value): "new-project-\(value.id)"
        case .renameWorkspace(let value): "workspace-\(value.id)"
        case .renameProject(let value): "project-\(value.id)"
        }
    }
    var title: String {
        switch self {
        case .newWorkspace: "Create Workspace"
        case .newProject: "Create Project"
        case .renameWorkspace: "Rename Workspace"
        case .renameProject: "Rename Project"
        }
    }
    var initialName: String {
        switch self {
        case .newWorkspace, .newProject: ""
        case .renameWorkspace(let value): value.name
        case .renameProject(let value): value.name
        }
    }
    var context: String {
        switch self {
        case .newWorkspace: "Keep each company or personal area in its own workspace."
        case .newProject(let value): "Workspace: \(value.name)"
        case .renameWorkspace: "The workspace identity and its projects stay the same."
        case .renameProject: "The project identity and its workspace stay the same."
        }
    }
}

private struct CatalogNameEditor: View {
    let editor: CatalogEditor
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.title).font(.title2).bold()
            Text(editor.context).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityIdentifier("catalog.name")
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("catalog.validation") }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do { try await save(name); dismiss() }
                        catch { self.error = WorkspaceBrowserModel.message(for: error); saving = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("catalog.save")
            }
        }
        .padding(24).frame(width: 440)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { name = editor.initialName; nameFocused = true }
    }
}
#endif
