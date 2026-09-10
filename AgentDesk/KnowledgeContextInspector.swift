#if os(macOS)
import AgentDeskDesign
import SwiftUI

struct KnowledgeContextInspector: View {
    let snapshot: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected knowledge").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("run.knowledge.done")
            }
            Text("Review source versions, classifications and any unavailable or omitted context. This is the redacted snapshot bound to the prepared run.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: (try? KnowledgeContextPresentation.text(snapshot)) ?? snapshot).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    .accessibilityIdentifier("run.knowledge.content")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("run.knowledge.scroll")
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20).macEditorLayout(idealWidth: 900, idealHeight: 640)
    }
}
#endif
