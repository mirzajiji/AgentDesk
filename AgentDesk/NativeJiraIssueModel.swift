#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

@MainActor
final class NativeJiraIssueModel: ObservableObject {
    @Published var identifier = ""
    @Published private(set) var busy = false
    @Published private(set) var pending: ApprovalRecord?
    @Published private(set) var content: String?
    @Published private(set) var message: String?
    private var review: NativeJiraReadReview?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let open: (String) async throws -> NativeJiraReadReview

    init(open: @escaping (String) async throws -> NativeJiraReadReview) { self.open = open }
    func lookup() {
        guard !busy else { return }
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 128 else { message = "Enter a Jira issue key."; return }
        cancel(); let token = generation
        busy = true; content = nil; message = nil
        task = Task {
            do {
                let session = try await open(key)
                guard token == generation, !Task.isCancelled else { await session.close(); return }
                review = session
                switch try await session.prepare() {
                case .allowed: try await display(session, approval: nil, token: token)
                case .approval(let record):
                    if token == generation { pending = record; message = "Review this issue read before contacting Jira for its content." }
                case .denied:
                    if token == generation { message = "Reading this issue is denied by current permissions." }
                    await session.close()
                }
            } catch {
                if token == generation {
                    message = "Issue lookup failed. Check the connection, issue key and current permissions."
                    if let review { await review.close() }
                }
            }
            if token == generation { busy = false }
        }
    }
    func approve() {
        guard !busy, let pending, let review else { return }
        busy = true; let token = generation
        task = Task {
            do {
                _ = try await review.review(pending.id, approve: true, expectedSequence: pending.sequence)
                try await display(review, approval: pending.id, token: token)
            } catch { if token == generation { message = "The reviewed read could not finish. Start a new lookup to check current permissions." } }
            if token == generation { self.pending = nil; busy = false }
            await review.close()
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        let old = review; review = nil; pending = nil; busy = false; content = nil; message = nil
        if let old { Task { await old.close() } }
    }
    private func display(_ session: NativeJiraReadReview, approval: UUID?, token: UUID) async throws {
        let result = try await session.execute(approvalID: approval)
        guard token == generation, !Task.isCancelled else { return }
        switch result {
        case .executed(.json(let text)): content = text.text; message = "Issue content received from Jira. Sensitive fields are masked."
        case .dryRun: message = "Dry run: no Jira issue request was sent."
        default: message = "Jira returned an unsupported result."
        }
        await session.close()
    }
}

extension WorkspaceBrowserModel {
    func openJiraIssue(project: ProjectRecord, record: PluginConfigurationRevision<JiraConnectionConfiguration>, identifier: String) async throws -> NativeJiraReadReview {
        let services = try await executionServices(for: project)
        let configuration = record.configuration
        guard configuration.scope == project.scope, configuration.enabled, let reference = configuration.credential else {
            throw AuthorizationError.scopeMismatch
        }
        let store = try await services.catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        guard let latest = try await store.read(id: configuration.id, in: project.scope),
              latest.revision == record.revision, latest.configuration == configuration else { throw ExecutionSetupError.staleContext }
        let setup = services.setup, environment = configuration.environmentID
        _ = try await setup.settings().policy(environmentID: environment)
        let context = RedactionContext(scope: project.scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        // Establishing the authenticated connection only performs account/site discovery.
        // Issue content is fetched exclusively through the runtime policy gate below.
        let connected = try await JiraCloudAdapter(store: KeychainSecretStore(scope: reference.scope)).connect(configuration)
        guard let connection = connected as? JiraCloudSession else { await connected.close(); throw JiraServiceError.unavailable }
        do {
            try Task.checkCancellation()
            let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [project.scope], environments: [environment],
                operations: [.readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(1800))
            let approvals = try ApprovalStore(database: services.database, scope: project.scope, environmentID: environment)
            return try await NativeJiraReadReview.open(connection: connection, operation: .issue(identifier: identifier),
                configurations: store, connectionID: configuration.id, context: context, redactor: redactor,
                authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: {
                    try await setup.settings().policy(environmentID: environment)
                })
        } catch { await connection.close(); throw error }
    }
}
#endif
