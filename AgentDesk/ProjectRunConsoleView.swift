#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import SwiftUI

struct ProjectRunConsoleView: View {
    @StateObject private var context: ProjectRunContextModel
    @StateObject private var session = NativeRunSession()
    @StateObject private var evidence = RunEvidenceModel()
    @StateObject private var liveOutput = NativeLiveOutputModel()
    @State private var taskText = ""
    @State private var confirmClose = false
    @State private var showKnowledge = false
    @State private var historyError: String?
    @Environment(\.dismiss) private var dismiss

    init(project: ProjectRecord, open: @escaping () async throws -> ProjectNativeServices) {
        _context = StateObject(wrappedValue: ProjectRunContextModel(project: project, open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run console").font(.title2).bold()
                Spacer()
                Button("Done") {
                    if session.hasPendingWork { confirmClose = true }
                    else { Task { await session.close(); evidence.clear(); dismiss() } }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("run.console.done")
            }
            if let error = session.errorMessage ?? context.errorMessage ?? evidence.errorMessage ?? historyError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("run.console.error")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selection
                    if let preview = context.presentation {
                        GroupBox("Reviewed context") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(preview.agentName) · \(preview.environmentName)").font(.headline)
                                DisclosureGroup("Instructions") { plain(preview.instructions) }
                                DisclosureGroup("Sources and versions") { plain(preview.sources) }
                                DisclosureGroup("Effective configuration") { plain(preview.configuration) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    if let prepared = session.prepared {
                        GroupBox("Prepared action") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Run \(prepared.runID)").textSelection(.enabled)
                                Text("Read-only agent · input fingerprint \(prepared.action.payload.rawValue)").textSelection(.enabled)
                                if let approval = prepared.approval { Text("Approval version \(approval.sequence)") }
                                if session.prepared?.knowledgeSnapshot != nil {
                                    Button("Inspect Selected Knowledge") { showKnowledge = true }
                                        .accessibilityIdentifier("run.knowledge")
                                }
                                if let snapshot = session.inputSnapshot { DisclosureGroup("Prepared input") { plain(snapshot) } }
                                if session.phase == .prepared {
                                    Text("Review the prepared input before starting. Codex has not been started for this run.")
                                    HStack {
                                        Button("Reject") { Task { await session.reject() } }.accessibilityIdentifier("run.reject")
                                        Button(prepared.approval == nil ? "Start Run" : "Approve and Start") { Task { await session.start() } }
                                            .buttonStyle(.borderedProminent).accessibilityIdentifier("run.start")
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    if let run = session.run {
                        GroupBox("Progress") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(run.state.rawValue).font(.headline).accessibilityIdentifier("run.state")
                                if let plan = session.progress {
                                    if let measured = plan.overallProgress {
                                        ProgressView(value: measured.fractionCompleted)
                                    } else { Text("Open-ended run · no overall percentage").foregroundStyle(.secondary) }
                                    ForEach(plan.items) { item in
                                        HStack { Text(item.definition.title); Spacer(); Text(item.state.rawValue).foregroundStyle(.secondary) }
                                    }
                                }
                                if session.phase == .running { Button("Cancel Run", role: .destructive) { session.cancelExecution() }.accessibilityIdentifier("run.cancel") }
                                if let outcome = session.outcome, outcome.state == nil { Text("The terminal state could not be confirmed.").foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    if !liveOutput.entries.isEmpty || liveOutput.errorMessage != nil {
                        GroupBox("Live Codex output") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Provider response · interpretation").font(.caption).foregroundStyle(.secondary)
                                if liveOutput.abbreviated { Text("Live preview abbreviated. Full text remains in saved evidence.").font(.caption) }
                                ForEach(liveOutput.entries) { entry in
                                    plain(entry.text).accessibilityIdentifier("run.live.output.\(entry.record.sequence)")
                                }
                                if let error = liveOutput.errorMessage { Text(error).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    if evidence.isOpen || session.service != nil { results }
                }.padding(.trailing, 4)
            }.accessibilityIdentifier("run.console.scroll")
        }
        .padding(20).macEditorLayout(idealWidth: 960, idealHeight: 640)
        .interactiveDismissDisabled()
        .task { await context.load() }
        .task(id: session.prepared?.runID) {
            liveOutput.clear()
            guard let id = session.prepared?.runID, let service = session.service else { return }
            let token = liveOutput.bind(service,
                context: RedactionContext(scope: service.scope, environmentID: service.environmentID, runID: id),
                agentID: service.agentID)
            while !Task.isCancelled {
                guard await liveOutput.refresh(token) else { break }
                if session.outcome != nil && !liveOutput.hasMore { break }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            if Task.isCancelled { liveOutput.clear(if: token) }
        }
        .onChange(of: context.selectedAgentID) { evidence.clear(); historyError = nil }
        .onChange(of: context.selectedEnvironmentID) { evidence.clear(); historyError = nil }
        .task(id: session.outcome?.runID) {
            if let outcome = session.outcome, let service = session.service {
                await evidence.showResult(outcome, using: service)
            }
        }
        .background(NativeRunWindowAnchor { session.presentWindow = $0 }.frame(width: 0, height: 0))
        .sheet(isPresented: $showKnowledge) {
            if let snapshot = session.prepared?.knowledgeSnapshot { KnowledgeContextInspector(snapshot: snapshot) }
        }
        .onDisappear { let owned = session; Task { await owned.close() } }
        .confirmationDialog("Stop this run and close the console?", isPresented: $confirmClose) {
            Button("Stop and Close", role: .destructive) { Task { await session.close(); evidence.clear(); dismiss() } }
        } message: { Text("Prepared work is discarded and active execution is cancelled before closing.") }
    }
    private var selection: some View {
        GroupBox("Choose context and task") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Agent", selection: $context.selectedAgentID) {
                    Text("Choose an agent").tag(AgentID?.none)
                    ForEach(context.agents) { agent in Text(agent.definition.name).tag(Optional(agent.id)) }
                }.accessibilityIdentifier("run.agent")
                Picker("Environment", selection: $context.selectedEnvironmentID) {
                    Text("Project default").tag(EnvironmentID?.none)
                    ForEach(context.environments) { environment in Text(environment.name).tag(Optional(environment.id)) }
                }.accessibilityIdentifier("run.environment")
                HStack {
                    Button("Reload") { Task { await context.load() } }
                    Button("Review Context") { Task { await context.preview() } }.disabled(context.selectedAgentID == nil)
                        .accessibilityIdentifier("run.context.review")
                    Button("Browse Saved Runs") {
                        historyError = nil
                        Task {
                            do { let archive = try await context.archive(); await evidence.load(archive) }
                            catch { historyError = NativeRunSession.message(error) }
                        }
                    }.disabled(context.selectedAgentID == nil).accessibilityIdentifier("run.history.open")
                }
                Text("Task").font(.headline)
                MacPlainTextEditor(text: $taskText, label: "Task", identifier: "run.task").frame(height: 120)
                Button("Prepare Run") { evidence.clear(); Task { await session.prepare(using: context, task: taskText) } }
                    .disabled(context.presentation == nil || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("run.prepare")
            }.padding(8).disabled(context.isBusy || session.hasPendingWork)
        }
    }
    private var results: some View {
        GroupBox("Results and evidence") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Refresh Runs") {
                    Task {
                        if evidence.isOpen { await evidence.refresh() }
                        else if let service = session.service { await evidence.load(service) }
                    }
                }
                    .accessibilityIdentifier("run.history.refresh")
                if evidence.isOpen && evidence.runs.isEmpty && evidence.errorMessage == nil {
                    Text("No saved runs for this agent and environment.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("run.history.empty")
                }
                ForEach(evidence.runs) { run in
                    Button("\(run.createdAt.formatted()) · \(run.state.rawValue) · \(run.id)") { Task { await evidence.select(run.id) } }
                        .accessibilityIdentifier("run.history.item.\(run.id)")
                }
                if evidence.moreRuns { Button("Older Runs") { Task { await evidence.refresh(older: true) } } }
                ForEach(evidence.records) { record in
                    Button("\(record.sequence) · \(record.kind.rawValue) · \(record.source.rawValue) · \(record.basis.rawValue)") { Task { await evidence.inspect(record) } }
                        .accessibilityIdentifier("run.evidence.\(record.kind.rawValue).\(record.sequence)")
                }
                if evidence.moreRecords, let id = evidence.selectedRun { Button("More Evidence") { Task { await evidence.select(id, more: true) } } }
                if let content = evidence.content { plain(content.text).accessibilityIdentifier("run.evidence.content") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func plain(_ text: String) -> some View {
        Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
