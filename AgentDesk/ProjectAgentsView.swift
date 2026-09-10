#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ProjectAgentsView: View {
    @StateObject private var model: ProjectAgentsModel
    @State private var editor: AgentEditorRequest?
    @State private var editingSharedInstructions = false
    @State private var editingSkills = false
    @State private var instructionPreview: InstructionPreviewRequest?
    @Environment(\.dismiss) private var dismiss

    init(project: ProjectRecord, openStore: @escaping () async throws -> ProjectAgentStore,
         openInstructions: @escaping () async throws -> ProjectInstructionStore,
         openSkills: @escaping () async throws -> ProjectSkillStore) {
        _model = StateObject(wrappedValue: ProjectAgentsModel(project: project, openStore: openStore,
                                                             openInstructions: openInstructions, openSkills: openSkills))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.project.name).font(.title).bold()
                    Text("Agents · Local project").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skills") { editingSkills = true }
                    .accessibilityIdentifier("skills.open").disabled(model.skillStore == nil)
                Button("Shared Instructions") { editingSharedInstructions = true }
                    .accessibilityIdentifier("instructions.shared")
                    .disabled(model.instructionStore == nil)
                Button("New Agent", systemImage: "plus") { editor = AgentEditorRequest() }
                    .accessibilityIdentifier("agent.create")
                    .disabled(model.loading || model.errorMessage != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = model.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Reload") { Task { await model.load() } }
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("agents.error")
            }
            if model.loading && model.agents.isEmpty {
                ProgressView("Opening agents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.agents.isEmpty {
                ContentUnavailableView("No agents yet", systemImage: "person.crop.rectangle.stack",
                                       description: Text("Create an agent from a template and tailor its instructions to this project."))
            } else {
                List(model.agents) { agent in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(agent.definition.name).font(.headline)
                            if agent.definition.archived { Text("Archived").foregroundStyle(.secondary) }
                            else if !agent.definition.enabled { Text("Disabled").foregroundStyle(.secondary) }
                            Spacer()
                            Button("Review Instructions") {
                                Task {
                                    if let value = await model.preview(agent) { instructionPreview = InstructionPreviewRequest(value: value) }
                                }
                            }
                            .accessibilityIdentifier("agent.preview.\(agent.definition.name)")
                            Text("Version \(agent.definition.revision)").foregroundStyle(.secondary)
                        }
                        Text(agent.definition.summary).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Label(agent.definition.profile.requestedAccess == .readOnly ? "Read-only request" : "Workspace write request",
                                  systemImage: "lock")
                                .font(.caption)
                            Spacer()
                            Button("Edit Instructions") { editor = AgentEditorRequest(existing: agent) }
                                .disabled(agent.definition.archived)
                                .accessibilityIdentifier("agent.edit.\(agent.definition.name)")
                            Button(agent.definition.archived ? "Restore" : "Archive") { Task { await model.toggleArchive(agent) } }
                                .accessibilityIdentifier("agent.archive.\(agent.definition.name)")
                        }
                    }
                    .padding(.vertical, 10)
                }
                .listStyle(.inset)
            }
            Text("Review the shared and agent instructions, then open the project’s Run console to prepare and approve execution.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 820, idealWidth: 880, minHeight: 520, idealHeight: 620)
        .task { await model.load() }
        .sheet(item: $editor) { request in
            AgentEditorView(existing: request.existing, skills: model.skills) { draft in try await model.save(draft, replacing: request.existing) }
        }
        .sheet(isPresented: $editingSharedInstructions) {
            if let store = model.instructionStore { SharedInstructionsView(store: store, scope: model.project.scope) }
        }
        .sheet(isPresented: $editingSkills, onDismiss: { Task { await model.load() } }) {
            if let store = model.skillStore { ProjectSkillsView(scope: model.project.scope, store: store) }
        }
        .sheet(item: $instructionPreview) { request in InstructionPreviewView(value: request.value) }
    }
}

private struct InstructionPreviewRequest: Identifiable {
    let id = UUID()
    let value: ComposedInstructions
}

private struct AgentEditorRequest: Identifiable {
    let id = UUID()
    var existing: AgentSnapshot? = nil
}

