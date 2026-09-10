#if os(macOS)
import AgentDeskCore
import SwiftUI

struct NativeRunMenu: View {
    @ObservedObject var registry: NativeRunRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Open run sessions")
        Text("Running: \(registry.runningCount)")
        Text("Awaiting approval: \(registry.approvalCount)")
        Text("Failed: \(registry.failedCount)")
        Divider()
        Button("Open AgentDesk") { openWindow(id: "main") }
        if registry.statuses.isEmpty {
            Text("No open run sessions")
        } else {
            ForEach(registry.statuses.values.sorted { $0.runID.rawValue < $1.runID.rawValue }) { status in
                Button("\(status.projectName) — \(status.state.rawValue)") { registry.focus(status.scope) }
                    .accessibilityIdentifier("menubar.run.\(status.runID)")
            }
        }
    }
}
#endif
