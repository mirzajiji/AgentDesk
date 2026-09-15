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
                    if let catalog = model.promptCatalog {
                        Text("Prompts (\(catalog.prompts.count))").font(.headline)
                        ForEach(Array(catalog.prompts.enumerated()), id: \.offset) { index, prompt in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: prompt.title?.text ?? prompt.name.text).font(.headline)
                                    .accessibilityIdentifier("mcp.prompt.\(index)")
                                Text(verbatim: prompt.name.text).font(.caption).foregroundStyle(.secondary)
                                if let description = prompt.description { Text(verbatim: description.text).textSelection(.enabled) }
                                if let arguments = prompt.arguments, !arguments.isEmpty {
                                    Text("Arguments").font(.subheadline).bold()
                                    ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: argument.title?.text ?? argument.name.text).bold()
                                            if argument.title != nil { Text(verbatim: argument.name.text).font(.caption) }
                                            Text("Required: \(argument.required.map { $0 ? "Yes" : "No" } ?? "Unspecified")").font(.caption)
                                            if let description = argument.description { Text(verbatim: description.text) }
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("These are server-provided descriptions. No prompt content has been loaded or applied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let catalog = model.resourceCatalog {
                        Text("Resources (\(catalog.resources.count))").font(.headline)
                        ForEach(Array(catalog.resources.enumerated()), id: \.offset) { index, resource in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: resource.title?.text ?? resource.name.text).font(.headline)
                                    .accessibilityIdentifier("mcp.resource.\(index)")
                                Text(verbatim: resource.name.text).font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: resource.uri.text).textSelection(.enabled)
                                if let description = resource.description { Text(verbatim: description.text).textSelection(.enabled) }
                                if let mime = resource.mimeType { Text("Type: \(mime.text)").font(.caption) }
                                if let size = resource.sizeBytes { Text("Size: \(size.text) bytes").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("Resource descriptions only. Contents have not been read.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Closing this window stops this connection. Server capabilities do not grant permission to use tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("mcp.lifecycle.details")
            Text(model.message).accessibilityIdentifier("mcp.lifecycle.message")
            if model.busy { ProgressView() }
            if model.pending != nil {
                Button(model.reviewingResources ? "Approve Resource Discovery" : model.reviewingPrompts ? "Approve Prompt Discovery" : model.reviewingDiscovery ? "Approve Tool Discovery" : model.reviewingCredentials ? "Approve Credential Access" : "Approve and Start") { model.approve() }
                    .disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.approve")
            } else if model.connected {
                HStack {
                    Button("Discover Tools") { model.discover() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.discover")
                    Button("Discover Prompts") { model.discoverPrompts() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.prompts")
                    Button("Discover Resources") { model.discoverResources() }.disabled(model.busy).accessibilityIdentifier("mcp.lifecycle.resources")
                }
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
