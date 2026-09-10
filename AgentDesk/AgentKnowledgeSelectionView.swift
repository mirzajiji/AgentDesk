#if os(macOS)
import SwiftUI

struct AgentKnowledgeSelectionView: View {
    @Binding var editing: AgentKnowledgeEditing
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Select project knowledge for runs", isOn: $editing.enabled)
                    .accessibilityIdentifier("agent.knowledge.enabled")
                if editing.enabled {
                    Text("Use one logical path per line, such as architecture/** or qa/**. Exclusions always win. An empty include list selects no sources.")
                        .font(.caption).foregroundStyle(.secondary)
                    paths("Include paths", text: $editing.include, identifier: "agent.knowledge.include")
                    paths("Exclude paths", text: $editing.exclude, identifier: "agent.knowledge.exclude")
                    TextField("Search terms (blank browses selected paths)", text: $editing.query)
                        .accessibilityIdentifier("agent.knowledge.query")
                    Toggle("Active requirements", isOn: $editing.requirements)
                    Toggle("Confirmed knowledge", isOn: $editing.confirmed)
                    Toggle("Notes (unconfirmed)", isOn: $editing.notes)
                    Toggle("Inbox (unreviewed)", isOn: $editing.inbox)
                    Stepper("Maximum sources: \(editing.maximumRecords)", value: $editing.maximumRecords, in: 1...32)
                    TextField("Context byte limit (1,024–32,768)", value: $editing.maximumBytes, format: .number)
                    paths("Related subjects (one kind/id per line)", text: $editing.relationships, identifier: "agent.knowledge.relationships")
                    Text("Kinds: automatedTest, manualTest, bug, documentation, workflow. Related requirements still obey the path and classification selection and resolve current active versions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Context is reviewed before a run. These preferences grant no additional permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
    private func paths(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            TextEditor(text: text).font(.system(.body, design: .monospaced))
                .frame(minHeight: 55, idealHeight: 70).accessibilityLabel(label).accessibilityIdentifier(identifier)
        }
    }
}
#endif