struct AgentEditorView: View {
    let existing: AgentSnapshot?
    let skills: [SkillSnapshot]
    let save: (AgentDraft) async throws -> Void
    @State private var draft = AgentTemplate.general.draft
    @State private var template = AgentTemplate.general
    @State private var modelIdentifier = ""
    @State private var knowledge = AgentKnowledgeEditing()
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Create Agent" : "Edit Agent").font(.title2).bold()
            if existing == nil {
                Picker("Template", selection: $template) {
                    ForEach(AgentTemplate.allCases) { template in Text(template.title).tag(template) }
                }
                .onChange(of: template) { _, value in draft = value.draft; modelIdentifier = ""; knowledge = AgentKnowledgeEditing(value.draft.profile.knowledge) }
            }
            TextField("Name", text: $draft.name).accessibilityIdentifier("agent.name")
            TextField("Description", text: $draft.summary).accessibilityIdentifier("agent.summary")
            TabView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructions").font(.headline)
                    TextEditor(text: $draft.instructions)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("agent.instructions")
                    Text("Saving creates a new version. Previous instructions remain available on disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding().tabItem { Text("Instructions") }
                Form {
                    Toggle("Agent enabled", isOn: $draft.enabled)
                    TextField("Codex model (blank uses provider default)", text: $modelIdentifier)
                    Picker("Requested access", selection: $draft.profile.requestedAccess) {
                        Text("Read only").tag(CodexAgentProfile.Access.readOnly)
                        Text("Workspace write").tag(CodexAgentProfile.Access.workspaceWrite)
                    }
                    Stepper("Maximum steps: \(draft.profile.maximumSteps)", value: $draft.profile.maximumSteps, in: 1...1_000)
                    Stepper("Timeout: \(draft.profile.timeoutSeconds) seconds", value: $draft.profile.timeoutSeconds, in: 1...86_400, step: 60)
                    Text("These are requests for the runtime. Saving a profile does not grant permission or start Codex.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding().tabItem { Text("Execution") }
                AgentKnowledgeSelectionView(editing: $knowledge)
                    .padding().tabItem { Text("Knowledge") }
                AgentSkillSelectionView(skills: skills, references: $draft.skillReferences)
                    .padding().tabItem { Text("Skills") }
            }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("agent.validation") }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Agent") {
                    saving = true
                    draft.profile.modelIdentifier = modelIdentifier.isEmpty ? nil : modelIdentifier
                    Task {
                        do { draft.profile.knowledge = try knowledge.selection(); try await save(draft); dismiss() }
                        catch { self.error = ProjectAgentsModel.message(error); saving = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("agent.save")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).macEditorLayout(idealWidth: 700, idealHeight: 520)
        .disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { draft = existing?.draft ?? template.draft; modelIdentifier = draft.profile.modelIdentifier ?? ""; knowledge = AgentKnowledgeEditing(draft.profile.knowledge) }
    }
}
private struct AgentSkillSelectionView: View {
    let skills: [SkillSnapshot]
    @Binding var references: [SkillReference]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Selected skills keep their exact version until you explicitly update the reference.").font(.caption).foregroundStyle(.secondary)
                if skills.isEmpty { Text("No skills available. Create one from the project’s Skills panel.") }
                ForEach(skills) { skill in
                    let selected = references.first { $0.id == skill.id && $0.scope == skill.definition.scope }
                    HStack {
                        Toggle(skill.definition.name, isOn: Binding(get: { selected != nil }, set: { enabled in
                            references.removeAll { $0.id == skill.id && $0.scope == skill.definition.scope }
                            if enabled, let reference = try? skill.definition.reference { references.append(reference) }
                        }))
                        .disabled(selected == nil && (skill.definition.archived || !skill.definition.enabled))
                        .accessibilityIdentifier("agent.skill.\(skill.definition.name)")
                        Text("Version \(selected?.revision ?? skill.definition.revision)").foregroundStyle(.secondary)
                        if skill.definition.archived || !skill.definition.enabled { Text("Unavailable").foregroundStyle(.orange) }
                        else if let selected, selected.revision != skill.definition.revision {
                            Button("Use version \(skill.definition.revision)") {
                                if let index = references.firstIndex(of: selected), let latest = try? skill.definition.reference { references[index] = latest }
                            }
                        }
                    }
                }
                ForEach(references.filter { reference in !skills.contains { $0.id == reference.id && $0.definition.scope == reference.scope } }, id: \.self) { reference in
                    HStack { Text("Missing skill · version \(reference.revision)").foregroundStyle(.orange); Button("Remove reference") { references.removeAll { $0 == reference } } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#endif
