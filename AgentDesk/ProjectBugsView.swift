#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ProjectBugsView: View {
    @StateObject private var model: ProjectBugsModel
    @State private var editor: BugEditorRequest?
    @State private var comparison: BugComparisonRequest?
    private let openReview: (() async throws -> ProjectNativeServices)?
    @State private var availableHeight: CGFloat = 640
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, openReview: (() async throws -> ProjectNativeServices)? = nil, open: @escaping () async throws -> NativeBugServices) {
        self.openReview = openReview
        _model = StateObject(wrappedValue: ProjectBugsModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Bug Registry").font(.title2).bold().accessibilityIdentifier("bugs.title")
                    Text(model.project.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
                Button("New Bug") { editor = .init() }.disabled(model.services == nil || model.error != nil).accessibilityIdentifier("bugs.create")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("bugs.done")
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("bugs.error") }
            if let issue = model.services?.environmentIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            TextField("Search title, behavior, details, ticket or UUID", text: $model.filter.query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("bugs.search")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { statusFilter; environmentFilter }
                GridRow { ticketFilter; archivedFilter }
            }
            .fixedSize(horizontal: false, vertical: true)
            HSplitView {
                VStack {
                    if model.loading && model.records.isEmpty { ProgressView("Opening registry…") }
                    else if model.records.isEmpty {
                        ContentUnavailableView(model.error == nil ? "No matching bugs" : "Registry unavailable", systemImage: "ladybug",
                            description: Text("Create a local report or adjust the filters."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.selectFromUI(id) } })) {
                            ForEach(model.records, id: \.id) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text((try? BugPresentation.sanitized(record.content, scope: model.project.scope).draft.title) ?? "Unavailable content").font(.headline)
                                    Text("\(record.content.assessment.rawValue.capitalized) · \(record.content.status.rawValue) · v\(record.revision)").font(.caption)
                                }.tag(record.id).accessibilityIdentifier("bug.row.\(record.id)")
                            }
                        }
                    }
                    if model.more { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.loading) }
                }.frame(minWidth: 210, idealWidth: 280)
                detail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        .macEditorLayout(idealWidth: 1080, idealHeight: 640)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .task(id: model.filter) { do { try await Task.sleep(for: .milliseconds(150)); await model.load() } catch { } }
        .onDisappear { model.cancel() }
        .sheet(item: $comparison) { request in
            if let openReview {
                BugDuplicateReviewView(project: model.project, incomingID: request.bug, open: openReview)
                    .frame(height: max(480, min(640, availableHeight - 24)))
            }
        }
        .sheet(item: $editor) { request in
            if let services = model.services {
                BugEditorView(store: services.store, existing: request.existing, environments: services.environments) { record in
                    Task { await model.didPublish(record) }
                }
                .frame(height: max(480, min(640, availableHeight - 24)))
            }
        }
    }
    private var statusFilter: some View {
        Picker("Status", selection: $model.filter.status) {
            Text("All statuses").tag(BugStatus?.none)
            ForEach(BugStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
        }.accessibilityIdentifier("bugs.filter.status")
    }
    private var environmentFilter: some View {
        Picker("Environment", selection: $model.filter.environment) {
            Text("All environments").tag(EnvironmentID?.none)
            ForEach(model.services?.environments ?? []) { Text($0.name).tag(Optional($0.id)) }
        }.accessibilityIdentifier("bugs.filter.environment")
    }
    private var ticketFilter: some View {
        Picker("Ticket", selection: $model.filter.registered) {
            Text("Any").tag(Bool?.none); Text("Linked").tag(Optional(true)); Text("Unlinked").tag(Optional(false))
        }.accessibilityIdentifier("bugs.filter.ticket")
    }
    private var archivedFilter: some View {
        Toggle("Include archived", isOn: $model.filter.includeArchived).disabled(model.filter.status != nil).accessibilityIdentifier("bugs.filter.archived")
    }
    @ViewBuilder private var detail: some View {
        if model.selecting { ProgressView("Opening bug…") }
        else if let record = model.displayed, let safe = try? BugPresentation.sanitized(record.content, scope: model.project.scope) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(safe.draft.title).font(.title2).bold().accessibilityIdentifier("bug.detail.title")
                    ViewThatFits(in: .horizontal) {
                        HStack { versionPicker; editButton }
                        VStack(alignment: .leading) { versionPicker; editButton }
                    }
                    Text(record.id.rawValue).font(.caption).textSelection(.enabled).accessibilityIdentifier("bug.detail.id")
                    Text("Viewing v\(record.revision) · \(safe.draft.status.rawValue) · \(safe.draft.assessment.rawValue)").accessibilityIdentifier("bug.detail.version")
                    if safe.changed { Text("Sensitive content is masked.").foregroundStyle(.orange) }
                    Text("Created \(record.createdAt.formatted()) · Updated \(record.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    ForEach((try? BugPresentation.fields(after: safe.draft)) ?? []) { field in
                        if !["title", "relationships"].contains(field.id),
                           field.id == "ticket" || !["", "[]", "{}", "None"].contains(field.after) {
                            GroupBox(field.title) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: field.after).textSelection(.enabled).accessibilityIdentifier("bug.detail.\(field.id)")
                                    if field.id == "ticket", let text = safe.draft.ticket?.url, let url = URL(string: text) {
                                        Link("Open Linked Ticket", destination: url)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                    }
                    Text("Links from this version").font(.headline)
                    if safe.draft.relationships.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(safe.draft.relationships, id: \.self) { link in
                        Button("\(link.kind.title): \(link.target)") { model.selectFromUI(link.target) }
                            .accessibilityIdentifier("bug.link.\(link.kind.rawValue).\(link.target)")
                    }
                    Text("Current incoming links").font(.headline)
                    Text("These links come from current registry versions, even while viewing this bug's history.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.incoming, id: \.id) { source in
                        ForEach(source.content.relationships.filter { $0.target == record.id }, id: \.self) { link in
                            Button("\(link.kind.inverseTitle): \(source.id)") { model.selectFromUI(source.id) }
                                .accessibilityIdentifier("bug.incoming.\(link.kind.rawValue).\(source.id)")
                        }
                    }
                    if model.moreIncoming { Button("Load More Incoming Links") { Task { await model.loadMoreIncoming() } }.disabled(model.loadingIncoming) }
                    if !record.requirements.isEmpty {
                        Text("Requirement references recorded with this version").font(.headline)
                        ForEach(Array(record.requirements.enumerated()), id: \.offset) { _, reference in
                            Text("\(reference.role.rawValue): \(reference.requirement.id) · v\(reference.requirement.version)\(reference.requirement.historical ? " · explicitly historical" : "")")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.accessibilityIdentifier("bug.detail.scroll")
        } else {
            ContentUnavailableView("Select a bug", systemImage: "ladybug", description: Text("Inspect supplied behavior, ticket associations and version history."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var versionPicker: some View {
        Picker("Version", selection: $model.selectedRevision) {
            ForEach(model.history, id: \.revision) { Text("v\($0.revision)").tag(Optional($0.revision)) }
        }.accessibilityIdentifier("bugs.version")
    }
    @ViewBuilder private var editButton: some View {
        if openReview != nil, let latest = model.history.first {
            Button("Review Duplicates") { comparison = .init(bug: latest.id) }.accessibilityIdentifier("bug.duplicates")
        }
        Button("Edit Latest Version") { editor = .init(existing: model.history.first) }.accessibilityIdentifier("bug.edit")
    }
}
private struct BugComparisonRequest: Identifiable { let id = UUID(); let bug: BugID }
private struct BugEditorRequest: Identifiable { let id = UUID(); var existing: BugRecord? = nil }
#endif
