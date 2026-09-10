#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct NativeRunsView: View {
    @ObservedObject var registry: NativeRunRegistry
    @ObservedObject var catalog: WorkspaceBrowserModel
    let open: (NativeCommandAction) -> Void
    @State private var projects: [NativeCommand] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section("Open run sessions") {
                if registry.statuses.isEmpty {
                    Text("No open run sessions").foregroundStyle(.secondary)
                        .accessibilityIdentifier("runs.sessions.empty")
                }
                ForEach(registry.statuses.values.sorted { $0.runID.rawValue < $1.runID.rawValue }) { status in
                    Button { registry.focus(status.scope) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.projectName).font(.headline)
                            Text("\(status.state.rawValue) · \(status.runID)").font(.caption)
                        }
                    }.accessibilityIdentifier("runs.session.\(status.runID)")
                }
            }
            Section("Project run consoles and history") {
                Text("Open a project console to review a new task or browse its saved runs.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
                if !loaded { ProgressView("Loading projects…") }
                else if projects.isEmpty { Text("Create a workspace and project to begin.") }
                ForEach(projects) { command in
                    Button(command.context, systemImage: "clock.arrow.circlepath") { open(command.action) }
                        .accessibilityIdentifier("runs.project.\(command.context)")
                }
            }
        }
        .task { await reload() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } } }
    }
    private func reload() async {
        do {
            let commands = try await catalog.commands()
            try Task.checkCancellation()
            projects = commands.commands.filter { if case .run = $0.action { true } else { false } }
            error = nil; loaded = true
        } catch is CancellationError {} catch {
            projects = []; self.error = WorkspaceBrowserModel.message(for: error); loaded = true
        }
    }
}
#endif
