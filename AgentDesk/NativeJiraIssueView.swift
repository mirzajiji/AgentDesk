#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import AgentDeskRuntime
import SwiftUI

struct NativeJiraIssueView: View {
    @StateObject private var model: NativeJiraIssueModel
    let site: String
    @Environment(\.dismiss) private var dismiss
    init(site: String, open: @escaping (String) async throws -> any NativeJiraIssueReview) {
        self.site = site; _model = StateObject(wrappedValue: NativeJiraIssueModel(open: open))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Jira Issue").font(.title2).bold()
                Spacer()
                Button("Done") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(site).foregroundStyle(.secondary)
            HStack {
                TextField("Issue key", text: $model.identifier, prompt: Text("PROJECT-123"))
                    .disabled(model.busy || model.pending != nil).accessibilityIdentifier("jira.issue.key")
                Button("Look Up") { model.lookup() }.disabled(model.busy || model.pending != nil)
                    .accessibilityIdentifier("jira.issue.lookup")
            }
            if model.busy { ProgressView("Reading issue…") }
            if let message = model.message { Text(message).accessibilityIdentifier("jira.issue.message") }
            if model.pending != nil {
                Text("Allow reading issue \(model.identifier) from this connection?")
                HStack {
                    Button("Approve Read") { model.approve() }.disabled(model.busy).accessibilityIdentifier("jira.issue.approve")
                    Button("Cancel Review") { model.cancel() }.accessibilityIdentifier("jira.issue.cancel")
                }
            } else if model.busy {
                Button("Cancel") { model.cancel() }
            }
            ScrollView {
                Text(verbatim: model.content ?? "Look up an issue to inspect its current Jira content.")
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("jira.issue.content")
            }
        }.padding(20).macEditorLayout(idealWidth: 820, idealHeight: 640)
        .onDisappear { model.cancel() }
    }
}
#endif
