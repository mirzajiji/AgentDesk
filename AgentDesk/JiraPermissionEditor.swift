#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskPlugins
import SwiftUI

struct JiraPermissionEditor: View {
    @ObservedObject var model: ProjectJiraConnectionsModel
    let record: PluginConfigurationRevision<JiraConnectionConfiguration>
    @State private var choices: [PluginCapability: PolicyDisposition]
    @State private var reviewing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: ProjectJiraConnectionsModel, record: PluginConfigurationRevision<JiraConnectionConfiguration>) {
        self.model = model; self.record = record
        _choices = State(initialValue: Dictionary(uniqueKeysWithValues: PluginCapability.allCases.map {
            ($0, record.configuration.permissions?.disposition(for: $0) ?? .deny)
        }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(reviewing ? "Review Jira permissions" : "Jira permissions").font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if reviewing {
                    Button("Back") { reviewing = false }.disabled(model.busy)
                    Button("Save Reviewed Permissions") {
                        Task {
                            do {
                                try await model.savePermissions(PluginCapability.allCases.map { .init($0, choices[$0] ?? .deny) }, for: record)
                                dismiss()
                            } catch { self.error = "Permissions could not be saved. Close this editor and refresh the connection before retrying." }
                        }
                    }.disabled(model.busy).accessibilityIdentifier("permissions.save")
                } else {
                    Button("Review Changes") { reviewing = true }.accessibilityIdentifier("permissions.review")
                }
            }
            Text(record.configuration.instance.host ?? "Jira").font(.headline)
            Text("Connection permissions can restrict workspace, project and environment policy. They cannot override a denial or grant OAuth access. Unimplemented capabilities remain unavailable.")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("permissions.error") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(PluginCapability.allCases, id: \.self) { capability in
                        if reviewing {
                            Text("\(title(for: capability)): \(record.configuration.permissions?.disposition(for: capability).rawValue ?? "deny") → \((choices[capability] ?? .deny).rawValue)")
                                .accessibilityIdentifier("permissions.change.\(capability.rawValue)")
                        } else {
                            Picker(title(for: capability), selection: Binding(get: { choices[capability] ?? .deny }, set: { choices[capability] = $0 })) {
                                Text("Deny").tag(PolicyDisposition.deny)
                                Text("Require approval").tag(PolicyDisposition.approval)
                                Text("Allow within policy").tag(PolicyDisposition.allow)
                            }.accessibilityIdentifier("permissions.rule.\(capability.rawValue)")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).macEditorLayout(idealWidth: 760, idealHeight: 600)
        .interactiveDismissDisabled(model.busy)
    }
    private func title(for capability: PluginCapability) -> String {
        switch capability {
        case .issuesRead: "Read issues"
        case .issuesCreate: "Create issues"
        case .issuesUpdate: "Update issues"
        case .issuesDelete: "Delete issues"
        case .commentsRead: "Read comments"
        case .commentsWrite: "Write comments"
        case .attachmentsRead: "Read attachments"
        case .attachmentsAdd: "Add attachments"
        }
    }

}
#endif
