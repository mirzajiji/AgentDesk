#if os(macOS)
import AgentDeskDesign
import AgentDeskSecurity
import SwiftUI

struct NativeMCPCredentialView: View {
    let connectionName: String
    let variables: [String]
    @StateObject private var model: NativeMCPCredentialModel
    @Environment(\.dismiss) private var dismiss
    init(connectionName: String, variables: [String], write: @escaping (String, SecretValue) async throws -> Void) {
        self.connectionName = connectionName; self.variables = variables
        _model = StateObject(wrappedValue: NativeMCPCredentialModel(write: write))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set MCP Credential").font(.title2).bold()
                Spacer()
                Button(model.needsRecovery ? "Close" : "Cancel") {
                    if model.needsRecovery { dismiss() }
                    else { Task { if await model.cancel() { dismiss() } } }
                }.keyboardShortcut(.cancelAction)
                Button("Save Credential") { model.save() }.disabled(model.busy || model.saved)
                    .accessibilityIdentifier("mcp.credential.save")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(connectionName).font(.headline)
                    Text("Configured variables: " + (variables.isEmpty ? "None" : variables.joined(separator: ", ")))
                    Text("Variable name").font(.headline)
                    TextField("Example: API_TOKEN", text: $model.variable).disabled(model.busy)
                        .accessibilityIdentifier("mcp.credential.variable")
                    Text("New value").font(.headline)
                    SecureField("Credential value", text: $model.value).disabled(model.busy)
                        .accessibilityIdentifier("mcp.credential.value")
                    Text("The value is stored in Keychain. Choosing an existing variable creates a new credential reference; existing values are never shown here.")
                    Text("Saving does not start the server or revoke older credentials. Runtime credential access is checked separately.")
                        .foregroundStyle(.secondary)
                    if model.busy { ProgressView("Saving credential…") }
                    if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("mcp.credential.error") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).macEditorLayout(idealWidth: 740, idealHeight: 480)
        .onChange(of: model.saved) { _, saved in if saved { dismiss() } }
        .onDisappear { Task { _ = await model.cancel() } }
    }
}
#endif
