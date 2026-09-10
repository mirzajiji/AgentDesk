#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct MemoryEditorView: View {
    @StateObject private var model: MemoryEditorModel
    let environments: [ProjectEnvironment]
    let onPublish: (MemoryRecord) -> Void
    @State private var tags = ""
    @State private var path = ""
    @State private var fieldError: String?
    @State private var advanced = false
    @Environment(\.dismiss) private var dismiss
    init(store: ProjectMemoryStore, existing: MemoryRecord?, kind: MemoryKind = .note,
         environments: [ProjectEnvironment], onPublish: @escaping (MemoryRecord) -> Void) {
        _model = StateObject(wrappedValue: MemoryEditorModel(store: store, existing: existing, kind: kind))
        self.environments = environments; self.onPublish = onPublish
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.proposal == nil ? (model.isNew ? "New Memory" : "Edit Memory") : "Review Memory Changes")
                .font(.title2).bold().accessibilityIdentifier("memory.editor.title")
            if let error = fieldError ?? model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("memory.editor.error") }
            if model.redacted { Text("Sensitive content was masked. Review the sanitized version before saving.").font(.callout).foregroundStyle(.orange) }
            if let proposal = model.proposal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Proposed version \(proposal.candidate.revision)").bold().accessibilityIdentifier("memory.proposed.version")
                        Text("Publishing keeps earlier versions and preserves the reviewed source labels. Confirmation changes authority; it does not turn an interpretation into an observation.")
                        ForEach(model.changes) { change in
                            GroupBox(change.field) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let before = change.before {
                                        Text("Before").font(.caption).foregroundStyle(.secondary)
                                        Text(verbatim: before).textSelection(.enabled)
                                        Divider()
                                    }
                                    Text("After").font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: change.after).textSelection(.enabled)
                                        .accessibilityIdentifier("memory.change.\(change.field)")
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            } else {
                TabView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Title", text: $model.draft.title).accessibilityIdentifier("memory.title")
                            Picker("Kind", selection: $model.draft.kind) {
                                ForEach(MemoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }.accessibilityIdentifier("memory.kind")
                            Picker("Topic", selection: $model.draft.topic) {
                                ForEach(MemoryTopic.allCases, id: \.self) { Text($0.memoryTitle).tag($0) }
                            }.accessibilityIdentifier("memory.topic")
                            Text("Content").font(.headline)
                            MacPlainTextEditor(text: $model.draft.body, label: "Memory content", identifier: "memory.body")
                                .frame(height: 240)
                            TextField("Tags, separated by commas", text: $tags).accessibilityIdentifier("memory.tags")
                            TextField("Logical path (optional)", text: $path).accessibilityIdentifier("memory.path")
                            Picker("Status", selection: $model.draft.disposition) {
                                Text("Active").tag(MemoryDisposition.active)
                                Text("Archived").tag(MemoryDisposition.archived)
                                if model.draft.kind == .inbox || model.draft.disposition == .ignored { Text("Ignored").tag(MemoryDisposition.ignored) }
                            }.accessibilityIdentifier("memory.disposition")
                            TextField("Reason for this version", text: $model.draft.changeReason).accessibilityIdentifier("memory.reason")
                            Text("Confirmed knowledge needs a topic. Notes and inbox entries remain nonauthoritative until explicitly reviewed and confirmed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding()
                    }.accessibilityIdentifier("memory.editor.scroll").tabItem { Text("Content") }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Environment scope").font(.headline)
                            Text("No selected environments means this memory applies throughout this project.")
                            ForEach(environments) { environment in
                                Toggle(environment.name, isOn: Binding(get: { model.draft.environmentScope.contains(environment.id) }, set: { enabled in
                                    model.draft.environmentScope.removeAll { $0 == environment.id }
                                    if enabled { model.draft.environmentScope.append(environment.id) }
                                }))
                            }
                            ForEach(model.draft.environmentScope.filter { id in !environments.contains { $0.id == id } }, id: \.self) { id in
                                Text("Stored environment: \(id). Its setup is unavailable; the selection is preserved.").foregroundStyle(.orange)
                            }
                            Text("Sources").font(.headline)
                            ForEach(Array(model.draft.sources.enumerated()), id: \.offset) { _, source in
                                GroupBox(source.label) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(source.origin.rawValue)
                                        if let reference = source.reference { Text(reference).textSelection(.enabled) }
                                        if let environment = source.environment { Text("Environment: \(environment)") }
                                        if let run = source.run { Text("Run: \(run)") }
                                        if let agent = source.agent { Text("Agent: \(agent)") }
                                        Text(source.capturedAt.formatted())
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Text("Use Structured Fields to edit source metadata or structured content. Source scopes are validated against this project.")
                            Button("Structured Fields") { advanced = true }.accessibilityIdentifier("memory.advanced")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.tabItem { Text("Scope & Sources") }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("memory.cancel")
                Spacer()
                if model.proposal != nil {
                    Button("Back to Editing") { Task { await model.cancelReview() } }.accessibilityIdentifier("memory.review.back")
                    Button("Publish Version") { Task { if let saved = await model.publish() { onPublish(saved); dismiss() } } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("memory.publish")
                } else {
                    Button("Review Changes") { prepare() }.buttonStyle(.borderedProminent).accessibilityIdentifier("memory.review")
                }
            }.disabled(model.busy)
        }
        .textFieldStyle(.roundedBorder).padding(20).macEditorLayout(idealWidth: 820, idealHeight: 680)
        .interactiveDismissDisabled(model.busy)
        .onAppear { syncFields() }
        .sheet(isPresented: $advanced, onDismiss: { syncFields() }) { MemoryJSONEditor(model: model) }
        .onDisappear { Task { await model.cancelReview() } }
    }
    private func syncFields() { tags = model.draft.tags.joined(separator: ", "); path = model.draft.knowledgePath?.rawValue ?? "" }
    private func prepare() {
        fieldError = nil
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { model.draft.knowledgePath = nil }
        else if let value = KnowledgePath(rawValue: path) { model.draft.knowledgePath = value }
        else { fieldError = "Use a relative logical path with valid names and no traversal."; return }
        model.draft.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        Task { await model.prepare() }
    }
}

struct MemoryJSONEditor: View {
    @ObservedObject var model: MemoryEditorModel
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Memory Structured Fields").font(.title2).bold()
            Text("Apply validates this draft. Publication still requires a separate review. Keep secrets in Keychain, using references here.")
            MacPlainTextEditor(text: $text, label: "Memory JSON", identifier: "memory.json")
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Apply to Draft") {
                    do { try model.applyJSON(text); dismiss() } catch { self.error = MemoryEditorModel.message(error) }
                }.accessibilityIdentifier("memory.json.apply")
            }
        }.padding(20).macEditorLayout(idealWidth: 820, idealHeight: 640)
        .onAppear { do { text = try model.json() } catch { self.error = MemoryEditorModel.message(error) } }
    }
}
extension MemoryTopic {
    var memoryTitle: String {
        switch self {
        case .projectDescription: "Project description"
        case .businessRule: "Business rule"
        case .apiBehavior: "API behavior"
        case .stateTransition: "State transition"
        case .environmentRule: "Environment rule"
        case .testExpectation: "Test expectation"
        case .architecture: "Architecture"
        case .qaDecision: "QA decision"
        case .discoveredBehavior: "Discovered behavior"
        case .terminology: "Terminology"
        case .documentation: "Documentation"
        case .unclassified: "Unclassified"
        }
    }
}
#endif
