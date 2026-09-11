import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation

/// One exact prepared invocation. Owned by trusted host code, never decoded from a client request.
actor PluginPolicySession {
    private let prepared: PreparedPluginAction
    private let mutationAttempts: MutationAttemptStore
    private let clock: @Sendable () -> Date
    private let gate: PolicyGate
    private let requesterID: UUID
    private var authorityGeneration = UUID()
    private let policyFingerprint: ActionFingerprint
    private let validateCurrent: @Sendable () async throws -> (PreparedPluginAction, PolicySnapshot)

    init(prepared: PreparedPluginAction, policy: PolicySnapshot, permissions: PluginPermissions,
         authorities: [PolicyAuthority], requesterID: UUID, store: ApprovalStore,
         clock: @escaping @Sendable () -> Date = { Date() },
         validateCurrent: @escaping @Sendable () async throws -> (PreparedPluginAction, PolicySnapshot)) throws {
        if let requester = authorities.first(where: { $0.id == requesterID }),
           case .pairedDevice = requester.kind { throw AuthorizationError.denied }
        guard try prepared.permissionsFingerprint == ActionFingerprint.canonical(permissions) else {
            throw AuthorizationError.stalePolicy
        }
        let restricted = try permissions.restricting(policy, connectionID: prepared.connectionID,
                                                     capability: prepared.capability)
        guard prepared.action.scope == restricted.scope,
              prepared.action.environmentID == restricted.environmentID else { throw AuthorizationError.scopeMismatch }
        mutationAttempts = try store.mutationAttempts()
        self.clock = clock
        self.policyFingerprint = try policy.fingerprint
        self.prepared = prepared; self.requesterID = requesterID; self.validateCurrent = validateCurrent
        gate = try PolicyGate(policy: restricted, authorities: authorities, store: store, clock: clock)
    }

    func prepare() async throws -> PolicyPreparation {
        try await checkCurrent()
        return try await gate.prepare(prepared.action, requesterID: requesterID)
    }

    func review(_ approvalID: UUID, reviewerID: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        if approve { try await checkCurrent() }
        return try await gate.review(approvalID, expectedAction: prepared.action, requesterID: requesterID,
                                     reviewerID: reviewerID, approve: approve, expectedSequence: expectedSequence)
    }

    func execute<Value: Sendable>(approvalID: UUID? = nil,
                                  operation: @Sendable (PolicyAction) async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        let generation = authorityGeneration
        try await checkCurrent(expectedAuthority: generation)
        return try await gate.execute(prepared.action, requesterID: requesterID, approvalID: approvalID) { action in
            try await self.checkCurrent(expectedAuthority: generation)
            return try await operation(action)
        }
    }

    func executeJira(_ operation: JiraReadOperation, connection: JiraCloudSession,
                     permissions: PluginPermissions, context: RedactionContext, redactor: ContentRedactor,
                     approvalID: UUID? = nil) async throws -> PolicyExecutionResult<JiraReadResult> {
        let invocation = prepared
        guard invocation.capability == operation.capability else { throw AuthorizationError.invalidInput }
        return try await execute(approvalID: approvalID) { action in
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await connection.executePrepared(operation, prepared: invocation, permissions: permissions,
                context: context, redactor: redactor)
        }
    }

    func executeJiraIssueSnapshot(identifier: String, connection: JiraCloudSession,
                                  permissions: PluginPermissions, context: RedactionContext,
                                  redactor: ContentRedactor, approvalID: UUID? = nil) async throws -> PolicyExecutionResult<JiraIssueSnapshot> {
        let invocation = prepared
        guard invocation.capability == .issuesRead else { throw AuthorizationError.invalidInput }
        return try await execute(approvalID: approvalID) { action in
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await connection.executeIssueSnapshot(identifier: identifier, prepared: invocation,
                permissions: permissions, context: context, redactor: redactor)
        }
    }

    func reconcileJiraComment(_ draft: JiraCommentDraft, startAt: Int, limit: Int,
                              connection: JiraCloudSession, permissions: PluginPermissions,
                              redactor: ContentRedactor, approvalID: UUID? = nil) async throws -> PolicyExecutionResult<JiraCommentCandidates> {
        let invocation = prepared
        guard invocation.capability == .commentsRead else { throw AuthorizationError.invalidInput }
        return try await execute(approvalID: approvalID) { action in
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await connection.reconcileComment(draft, startAt: startAt, limit: limit,
                preparedRead: invocation, permissions: permissions, redactor: redactor)
        }
    }

    func executeJiraComment(_ draft: JiraCommentDraft, connection: JiraCloudSession,
                            permissions: PluginPermissions, context: RedactionContext, redactor: ContentRedactor,
                            approvalID: UUID? = nil,
                            beforeDispatch: @escaping @Sendable () async throws -> Void = {}) async throws -> PolicyExecutionResult<JiraCommentReceipt> {
        let invocation = prepared
        guard invocation.capability == .commentsWrite, draft.content.context == context else { throw AuthorizationError.invalidInput }
        let generation = authorityGeneration
        return try await execute(approvalID: approvalID) { action in
            // A write always needs an explicit consumed review, even if general policy allows it.
            guard let approvalID else { throw AuthorizationError.approvalRequired }
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await self.recordMutation(action, approvalID: approvalID) {
                try await connection.executeComment(draft, prepared: invocation, permissions: permissions, redactor: redactor,
                beforeDispatch: {
                    try await self.checkCurrent(expectedAuthority: generation)
                    try await beforeDispatch()
                    try await self.checkCurrent(expectedAuthority: generation)
                })
            }
        }
    }

    func executeJiraTextAttachment(_ draft: JiraTextAttachmentDraft, connection: JiraCloudSession,
                            permissions: PluginPermissions, context: RedactionContext, redactor: ContentRedactor,
                            approvalID: UUID? = nil,
                            beforeDispatch: @escaping @Sendable () async throws -> Void = {}) async throws -> PolicyExecutionResult<JiraAttachmentReceipt> {
        let invocation = prepared
        guard invocation.capability == .attachmentsAdd, draft.content.context == context else { throw AuthorizationError.invalidInput }
        let generation = authorityGeneration
        return try await execute(approvalID: approvalID) { action in
            // A write always needs an explicit consumed review, even if general policy allows it.
            guard let approvalID else { throw AuthorizationError.approvalRequired }
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await self.recordMutation(action, approvalID: approvalID) {
                try await connection.executeTextAttachment(draft, prepared: invocation, permissions: permissions, redactor: redactor,
                beforeDispatch: {
                    try await self.checkCurrent(expectedAuthority: generation)
                    try await beforeDispatch()
                    try await self.checkCurrent(expectedAuthority: generation)
                })
            }
        }
    }

    func executeJiraIssueEdit(_ draft: JiraIssueEditDraft, connection: JiraCloudSession,
                              permissions: PluginPermissions, redactor: ContentRedactor,
                              readSession: PluginPolicySession, readApprovalID: UUID? = nil,
                              approvalID: UUID) async throws -> PolicyExecutionResult<JiraIssueEditReceipt> {
        let invocation = prepared
        guard invocation.capability == .issuesUpdate else { throw AuthorizationError.invalidInput }
        let generation = authorityGeneration
        return try await execute(approvalID: approvalID) { action in
            guard action == invocation.action else { throw AuthorizationError.stalePolicy }
            return try await self.recordMutation(action, approvalID: approvalID) {
                try await connection.executeIssueEdit(draft, prepared: invocation, permissions: permissions,
                redactor: redactor, readCurrent: {
                    let result = try await readSession.executeJiraIssueSnapshot(identifier: draft.identifier,
                        connection: connection, permissions: permissions, context: draft.context,
                        redactor: redactor, approvalID: readApprovalID)
                    guard case .executed(let snapshot) = result else { throw AuthorizationError.denied }
                    return snapshot
                }, beforeDispatch: { try await self.checkCurrent(expectedAuthority: generation) })
            }
        }
    }

    func executeBugJiraComment(_ evidence: BugJiraComment, connection: JiraCloudSession,
                               permissions: PluginPermissions, redactor: ContentRedactor,
                               approvalID: UUID) async throws -> PolicyExecutionResult<JiraCommentReceipt> {
        try await evidence.validate()
        return try await executeJiraComment(evidence.draft, connection: connection, permissions: permissions,
            context: evidence.draft.content.context, redactor: redactor, approvalID: approvalID,
            beforeDispatch: { try await evidence.validate() })
    }

    private func recordMutation<Value: Sendable>(_ action: PolicyAction, approvalID: UUID,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        _ = try await mutationAttempts.begin(action, approvalID: approvalID, at: clock())
        let value: Value
        do { value = try await operation() }
        catch {
            if case JiraMutationError.rejected = error {
                _ = try await mutationAttempts.finish(action, approvalID: approvalID, outcome: .rejected, at: clock())
            }
            // Other errors retain uncertainty. No response body or error description is persisted.
            throw error
        }
        _ = try await mutationAttempts.finish(action, approvalID: approvalID, outcome: .acknowledged, at: clock())
        return value
    }

    func installAuthority(_ authority: PolicyAuthority) async throws {
        authorityGeneration = UUID()
        if authority.id == requesterID, case .pairedDevice = authority.kind {
            await gate.removeAuthority(authority.id)
            throw AuthorizationError.denied
        }
        try await gate.installAuthority(authority)
    }
    func removeAuthority(_ id: UUID) async {
        authorityGeneration = UUID()
        await gate.removeAuthority(id)
    }

    private func checkCurrent(expectedAuthority: UUID? = nil) async throws {
        try Task.checkCancellation()
        let current = try await validateCurrent()
        guard current.0.action == prepared.action, try current.1.fingerprint == policyFingerprint else { throw AuthorizationError.stalePolicy }
        guard expectedAuthority == nil || expectedAuthority == authorityGeneration else {
            throw AuthorizationError.stalePolicy
        }
        try Task.checkCancellation()
    }
}
