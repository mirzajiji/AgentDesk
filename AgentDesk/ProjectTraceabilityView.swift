#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskSecurity
import SwiftUI

struct ProjectTraceabilityView: View {
    @StateObject private var model: ProjectTraceabilityModel
    @State private var editor: TraceEditorRequest?
    @State private var bugEditor: ImpactBugEditorRequest?
    @State private var impactRequirement = ""
    @State private var availableHeight: CGFloat = 640
    @Environment(\.dismiss) private var dismiss
    init(project: ProjectRecord, open: @escaping () async throws -> NativeTraceabilityServices) {
        _model = StateObject(wrappedValue: ProjectTraceabilityModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) { Text("Traceability & Impact").font(.title2).bold(); Text(model.project.name).foregroundStyle(.secondary) }
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
                Button("New Links") { editor = .init() }.disabled(model.services == nil || model.error != nil).accessibilityIdentifier("trace.create")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("trace.done")
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("trace.error") }
            if let issue = model.services?.environmentIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            TextField("Search title, subject or requirement", text: $model.filter.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("trace.search")
            ViewThatFits(in: .horizontal) { HStack { filters }; VStack(alignment: .leading) { filters } }
            HStack {
                TextField("Requirement ID for impact", text: $impactRequirement).accessibilityIdentifier("trace.impact.requirement")
                Button("Inspect Impact") {
                    if let id = RequirementID(rawValue: impactRequirement.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Task { await model.loadImpact(id) }
                    }
                }.disabled(model.services == nil || model.loadingImpact || RequirementID(rawValue: impactRequirement.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    .accessibilityIdentifier("trace.impact.inspect")
            }
            HSplitView {
                VStack {
                    if model.loading && model.records.isEmpty { ProgressView("Opening links…") }
                    else if model.records.isEmpty {
                        ContentUnavailableView("No matching links", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Link a subject to its requirements or adjust the filters."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: Binding(get: { model.selectedSubject }, set: { if let subject = $0 { model.selectFromUI(subject) } })) {
                            ForEach(model.records, id: \.subject) { record in
                                VStack(alignment: .leading) {
                                    Text(safe(record.title, environment: record.environment)).font(.headline)
                                    Text("\(record.subject.kind.traceTitle) · r\(record.revision)\(record.archived ? " · archived" : "")").font(.caption)
                                }.tag(record.subject).accessibilityIdentifier("trace.row.\(record.subject.kind.rawValue).\(record.subject.id)")
                            }
                        }
                    }
                    if model.more { Button("Load More") { Task { await model.load(more: true) } }.disabled(model.loading) }
                }.frame(minWidth: 210, idealWidth: 280)
                detail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        .macEditorLayout(idealWidth: 1100, idealHeight: 640)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .task(id: model.filter) { do { try await Task.sleep(for: .milliseconds(150)); await model.load() } catch { } }
        .onDisappear { model.cancel() }
        .sheet(item: $editor) { request in
            if let services = model.services {
                TraceabilityEditorView(services: services, existing: request.existing) { record in Task { await model.didPublish(record) } }
                    .frame(height: max(480, min(640, availableHeight - 24)))
            }
        }
        .sheet(item: $bugEditor) { request in
            if let services = model.services {
                BugEditorView(store: services.bugs, existing: request.record, environments: services.environments) { _ in
                    Task { await model.loadImpact(request.requirement) }
                }.frame(height: max(480, min(640, availableHeight - 24)))
            }
        }
    }
    @ViewBuilder private var filters: some View {
        Picker("Kind", selection: $model.filter.kind) {
            Text("All kinds").tag(TraceabilitySubject.Kind?.none)
            ForEach(TraceabilitySubject.Kind.allCases, id: \.self) { Text($0.traceTitle).tag(Optional($0)) }
        }
        Picker("Environment", selection: $model.filter.environment) {
            Text("All environments").tag(EnvironmentID?.none)
            ForEach(model.services?.environments ?? []) { Text($0.name).tag(Optional($0.id)) }
        }
        Toggle("Include archived", isOn: $model.filter.includeArchived).accessibilityIdentifier("trace.filter.archived")
    }
    @ViewBuilder private var detail: some View {
        if model.selecting { ProgressView("Resolving requirements…") }
        else if let record = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(safe(record.title, environment: record.environment)).font(.title2).bold().accessibilityIdentifier("trace.detail.title")
                    Text("\(record.subject.kind.traceTitle): \(record.subject.id) · revision \(record.revision)")
                    Text("Environment: \(record.environment)\(record.archived ? " · archived links" : "")")
                    Button("Edit Links") { editor = .init(existing: record) }.accessibilityIdentifier("trace.edit")
                    Toggle("Inspect recorded historical versions", isOn: $model.historical).accessibilityIdentifier("trace.inspect.historical")
                    Text(model.historical ? "Explicit historical inspection. These are the versions recorded with the links." : "Current active requirements for normal reruns. Missing or retired behavior is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.references) { reference in
                        GroupBox(reference.id.rawValue) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recorded v\(reference.linked.version) · \(reference.status.traceTitle)").accessibilityIdentifier("trace.status.\(reference.id)")
                                if let version = model.historical ? reference.recorded : reference.current {
                                    Text("Viewing requirement v\(version.version)").bold().accessibilityIdentifier("trace.viewing.\(reference.id)")
                                    if let fields = requirementFields(version, environment: record.environment) {
                                        ForEach(fields) { field in
                                            VStack(alignment: .leading) { Text(field.field).font(.headline); Text(verbatim: field.after).textSelection(.enabled) }
                                        }
                                    } else { Text("Requirement content could not be safely displayed.").foregroundStyle(.orange) }
                                } else { Text("No applicable active version").foregroundStyle(.orange) }
                                Button("Inspect Impact") { Task { await model.loadImpact(reference.id) } }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    impactDetails
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.accessibilityIdentifier("trace.detail.scroll")
        } else if model.impact != nil || model.loadingImpact || model.impactError != nil {
            ScrollView { VStack(alignment: .leading, spacing: 12) { impactDetails }.frame(maxWidth: .infinity, alignment: .leading).padding(12) }
        } else {
            ContentUnavailableView("Select linked work", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Inspect current requirements, recorded versions and impact."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var impactDetails: some View {
        if model.loadingImpact { ProgressView("Loading impact…") }
        if let error = model.impactError { Text(error).foregroundStyle(.orange) }
        if let report = model.impact {
            Text("Impact of \(report.requirement)").font(.headline)
            Text("Current nonarchived link records across this project; stale means review is needed, not that a test was executed or failed.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(report.links.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading) {
                    Button(safe(item.record.title, environment: item.record.environment)) { model.selectFromUI(item.record.subject) }
                    Text("\(item.record.subject.kind.traceTitle) · \(item.status.traceTitle) · environment \(item.record.environment)")
                }
            }
            if report.links.isEmpty { Text("No active linked subjects.") }
        }
        if let report = model.bugImpact {
            Text("Bug Registry associations").font(.headline)
            ForEach(Array(report.links.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading) {
                    Text(safe(item.record.content.title, environment: item.record.content.environment ?? EnvironmentID())).bold()
                    Button("Review Bug") { bugEditor = .init(record: item.record, requirement: report.requirement) }
                        .accessibilityIdentifier("trace.impact.bug.\(item.record.id)")
                    Text("Bug \(item.record.id) · \(item.linked.role.rawValue) · recorded v\(item.linked.requirement.version) · \(item.status.traceTitle)")
                }
            }
            if report.links.isEmpty { Text("No nonarchived bugs associated with this requirement.") }
        }
    }
    private func safe(_ text: String, environment: EnvironmentID) -> String {
        (try? TraceabilityEditorModel.safeText(text, scope: model.project.scope, environment: environment).text) ?? "Unavailable content"
    }
    private func requirementFields(_ version: RequirementVersion, environment: EnvironmentID) -> [RequirementChange]? {
        do {
            let context = RedactionContext(scope: model.project.scope, environmentID: environment, runID: RunID())
            let bytes = try JSONEncoder().encode(version.content)
            let safe = try ContentRedactor(context: context).redactJSON(String(decoding: bytes, as: UTF8.self), in: context)
            return try ConfigurationJSON.decode(RequirementDraft.self, from: Data(safe.text.utf8)).changes(from: nil)
        } catch { return nil }
    }
}
private struct ImpactBugEditorRequest: Identifiable { let id = UUID(); let record: BugRecord; let requirement: RequirementID }
private struct TraceEditorRequest: Identifiable { let id = UUID(); var existing: RequirementTraceRecord? = nil }
extension RequirementImpact.Status {
    var traceTitle: String { switch self { case .current: "Current"; case .potentiallyStale: "Potentially stale"; case .unavailable: "Unavailable" } }
}
#endif
