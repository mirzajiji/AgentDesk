#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import Combine
import Foundation

enum NativeConsoleError: Error { case codexUnavailable }

@MainActor
final class NativeRunSession: ObservableObject {
    enum Phase { case idle, preparing, prepared, running, finished, closing }
    typealias Open = (ProjectNativeServices, ProjectRunContext) async throws -> NativeRunService
    @Published private(set) var phase = Phase.idle
    @Published private(set) var prepared: PreparedRun?
    @Published private(set) var inputSnapshot: String?
    @Published private(set) var run: StoredRun?
    @Published private(set) var progress: RunWorkPlan?
    @Published private(set) var outcome: RunOutcome?
    @Published private(set) var errorMessage: String?
    private(set) var service: NativeRunService?
    private var context: ProjectRunContext?
    private var setup: ProjectExecutionSetupService?
    private var execution: RunExecution?
    private var observation: Task<Void, Never>?
    private var completion: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var subscription: RunEventSubscription?
    private var closing: Task<Void, Never>?
    private var generation = 0
    private let open: Open
    private let registry: NativeRunRegistry

    init(registry: NativeRunRegistry = .shared, open: Open? = nil) {
        self.registry = registry; self.open = open ?? Self.openNative
    }
    deinit {
        execution?.cancel(); observation?.cancel(); completion?.cancel(); monitoring?.cancel(); subscription?.cancel()
        let service = service, registry = registry
        Task { @MainActor in
            if let service { await service.shutdown(); registry.release(service) }
        }
    }
    var hasPendingWork: Bool { phase == .preparing || phase == .prepared || phase == .running || phase == .closing }

    func prepare(using model: ProjectRunContextModel, task: String) async {
        guard !hasPendingWork else { return }
        await close()
        phase = .preparing; errorMessage = nil; outcome = nil; run = nil; progress = nil; inputSnapshot = nil
        let token = generation
        do {
            let context = try await model.contextForPreparation()
            guard let services = model.services else { throw ExecutionSetupError.staleContext }
            let service = try await open(services, context)
            guard token == generation else { await service.shutdown(); return }
            self.service = service
            try await registry.register(service)
            let prepared = try await service.prepare(context: context, setup: services.setup, task: task)
            let snapshot = try await service.inputSnapshot(for: prepared.runID)
            let run = try await service.run(prepared.runID)
            try Task.checkCancellation()
            guard token == generation else { return }
            self.context = context; setup = services.setup; self.prepared = prepared
            inputSnapshot = snapshot.text; self.run = run; phase = .prepared
            observe(prepared.runID, service: service, token: token)
            monitor(context, setup: services.setup, token: token)
        } catch {
            if token == generation { await close(); errorMessage = Self.message(error) }
        }
    }

    /// The UI invokes this only after the user reviews the bound input snapshot/action.
    func start() async {
        guard phase == .prepared, let prepared, let service, let context, let setup else { return }
        phase = .preparing; let token = generation
        do {
            try await setup.validate(context)
            if let approval = prepared.approval {
                _ = try await service.review(prepared, approve: true, expectedSequence: approval.sequence)
            }
            try await setup.validate(context)
            let execution = try await service.start(prepared)
            guard token == generation else { execution.cancel(); return }
            self.execution = execution; phase = .running
            completion = Task { [weak self] in
                let result = await execution.result()
                guard let self, self.generation == token else { return }
                self.monitoring?.cancel()
                do {
                    let run = try await service.run(result.runID)
                    let progress = try await service.progress(for: result.runID)
                    guard self.generation == token else { return }
                    self.run = run; self.progress = progress
                } catch { if self.generation == token { self.errorMessage = Self.message(error) } }
                guard self.generation == token else { return }
                self.outcome = result; self.phase = .finished
            }
        } catch { if token == generation { await close(); errorMessage = Self.message(error) } }
    }

    func reject() async {
        guard phase == .prepared, let service, let prepared else { return }
        phase = .preparing; let token = generation
        do {
            if let approval = prepared.approval {
                _ = try await service.review(prepared, approve: false, expectedSequence: approval.sequence)
            }
            let result = try await service.discard(prepared)
            guard token == generation else { return }
            outcome = result; phase = .finished; monitoring?.cancel()
        } catch { if token == generation { await close(); errorMessage = Self.message(error) } }
    }
    func cancelExecution() { execution?.cancel() }

