#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskPlugins
import SwiftUI
import AppKit

struct NativeConnectionsView: View {
    @ObservedObject var catalog: WorkspaceBrowserModel
    @State private var projectID: ProjectID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Workspace", selection: Binding(get: { catalog.selectedWorkspace }, set: { id in
                    projectID = nil; Task { await catalog.select(id) }
                })) {
                    Text("Choose workspace").tag(WorkspaceID?.none)
                    ForEach(catalog.workspaces) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("connections.workspace")
                Picker("Project", selection: $projectID) {
                    Text("Choose project").tag(ProjectID?.none)
                    ForEach(catalog.projects) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("connections.project")
            }
            if let error = catalog.errorMessage { Text(error).foregroundStyle(.orange) }
            if let project = catalog.projects.first(where: { $0.id == projectID }) {
                ProjectJiraConnectionsView(project: project, open: { try await catalog.jiraConfigurationServices(for: project) })
                    .id(project.scope)
            } else {
                ContentUnavailableView("Choose a project", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Connections belong to a workspace, project and environment. Create a project in Workspaces if needed."))
            }
        }.padding(20)
        .onChange(of: catalog.projects.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == projectID }) { projectID = ids.first }
        }
    }
}

private struct JiraEditorRequest: Identifiable {
    let id = UUID()
    var existing: PluginConfigurationRevision<JiraConnectionConfiguration>?
}

