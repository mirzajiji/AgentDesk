#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ExecutionDocumentEditor: View {
    let scope: ProjectScope
    let request: ExecutionEditorRequest
    let save: (ExecutionConfigurationDraft) async throws -> Void
    @State private var draft: ExecutionConfigurationDraft
    @State private var saving = false
    @State private var error: String?
    @State private var advanced: AdvancedExecutionEdit?
    @Environment(\.dismiss) private var dismiss
    init(scope: ProjectScope, request: ExecutionEditorRequest, save: @escaping (ExecutionConfigurationDraft) async throws -> Void) {
        self.scope = scope; self.request = request; self.save = save
        _draft = State(initialValue: request.draft)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.level == .workspace ? "Workspace Execution Settings" : "Project Execution Settings").font(.title2).bold()
            Text(request.level == .workspace ? "Changes apply to projects in this workspace." : "Choose the environments and limits for this project.").foregroundStyle(.secondary)
            Form {
                ExecutionLimitsEditor(settings: $draft.settings)
                ExecutionPolicyEditor(policy: $draft.policy, scope: scope, level: request.level == .workspace ? .workspace : .project)
                if request.level == .workspace {
                    Toggle("Lock workspace execution", isOn: $draft.workspaceLocked).accessibilityIdentifier("execution.locked")
                } else {
                    Section("Environments") {
                        Picker("Default environment", selection: $draft.defaultEnvironmentID) {
                            Text("Choose for each run").tag(nil as EnvironmentID?)
                            ForEach(draft.environments.filter(\.enabled)) { environment in
                                Text(environment.name).tag(Optional(environment.id))
                            }
                        }.accessibilityIdentifier("execution.defaultEnvironment")
                        ForEach($draft.environments) { $environment in
                            DisclosureGroup {
                                TextField("Name", text: $environment.name).accessibilityIdentifier("environment.name.\(environment.id)")
                                Picker("Type", selection: $environment.kind) {
                                    Text("Development").tag(PolicySnapshot.Environment.development)
                                    Text("Test").tag(PolicySnapshot.Environment.test)
                                    Text("Production").tag(PolicySnapshot.Environment.production)
                                }
                                Toggle("Enabled", isOn: $environment.enabled)
                                    .onChange(of: environment.enabled) { _, enabled in
                                        if !enabled && draft.defaultEnvironmentID == environment.id { draft.defaultEnvironmentID = nil }
                                    }
                                ExecutionLimitsEditor(settings: $environment.constraints)
                                ExecutionPolicyEditor(policy: $environment.policy, scope: scope, level: .environment, environmentID: environment.id)
                                Button("Remove Environment", role: .destructive) {
                                    let id = environment.id
                                    ExecutionDraftEditing.removeEnvironment(id, from: &draft)
                                }
                            } label: { Text(environment.name.isEmpty ? "Unnamed environment" : environment.name) }
                        }
                        Button("Add Environment", systemImage: "plus") {
                            draft.environments.append(ProjectEnvironment(scope: scope, name: "New environment", constraints: .init(accessCeiling: .readOnly)))
                        }.disabled(draft.environments.count >= 64).accessibilityIdentifier("execution.environment.add")
                    }
                }
                Section {
                    Text("Saving stops active runs affected by these workspace or project settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Blank limits inherit. Effective limits use the strictest saved value. Additional saved constraints remain in effect.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("execution.validation") }
            HStack {
                Button("Advanced JSON…") {
                    do { advanced = try AdvancedExecutionEdit(text: ExecutionDraftEditing.json(draft)) }
                    catch { self.error = "The advanced editor could not open these settings." }
                }.accessibilityIdentifier("execution.advanced.open")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Settings") {
                    saving = true
                    Task {
                        do { try await save(draft); dismiss() }
                        catch { self.error = ProjectSetupModel.message(error); saving = false }
                    }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("execution.save")
            }
        }.padding(24).macEditorLayout(idealWidth: 760).disabled(saving).interactiveDismissDisabled(saving)
        .sheet(item: $advanced) { edit in
            AdvancedExecutionEditor(edit: edit, scope: scope, level: request.level) { updated in draft = updated; error = nil }
        }
    }
}

private struct ExecutionLimitsEditor: View {
    @Binding var settings: ExecutionSettings
    private var number: NumberFormatter { let value = NumberFormatter(); value.numberStyle = .none; value.allowsFloats = false; return value }
    var body: some View {
        Section("Model and limits") {
            TextField("Model (blank inherits)", text: Binding(get: { settings.modelIdentifier ?? "" }, set: { settings.modelIdentifier = $0.isEmpty ? nil : $0 }))
                .accessibilityIdentifier("execution.model")
            TextField("Maximum activities", value: $settings.maximumSteps, formatter: number).accessibilityIdentifier("execution.steps")
            TextField("Timeout in seconds", value: $settings.timeoutSeconds, formatter: number).accessibilityIdentifier("execution.timeout")
            TextField("Maximum output bytes", value: $settings.maximumOutputBytes, formatter: number).accessibilityIdentifier("execution.outputLimit")
            Text("Agent execution currently supports read-only repository access.").foregroundStyle(.secondary)
        }
    }
}

private struct ExecutionPolicyEditor: View {
    @Binding var policy: PolicyDocument?
    let scope: ProjectScope
    let level: PolicyLevel
    var environmentID: EnvironmentID? = nil
    @State private var error: String?
    var body: some View {
        Section("Permissions at this level") {
            Picker("Read run evidence", selection: disposition(.readEvidence)) {
                Text("Deny").tag(PolicyDisposition.deny)
                Text("Allow").tag(PolicyDisposition.allow)
                if policy?.disposition(for: .readEvidence) == .approval { Text("Approval required (unavailable for preflight)").tag(PolicyDisposition.approval) }
            }.accessibilityIdentifier("execution.policy.readEvidence")
            Picker("Run a read-only agent", selection: disposition(.runReadOnlyAgent)) {
                Text("Deny").tag(PolicyDisposition.deny)
                Text("Require approval").tag(PolicyDisposition.approval)
                Text("Allow").tag(PolicyDisposition.allow)
            }.accessibilityIdentifier("execution.policy.run")
            Text("Workspace, project and environment permissions all apply. A denial at any level blocks the operation.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
    }
    private func disposition(_ operation: PolicyOperation) -> Binding<PolicyDisposition> {
        Binding(get: { policy?.disposition(for: operation) ?? .deny }, set: { value in
            do {
                policy = try ExecutionDraftEditing.change(operation, to: value, policy: policy,
                    scope: scope, level: level, environmentID: environmentID)
                error = nil
            } catch { self.error = "This permission change could not be applied." }
        })
    }
}
#endif
