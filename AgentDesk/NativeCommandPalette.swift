#if os(macOS)
import SwiftUI

private struct ShowCommandPaletteKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var showCommandPalette: (() -> Void)? {
        get { self[ShowCommandPaletteKey.self] }
        set { self[ShowCommandPaletteKey.self] = newValue }
    }
}

struct NativePaletteCommands: Commands {
    @FocusedValue(\.showCommandPalette) private var show
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Command Palette…") { show?() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(show == nil)
        }
    }
}

struct NativeCommandPalette: View {
    @ObservedObject var model: WorkspaceBrowserModel
    let choose: (NativeCommandAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: NativeCommandCatalog?
    @State private var query = ""
    @State private var selection: NativeCommandAction?
    @State private var error: String?
    @State private var dispatched = false
    @FocusState private var searchFocused: Bool

    private var results: [NativeCommand] { catalog?.search(query) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Command Palette").font(.title2).bold()
            TextField("Search commands, workspaces, and projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("command.search")
                .onSubmit { submit() }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            if let error {
                Text(error).foregroundStyle(.red)
            } else if catalog == nil {
                ProgressView("Loading commands…")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: $selection) {
                    ForEach(results) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(command.title, systemImage: command.symbol)
                            Text(command.context).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(command.id)
                        .onTapGesture(count: 2) { dispatch(command.action) }
                    }
                }
                .accessibilityIdentifier("command.results")
            }
            HStack {
                Text("Commands open a screen for review.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || dispatched)
                    .accessibilityIdentifier("command.open")
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 500)
        .onChange(of: query) { selection = results.first?.id }
        .onMoveCommand { direction in
            if direction == .down { moveSelection(1) }
            if direction == .up { moveSelection(-1) }
        }
        .task {
            searchFocused = true
            do {
                let loaded = try await model.commands()
                try Task.checkCancellation()
                catalog = loaded
                selection = results.first?.id
            } catch is CancellationError {} catch { self.error = WorkspaceBrowserModel.message(for: error) }
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(index + offset, 0), results.count - 1)].id
    }

    private func submit() {
        guard let selection, results.contains(where: { $0.id == selection }) else { return }
        dispatch(selection)
    }

    private func dispatch(_ action: NativeCommandAction) {
        guard !dispatched else { return }
        dispatched = true
        choose(action)
    }
}
#endif
