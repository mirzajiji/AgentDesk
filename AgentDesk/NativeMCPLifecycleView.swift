#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskMCP
import AgentDeskRuntime
import AgentDeskSecurity
import SwiftUI

struct NativeMCPLifecycleView: View {
    let configuration: MCPStdioConfiguration
    @StateObject private var model: NativeMCPLifecycleModel
    @Environment(\.dismiss) private var dismiss
    init(configuration: MCPStdioConfiguration, open: @escaping () async throws -> any NativeMCPLifecycle) {
        self.configuration = configuration
        _model = StateObject(wrappedValue: NativeMCPLifecycleModel(needsCredentials: !configuration.secretEnvironment.isEmpty, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(configuration.name).font(.title2).bold()
                Spacer()
                Button("Done") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Executable").font(.headline)
                    Text(verbatim: configuration.executable).textSelection(.enabled)
                    Text("Arguments").font(.headline)
                    if configuration.arguments.isEmpty { Text("None") }
                    ForEach(Array(configuration.arguments.enumerated()), id: \.offset) { index, argument in
                        Text(verbatim: "\(index + 1): \(argument)").textSelection(.enabled)
                    }
                    Text("Working directory").font(.headline)
                    Text(configuration.directoryBase == .registeredRepository ? "Registered repository" : "Workspace")
                    Text(verbatim: configuration.workingDirectory?.relativePath ?? "Repository root")
                    Text("Environment: \(configuration.environmentID.rawValue)").font(.caption)
                    if !configuration.secretEnvironment.isEmpty {
                        Text("Credential variables").font(.headline)
                        Text(configuration.secretEnvironment.keys.sorted().joined(separator: ", "))
                    }
                    if let catalog = model.catalog {
                        Text("Tools (\(catalog.tools.count))").font(.headline)
                        ForEach(Array(catalog.tools.enumerated()), id: \.offset) { index, tool in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: tool.title?.text ?? tool.name.text).font(.headline)
                                    .accessibilityIdentifier("mcp.tool.\(index)")
                                Text(verbatim: tool.name.text).font(.caption).foregroundStyle(.secondary)
                                if let description = tool.description { Text(verbatim: description.text).textSelection(.enabled) }
                                Text("Server hints · Read only: \(tool.readOnlyHint.map { $0 ? "Yes" : "No" } ?? "Unspecified") · Destructive: \(tool.destructiveHint.map { $0 ? "Yes" : "No" } ?? "Unspecified")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Text("Closing this window stops this connection. Server capabilities do not grant permission to use tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("mcp.lifecycle.details")
            Text(model.message).accessibilityIdentifier("mcp.lifecycle.message")
            if model.busy { ProgressView() }
            if model.pending != nil {
                Button(model.reviewingDiscovery ? "Approve Tool Discovery" : model.reviewingCredentials ? "Approve Credential Access" : "Approve and Start") { model.approve() }
                    .disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.approve")
            } else if model.connected {
                Button("Discover Tools") { model.discover() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.discover")
                Button("Check Health") { model.checkHealth() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.health")
            } else {
                Button("Review Start") { model.prepare() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.review")
            }
            Button("Stop / Cancel Review") { model.stop() }.accessibilityIdentifier("mcp.lifecycle.stop")
        }.padding(20).macEditorLayout(idealWidth: 780, idealHeight: 600)
        .onDisappear { model.stop() }
    }
}
#endif
