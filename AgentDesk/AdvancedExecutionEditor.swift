#if os(macOS)
import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct AdvancedExecutionEdit: Identifiable {
    let id = UUID()
    let text: String
}

struct AdvancedExecutionEditor: View {
    let scope: ProjectScope
    let level: ExecutionConfigurationLevel
    let apply: (ExecutionConfigurationDraft) -> Void
    @State private var text: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(edit: AdvancedExecutionEdit, scope: ProjectScope, level: ExecutionConfigurationLevel,
         apply: @escaping (ExecutionConfigurationDraft) -> Void) {
        self.scope = scope; self.level = level; self.apply = apply; _text = State(initialValue: edit.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced Execution Settings").font(.title2).bold()
            Text("Edit complete settings, including model and environment allowlists, output schemas and policy rules. Applying updates the form; Save Settings publishes a new version.")
                .foregroundStyle(.secondary)
            MacPlainTextEditor(text: $text, label: "Complete execution settings JSON", identifier: "execution.advanced.json")
                .border(.separator)
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("execution.advanced.error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to Form") {
                    do {
                        let draft = try ExecutionDraftEditing.decode(text, at: level, in: scope)
                        apply(draft); dismiss()
                    } catch {
                        self.error = Self.message(error)
                    }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("execution.advanced.apply")
            }
        }.padding(24).macEditorLayout(idealWidth: 820)
    }
    private static func message(_ error: any Error) -> String {
        let reason: String
        if error as? ExecutionConfigurationError == .scopeMismatch {
            reason = "The workspace, project or environment identifiers do not match this editor."
        } else if error is DecodingError {
            reason = "Check JSON field names and value types against the original settings."
        } else if error as? OutputContractError == .invalidJSON {
            reason = "Enter valid JSON without duplicate keys."
        } else if error is OutputContractError {
            reason = "Check the output schema and JSON size limits."
        } else {
            reason = "Check configuration limits, environment references and policy rules."
        }
        return reason + " The form has not changed."
    }
}
#endif
