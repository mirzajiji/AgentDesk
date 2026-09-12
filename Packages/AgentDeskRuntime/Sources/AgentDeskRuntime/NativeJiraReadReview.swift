import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation

/// Owns a dedicated, already authenticated connection for one local-user read review.
/// Connection establishment is a separate native administrative action.
public actor NativeJiraReadReview {
    private let gate: PluginPolicySession
    private let connection: JiraCloudSession
    private let operation: JiraReadOperation
    private let permissions: PluginPermissions
    private let context: RedactionContext
    private let redactor: ContentRedactor
    private let requesterID: UUID
    private var closed = false

    private init(gate: PluginPolicySession, connection: JiraCloudSession, operation: JiraReadOperation,
                 permissions: PluginPermissions, context: RedactionContext, redactor: ContentRedactor, requesterID: UUID) {
        self.gate = gate; self.connection = connection; self.operation = operation
        self.permissions = permissions; self.context = context; self.redactor = redactor; self.requesterID = requesterID
    }

    public static func open(connection: JiraCloudSession, operation: JiraReadOperation,
                            configurations: ProjectPluginConfigurationStore<JiraConnectionConfiguration>, connectionID: UUID,
                            context: RedactionContext, redactor: ContentRedactor,
                            authorities: [PolicyAuthority], requesterID: UUID, approvals: ApprovalStore,
                            currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot) async throws -> NativeJiraReadReview {
        do {
            guard let authority = authorities.first(where: { $0.id == requesterID }), case .localUser = authority.kind,
                  let record = try await configurations.read(id: connectionID, in: context.scope),
                  record.configuration.environmentID == context.environmentID else { throw AuthorizationError.scopeMismatch }
            let permissions = try record.configuration.resolvedPermissions()
            let id = UUID()
            let gate = try await PluginPolicySession.openStored(configurationStore: configurations, connectionID: connectionID,
                scope: context.scope, authorities: authorities, requesterID: requesterID, approvals: approvals,
                currentPolicy: currentPolicy, prepare: { record, currentPermissions in
                    try await connection.prepare(operation, id: id, configurationRevision: record.revision,
                        permissions: currentPermissions, runID: context.runID)
                })
            return NativeJiraReadReview(gate: gate, connection: connection, operation: operation,
                permissions: permissions, context: context, redactor: redactor, requesterID: requesterID)
        } catch {
            await connection.close()
            throw error
        }
    }

    public func prepare() async throws -> PolicyPreparation {
        guard !closed else { throw AuthorizationError.denied }
        return try await gate.prepare()
    }
    public func review(_ approvalID: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        guard !closed else { throw AuthorizationError.denied }
        return try await gate.review(approvalID, reviewerID: requesterID, approve: approve, expectedSequence: expectedSequence)
    }
    public func execute(approvalID: UUID? = nil) async throws -> PolicyExecutionResult<JiraReadResult> {
        guard !closed else { throw AuthorizationError.denied }
        return try await gate.executeJira(operation, connection: connection, permissions: permissions,
            context: context, redactor: redactor, approvalID: approvalID)
    }
    public func close() async {
        closed = true
        await gate.removeAuthority(requesterID)
        await connection.close()
    }
}
