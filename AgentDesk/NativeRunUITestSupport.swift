#if DEBUG && os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
@testable import AgentDeskRuntime

/// Available only in Debug, only in a UUID-scoped UI-test container. Never selects user data.
enum NativeRunUITestSupport {
    static func mode() -> String? {
        guard let id = ProcessInfo.processInfo.environment["AGENTDESK_TEST_CONTAINER_ID"], UUID(uuidString: id) != nil,
              let mode = ProcessInfo.processInfo.environment["AGENTDESK_TEST_RUN_MODE"], ["success", "quiet", "diff", "stream"].contains(mode) else { return nil }
        return mode
    }
    static func root() throws -> URL {
        guard mode() != nil, let raw = ProcessInfo.processInfo.environment["AGENTDESK_TEST_CONTAINER_ID"],
              let id = UUID(uuidString: raw) else { throw CatalogError.invalidConfiguration }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("AgentDesk/UITesting/\(id.uuidString)")
    }
    static func seed(catalog: WorkspaceCatalog, applicationRoot: URL) async throws {
        guard mode() != nil else { return }
        guard applicationRoot.standardizedFileURL == (try root()).standardizedFileURL else { throw CatalogError.invalidConfiguration }
        guard try await catalog.workspaces().isEmpty else { return }
        let workspace = try await catalog.createWorkspace(name: "Synthetic run workspace")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic run project")
        let setup = ProjectExecutionSetupService(catalog: catalog, scope: project.scope)
        for level in [ExecutionConfigurationLevel.workspace, .project] {
            let draft = try await setup.proposedDefaults(at: level)
            _ = try await setup.save(draft, at: level, expectedRevision: nil)
        }
        _ = try await catalog.agentStore(in: project.scope).create(.init(name: "Synthetic reviewer",
            instructions: "Inspect synthetic files only."), in: project.scope)
        if let mode = ProcessInfo.processInfo.environment["AGENTDESK_TEST_BUG_REVIEW_MODE"], ["duplicate", "ambiguous"].contains(mode) {
            guard let environment = try await setup.settings().project?.draft.environments.first?.id else { throw CatalogError.invalidConfiguration }
            let requirements = try await catalog.requirementStore(in: project.scope), id = RequirementID(rawValue: "synthetic-refund")!
            let requirement = try await requirements.prepare(.init(description: "Accept a valid synthetic refund", changeReason: "UI fixture", status: .active), id: id, expectedVersion: nil, in: project.scope)
            _ = try await requirements.publishReviewed(requirement, in: project.scope)
            let bugs = try await catalog.bugStore(in: project.scope)
            var draft = BugDraft(title: "Incoming synthetic finding", sources: [.init(scope: project.scope, origin: .observed, label: "Synthetic UI fixture", capturedAt: Date())],
                changeReason: "UI fixture", assessment: .observed, environment: environment,
                rootBehavior: "Valid synthetic refund rejected", expectedBehavior: "Accept", actualBehavior: "Reject", reproduction: ["Request a synthetic refund"],
                details: ["endpoint": .text("POST /synthetic/refunds"), "password": .text("synthetic-review-secret")])
            let incoming = try await bugs.prepare(draft, requirements: [.init(requirement: .init(id: id))], in: project.scope)
            _ = try await bugs.publishReviewed(incoming, in: project.scope)
            draft.title = "Existing synthetic ticket"; draft.ticket = try .init(key: "SYN-42")
            if mode == "ambiguous" { draft.actualBehavior = "Reject only after retry" }
            let existing = try await bugs.prepare(draft, requirements: [.init(requirement: .init(id: id))], in: project.scope)
            _ = try await bugs.publishReviewed(existing, in: project.scope)
        }
    }
    static func openReview(_ services: ProjectNativeServices, context: ProjectRunContext) async throws -> NativeRunService {
        guard mode() != nil else { throw CatalogError.invalidConfiguration }
        let expected = try root().appendingPathComponent("Data/\(context.scope.workspaceID)/operations.sqlite")
        guard services.database.standardizedFileURL == expected.standardizedFileURL,
              services.setup.scope == context.scope else { throw CatalogError.invalidConfiguration }
        return try await NativeRunService.openReview(database: services.database,
            directory: services.database.deletingLastPathComponent(), configuration: context.configuration)
    }
    static func open(_ services: ProjectNativeServices, context: ProjectRunContext) async throws -> NativeRunService {
        guard let mode = mode() else { throw CatalogError.invalidConfiguration }
        let expected = try root().appendingPathComponent("Data/\(context.scope.workspaceID)/operations.sqlite")
        guard services.database.standardizedFileURL == expected.standardizedFileURL,
              services.setup.scope == context.scope else { throw CatalogError.invalidConfiguration }
        let provider = try UITestExecutionProvider(scope: context.scope, quiet: mode == "quiet", streaming: mode == "stream",
            diffDatabase: mode == "diff" ? services.database : nil)
        return try await NativeRunService.open(database: services.database, directory: services.database.deletingLastPathComponent(),
            configuration: context.configuration, captureRepository: false, provider: provider)
    }
}

private actor UITestExecutionProvider: ExecutionProvider {
    nonisolated let resource: ExecutionResource
    private let quiet: Bool
    private let streaming: Bool
    private let diffDatabase: URL?
    init(scope: ProjectScope, quiet: Bool, streaming: Bool, diffDatabase: URL?) throws {
        resource = try .directory(in: scope, device: 1, inode: 2); self.quiet = quiet; self.streaming = streaming; self.diffDatabase = diffDatabase
    }
    func start(_ request: ExecutionRequest) async throws -> ProviderExecution {
        if let database = diffDatabase {
            // Synthetic stored diff for presentation acceptance; real Git capture has its own integration tests.
            let identity = request.identity
            let context = RedactionContext(scope: identity.scope, environmentID: identity.environmentID, runID: identity.runID)
            let redactor = try ContentRedactor(context: context)
            let diff = "diff --git a/synthetic.txt b/synthetic.txt\n--- a/synthetic.txt\n+++ b/synthetic.txt\n@@ -1 +1 @@\n-old synthetic line\n+new synthetic line\n"
            let store = try EvidenceStore(database: database, context: context, agentID: identity.agentID)
            _ = try await store.publishArtifact(redactor.redactText(diff, in: context), kind: .diff,
                source: .repository, basis: .observed, format: .diff)
        }
        let (events, output) = AsyncThrowingStream<ExecutionProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        output.yield(.init(identity: request.identity, sequence: 1, payload: .started))
        if !quiet {
            let text = "Synthetic result: reviewed files.\npassword=synthetic-ui-result-secret"
            output.yield(.init(identity: request.identity, sequence: 2, payload: .message(id: "result", text: text)))
            if !streaming {
                output.yield(.init(identity: request.identity, sequence: 3, payload: .completed(text: text)))
                output.finish()
            }
        }
        return ProviderExecution(events: events) { output.finish(throwing: CancellationError()) }
    }
}
#endif
