#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import Combine
import Foundation

/// Owns the review-only project's lease and selected repository grant until the sheet closes.
@MainActor
final class NativeBugReviewSession: ObservableObject {
    @Published private(set) var model: NativeBugReviewModel?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var service: NativeRunService?
    private var monitoring: Task<Void, Never>?
    private var generation = 0
    private var closing: Task<Void, Never>?
    typealias Open = (ProjectNativeServices, ProjectRunContext) async throws -> NativeRunService
    private let openService: Open
    init(open: Open? = nil) { openService = open ?? Self.openNative }
    private static func openNative(_ services: ProjectNativeServices, _ context: ProjectRunContext) async throws -> NativeRunService {
        #if DEBUG
        if NativeRunUITestSupport.mode() != nil { return try await NativeRunUITestSupport.openReview(services, context: context) }
        #endif
        let repository = try await services.repositories.access(in: context.scope)
        return try await NativeRunService.openReview(database: services.database, repository: repository, configuration: context.configuration)
    }

    deinit {
        monitoring?.cancel()
        if let service { Task { await service.shutdown() } }
    }

    func open(using selection: ProjectRunContextModel, incomingID: BugID) async {
        await close()
        busy = true; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            let context = try await selection.contextForPreparation()
            guard let services = selection.services else { throw ExecutionSetupError.staleContext }
            let opened = try await openService(services, context)
            guard token == generation, !Task.isCancelled else { await opened.shutdown(); return }
            service = opened
            let model = NativeBugReviewModel(service: opened, catalog: services.catalog, incomingID: incomingID,
                validateContext: { try await services.setup.validate(context) })
            self.model = model
            await model.load()
            guard token == generation else { return }
            try Task.checkCancellation()
            monitoring = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        try await services.setup.validate(context)
                    }
                } catch is CancellationError { } catch {
                    guard let self, self.generation == token else { return }
                    await self.close()
                    self.error = "The selected context changed. Review the current agent and environment before continuing."
                }
            }
        } catch {
            if token == generation {
                await close()
                self.error = NativeRunSession.message(error)
            }
        }
    }

    func close() async {
        if let closing { await closing.value; return }
        generation += 1; monitoring?.cancel(); monitoring = nil
        model?.cancel(); model = nil; busy = false
        let previous = service; service = nil
        let cleanup = Task { if let previous { await previous.shutdown() } }
        closing = cleanup
        await cleanup.value; closing = nil
    }
}
#endif
