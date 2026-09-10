#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskSecurity
import SwiftUI

struct RequirementLinksEditor: View {
    @Binding var links: [NativeRequirementLink]
    var showsRole = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($links) { $link in
                GroupBox("Requirement link") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Requirement identifier", text: $link.requirement).accessibilityIdentifier("trace.link.id")
                        if showsRole {
                            Picker("Role", selection: $link.role) {
                                Text("Affects").tag(BugRequirementRequest.Role.affects)
                                Text("Introduced by").tag(BugRequirementRequest.Role.introducedBy)
                            }
                        }
                        Toggle("Use an explicit historical version", isOn: $link.historical).accessibilityIdentifier("trace.link.historical")
                        if link.historical {
                            TextField("Version number", text: $link.version).accessibilityIdentifier("trace.link.version")
                        } else { Text("Resolves the latest active version when reviewed.").font(.caption).foregroundStyle(.secondary) }
                        Button("Remove Link") { links.removeAll { $0.id == link.id } }
                    }.padding(6)
                }
            }
            Button("Add Requirement") { links.append(.init()) }.disabled(links.count >= 64).accessibilityIdentifier("trace.link.add")
        }
    }
}

struct TraceabilityEditorView: View {
    @StateObject private var model: TraceabilityEditorModel
    let onPublish: (RequirementTraceRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    init(services: NativeTraceabilityServices, existing: RequirementTraceRecord? = nil, onPublish: @escaping (RequirementTraceRecord) -> Void) {
        _model = StateObject(wrappedValue: TraceabilityEditorModel(services: services, existing: existing)); self.onPublish = onPublish
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.proposal == nil ? "Requirement Links" : "Review Requirement Links").font(.title2).bold()
                .accessibilityIdentifier("trace.editor.title")
            if let error = model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("trace.editor.error") }
            if model.redacted { Text("Sensitive text was masked before review.").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proposal = model.proposal {
                        Text("Proposed revision \(proposal.candidate.revision)").bold().accessibilityIdentifier("trace.proposed.revision")
                        if let previous = model.existing { summary(previous, label: "Before") }
                        summary(proposal.candidate, label: "After")
                        Text("Publication saves these exact links. Normal reruns still resolve current active requirements; historical reproduction must be selected explicitly.").font(.callout)
                    } else {
                        Picker("Subject kind", selection: $model.kind) {
                            ForEach(TraceabilitySubject.Kind.allCases, id: \.self) { Text($0.traceTitle).tag($0) }
                        }.disabled(model.existing != nil).accessibilityIdentifier("trace.kind")
                        TextField("Subject identifier", text: $model.identifier).disabled(model.existing != nil).accessibilityIdentifier("trace.subject")
                        Text(model.kind == .bug ? "Use an existing internal bug UUID from this project." : "This identifies a test, workflow or document; saving metadata does not execute or verify it.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Title", text: $model.title).accessibilityIdentifier("trace.title")
                        Picker("Environment", selection: $model.environment) {
                            Text("Choose environment").tag(EnvironmentID?.none)
                            ForEach(model.services.environments) { Text($0.name).tag(Optional($0.id)) }
                            if let environment = model.environment, !model.services.environments.contains(where: { $0.id == environment }) {
                                Text("Stored environment: \(environment)").tag(Optional(environment))
                            }
                        }.accessibilityIdentifier("trace.environment")
                        RequirementLinksEditor(links: $model.links)
                        Toggle("Archive this link record", isOn: $model.archived).accessibilityIdentifier("trace.archived")
                        TextField("Reason for this revision", text: $model.reason).accessibilityIdentifier("trace.reason")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.accessibilityIdentifier("trace.editor.scroll")
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("trace.cancel")
                Spacer()
                if model.proposal != nil {
                    Button("Back to Editing") { Task { await model.cancelReview() } }.accessibilityIdentifier("trace.review.back")
                    Button("Publish Links") { Task { if let record = await model.publish() { onPublish(record); dismiss() } } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("trace.publish")
                } else {
                    Button("Review Links") { Task { await model.prepare() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("trace.review")
                }
            }.disabled(model.busy)
        }.textFieldStyle(.roundedBorder).padding(20).macEditorLayout(idealWidth: 860, idealHeight: 640)
        .interactiveDismissDisabled(model.busy)
        .onDisappear { Task { await model.cancelReview() } }
    }
    private func summary(_ record: RequirementTraceRecord, label: String) -> some View {
        GroupBox(label) {
            VStack(alignment: .leading, spacing: 8) {
                Text((try? TraceabilityEditorModel.safeText(record.title, scope: record.scope, environment: record.environment).text) ?? "Unavailable title").bold()
                Text("\(record.subject.kind.traceTitle): \(record.subject.id)")
                Text("Environment: \(record.environment)")
                Text(record.archived ? "Archived" : "Active")
                ForEach(record.requirements, id: \.id) { link in
                    Text("\(link.id) · v\(link.version) · \(link.historical ? "explicitly historical" : "latest active at review")")
                        .accessibilityIdentifier("trace.review.\(label.lowercased()).link.\(link.id)")
                }
                Text((try? TraceabilityEditorModel.safeText(record.changeReason, scope: record.scope, environment: record.environment).text) ?? "Unavailable reason")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
extension TraceabilitySubject.Kind {
    var traceTitle: String {
        switch self {
        case .automatedTest: "Automated test"
        case .manualTest: "Manual test"
        case .bug: "Bug"
        case .documentation: "Documentation"
        case .workflow: "Workflow"
        }
    }
}
#endif
