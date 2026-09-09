#if os(macOS)
import AgentDeskRuntime
import Combine
import Foundation

struct CodexLocalConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var enabled = true
    var executablePath: String?
    func validate() throws {
        guard schemaVersion == 1 else { throw CodexSettingsError.invalidConfiguration }
        if let path = executablePath {
            guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CodexSettingsError.invalidConfiguration
            }
        }
    }
}

enum CodexSettingsError: Error { case invalidConfiguration }

/// A small machine-local, nonsecret JSON file in the application's own support directory.
@MainActor
final class CodexSettingsStore {
    private let file: URL
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("codex.json")
    }
    func load() throws -> CodexLocalConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return CodexLocalConfiguration() }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_192,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw CodexSettingsError.invalidConfiguration }
        let value = try JSONDecoder().decode(CodexLocalConfiguration.self, from: Data(contentsOf: file))
        try value.validate(); return value
    }
    func save(_ value: CodexLocalConfiguration) throws {
        try value.validate()
        // Validate an existing record before replacing it; corrupt files remain available for diagnosis.
        _ = try load()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func applicationStore() throws -> CodexSettingsStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("AgentDesk/Settings")
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["AGENTDESK_TEST_CONTAINER_ID"], let id = UUID(uuidString: raw) {
            directory = support.appendingPathComponent("AgentDesk/UITesting/\(id.uuidString)/Settings")
        }
        #endif
        return try CodexSettingsStore(directory: directory)
    }
}

@MainActor
final class CodexSettingsModel: ObservableObject {
    enum Activity: String { case checking = "Checking Codex…", signingIn = "Continue signing in in your browser…", signingOut = "Signing out…" }
    @Published private(set) var configuration = CodexLocalConfiguration()
    @Published private(set) var snapshot: CodexDiagnosticSnapshot?
    @Published private(set) var activity: Activity?
    @Published private(set) var errorMessage: String?
    private let service: any CodexDiagnosing
    private var store: CodexSettingsStore?
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(service: any CodexDiagnosing = CodexHostClient(), store: CodexSettingsStore? = nil) {
        self.service = service
        do {
            let store = try store ?? CodexSettingsStore.applicationStore()
            configuration = try store.load(); self.store = store
        } catch { errorMessage = "Codex settings couldn’t be opened. Check the local settings file before trying again." }
    }
    deinit { operation?.cancel() }

    var isBusy: Bool { activity != nil }
    var canConfigure: Bool { store != nil && !isBusy }
    var canLogin: Bool { configuration.enabled && !isBusy && snapshot?.installation?.capabilities.login == true }
    var canLogout: Bool { configuration.enabled && !isBusy && snapshot?.installation?.capabilities.logout == true && snapshot?.authentication != .signedOut }
    var status: String {
        if !configuration.enabled { return "Disconnected" }
        if let activity { return activity.rawValue }
        guard let snapshot else { return "Not checked" }
        if let issue = snapshot.issue { return Self.message(issue) }
        switch snapshot.authentication {
        case .chatGPT: return "ChatGPT credentials found"
        case .signedOut: return "Sign in to Codex"
        case .unsupportedMethod: return "ChatGPT sign-in required"
        case .unknown: return "Sign-in status unavailable"
        }
    }

    func refresh() {
        guard configuration.enabled, store != nil else { return }
        let selected = configuration.executablePath.map { URL(fileURLWithPath: $0) }, service = service
        start(.checking) { try await service.inspect(executable: selected) }
    }
    func login() {
        guard canLogin, let installation = snapshot?.installation else { return }
        let service = service
        start(.signingIn) { try await service.login(using: installation) }
    }
    func logout() {
        guard canLogout, let installation = snapshot?.installation else { return }
        let service = service
        start(.signingOut) { try await service.logout(using: installation) }
    }
    func cancel() {
        generation += 1; operation?.cancel(); operation = nil; activity = nil; snapshot = nil
    }
    func setEnabled(_ enabled: Bool) {
        var next = configuration; next.enabled = enabled
        guard save(next) else { return }
        cancel()
        if enabled { refresh() }
    }
    func chooseExecutable(_ location: URL?) {
        guard canConfigure else { return }
        if let location, !location.isFileURL { errorMessage = "Choose a local Codex executable."; return }
        var next = configuration; next.executablePath = location?.path
        guard save(next) else { return }
        snapshot = nil; refresh()
    }
    private func save(_ next: CodexLocalConfiguration) -> Bool {
        guard let store else { return false }
        do { try store.save(next); configuration = next; errorMessage = nil; return true }
        catch { errorMessage = "Codex settings couldn’t be saved. Your previous settings are preserved."; return false }
    }
    private func start(_ activity: Activity, work: @escaping @Sendable () async throws -> CodexDiagnosticSnapshot) {
        guard !isBusy else { return }
        generation += 1; let token = generation
        self.activity = activity; errorMessage = nil
        operation = Task { [weak self] in
            do {
                let result = try await work()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.snapshot = result; self.activity = nil; self.operation = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.activity = nil; self.operation = nil; self.snapshot = nil
                if !(error is CancellationError) { self.errorMessage = Self.message(error as? CodexDiagnosticIssue ?? .commandFailed) }
            }
        }
    }
    static func message(_ issue: CodexDiagnosticIssue) -> String {
        switch issue {
        case .notInstalled: "Codex CLI not found"
        case .invalidExecutable: "Choose a valid Codex executable"
        case .incompatibleCLI: "This CLI version isn’t supported"
        case .permissionDenied: "Permission to run Codex was denied"
        case .timedOut: "Codex didn’t respond in time"
        case .outputLimit: "Codex returned too much diagnostic output"
        case .commandFailed: "Couldn’t check Codex"
        case .busy: "Another Codex account operation is in progress"
        }
    }
}
#endif
