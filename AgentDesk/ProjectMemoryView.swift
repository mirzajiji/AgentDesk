#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ProjectMemoryView: View {
    @StateObject private var model: ProjectMemoryModel
    @State private var editor: MemoryEditorRequest?
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, open: @escaping () async throws -> NativeMemoryServices) {
        _model = StateObject(wrappedValue: ProjectMemoryModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Project Memory").font(.title2).bold().accessibilityIdentifier("memory.browser.title")
                    Text(model.project.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
                Button("New Memory") { editor = .init() }.disabled(model.services == nil || model.error != nil)
                    .accessibilityIdentifier("memory.create")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("memory.done")
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("memory.error") }
            if let issue = model.services?.environmentIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            TextField("Search project memory", text: $model.filter.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("memory.search")
            ViewThatFits(in: .horizontal) {
                HStack { filters }
                VStack(alignment: .leading) { filters }
            }
            HSplitView {
                VStack {
                    if model.loading && model.records.isEmpty { ProgressView("Opening memory…") }
                    else if model.records.isEmpty {
                        ContentUnavailableView("No matching memory", systemImage: "brain", description: Text("Create a note or adjust the filters."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.selectFromUI(id) } })) {
                            ForEach(model.records, id: \.id) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((try? MemoryPresentation.sanitized(record.content, scope: model.project.scope).draft.title) ?? "Unavailable content").font(.headline)
                                    Text("\(record.content.kind.rawValue.capitalized) · v\(record.revision) · \(record.content.disposition.rawValue)").font(.caption)
                                }.tag(record.id).accessibilityIdentifier("memory.row.\(record.id)")
                            }
                        }
                    }
                    if model.more { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.loading) }
                }.frame(minWidth: 220, idealWidth: 280)
                detail.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        .macEditorLayout(idealWidth: 1000, idealHeight: 700)
        .task(id: model.filter) {
            do { try await Task.sleep(for: .milliseconds(150)); await model.load() } catch { }
        }
        .onDisappear { model.cancel() }
        .sheet(item: $editor) { request in
            if let services = model.services {
                MemoryEditorView(store: services.store, existing: request.existing, environments: services.environments) { record in
                    Task { await model.didPublish(record) }
                }
            }
        }
    }
    @ViewBuilder private var filters: some View {
        Picker("Kind", selection: $model.filter.kind) {
            Text("All kinds").tag(MemoryKind?.none)
            ForEach(MemoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
        }.accessibilityIdentifier("memory.filter.kind")
        Picker("Environment", selection: $model.filter.environment) {
            Text("All environments").tag(EnvironmentID?.none)
            ForEach(model.services?.environments ?? []) { Text($0.name).tag(Optional($0.id)) }
        }.accessibilityIdentifier("memory.filter.environment")
        Toggle("Include archived/ignored", isOn: $model.filter.includeInactive).accessibilityIdentifier("memory.filter.inactive")
    }
    @ViewBuilder private var detail: some View {
        if model.selecting { ProgressView("Opening history…") }
        else if let record = model.displayed, let safe = try? MemoryPresentation.sanitized(record.content, scope: model.project.scope) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("Version", selection: $model.selectedRevision) {
                            ForEach(model.history, id: \.revision) { Text("v\($0.revision)").tag(Optional($0.revision)) }
                        }.accessibilityIdentifier("memory.version")
                        Button("Edit Latest Version") { editor = .init(existing: model.history.first) }.accessibilityIdentifier("memory.edit")
                    }
                    Text(safe.draft.title).font(.title2).bold()
                    Text("\(safe.draft.kind.rawValue.capitalized) · \(safe.draft.topic.memoryTitle) · \(safe.draft.disposition.rawValue)")
                    if safe.changed { Text("Sensitive content is masked.").foregroundStyle(.orange) }
                    Text(verbatim: safe.draft.body).textSelection(.enabled).accessibilityIdentifier("memory.content")
                    if !safe.draft.tags.isEmpty { Text("Tags: \(safe.draft.tags.joined(separator: ", "))") }
                    if let path = safe.draft.knowledgePath { Text("Logical path: \(path.rawValue)") }
                    Text(safe.draft.environmentScope.isEmpty ? "All project environments" : "Environments: " + safe.draft.environmentScope.map(\.rawValue).joined(separator: ", "))
                    if !safe.draft.structured.isEmpty { GroupBox("Structured content") { Text(verbatim: (try? MemoryPresentation.json(safe.draft.structured)) ?? "Unavailable").textSelection(.enabled) } }
                    ForEach(Array(safe.draft.sources.enumerated()), id: \.offset) { _, source in
                        GroupBox("Source · \(source.origin.rawValue)") {
                            VStack(alignment: .leading) {
                                Text(source.label); if let reference = source.reference { Text(reference).textSelection(.enabled) }
                                if let environment = source.environment { Text("Environment: \(environment)") }
                                if let run = source.run { Text("Run: \(run)") }
                                if let agent = source.agent { Text("Agent: \(agent)") }
                                Text(source.capturedAt.formatted()).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Version reason: \(safe.draft.changeReason)").font(.callout)
                    Text("Created \(record.createdAt.formatted()) · Updated \(record.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } else {
            ContentUnavailableView("Select memory", systemImage: "doc.text.magnifyingglass", description: Text("Inspect its content, sources and immutable history."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
private struct MemoryEditorRequest: Identifiable { let id = UUID(); var existing: MemoryRecord? = nil }
#endif
