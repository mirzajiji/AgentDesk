#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskRuntime
import AppKit
import SwiftUI

struct ProjectSetupView: View {
    @StateObject private var model: ProjectSetupModel
    @State private var editor: ExecutionEditorRequest?
    @State private var editorError: String?
    @State private var removingRepository = false
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, open: @escaping () async throws -> ProjectNativeServices) {
        _model = StateObject(wrappedValue: ProjectSetupModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.project.name).font(.title).bold()
                    Text("Repository and execution settings").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") { Task { await model.load() } }.disabled(model.isBusy)
                    .accessibilityIdentifier("project.setup.reload")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                    .accessibilityIdentifier("project.setup.done")
            }
            if let error = model.errorMessage ?? editorError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("project.setup.error")
            }
            if model.isBusy { ProgressView("Updating project setup…").accessibilityIdentifier("project.setup.busy") }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupBox("Repository") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let repository = model.repository {
                                Label(repository.name, systemImage: "folder.fill").font(.headline)
                                Text(repository.path).textSelection(.enabled).font(.callout)
                                    .accessibilityIdentifier("project.repository.path")
                                Text("Registration version \(repository.revision)").foregroundStyle(.secondary)
                                Label(model.repositoryAccessAvailable == true ? "Read-only access verified" : "Folder access needs checking",
                                    systemImage: model.repositoryAccessAvailable == true ? "checkmark.shield" : "exclamationmark.shield")
                                    .accessibilityIdentifier("project.repository.access")
                            } else {
                                Text("No repository selected").font(.headline)
                                    .accessibilityIdentifier("project.repository.empty")
                                Text("Choose the Git repository this project’s agents may read.").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(model.repository == nil ? "Choose Repository…" : "Choose Another Repository…") { chooseRepository() }
                                    .accessibilityIdentifier("project.repository.choose")
                                if model.repository != nil {
                                    Button("Remove Registration", role: .destructive) { removingRepository = true }
                                        .accessibilityIdentifier("project.repository.remove")
                                }
                            }.disabled(model.isBusy || model.services == nil)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    ForEach([ExecutionConfigurationLevel.workspace, .project], id: \.rawValue) { level in
                        GroupBox(level == .workspace ? "Workspace execution" : "Project execution") {
                            VStack(alignment: .leading, spacing: 10) {
                                if let snapshot = model.settings?.configuration(at: level) {
                                    Text("Saved version \(snapshot.revision)").accessibilityIdentifier("execution.saved.\(level.rawValue)")
                                    Text(level == .workspace ? "Shared by projects in this workspace." : "Applies to this project and its environments.")
                                        .foregroundStyle(.secondary)
                                    if level == .project {
                                        Text("\(snapshot.draft.environments.count) environments")
                                    }
                                } else {
                                    Text("Not configured").foregroundStyle(.secondary)
                                    Text("Review the read-only starting settings before saving. Agent runs require approval.")
                                }
                                Button(model.settings?.configuration(at: level) == nil ? "Review Starting Settings" : "Edit Settings") {
                                    Task {
                                        do {
                                            let draft = try await model.draft(at: level)
                                            editor = ExecutionEditorRequest(level: level, revision: model.settings?.configuration(at: level)?.revision, draft: draft)
                                            editorError = nil
                                        } catch { editorError = ProjectSetupModel.message(error) }
                                    }
                                }.accessibilityIdentifier("execution.edit.\(level.rawValue)")
                                    .disabled(model.isBusy || model.settings == nil)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }
            }
        }
        .padding(24).macEditorLayout()
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.load() }
        .sheet(item: $editor) { request in
            ExecutionDocumentEditor(scope: model.project.scope, request: request) { draft in
                try await model.save(draft, at: request.level, expectedRevision: request.revision)
            }
        }
        .confirmationDialog("Remove this repository registration?", isPresented: $removingRepository, titleVisibility: .visible) {
            Button("Remove Registration", role: .destructive) { Task { await model.removeRepository() } }
        } message: { Text("The repository folder and its files will stay on your Mac.") }
    }
    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Repository"; panel.message = "Select the root folder of an ordinary Git repository."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false; panel.resolvesAliases = false; panel.prompt = "Use Repository"
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            Task { await model.register(selected) }
        }
    }
}

struct ExecutionEditorRequest: Identifiable {
    let id = UUID()
    let level: ExecutionConfigurationLevel
    let revision: Int?
    let draft: ExecutionConfigurationDraft
}
#endif
