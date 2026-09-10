import AgentDeskCore
import AgentDeskDesign
import SwiftUI

struct ContentView: View {
    #if os(macOS)
    @StateObject private var catalog = WorkspaceBrowserModel()
    @Environment(\.openSettings) private var openSettings
    @State private var paletteVisible = false
    @State private var pendingCommand: NativeCommandAction?
    @State private var routedCommand: NativeCommandAction?
    @State private var navigation = ShellNavigation(role: .macHost)
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: selection) {
                Section("AgentDesk") {
                    ForEach(navigation.role.destinations) { destination in
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination)
                            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                Label("Local Mac", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } detail: {
            destinationView(navigation.selection)
                .navigationTitle(navigation.selection.title)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .accessibilityIdentifier("settings.open")
        }
        .focusedSceneValue(\.showCommandPalette, { paletteVisible = true })
        .sheet(isPresented: $paletteVisible, onDismiss: {
            guard let command = pendingCommand else { return }
            pendingCommand = nil
            if command == .settings { openSettings() }
            else { navigation.select(.workspaces); routedCommand = command }
        }) {
            NativeCommandPalette(model: catalog) { command in
                pendingCommand = command
                paletteVisible = false
            }
        }
        .task { await catalog.reload() }
        #else
        NavigationStack {
            destinationView(.companion)
                .navigationTitle("AgentDesk")
        }
        #endif
    }

    #if os(macOS)
    private var selection: Binding<ShellDestination?> {
        Binding(
            get: { navigation.selection },
            set: { if let destination = $0 { navigation.select(destination) } }
        )
    }
    #endif

    @ViewBuilder
    private func destinationView(_ destination: ShellDestination) -> some View {
        switch destination {
        case .workspaces:
            #if os(macOS)
            WorkspaceBrowserView(model: catalog, command: $routedCommand)
            #else
            EmptyView()
            #endif
        case .runs:
            DeskEmptyState("No runs yet", systemImage: "play.rectangle",
                           message: "Agent activity and results will appear here when you start a run.",
                           accessibilityIdentifier: "empty.runs")
        case .connections:
            DeskEmptyState("No connections configured", systemImage: "point.3.connected.trianglepath.dotted",
                           message: "Project connections will appear here. No external services are connected.",
                           accessibilityIdentifier: "empty.connections")
        case .companion:
            DeskEmptyState("No Mac connected", systemImage: "laptopcomputer.and.iphone",
                           message: "Your Mac runs your agents. This companion will let you review their progress. Pairing is not available in this build.",
                           accessibilityIdentifier: "empty.companion")
        }
    }
}

private extension ShellDestination {
    var title: LocalizedStringKey {
        switch self {
        case .workspaces: "Workspaces"
        case .runs: "Runs"
        case .connections: "Connections"
        case .companion: "Companion"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: "square.stack.3d.up"
        case .runs: "play.rectangle"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .companion: "laptopcomputer.and.iphone"
        }
    }
}

struct ContentViewPreviews: PreviewProvider {
    static var previews: some View { ContentView() }
}
