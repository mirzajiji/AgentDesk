#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct NativeReadinessView: View {
    @StateObject private var model: NativeReadinessModel
    @ObservedObject var catalog: WorkspaceBrowserModel
    let choose: (NativeCommandAction) -> Void
    @Environment(\.dismiss) private var dismiss

    init(catalog: WorkspaceBrowserModel, choose: @escaping (NativeCommandAction) -> Void) {
        self.catalog = catalog; self.choose = choose
        _model = StateObject(wrappedValue: NativeReadinessModel { try await NativeReadinessModel.check(catalog: catalog) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Get started with AgentDesk").font(.title2).bold()
            Text("Your Mac runs agents. Set up local tools and a project, then review each task before execution.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.checking { ProgressView("Checking local setup…") }
                    if let error = model.error { Text(error).foregroundStyle(.orange) }
                    ForEach(model.items) { item in
                        HStack(alignment: .top) {
                            Image(systemName: item.state == .ready ? "checkmark.circle" : "wrench.and.screwdriver")
                                .foregroundStyle(item.state == .ready ? .green : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text(item.detail).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("readiness.\(item.id)")
                    }
                    if let checked = model.checkedAt { Text("Checked \(checked.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    Divider()
                    Button("Open Codex Settings") { choose(.settings) }.accessibilityIdentifier("readiness.settings")
                    Button("Create Workspace") { choose(.createWorkspace) }.accessibilityIdentifier("readiness.workspace")
                    if let workspace = catalog.currentWorkspace {
                        Button("Create Project in \(workspace.name)") { choose(.createProject(workspace.id)) }
                    }
                    if let project = catalog.projects.first {
                        Button("Manage Agents and Skills in \(project.name)") { choose(.agents(project.scope)) }
                        Button("Set Up \(project.name)") { choose(.setup(project.scope)) }
                    }
                    Text("The iPhone companion will require explicit pairing in a later phase. No remote access is enabled here.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.checking { Button("Cancel Check") { model.cancel() } }
                else { Button("Check Again") { model.refresh() }.accessibilityIdentifier("readiness.refresh") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("readiness.done")
            }
        }
        .padding(24).macEditorLayout(idealWidth: 720, idealHeight: 600)
        .onAppear { model.refresh() }
        .onDisappear { model.cancel() }
    }
}
#endif
