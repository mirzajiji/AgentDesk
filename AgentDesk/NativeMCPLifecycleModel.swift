#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

protocol NativeMCPLifecycle: Sendable {
    func prepare() async throws -> PolicyPreparation
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord
    func prepareCredentials() async throws -> PolicyPreparation
    func reviewCredentials(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord
    func start(approvalID: UUID, credentialApprovalID: UUID?) async throws -> MCPServerPresentation
    func prepareDiscovery() async throws -> PolicyPreparation
    func reviewDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord
    func discoverTools(approvalID: UUID?) async throws -> MCPToolCatalogPresentation
    func preparePromptDiscovery() async throws -> PolicyPreparation
    func reviewPromptDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord
    func discoverPrompts(approvalID: UUID?) async throws -> MCPPromptCatalogPresentation
    func prepareResourceDiscovery() async throws -> PolicyPreparation
    func reviewResourceDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord
    func discoverResources(approvalID: UUID?) async throws -> MCPResourceCatalogPresentation
    func ping() async throws
    func close() async
}
extension NativeMCPConnection: NativeMCPLifecycle {}

@MainActor final class NativeMCPLifecycleModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var pending: ApprovalRecord?
    @Published private(set) var reviewingCredentials = false
    @Published private(set) var reviewingDiscovery = false
    @Published private(set) var reviewingPrompts = false
    @Published private(set) var reviewingResources = false
    @Published private(set) var resourceCatalog: MCPResourceCatalogPresentation?
    @Published private(set) var promptCatalog: MCPPromptCatalogPresentation?
    @Published private(set) var catalog: MCPToolCatalogPresentation?
    @Published private(set) var message = "Review this connection before starting its process."
    private let needsCredentials: Bool
    private let open: () async throws -> any NativeMCPLifecycle
    private var session: (any NativeMCPLifecycle)?
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation = UUID()
    private var launchApproval: UUID?
    private var stopping = false
    init(needsCredentials: Bool, open: @escaping () async throws -> any NativeMCPLifecycle) {
        self.needsCredentials = needsCredentials; self.open = open
    }
    func prepare() {
        guard !busy, session == nil else { return }
        busy = true; let token = generation
        task = Task {
            do {
                let value = try await open()
                guard token == generation, !Task.isCancelled else { await value.close(); return }
                session = value
                guard case .approval(let record) = try await value.prepare() else { throw AuthorizationError.denied }
                guard token == generation, !Task.isCancelled else { return }
                pending = record; message = "Approve this exact process launch."
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    func approve() {
        guard !busy, let pending, let session else { return }
        busy = true; let token = generation, credentials = reviewingCredentials, discovery = reviewingDiscovery, prompts = reviewingPrompts, resources = reviewingResources
        task = Task {
            do {
                if resources {
                    _ = try await session.reviewResourceDiscovery(pending.id, approve: true, expectedSequence: pending.sequence)
                    try await loadResources(session, approvalID: pending.id, token: token)
                } else if prompts {
                    _ = try await session.reviewPromptDiscovery(pending.id, approve: true, expectedSequence: pending.sequence)
                    try await loadPrompts(session, approvalID: pending.id, token: token)
                } else if discovery {
                    _ = try await session.reviewDiscovery(pending.id, approve: true, expectedSequence: pending.sequence)
                    try await loadTools(session, approvalID: pending.id, token: token)
                } else if credentials {
                    _ = try await session.reviewCredentials(pending.id, approve: true, expectedSequence: pending.sequence)
                    try await start(session, credential: pending.id, token: token)
                } else {
                    _ = try await session.review(pending.id, approve: true, expectedSequence: pending.sequence)
                    guard token == generation, !Task.isCancelled else { return }
                    launchApproval = pending.id; self.pending = nil
                    if needsCredentials {
                        switch try await session.prepareCredentials() {
                        case .approval(let record):
                            guard token == generation, !Task.isCancelled else { return }
                            self.pending = record; reviewingCredentials = true
                            message = "Separately approve reading the configured credentials for this process."
                        case .allowed: try await start(session, credential: nil, token: token)
                        case .denied: throw AuthorizationError.denied
                        }
                    } else { try await start(session, credential: nil, token: token) }
                }
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    func discover() {
        guard connected, !busy, pending == nil, let session else { return }
        busy = true; catalog = nil; let token = generation
        task = Task {
            do {
                let preparation = try await session.prepareDiscovery()
                guard token == generation, !Task.isCancelled else { return }
                switch preparation {
                case .approval(let record):
                    pending = record; reviewingDiscovery = true
                    message = "Approve listing tools from this connection. This does not authorize running them."
                case .allowed: try await loadTools(session, approvalID: nil, token: token)
                case .denied: throw AuthorizationError.denied
                }
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    private func loadTools(_ session: any NativeMCPLifecycle, approvalID: UUID?, token: UUID) async throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        let result = try await session.discoverTools(approvalID: approvalID)
        guard token == generation, !Task.isCancelled else { return }
        catalog = result; pending = nil; reviewingDiscovery = false
        message = result.tools.isEmpty ? "This server returned no tools." : "Tool descriptions loaded."
    }
    func discoverPrompts() {
        guard connected, !busy, pending == nil, let session else { return }
        busy = true; promptCatalog = nil; let token = generation
        task = Task {
            do {
                let preparation = try await session.preparePromptDiscovery()
                guard token == generation, !Task.isCancelled else { return }
                switch preparation {
                case .approval(let record):
                    pending = record; reviewingPrompts = true
                    message = "Approve listing prompt descriptions from this connection."
                case .allowed: try await loadPrompts(session, approvalID: nil, token: token)
                case .denied: throw AuthorizationError.denied
                }
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    private func loadPrompts(_ session: any NativeMCPLifecycle, approvalID: UUID?, token: UUID) async throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        let result = try await session.discoverPrompts(approvalID: approvalID)
        guard token == generation, !Task.isCancelled else { return }
        promptCatalog = result; pending = nil; reviewingPrompts = false
        message = result.prompts.isEmpty ? "This server returned no prompts." : "Prompt descriptions loaded."
    }
    func discoverResources() {
        guard connected, !busy, pending == nil, let session else { return }
        busy = true; resourceCatalog = nil; let token = generation
        task = Task {
            do {
                let preparation = try await session.prepareResourceDiscovery()
                guard token == generation, !Task.isCancelled else { return }
                switch preparation {
                case .approval(let record):
                    pending = record; reviewingResources = true
                    message = "Approve listing resource descriptions from this connection."
                case .allowed: try await loadResources(session, approvalID: nil, token: token)
                case .denied: throw AuthorizationError.denied
                }
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    private func loadResources(_ session: any NativeMCPLifecycle, approvalID: UUID?, token: UUID) async throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        let result = try await session.discoverResources(approvalID: approvalID)
        guard token == generation, !Task.isCancelled else { return }
        resourceCatalog = result; pending = nil; reviewingResources = false
        message = result.resources.isEmpty ? "This server returned no resources." : "Resource descriptions loaded."
    }
    func checkHealth() {
        guard connected, !busy, let session else { return }
        busy = true; let token = generation
        task = Task {
            do {
                try await session.ping()
                if token == generation { message = "Server responded to the health check." }
            } catch { await failed(token) }
            if token == generation { busy = false }
        }
    }
    func stop() {
        guard !stopping else { return }; stopping = true
        generation = UUID(); task?.cancel(); task = nil
        let old = session; session = nil; pending = nil; launchApproval = nil
        connected = false; reviewingCredentials = false; reviewingDiscovery = false; catalog = nil; reviewingPrompts = false; promptCatalog = nil; reviewingResources = false; resourceCatalog = nil; busy = true; message = "Stopping…"
        let token = generation, cleanup = enqueueCleanup(old)
        task = Task {
            await cleanup.value
            if token == generation { cleanupTask = nil; busy = false; stopping = false; message = "Stopped." }
        }
    }
    private func start(_ value: any NativeMCPLifecycle, credential: UUID?, token: UUID) async throws {
        guard token == generation, !Task.isCancelled, let launchApproval else { throw CancellationError() }
        let result = try await value.start(approvalID: launchApproval, credentialApprovalID: credential)
        guard token == generation, !Task.isCancelled else { await value.close(); return }
        connected = true; pending = nil; reviewingCredentials = false
        message = "Connected using MCP \(result.mode.rawValue)." + (result.name.map { " Server: \($0.text)" } ?? "")
    }
    private func failed(_ token: UUID) async {
        guard token == generation else { return }
        let old = session; session = nil; pending = nil; launchApproval = nil; connected = false; reviewingCredentials = false; reviewingDiscovery = false; catalog = nil; reviewingPrompts = false; promptCatalog = nil; reviewingResources = false; resourceCatalog = nil
        let cleanup = enqueueCleanup(old)
        await cleanup.value
        if token == generation {
            cleanupTask = nil
            message = "Connection failed or was denied. Check the executable, registered repository and current permissions, then review again."
        }
    }
    /// A cancelled UI operation cannot discard cleanup that already owns a process.
    private func enqueueCleanup(_ value: (any NativeMCPLifecycle)?) -> Task<Void, Never> {
        let previous = cleanupTask
        let cleanup = Task { await previous?.value; await value?.close() }
        cleanupTask = cleanup
        return cleanup
    }
}
#endif
