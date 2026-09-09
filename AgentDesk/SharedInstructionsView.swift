#if os(macOS)
import AgentDeskCore
import SwiftUI

struct SharedInstructionsView: View {
    @StateObject private var model: SharedInstructionsModel
    @Environment(\.dismiss) private var dismiss

    init(store: ProjectInstructionStore, scope: ProjectScope) {
        _model = StateObject(wrappedValue: SharedInstructionsModel(store: store, scope: scope))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shared Instructions").font(.title2).bold()
                Spacer()
                Picker("Scope", selection: $model.level) {
                    ForEach(InstructionLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 240).accessibilityIdentifier("instructions.level")
                .disabled(model.hasUnsavedChanges)
                .help("Save or cancel changes before switching scope.")
            }
            Text(model.level == .workspace ? "Applies to every project in this workspace. Keep project-specific guidance in Project." : "Applies only to agents in this project.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack {
                    List(selection: $model.selectedID) {
                        ForEach(model.draft.documents) { document in
                            VStack(alignment: .leading) {
                                Text(document.title)
                                Text(model.draft.roots.contains(document.id) ? "Used directly" : "Reusable include")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(document.id)
                        }
                    }
                    HStack {
                        Button("Add", systemImage: "plus") { model.add() }.accessibilityIdentifier("instructions.add")
                            .disabled(model.draft.documents.count >= 64)
                        Button("Remove", systemImage: "minus") { model.removeSelected() }.disabled(model.selectedID == nil)
                    }
                }.frame(width: 200)
                if let index = model.draft.documents.firstIndex(where: { $0.id == model.selectedID }) {
                    let document = model.draft.documents[index]
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Title", text: $model.draft.documents[index].title).accessibilityIdentifier("instructions.title")
                        HStack {
                            Toggle("Use directly", isOn: Binding(get: { model.draft.roots.contains(document.id) },
                                set: { model.setRoot(document.id, enabled: $0) })).accessibilityIdentifier("instructions.root")
                            Spacer()
                            Menu("Includes (\(document.includes.count))") {
                                ForEach(model.draft.documents.filter { $0.id != document.id }) { other in
                                    Toggle(other.title, isOn: Binding(get: { document.includes.contains(other.id) },
                                        set: { model.setIncluded(other.id, in: document.id, enabled: $0) }))
                                }
                            }.disabled(model.draft.documents.count < 2)
                        }
                        TextEditor(text: $model.draft.documents[index].text)
                            .font(.system(.body, design: .monospaced)).accessibilityIdentifier("instructions.text")
                        Text("Includes appear before this file. Each file is included once per scope.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("No shared instructions", systemImage: "doc.text",
                                           description: Text("Add guidance or reusable instruction files for this scope."))
                }
            }.disabled(!model.canEdit)
            if let error = model.errorMessage {
                HStack {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("instructions.error")
                    Button("Reload") { Task { await model.reload() } }
                }
            }
            HStack {
                Text(model.revision.map { "Saved version \($0) · Changes create a new version" } ?? "No saved version")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Instructions") { Task { if await model.save() { dismiss() } } }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("instructions.save")
                    .disabled(!model.canEdit)
            }
        }
        .padding(24).frame(width: 740, height: 520).textFieldStyle(.roundedBorder)
        .disabled(model.busy).interactiveDismissDisabled(model.busy)
        .task(id: model.level) { await model.reload() }
    }
}

struct InstructionPreviewView: View {
    let value: ComposedInstructions
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effective Instructions").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("instructions.preview.done")
            }
            Text("Global → Workspace → Project → Agent · Agent version \(value.agentRevision)")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(value.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(source.layer) · Version \(source.revision)").font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("instruction.source.\(source.layer)")
                            Text(source.title).font(.headline)
                            Text(source.text).frame(maxWidth: .infinity, alignment: .leading)
                            DisclosureGroup("Source and fingerprint") {
                                Text(source.relativeFile).font(.caption.monospaced())
                                Text("SHA-256: \(source.sha256)").font(.caption2.monospaced())
                            }
                        }
                        Divider()
                    }
                }.textSelection(.enabled)
            }
            Text("This preview records the selected versions. Saving instructions does not grant tools or permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 740, height: 520)
    }
}
#endif
