#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskDesign
import SwiftUI

struct MutationHistoryView: View {
    @StateObject private var model: MutationHistoryModel
    let projectName: String
    let environmentName: String
    @Environment(\.dismiss) private var dismiss
    init(projectName: String, environmentName: String, open: @escaping () async throws -> NativeMutationHistory) {
        self.projectName = projectName; self.environmentName = environmentName
        _model = StateObject(wrappedValue: MutationHistoryModel(open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mutation History").font(.title2).bold().accessibilityIdentifier("mutation.history.title")
                    Text(verbatim: "\(projectName) · \(environmentName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("mutation.history.done")
            }
            Text("Unresolved attempts may have reached Jira. Check current Jira evidence before preparing another write.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("mutation.history.error")
            }
            if model.loading && model.records.isEmpty {
                ProgressView("Opening history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.records.isEmpty {
                ContentUnavailableView(model.errorMessage == nil ? "No mutation attempts" : "History unavailable",
                    systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.records, id: \.action.id) { record in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(label(record.outcome)).font(.headline)
                                    Text(verbatim: "Action \(record.action.id.uuidString)").textSelection(.enabled)
                                    Text(verbatim: "Approval \(record.approvalID.uuidString)").font(.caption).textSelection(.enabled)
                                    Text("Started \(record.startedAt.formatted()) · Updated \(record.updatedAt.formatted())").font(.caption)
                                    if let run = record.action.runID { Text(verbatim: "Run \(run.rawValue)").font(.caption).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                            }.accessibilityIdentifier("mutation.history.row.\(record.action.id.uuidString)")
                        }
                        if model.hasMore {
                            Button("Load More") { Task { await model.load(more: true) } }.disabled(model.loading)
                        }
                    }.padding(4)
                }
            }
            Text("Ordered by action ID. Refresh to include new attempts.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        .macEditorLayout(idealWidth: 820, idealHeight: 640)
        .task { await model.load() }
        .onDisappear { Task { await model.close() } }
    }
    private func label(_ outcome: MutationAttemptOutcome) -> String {
        switch outcome {
        case .unresolved: "Unresolved — verify Jira state"
        case .acknowledged: "Acknowledged by Jira"
        case .rejected: "Rejected by Jira"
        case .notDispatched: "Not dispatched"
        }
    }
}
#endif
