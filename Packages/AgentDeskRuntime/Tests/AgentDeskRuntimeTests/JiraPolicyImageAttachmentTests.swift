import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import XCTest
@testable import AgentDeskPlugins
@testable import AgentDeskRuntime

@MainActor final class JiraPolicyImageAttachmentTests: XCTestCase {
    func testUnapprovedAndDeniedAttachmentsNeverDispatchThenApprovalRunsOnce() async throws {
        try await exerciseDispatch(networkFailure: false)
    }
    func testUnknownOutcomeStillConsumesApprovalAcrossReopen() async throws {
        try await exerciseDispatch(networkFailure: true)
    }
    private func makeDraft(identifier: String, filename: RedactedText, content: RedactedText) throws -> JiraImageAttachmentDraft {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 255, count: 16) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let masked = try ImageEvidenceRedactor.mask(data as Data, regions: [.init(x: 0, y: 0, width: 1, height: 1)], in: content.context)
        return try JiraImageAttachmentDraft(identifier: identifier, filename: filename, image: masked)
    }
    private func exerciseDispatch(networkFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date().addingTimeInterval(600), scopes: ["write:jira-work", "read:jira-work"])
        let vault = try JiraCredentialVault(configuration: config, store: JiraImagePolicySecrets(scope: secretScope))
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work", "read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [JiraImagePolicyProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"Synthetic","active":true}"#.utf8)))
        let connection = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment], operations: [.externalMutation, .readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let identifier = networkFailure ? "SYN-2" : "SYN-1"
        let path = resource.apiOrigin.path + "/rest/api/3/issue/\(identifier)/attachments"
        for disposition: PolicyDisposition in [.deny, .approval] {
            let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.attachmentsAdd, disposition), .init(.attachmentsRead, .allow)])
            let readAction = try await connection.prepare(.attachmentSettings, configurationRevision: 1, permissions: permissions, runID: context.runID)
            let readGate = try PluginPolicySession(prepared: readAction, policy: policy, permissions: permissions, authorities: [user], requesterID: user.id, store: store, validateCurrent: { (readAction, policy) })
            let operation = try makeDraft(identifier: identifier, filename: redactor.redactText("evidence.png", in: context), content: redactor.redactText("Reviewed evidence", in: context))
            JiraImagePolicyProtocol.sizes.withLock { $0[path] = operation.byteCount }
            let prepared = try await connection.prepareImageAttachment(operation, configurationRevision: 1, permissions: permissions, runID: context.runID)
            let gate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions, authorities: [user], requesterID: user.id, store: store, validateCurrent: { (prepared, policy) })
            do {
                _ = try await gate.executeJiraImageAttachment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, readSession: readGate)
                XCTFail("Unauthorized attachment dispatched")
            } catch { XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired) }
            XCTAssertEqual(JiraImagePolicyProtocol.counts.withLock { $0[path, default: 0] }, 0)
            if disposition == .approval {
                guard case .approval(let pending) = try await gate.prepare() else { return XCTFail("Missing approval") }
                _ = try await gate.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
                do {
                    _ = try await gate.executeJiraImageAttachment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, readSession: readGate, approvalID: pending.id)
                    XCTAssertFalse(networkFailure)
                } catch {
                    XCTAssertTrue(networkFailure)
                    XCTAssertEqual(error as? JiraMutationError, .outcomeUnknown)
                }
                XCTAssertEqual(JiraImagePolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
                do {
                    _ = try await gate.executeJiraImageAttachment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, readSession: readGate, approvalID: pending.id)
                    XCTFail("Attachment approval replayed")
                } catch { }
                let reopened = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
                let persisted = try await reopened.approval(pending.id)
                XCTAssertEqual(persisted?.state, .consumed)
                let ledger = try reopened.mutationAttempts()
                let attempt = try await ledger.record(prepared.action.id)
                XCTAssertEqual(attempt?.outcome, networkFailure ? .unresolved : .acknowledged)
                XCTAssertEqual(attempt?.approvalID, pending.id)
                let restoredGate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions,
                    authorities: [user], requesterID: user.id, store: reopened, validateCurrent: { (prepared, policy) })
                do {
                    _ = try await restoredGate.executeJiraImageAttachment(operation, connection: connection, permissions: permissions,
                        context: context, redactor: redactor, readSession: readGate, approvalID: pending.id)
                    XCTFail("Persisted approval replayed through a new gate")
                } catch { }
                XCTAssertEqual(JiraImagePolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
            }
        }
        let finalPermissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.attachmentsAdd, .approval), .init(.attachmentsRead, .allow)])
        let finalReadAction = try await connection.prepare(.attachmentSettings, configurationRevision: 1, permissions: finalPermissions, runID: context.runID)
        let readGate = try PluginPolicySession(prepared: finalReadAction, policy: policy, permissions: finalPermissions, authorities: [user], requesterID: user.id, store: store, validateCurrent: { (finalReadAction, policy) })
        let finalDraft = try makeDraft(identifier: identifier, filename: redactor.redactText("evidence.png", in: context), content: redactor.redactText("New reviewed evidence", in: context))
        let finalAction = try await connection.prepareImageAttachment(finalDraft, configurationRevision: 1, permissions: finalPermissions, runID: context.runID)
        let finalGate = try PluginPolicySession(prepared: finalAction, policy: policy, permissions: finalPermissions,
            authorities: [user], requesterID: user.id, store: store, validateCurrent: { (finalAction, policy) })
        guard case .approval(let review) = try await finalGate.prepare() else { return XCTFail("Missing final review") }
        _ = try await finalGate.review(review.id, reviewerID: user.id, approve: true, expectedSequence: review.sequence)
        do {
            _ = try await finalGate.executeJiraImageAttachment(finalDraft, connection: connection, permissions: finalPermissions,
                context: context, redactor: redactor, readSession: readGate, approvalID: review.id,
                beforeDispatch: { await finalGate.removeAuthority(user.id) })
            XCTFail("Authority revoked during evidence validation still dispatched")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        XCTAssertEqual(JiraImagePolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
        await connection.close()
        _ = JiraImagePolicyProtocol.counts.withLock { $0.removeValue(forKey: path) }
        _ = JiraImagePolicyProtocol.sizes.withLock { $0.removeValue(forKey: path) }
    }
}
private actor JiraImagePolicySecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values[reference] = value }
    func get(_ reference: SecretReference) throws -> SecretValue? { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; return values[reference] }
    func delete(_ reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values.removeValue(forKey: reference) }
    func exists(_ reference: SecretReference) throws -> Bool { try get(reference) != nil }
}
private final class JiraImagePolicyProtocol: URLProtocol {
    static let sizes = Mutex<[String: Int]>([:])
    static let counts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.counts.withLock { $0[url.path, default: 0] += 1 }
        if url.path.hasSuffix("/attachment/meta") {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"enabled":true,"uploadLimit":1000}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.path.contains("/SYN-2/") {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = Self.sizes.withLock { $0[url.path] ?? -1 }
        client?.urlProtocol(self, didLoad: Data("[{\"id\":\"123\",\"filename\":\"evidence.png\",\"size\":\(size)}]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
