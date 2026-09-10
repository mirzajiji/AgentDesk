#if os(macOS)
import AgentDeskRuntime
import Combine
import Foundation

struct NativeReadinessItem: Identifiable, Equatable {
    enum State { case ready, needsAttention }
    let id: String
    let title: String
    let detail: String
    let state: State
}

@MainActor
final class NativeReadinessModel: ObservableObject {
    typealias Probe = () async throws -> [NativeReadinessItem]
    @Published private(set) var items: [NativeReadinessItem] = []
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    private let probe: Probe
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(probe: @escaping Probe) { self.probe = probe }
    deinit { operation?.cancel() }
    func refresh() {
        cancel(); checking = true; error = nil
        let token = generation, probe = probe
        operation = Task { [weak self] in
            do {
                let items = try await probe()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.items = items; self.checkedAt = Date(); self.checking = false
            } catch is CancellationError {} catch {
                guard let self, self.generation == token else { return }
                self.error = "The readiness check could not finish. Retry or open Settings to review the local setup."
                self.checking = false
            }
        }
    }
    func cancel() {
        generation += 1; operation?.cancel(); operation = nil; checking = false
        items = []; checkedAt = nil
    }

    static func check(catalog: WorkspaceBrowserModel) async throws -> [NativeReadinessItem] {
        var items: [NativeReadinessItem] = []
        do {
            let commands = try await catalog.commands()
            let projects = commands.commands.filter { if case .run = $0.action { true } else { false } }
            items.append(.init(id: "storage", title: "Local workspace storage", detail: "Workspace configuration can be read.", state: .ready))
            items.append(.init(id: "projects", title: "Workspace and project", detail: projects.isEmpty ? "Create a workspace and project to get started." : "\(projects.count) local projects available. Configure an agent and repository in the project.", state: projects.isEmpty ? .needsAttention : .ready))
        } catch is CancellationError { throw CancellationError() } catch {
            items.append(.init(id: "storage", title: "Local workspace storage", detail: "Storage could not be read. Retry from Workspaces; existing files are preserved.", state: .needsAttention))
        }
        do {
            let version = try await MacGitReadiness.version()
            items.append(.init(id: "git", title: "Git", detail: "Git \(version) responds. Each project still needs an authorized repository.", state: .ready))
        } catch is CancellationError { throw CancellationError() } catch {
            items.append(.init(id: "git", title: "Git", detail: "Git did not respond. Check the Mac’s command-line developer tools, then retry.", state: .needsAttention))
        }
        try Task.checkCancellation()
        do {
            let settings = try CodexSettingsStore.applicationStore().load()
            if !settings.enabled {
                items.append(.init(id: "codex", title: "Codex", detail: "Disconnected. Connect in Settings when you are ready to run agents.", state: .needsAttention))
            } else {
                let snapshot = try await CodexHostClient().inspect(executable: settings.executablePath.map { URL(fileURLWithPath: $0) })
                let ready = snapshot.issue == nil && snapshot.installation != nil && snapshot.authentication == .chatGPT
                items.append(.init(id: "codex", title: "Codex and native execution helper", detail: ready ? "The helper responds and Codex has ChatGPT credentials. Every run still requires project checks and review." : "Open Settings to check installation and ChatGPT sign-in.", state: ready ? .ready : .needsAttention))
            }
        } catch is CancellationError { throw CancellationError() } catch {
            items.append(.init(id: "codex", title: "Codex and native execution helper", detail: "The check could not complete. Open Settings for recovery actions.", state: .needsAttention))
        }
        try Task.checkCancellation()
        return items
    }
}
#endif
