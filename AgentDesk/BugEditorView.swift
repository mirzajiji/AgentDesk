#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct BugEditorView: View {
    @StateObject private var model: BugEditorModel
    let environments: [ProjectEnvironment]
    let onPublish: (BugRecord) -> Void
    @State private var ticketKey = ""
    @State private var ticketURL = ""
    @State private var target = ""
    @State private var sourceLabel = ""
    @State private var relationship = BugRelationship.Kind.relatedTo
    @State private var sourceOrigin = MemorySource.Origin.humanStatement
    @State private var fieldError: String?
    @State private var advanced = false
    @State private var availableHeight: CGFloat = 640
    @State private var coverageKind = TraceabilitySubject.Kind.automatedTest
    @State private var coverageIdentifier = ""
    @Environment(\.dismiss) private var dismiss
    init(store: ProjectBugStore, existing: BugRecord?, environments: [ProjectEnvironment], onPublish: @escaping (BugRecord) -> Void) {
        _model = StateObject(wrappedValue: BugEditorModel(store: store, existing: existing))
        self.environments = environments; self.onPublish = onPublish
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.proposal != nil ? "Review Bug Changes" : model.existing == nil ? "New Bug" : "Edit Bug")
                .font(.title2).bold().accessibilityIdentifier("bug.editor.title")
            if let error = fieldError ?? model.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("bug.editor.error") }
            if model.redacted { Text("Sensitive content was masked. Review the sanitized changes.").foregroundStyle(.orange).font(.callout) }
            if let proposal = model.proposal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Proposed version \(proposal.candidate.revision)").bold().accessibilityIdentifier("bug.proposed.version")
                        Text("Publishing saves this local registry version. A ticket association is a supplied reference; it does not verify or update a remote issue.")
                        ForEach(model.fields) { field in
                            GroupBox(field.title) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let before = field.before { Text("Before").font(.caption).foregroundStyle(.secondary); Text(verbatim: before).textSelection(.enabled); Divider() }
                                    Text("After").font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: field.after).textSelection(.enabled).accessibilityIdentifier("bug.change.\(field.id)")
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            } else {
                TabView {
                    ScrollView { behavior.padding() }.accessibilityIdentifier("bug.behavior.scroll").tabItem { Text("Behavior") }
                    ScrollView { links.padding() }.accessibilityIdentifier("bug.links.scroll").tabItem { Text("Ticket & Links") }
                    ScrollView { sources.padding() }.accessibilityIdentifier("bug.sources.scroll").tabItem { Text("Sources & Details") }
                }
                TextField("Reason for this version", text: $model.draft.changeReason).accessibilityIdentifier("bug.reason")
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("bug.cancel")
                Spacer()
                if model.proposal != nil {
                    Button("Back to Editing") { Task { await model.cancelReview() } }.accessibilityIdentifier("bug.review.back")
                    Button("Publish Version") { Task { if let saved = await model.publish() { onPublish(saved); dismiss() } } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("bug.publish")
                } else {
                    Button("Structured Fields") { advanced = true }.accessibilityIdentifier("bug.advanced")
                    Button("Review Changes") { prepare() }.buttonStyle(.borderedProminent).accessibilityIdentifier("bug.review")
                }
            }.disabled(model.busy)
        }.textFieldStyle(.roundedBorder).padding(20).macEditorLayout(idealWidth: 880, idealHeight: 640)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .interactiveDismissDisabled(model.busy)
        .onAppear { syncTicket() }
        .sheet(isPresented: $advanced, onDismiss: { syncTicket() }) {
            BugJSONEditor(model: model).frame(height: max(480, min(640, availableHeight - 24)))
        }
        .onDisappear { Task { await model.cancelReview() } }
    }
    private var behavior: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $model.draft.title).accessibilityIdentifier("bug.title")
            Picker("Origin", selection: $model.draft.origin) {
                ForEach(BugOrigin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.accessibilityIdentifier("bug.origin")
            Picker("Assessment", selection: $model.draft.assessment) {
                ForEach(BugAssessment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.accessibilityIdentifier("bug.assessment")
            Text("Reported means unverified. Observed requires source provenance and complete behavior. Blocked means an upstream bug prevented verification.").font(.caption).foregroundStyle(.secondary)
            Picker("Status", selection: $model.draft.status) {
                ForEach(BugStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.accessibilityIdentifier("bug.status")
            Picker("Environment", selection: $model.draft.environment) {
                Text("Unspecified").tag(EnvironmentID?.none)
                ForEach(environments) { Text($0.name).tag(Optional($0.id)) }
                if let id = model.draft.environment, !environments.contains(where: { $0.id == id }) {
                    Text("Stored environment: \(id)").tag(Optional(id))
                }
            }.accessibilityIdentifier("bug.environment")
            textEditor("Root behavior", text: $model.draft.rootBehavior, id: "bug.root")
            textEditor("Expected behavior", text: $model.draft.expectedBehavior, id: "bug.expected")
            textEditor("Actual behavior", text: $model.draft.actualBehavior, id: "bug.actual")
            Text("Reproduction steps").font(.headline)
            ForEach(model.draft.reproduction.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    HStack { Text("Step \(index + 1)"); Spacer(); Button("Remove Step") { model.draft.reproduction.remove(at: index) } }
                    MacPlainTextEditor(text: Binding(get: { model.draft.reproduction.indices.contains(index) ? model.draft.reproduction[index] : "" },
                        set: { if model.draft.reproduction.indices.contains(index) { model.draft.reproduction[index] = $0 } }),
                        label: "Step \(index + 1)", identifier: "bug.step.\(index)").frame(height: 80)
                }
            }
            Button("Add Step") { model.draft.reproduction.append("") }.disabled(model.draft.reproduction.count >= 128)
        }
    }
    private var links: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual ticket association").font(.headline)
            TextField("Ticket key (optional)", text: $ticketKey).accessibilityIdentifier("bug.ticket.key")
            TextField("HTTPS ticket URL (optional)", text: $ticketURL).accessibilityIdentifier("bug.ticket.url")
            Text("Supply a key, URL or both. Clear both to unlink in a new version. No remote request is sent.").font(.caption).foregroundStyle(.secondary)
            Divider(); Text("Bug relationships").font(.headline)
            ForEach(model.draft.relationships, id: \.self) { link in
                HStack {
                    Text("\(link.kind.title): \(link.target)").textSelection(.enabled)
                    Spacer(); Button("Remove") { model.draft.relationships.removeAll { $0 == link } }
                }
            }
            Picker("Relationship", selection: $relationship) {
                ForEach(BugRelationship.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("bug.relationship.kind")
            TextField("Target bug UUID", text: $target).accessibilityIdentifier("bug.relationship.target")
            Button("Add Relationship") {
                guard let id = BugID(rawValue: target.trimmingCharacters(in: .whitespacesAndNewlines)) else { fieldError = "Enter a valid bug UUID from this project."; return }
                let link = BugRelationship(kind: relationship, target: id)
                guard !model.draft.relationships.contains(link), model.draft.relationships.count < 64 else { fieldError = "This relationship already exists or the limit was reached."; return }
                model.draft.relationships.append(link); target = ""; fieldError = nil
            }.accessibilityIdentifier("bug.relationship.add")
            Text("Targets must already exist in this project. Review validates scope, self-links and directed cycles.").font(.caption).foregroundStyle(.secondary)
            if let existing = model.existing, !existing.requirements.isEmpty {
                Text("Preserved requirement references").font(.headline)
                ForEach(Array(existing.requirements.enumerated()), id: \.offset) { _, reference in
                    Text("\(reference.role.rawValue): \(reference.requirement.id) · v\(reference.requirement.version)")
                }
            }
            Toggle("Edit requirement associations", isOn: $model.editRequirementLinks).accessibilityIdentifier("bug.requirements.edit")
            if model.editRequirementLinks {
                RequirementLinksEditor(links: $model.requirementLinks, showsRole: true)
                Text("Review resolves the selected versions. Removing every link explicitly clears the associations.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Existing requirement references remain unchanged.").font(.caption).foregroundStyle(.secondary) }
            Divider(); Text("Coverage subjects").font(.headline)
            ForEach(model.draft.coveredBy, id: \.self) { subject in
                HStack {
                    Text("\(subject.kind.traceTitle): \(subject.id)")
                    Spacer(); Button("Remove Coverage") { model.draft.coveredBy.removeAll { $0 == subject } }
                }
            }
            Picker("Test kind", selection: $coverageKind) {
                Text("Automated test").tag(TraceabilitySubject.Kind.automatedTest)
                Text("Manual test").tag(TraceabilitySubject.Kind.manualTest)
            }
            TextField("Test identifier", text: $coverageIdentifier).accessibilityIdentifier("bug.coverage.id")
            Button("Add Coverage Subject") {
                guard let id = RequirementID(rawValue: coverageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    fieldError = "Enter a valid test identifier."; return
                }
                let subject = TraceabilitySubject(kind: coverageKind, id: id)
                guard !model.draft.coveredBy.contains(subject), model.draft.coveredBy.count < 64 else { fieldError = "This test is already linked or the limit was reached."; return }
                model.draft.coveredBy.append(subject); coverageIdentifier = ""; fieldError = nil
            }.accessibilityIdentifier("bug.coverage.add")
            Text("Coverage subjects are references to tests. Linking one does not claim it ran or passed.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source provenance").font(.headline)
            Text("These are supplied declarations. Recording an observation does not independently verify an artifact or execute a test.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.draft.sources.enumerated()), id: \.offset) { index, source in
                GroupBox(source.label) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.origin.rawValue); Text(source.capturedAt.formatted())
                        if let reference = source.reference { Text(reference).textSelection(.enabled) }
                        if let environment = source.environment { Text("Environment: \(environment)") }
                        if let run = source.run { Text("Run: \(run)") }
                        if let agent = source.agent { Text("Agent: \(agent)") }
                        Button("Remove Source") { model.draft.sources.remove(at: index) }.disabled(model.draft.sources.count <= 1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            TextField("New source label", text: $sourceLabel).accessibilityIdentifier("bug.source.label")
            Picker("Source origin", selection: $sourceOrigin) {
                Text("Human statement").tag(MemorySource.Origin.humanStatement)
                Text("Observed (user-attested)").tag(MemorySource.Origin.observed)
                Text("Interpretation").tag(MemorySource.Origin.interpretation)
            }.accessibilityIdentifier("bug.source.origin")
            Button("Add Local Source") {
                guard !sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fieldError = "Give the source a label."; return }
                model.draft.sources.append(.init(scope: model.store.scope, origin: sourceOrigin, label: sourceLabel,
                    environment: model.draft.environment, capturedAt: Date()))
                sourceLabel = ""; fieldError = nil
            }.disabled(model.draft.sources.count >= 32).accessibilityIdentifier("bug.source.add")
            Text("Structured Fields includes endpoint/component details, exact evidence references and coverage subjects. Sources and evidence remain project/environment scoped.").font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func textEditor(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.headline); MacPlainTextEditor(text: text, label: title, identifier: id).frame(height: 100) }
    }
    private func syncTicket() { ticketKey = model.draft.ticket?.key ?? ""; ticketURL = model.draft.ticket?.url ?? "" }
    private func prepare() {
        fieldError = nil
        let key = ticketKey.trimmingCharacters(in: .whitespacesAndNewlines), url = ticketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do { model.draft.ticket = key.isEmpty && url.isEmpty ? nil : try ExternalBugTicket(key: key.isEmpty ? nil : key, url: url.isEmpty ? nil : url) }
        catch { fieldError = "Use a valid uppercase ticket key or HTTPS URL without credentials, query or fragment."; return }
        Task { await model.prepare() }
    }
}

struct BugJSONEditor: View {
    @ObservedObject var model: BugEditorModel
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bug Structured Fields").font(.title2).bold()
            Text("Apply validates the draft; publication still requires review. Preserve source scope and exact evidence identity. Previous comparison decisions cannot be edited here.")
            MacPlainTextEditor(text: $text, label: "Bug JSON", identifier: "bug.json")
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("bug.json.error") }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Apply to Draft") { do { try model.applyJSON(text); dismiss() } catch { self.error = BugEditorModel.message(error) } }
                    .accessibilityIdentifier("bug.json.apply")
            }
        }.padding(20).macEditorLayout(idealWidth: 860, idealHeight: 640)
        .onAppear { do { text = try model.json() } catch { self.error = BugEditorModel.message(error) } }
    }
}
#endif
