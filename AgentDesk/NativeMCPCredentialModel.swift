#if os(macOS)
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

@MainActor final class NativeMCPCredentialModel: ObservableObject {
    @Published var variable = ""
    @Published var value = ""
    @Published private(set) var busy = false
    @Published private(set) var saved = false
    @Published private(set) var error: String?
    private let write: (String, SecretValue) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var needsRecovery = false
    init(write: @escaping (String, SecretValue) async throws -> Void) { self.write = write }
    func save() {
        guard !busy, !saved, !needsRecovery else { return }
        let name = variable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let secret = try? SecretValue(Data(value.utf8)) else {
            error = "Enter a variable name and a non-empty credential value."; return
        }
        value = ""; busy = true; error = nil; let token = generation
        task = Task {
            do {
                try await write(name, secret)
                if token == generation, !Task.isCancelled { saved = true }
            } catch {
                if case MCPCredentialEditError.cleanupRequired(let reference) = error {
                    needsRecovery = true
                    self.error = "Saving failed and cleanup needs attention for credential reference \(reference.id). Refresh the connection before trying again."
                } else if token == generation {
                    self.error = "Credential could not be saved. Check the variable name, Keychain access and current configuration, then enter the value again."
                }
            }
            if token == generation { busy = false }
        }
    }
    /// Wait for save/rollback before dismissal and the parent's configuration refresh.
    func cancel() async -> Bool {
        generation = UUID(); let pending = task; pending?.cancel()
        value = ""; saved = false
        if !needsRecovery { error = nil }
        await pending?.value
        task = nil; busy = false
        return !needsRecovery
    }
}
#endif
