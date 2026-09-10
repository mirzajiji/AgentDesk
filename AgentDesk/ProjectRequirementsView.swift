#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ProjectRequirementsView: View {
    @StateObject private var model: ProjectRequirementsModel
    @State private var editor: EditorRequest?
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, open: @escaping () async throws -> NativeRequirementServices) {
        _model = StateObject(wrappedValue: ProjectRequirementsModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Requirements").font(.title2).bold()
                    Text(model.project.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Requirement") { editor = EditorRequest() }
                    .disabled(model.services == nil || model.errorMessage != nil).accessibilityIdentifier("requirements.create")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("requirements.done")
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("requirements.error")
            }
            if let issue = model.services?.environmentIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Latest published versions · drafts and retired requirements included").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.load(); if let id = model.selectedID { await model.select(id) } } }
                    .disabled(model.isLoading).accessibilityIdentifier("requirements.refresh")
            }
            if model.isLoading && model.records.isEmpty {
                ProgressView("Opening requirements…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.records.isEmpty && model.errorMessage != nil {
                ContentUnavailableView("Requirements unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Check project storage and refresh to try again."))
            } else if model.records.isEmpty {
                ContentUnavailableView("No requirements yet", systemImage: "doc.text", description: Text("Create a requirement and review its first version. Later changes preserve this history."))
                    .accessibilityIdentifier("requirements.empty")
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { id in
                    if let id { Task { await model.select(id) } }
                })) {
                    ForEach(model.records, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.id) · v\(record.version) · \(record.content.status.rawValue)").font(.headline)
                            Text(record.content.description).lineLimit(1).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .tag(record.id).accessibilityElement(children: .combine)
                            .accessibilityIdentifier("requirement.row.\(record.id)")
                    }
                    if model.more { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.isLoading) }
                }.frame(minHeight: 100, idealHeight: 160, maxHeight: 200)
                Divider()
                if model.isSelecting { ProgressView("Opening versions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let version = model.displayed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack { versionPicker; Spacer(); editButton }
                                VStack(alignment: .leading) { versionPicker; editButton }
                            }
                            Text("Latest published: v\(model.history.first?.version ?? version.version)")
                            Text(model.active.map { "Active version: v\($0.version)" } ?? "No active version")
                                .accessibilityIdentifier("requirements.active")
                            Text("Viewing v\(version.version) · \(version.content.status.rawValue)").font(.headline)
                                .accessibilityIdentifier("requirements.viewing")
                            Text(version.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            ForEach((try? version.content.changes(from: nil)) ?? []) { field in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(field.field).font(.headline)
                                    Text(verbatim: field.after).textSelection(.enabled)
                                        .accessibilityIdentifier("requirement.detail.\(field.field)")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }.accessibilityIdentifier("requirements.detail.scroll")
                } else {
                    ContentUnavailableView("Select a requirement", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Inspect current behavior and earlier versions."))
                }
            }
        }
        .padding(20).macEditorLayout(idealWidth: 960, idealHeight: 640)
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .sheet(item: $editor) { request in
            if let services = model.services {
                RequirementEditorView(store: services.store, existing: request.existing, environments: services.environments) { version in
                    Task { await model.didPublish(version) }
                }
            }
        }
    }
    private var versionPicker: some View {
        Picker("Version", selection: $model.selectedVersion) {
            ForEach(model.history, id: \.version) { version in
                Text("v\(version.version) · \(version.content.status.rawValue)").tag(Optional(version.version))
            }
        }.accessibilityIdentifier("requirements.version")
    }
    private var editButton: some View {
        Button("Edit Latest Version") { editor = EditorRequest(existing: model.history.first) }
            .accessibilityIdentifier("requirement.edit.latest")
    }
    private struct EditorRequest: Identifiable {
        let id = UUID()
        var existing: RequirementVersion?
    }
}
#endif
