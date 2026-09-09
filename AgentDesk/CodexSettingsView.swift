#if os(macOS)
import AgentDeskRuntime
import AppKit
import SwiftUI

struct CodexSettingsView: View {
    @ObservedObject var model: CodexSettingsModel
    @State private var confirmLogout = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider", value: "Codex CLI")
                LabeledContent("Status") {
                    HStack {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(model.status).accessibilityIdentifier("codex.status")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("codex.status.row")
                if let installation = model.snapshot?.installation {
                    LabeledContent("Version", value: installation.version)
                    LabeledContent("Executable") {
                        Text(installation.executable.path).font(.caption).textSelection(.enabled).lineLimit(3)
                    }
                }
                Text("Codex manages sign-in securely. Account plan and remaining usage are unavailable from this check.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("AI · Codex") }

            Section("Connection") {
                HStack {
                    Button("Health Check") { model.refresh() }
                        .disabled(model.isBusy || !model.configuration.enabled || !model.canConfigure)
                        .accessibilityIdentifier("codex.refresh")
                    Button("Sign In…") { model.login() }.disabled(!model.canLogin).accessibilityIdentifier("codex.login")
                    Button("Sign Out…") { confirmLogout = true }.disabled(!model.canLogout).accessibilityIdentifier("codex.logout")
                    if model.isBusy {
                        Button("Cancel") { model.cancel() }.accessibilityIdentifier("codex.cancel")
                    }
                }
                HStack {
                    Button("Choose Executable…") { chooseExecutable() }.disabled(!model.canConfigure)
                        .accessibilityIdentifier("codex.choose")
                    if model.configuration.executablePath != nil {
                        Button("Use Automatic Detection") { model.chooseExecutable(nil) }.disabled(!model.canConfigure)
                    }
                    Spacer()
                    Button(model.configuration.enabled ? "Disconnect" : "Connect") { model.setEnabled(!model.configuration.enabled) }
                        .disabled(!model.canConfigure).accessibilityIdentifier("codex.toggle")
                }
                Text("Disconnect stops AgentDesk from using Codex and keeps your CLI sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("codex.error") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 420)
        .task { if model.snapshot == nil { model.refresh() } }
        .confirmationDialog("Sign out of Codex on this Mac?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.logout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also signs out the Codex CLI. Your AgentDesk workspaces and projects will remain available.")
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex CLI executable"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { response in
            if response == .OK, let selected = panel.url { model.chooseExecutable(selected) }
        }
    }
}
#endif
