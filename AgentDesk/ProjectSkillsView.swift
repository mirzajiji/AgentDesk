#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ProjectSkillsView: View {
    @StateObject private var model: ProjectSkillsModel
    @State private var editor: SkillEditorRequest?
    @Environment(\.dismiss) private var dismiss
    init(scope: ProjectScope, store: ProjectSkillStore) { _model = StateObject(wrappedValue: ProjectSkillsModel(scope: scope, store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Skills").font(.title).bold(); Spacer()
                Button("New Skill", systemImage: "plus") { editor = SkillEditorRequest() }
                    .accessibilityIdentifier("skill.create").disabled(model.loading || model.error != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("skills.done")
            }
            Text("Reusable instructions, saved as versions. Attach an exact version in the agent’s Skills tab.")
                .foregroundStyle(.secondary)
            if let error = model.error {
                HStack { Text(error).foregroundStyle(.red); Button("Reload") { Task { await model.load() } } }
                    .accessibilityIdentifier("skills.error")
            }
            if model.loading && model.skills.isEmpty { ProgressView("Opening skills…") }
            else if model.skills.isEmpty {
                ContentUnavailableView("No skills yet", systemImage: "books.vertical", description: Text("Create instructions for a repeatable review or engineering method."))
            } else {
                List(model.skills) { skill in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(skill.definition.name).font(.headline)
                            Text(skill.definition.scope.projectID == nil ? "Workspace" : "Project").foregroundStyle(.secondary)
                            Spacer(); Text("Version \(skill.definition.revision)")
                        }
                        Text(skill.definition.summary).foregroundStyle(.secondary)
                        HStack {
                            if skill.definition.archived { Text("Archived") }
                            else if !skill.definition.enabled { Text("Disabled") }
                            Text("\(skill.definition.requiredPermissions.count) permission requests · \(skill.attachments.count) attachments")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit Skill") { editor = SkillEditorRequest(existing: skill) }
                                .disabled(skill.definition.archived).accessibilityIdentifier("skill.edit.\(skill.definition.name)")
                            Button(skill.definition.archived ? "Restore" : "Archive") { Task { await model.archive(skill) } }
                                .accessibilityIdentifier("skill.archive.\(skill.definition.name)")
                        }
                    }.padding(.vertical, 8)
                }
            }
            Text("Permissions listed by a skill are requests. Runtime policy and approvals still control every action. Script attachments are not executed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).macEditorLayout(idealWidth: 780, idealHeight: 560)
        .task { await model.load() }
        .sheet(item: $editor) { request in
            SkillEditorView(scope: model.scope, existing: request.existing) { draft, owner in
                try await model.save(draft, owner: owner, replacing: request.existing)
            }
        }
    }
}
private struct SkillEditorRequest: Identifiable { let id = UUID(); var existing: SkillSnapshot? = nil }
struct SkillEditorView: View {
    let scope: ProjectScope
    let existing: SkillSnapshot?
    let save: (SkillDraft, SkillScope) async throws -> Void
    @State private var draft = SkillDraft(name: "", instructions: "")
    @State private var shared = false
    @State private var saving = false
    @State private var error: String?
    @State private var attachmentEditor: SkillAttachmentEditorRequest?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Create Skill" : "Edit Skill").font(.title2).bold()
            TextField("Name", text: $draft.name).accessibilityIdentifier("skill.name")
            TextField("Description", text: $draft.summary).accessibilityIdentifier("skill.summary")
            Picker("Scope", selection: $shared) { Text("This project").tag(false); Text("This workspace").tag(true) }
                .disabled(existing != nil).accessibilityIdentifier("skill.scope")
            TabView {
                TextEditor(text: $draft.instructions).font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("skill.instructions").padding().tabItem { Text("Instructions") }
                Form {
                    Toggle("Skill enabled", isOn: $draft.enabled)
                    ForEach(PolicyOperation.allCases, id: \.self) { operation in
                        Toggle(operation.skillPermissionTitle, isOn: Binding(get: { draft.requiredPermissions.contains(operation) }, set: { selected in
                            draft.requiredPermissions.removeAll { $0 == operation }
                            if selected { draft.requiredPermissions.append(operation) }
                        }))
                    }
                    Text("These declarations request review; they do not grant access.").font(.caption).foregroundStyle(.secondary)
                }.padding().tabItem { Text("Permissions") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Button("Add Attachment", systemImage: "plus") { attachmentEditor = SkillAttachmentEditorRequest() }
                            .disabled(draft.attachments.count >= 16).accessibilityIdentifier("skill.attachment.add")
                        if draft.attachments.isEmpty { Text("No attachments. Add example documents or script text.").foregroundStyle(.secondary) }
                        ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, file in
                            HStack {
                                Text(file.relativeFile).font(.headline); Spacer()
                                Button("Edit") { attachmentEditor = SkillAttachmentEditorRequest(index: index, file: file) }
                                Button("Remove", role: .destructive) { draft.attachments.remove(at: index) }
                            }
                            Text(file.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Text("Attachments are saved with the skill version. Script text is shown for review and is never run here.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.tabItem { Text("Attachments") }
            }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("skill.validation") }
            HStack {
                Text("Saving creates a new version.").font(.caption).foregroundStyle(.secondary); Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Skill") {
                    saving = true
                    let owner = SkillScope(workspaceID: scope.workspaceID, projectID: shared ? nil : scope.projectID)
                    Task { do { try await save(draft, owner); dismiss() } catch { self.error = ProjectAgentsModel.message(error); saving = false } }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("skill.save")
            }
        }
        .textFieldStyle(.roundedBorder).padding(24).macEditorLayout(idealWidth: 720, idealHeight: 590)
        .disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { if let existing { draft = existing.draft; shared = existing.definition.scope.projectID == nil } }
        .sheet(item: $attachmentEditor) { request in
            SkillAttachmentEditorView(request: request) { file in
                try draft.setAttachment(file, at: request.index)
            }
        }
    }
}
private struct SkillAttachmentEditorRequest: Identifiable {
    let id = UUID()
    var index: Int? = nil
    var file = SkillAttachment(kind: .example, name: "example.md", text: "")
}
private struct SkillAttachmentEditorView: View {
    let request: SkillAttachmentEditorRequest
    let save: (SkillAttachment) throws -> Void
    @State private var file = SkillAttachment(kind: .example, name: "example.md", text: "")
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill Attachment").font(.title2).bold()
            Picker("Kind", selection: $file.kind) { Text("Example").tag(SkillAttachment.Kind.example); Text("Script text").tag(SkillAttachment.Kind.script) }
            TextField("Filename", text: $file.name).accessibilityIdentifier("skill.attachment.name")
            TextEditor(text: $file.text).font(.system(.body, design: .monospaced)).accessibilityIdentifier("skill.attachment.text")
            Text("Use a filename without folders. Examples use .md or .json. Script text is stored without execution permission.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Keep Attachment") { do { try save(file); dismiss() } catch { self.error = ProjectAgentsModel.message(error) } }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("skill.attachment.keep")
            }
        }.padding(24).macEditorLayout(idealWidth: 640, idealHeight: 480).textFieldStyle(.roundedBorder)
        .onAppear { file = request.file }
    }
}
extension PolicyOperation {
    var skillPermissionTitle: String {
        switch self {
        case .readEvidence: "Read project evidence"
        case .runReadOnlyAgent: "Run a read-only agent"
        case .writeProject: "Write project files"
        case .readSecret: "Read a scoped secret"
        case .updateSecret: "Update a scoped secret"
        case .changeConfiguration: "Change configuration"
        case .runShell: "Run a shell operation"
        case .externalMutation: "Change an external system"
        case .destructiveAction: "Perform a destructive action"
        }
    }
}
#endif
