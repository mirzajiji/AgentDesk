#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct RequirementEditorView: View {
    @StateObject private var model: RequirementEditorModel
    let environments: [ProjectEnvironment]
    let onPublish: (RequirementVersion) -> Void
    @State private var advanced = false
    @Environment(\.dismiss) private var dismiss

    init(store: ProjectRequirementStore, existing: RequirementVersion?, environments: [ProjectEnvironment],
         onPublish: @escaping (RequirementVersion) -> Void) {
        _model = StateObject(wrappedValue: RequirementEditorModel(store: store, existing: existing))
        self.environments = environments; self.onPublish = onPublish
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.proposal == nil ? "Edit requirement" : "Review requirement changes").font(.title2).bold()
            if let error = model.errorMessage { Text(error).foregroundStyle(.orange).accessibilityIdentifier("requirement.error") }
            ScrollView {
                if let proposal = model.proposal {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Current version: \(model.existing.map { "v\($0.version)" } ?? "New requirement")")
                        Text("Proposed version: v\(proposal.candidate.version)").bold().accessibilityIdentifier("requirement.proposed.version")
                        Text("\(proposal.candidate.id)").textSelection(.enabled)
                        Text("Creating this version preserves all earlier versions. The reviewed status determines whether it becomes active.")
                        ForEach(model.changes) { change in
                            GroupBox(change.field) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let before = change.before {
                                        Text("Before").font(.caption).foregroundStyle(.secondary)
                                        Text(verbatim: before).textSelection(.enabled)
                                    }
                                    Text("After").font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: change.after).textSelection(.enabled)
                                        .accessibilityIdentifier("requirement.change.\(change.field)")
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Requirement ID (lowercase words and hyphens)", text: $model.idText)
                            .disabled(model.existing != nil).accessibilityIdentifier("requirement.id")
                        Picker("Status", selection: $model.draft.status) {
                            Text("Draft").tag(RequirementStatus.draft)
                            Text("Active").tag(RequirementStatus.active)
                            Text("Retired").tag(RequirementStatus.retired)
                        }.accessibilityIdentifier("requirement.status")
                        Text("Drafts preserve the last active version. Retiring stops this requirement from resolving as active.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Description").font(.headline)
                        MacPlainTextEditor(text: $model.draft.description, label: "Description", identifier: "requirement.description").frame(height: 120)
                        Text("Change reason").font(.headline)
                        MacPlainTextEditor(text: $model.draft.changeReason, label: "Change reason", identifier: "requirement.reason").frame(height: 70)
                        GroupBox("Environment scope") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.draft.environmentScope.isEmpty ? "All project environments" : "Only selected environments")
                                ForEach(environments) { environment in
                                    Toggle(environment.name, isOn: Binding(get: { model.draft.environmentScope.contains(environment.id) }, set: { enabled in
                                        model.draft.environmentScope.removeAll { $0 == environment.id }
                                        if enabled { model.draft.environmentScope.append(environment.id) }
                                    })).accessibilityIdentifier("requirement.environment.\(environment.name)")
                                }
                                ForEach(model.draft.environmentScope.filter { id in !environments.contains { $0.id == id } }, id: \.self) { id in
                                    Text("Stored environment \(id) is not currently configured. Use Advanced JSON to change this reference.").font(.caption)
                                }
                                if environments.isEmpty { Text("Configure named environments in project Setup.").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        Button("Advanced JSON…") { advanced = true }.accessibilityIdentifier("requirement.json.open")
                        Text("Edit preconditions, rules, acceptance criteria, validation descriptions, structured expected behavior and references in Advanced JSON.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.isBusy)
                }
            }.accessibilityIdentifier("requirement.editor.scroll")
            HStack {
                Button("Cancel") { Task { await model.cancelReview(); dismiss() } }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("requirement.cancel")
                Spacer()
                if let proposal = model.proposal {
                    Button("Edit Changes") { Task { await model.cancelReview() } }.accessibilityIdentifier("requirement.edit.again")
                    Button("Create v\(proposal.candidate.version)") {
                        Task { if let saved = await model.publish() { onPublish(saved); dismiss() } }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("requirement.publish")
                } else {
                    Button("Review Changes") { Task { await model.prepare() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("requirement.review")
                }
            }.disabled(model.isBusy)
        }
        .padding(20).macEditorLayout(idealWidth: 820, idealHeight: 640)
        .interactiveDismissDisabled(model.isBusy)
        .sheet(isPresented: $advanced) { RequirementJSONEditor(model: model) }
        .onDisappear { Task { await model.cancelReview() } }
    }
}

struct RequirementJSONEditor: View {
    @ObservedObject var model: RequirementEditorModel
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Requirement JSON").font(.title2).bold()
            Text("Apply validates this draft. Publishing still requires a separate review.").font(.callout)
            MacPlainTextEditor(text: $text, label: "Requirement JSON", identifier: "requirement.json")
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("requirement.json.error") }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to Draft") {
                    do { try model.applyJSON(text); dismiss() }
                    catch { self.error = RequirementEditorModel.message(error) }
                }.accessibilityIdentifier("requirement.json.apply")
            }
        }.padding(20).macEditorLayout(idealWidth: 820, idealHeight: 620)
        .onAppear { do { text = try model.json() } catch { self.error = RequirementEditorModel.message(error) } }
    }
}
#endif