    func close() async {
        if let closing { await closing.value; return }
        generation += 1; phase = .closing
        observation?.cancel(); observation = nil; subscription?.cancel(); subscription = nil
        completion?.cancel(); completion = nil; monitoring?.cancel(); monitoring = nil
        execution?.cancel(); execution = nil
        let service = service; self.service = nil
        prepared = nil; context = nil; setup = nil
        let registry = registry
        let cleanup = Task {
            if let service { await service.shutdown(); registry.release(service) }
        }
        closing = cleanup
        await cleanup.value
        closing = nil; phase = .idle
    }

    private func observe(_ id: RunID, service: NativeRunService, token: Int) {
        observation = Task { [weak self] in
            var cursor: Int64 = 0
            while !Task.isCancelled {
                do {
                    let next = try await service.subscribe(to: id, after: cursor)
                    guard self?.generation == token else { next.cancel(); return }
                    self?.subscription = next
                    for try await event in next.events {
                        guard let self, self.generation == token else { next.cancel(); return }
                        cursor = event.sequence
                        let run = try await service.run(id)
                        guard self.generation == token else { next.cancel(); return }
                        self.run = run
                        if let progress = event.progress { self.progress = progress }
                    }
                    return
                } catch RunLifecycleError.replayRequired {
                    do {
                        let history = try await service.history(for: id, after: cursor)
                        guard let self, self.generation == token else { return }
                        for event in history { cursor = event.sequence; if let progress = event.progress { self.progress = progress } }
                        let run = try await service.run(id)
                        guard self.generation == token else { return }
                        self.run = run
                    } catch { if let self, self.generation == token { self.errorMessage = Self.message(error) }; return }
                } catch is CancellationError { return }
                catch { if let self, self.generation == token { self.errorMessage = Self.message(error) }; return }
            }
        }
    }
    private func monitor(_ context: ProjectRunContext, setup: ProjectExecutionSetupService, token: Int) {
        monitoring = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(500))
                    try await setup.validate(context)
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                await self.close()
                self.errorMessage = error as? CatalogError == .busy
                    ? Self.message(error)
                    : "The reviewed configuration or sources changed or could not be verified. Review the current context before another run."
            }
        }
    }

    private static func openNative(_ services: ProjectNativeServices, _ context: ProjectRunContext) async throws -> NativeRunService {
        #if DEBUG
        if NativeRunUITestSupport.mode() != nil { return try await NativeRunUITestSupport.open(services, context: context) }
        #endif
        let settings = try CodexSettingsStore.applicationStore().load()
        guard settings.enabled else { throw NativeConsoleError.codexUnavailable }
        let diagnostics = try await CodexHostClient().inspect(executable: settings.executablePath.map { URL(fileURLWithPath: $0) })
        guard diagnostics.issue == nil, diagnostics.authentication == .chatGPT, let installation = diagnostics.installation else {
            throw NativeConsoleError.codexUnavailable
        }
        let repository = try await services.repositories.access(in: context.scope)
        return try await NativeRunService.open(database: services.database, repository: repository,
            executable: installation.executable, configuration: context.configuration)
    }
    static func message(_ error: any Error) -> String {
        if error as? CatalogError == .busy {
            return "Project configuration is busy. Wait for current activity to finish, then review the context and retry."
        }
        if error is CancellationError { return "The operation was cancelled." }
        if error is AuthorizationError { return "This operation is not authorized by the current policy or approval. Review the current settings." }
        if error is ExecutionSetupError { return "The reviewed context is no longer current. Reload and review it before preparing a run." }
        if error is NativeConsoleError { return "Open Codex Settings and verify an enabled, signed-in Codex installation." }
        if error as? RunCoordinatorError == .busy { return "Another run session owns this project. Close it before opening a new session." }
        return "The run operation could not complete. Check project setup and the current run state before retrying."
    }
}
#endif