struct ProjectJiraConnectionsView: View {
    @StateObject private var model: ProjectJiraConnectionsModel
    @State private var editor: JiraEditorRequest?
    private let registration = try? NativeJiraRegistration.load()
    init(project: ProjectRecord, open: @escaping () async throws -> NativeJiraConfigurationServices) {
        _model = StateObject(wrappedValue: ProjectJiraConnectionsModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Jira connections").font(.title2).bold().accessibilityIdentifier("connections.title")
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.busy)
                Button("New Jira Connection") { editor = .init() }
                    .disabled(model.busy || model.environments.isEmpty).accessibilityIdentifier("connections.create")
            }
            Text("Saving configuration does not contact Jira. Sign-in requests read access; runtime permissions remain separate.")
                .foregroundStyle(.secondary)
            if registration == nil {
                Text("Jira sign-in is unavailable in this build: the publisher’s OAuth registration is not configured.")
                    .foregroundStyle(.secondary).accessibilityIdentifier("connections.registration.unavailable")
            }
            if let message = model.authenticationMessage {
                Text(message).accessibilityIdentifier("connections.authentication")
                if model.busy { Button("Cancel Authentication") { model.cancelSignIn() }.accessibilityIdentifier("connections.login.cancel") }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("connections.error") }
            if model.busy { ProgressView("Loading connections…") }
            if model.environments.isEmpty && !model.busy {
                Text("Add an environment in the project’s Setup before creating a connection.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.records.isEmpty && !model.busy && model.error == nil {
                        Text("No Jira connections saved for this project.").accessibilityIdentifier("connections.empty")
                    }
                    ForEach(model.records, id: \.configuration.id) { record in
                        GroupBox {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.configuration.instance.host ?? "Jira").font(.headline)
                                    Text(model.environments.first(where: { $0.id == record.configuration.environmentID })?.name ?? "Unavailable environment")
                                    Text(!record.configuration.enabled ? "Disabled" :
                                        model.checks[record.configuration.id]?.revision == record.revision ? "Enabled · Connection checked" : "Enabled · Authentication not checked")
                                        .foregroundStyle(.secondary)
                                    Text("Configuration version \(record.revision)").font(.caption).foregroundStyle(.secondary)
                                    if let check = model.checks[record.configuration.id], check.revision == record.revision {
                                        Text("Connection verified at \(check.checkedAt.formatted(date: .omitted, time: .shortened))")
                                            .accessibilityIdentifier("connection.check.\(record.configuration.id)")
                                        Text("Available implementations: " + check.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text("Runtime policy still authorizes each operation.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                ViewThatFits(in: .horizontal) {
                                    HStack { connectionActions(record) }
                                    VStack(alignment: .trailing, spacing: 8) { connectionActions(record) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }.accessibilityIdentifier("connection.row.\(record.configuration.id)")
                    }
                    if model.hasMore { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.busy) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
        .onDisappear { model.close() }
        .sheet(item: $editor) { request in JiraConnectionEditor(model: model, existing: request.existing) }
    }
    @ViewBuilder private func connectionActions(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>) -> some View {
        Button("Sign In") {
            guard let registration else { return }
            model.signIn(record, registration: registration) { url in
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else { throw JiraServiceError.unavailable }
            }
        }.disabled(model.busy || !record.configuration.enabled || registration == nil)
            .accessibilityIdentifier("connection.login.\(record.configuration.id)")
        if record.configuration.credential != nil {
            Button("Refresh Grant") {
                if let registration { model.refreshGrant(record, registration: registration) }
            }.disabled(model.busy || !record.configuration.enabled || registration == nil)
                .accessibilityIdentifier("connection.refresh-grant.\(record.configuration.id)")
            Button("Test Connection") { Task { await model.testConnection(record) } }
                .disabled(model.busy || !record.configuration.enabled)
                .accessibilityIdentifier("connection.test.\(record.configuration.id)")
            Button("Log Out") { Task { await model.logout(record) } }.disabled(model.busy)
                .accessibilityIdentifier("connection.logout.\(record.configuration.id)")
        }
        Button("Edit") { editor = .init(existing: record) }.disabled(model.busy)
            .accessibilityIdentifier("connection.edit.\(record.configuration.id)")
    }

}

private struct JiraConnectionEditor: View {
    @ObservedObject var model: ProjectJiraConnectionsModel
    let existing: PluginConfigurationRevision<JiraConnectionConfiguration>?
    @State private var instance: String
    @State private var environment: EnvironmentID?
    @State private var enabled: Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(model: ProjectJiraConnectionsModel, existing: PluginConfigurationRevision<JiraConnectionConfiguration>?) {
        self.model = model; self.existing = existing
        _instance = State(initialValue: existing?.configuration.instance.absoluteString ?? "")
        _environment = State(initialValue: existing?.configuration.environmentID ?? model.environments.first?.id)
        _enabled = State(initialValue: existing?.configuration.enabled ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(existing == nil ? "New Jira Connection" : "Edit Jira Connection").font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Save Configuration") { save() }.disabled(model.busy || environment == nil)
                    .accessibilityIdentifier("connection.save")
            }
            Text(model.project.name).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("connection.editor.error") }
            Form {
                TextField("Jira site", text: $instance, prompt: Text("https://your-site.atlassian.net"))
                    .accessibilityIdentifier("connection.instance")
                Picker("Environment", selection: $environment) {
                    ForEach(model.environments) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(existing != nil).accessibilityIdentifier("connection.environment")
                Toggle("Enabled", isOn: $enabled).accessibilityIdentifier("connection.enabled")
                Text("Saving creates a new local configuration version. Authentication and runtime permissions remain separate.")
                    .font(.callout).foregroundStyle(.secondary)
            }.formStyle(.grouped)
        }.padding(20).macEditorLayout(idealWidth: 700, idealHeight: 480)
        .interactiveDismissDisabled(model.busy)
    }
    private func save() {
        guard let environment else { return }
        error = nil
        Task {
            do { try await model.save(instance: instance, environment: environment, enabled: enabled, existing: existing); dismiss() }
            catch PluginConfigurationError.invalidEndpoint { error = "Enter an HTTPS Jira site address without a path, credentials, query or fragment." }
            catch PluginConfigurationError.credentialScopeMismatch { error = "This site has a saved credential reference. Disconnect it before changing the site." }
            catch { self.error = "Configuration could not be saved. Refresh the connections and check the project environment before retrying." }
        }
    }
}
#endif
