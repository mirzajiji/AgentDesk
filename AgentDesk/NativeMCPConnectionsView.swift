#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskMCP
import SwiftUI

private struct MCPEditRequest: Identifiable {
    let id = UUID()
    var record: MCPConfigurationRevision<MCPStdioConfiguration>?
}
struct NativeMCPConnectionsView: View {
    @StateObject private var model: ProjectMCPConnectionsModel
    @State private var editor: MCPEditRequest?
    init(project: ProjectRecord, open: @escaping () async throws -> NativeMCPConfigurationServices) {
        _model = StateObject(wrappedValue: ProjectMCPConnectionsModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MCP connections").font(.title2).bold()
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                Button("New MCP Connection") { editor = .init() }
                    .disabled(model.busy || model.environments.isEmpty).accessibilityIdentifier("mcp.create")
            }
            Text("Configure local MCP servers for this project. Saving does not start a process.").foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if model.busy { ProgressView("Loading MCP connections…") }
            if model.environments.isEmpty && !model.busy {
                Text("Add an environment in the project’s Setup before creating a connection.")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.records.isEmpty && !model.busy { Text("No MCP connections saved.").accessibilityIdentifier("mcp.empty") }
                    ForEach(model.records, id: \.configuration.id) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.configuration.name).font(.headline)
                                Text(record.configuration.executable).font(.caption).textSelection(.enabled)
                                Text("\(record.configuration.enabled ? "Enabled" : "Disabled") · Configuration v\(record.revision)").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { editor = .init(record: record) }.disabled(model.busy)
                                .accessibilityIdentifier("mcp.edit.\(record.configuration.id)")
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.hasMore { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.busy) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.task { await model.load() }.onDisappear { model.cancel() }
        .sheet(item: $editor) { MCPConnectionEditor(model: model, existing: $0.record) }
    }
}
private struct MCPConnectionEditor: View {
    @ObservedObject var model: ProjectMCPConnectionsModel
    let existing: MCPConfigurationRevision<MCPStdioConfiguration>?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var directory = ""
    @State private var arguments: [String] = []
    @State private var environment: EnvironmentID?
    @State private var enabled = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(existing == nil ? "New MCP Connection" : "Edit MCP Connection").font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || environment == nil).accessibilityIdentifier("mcp.save")
            }
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("mcp.editor.error") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name).accessibilityIdentifier("mcp.name")
                    Text("Executable absolute path").font(.caption).foregroundStyle(.secondary)
                    TextField("Executable absolute path", text: $executable).accessibilityIdentifier("mcp.executable")
                    Text("Working directory relative to workspace").font(.caption).foregroundStyle(.secondary)
                    TextField("Working directory relative to workspace", text: $directory).accessibilityIdentifier("mcp.directory")
                    Picker("Environment", selection: $environment) {
                        Text("Choose environment").tag(EnvironmentID?.none)
                        ForEach(model.environments) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(existing != nil)
                    Toggle("Enabled", isOn: $enabled)
                    Text("Arguments").font(.headline)
                    Text("Add one argument per field. Do not put passwords or tokens in arguments.").foregroundStyle(.secondary)
                    ForEach(arguments.indices, id: \.self) { index in
                        HStack {
                            TextField("Argument \(index + 1)", text: $arguments[index]).accessibilityIdentifier("mcp.argument.\(index)")
                            Button("Remove") { arguments.remove(at: index) }
                        }
                    }
                    Button("Add Argument") { arguments.append("") }.disabled(arguments.count >= 128)
                    Text("Local process startup and credential editing are not available in this screen yet.").foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder)
            }
        }.padding(20).macEditorLayout(idealWidth: 720, idealHeight: 560)
        .onAppear {
            if let value = existing?.configuration {
                name = value.name; executable = value.executable; directory = value.workingDirectory.relativePath
                arguments = value.arguments; environment = value.environmentID; enabled = value.enabled
            } else { environment = model.environments.first?.id }
        }
    }
    private func save() async {
        guard let environment else { return }
        do {
            try await model.save(name: name, executable: executable, arguments: arguments, directory: directory,
                environment: environment, enabled: enabled, existing: existing)
            dismiss()
        } catch { self.error = "Could not save. Check the paths and arguments, or reopen the connection if it changed." }
    }
}
#endif
