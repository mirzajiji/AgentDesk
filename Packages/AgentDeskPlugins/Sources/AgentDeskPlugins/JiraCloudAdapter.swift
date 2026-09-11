import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Restores an existing scoped OAuth grant. Interactive login/refresh is handled separately.
public struct JiraCloudAdapter: JiraConnectionAdapter {
    let store: any SecretStore
    var now: @Sendable () -> Date = { Date() }
    var makeTransport: @Sendable (URL) throws -> JiraHTTPTransport = { try JiraHTTPTransport(origin: $0, maximumBytes: 8_388_608) }

    public init(store: any SecretStore) { self.store = store }

    init(store: any SecretStore, now: @escaping @Sendable () -> Date, makeTransport: @escaping @Sendable (URL) throws -> JiraHTTPTransport) {
        self.store = store; self.now = now; self.makeTransport = makeTransport
    }

    public func connect(_ configuration: JiraConnectionConfiguration) async throws -> any PluginConnectionSession {
        try Task.checkCancellation()
        guard configuration.enabled else { throw PluginConnectionError.disabled }
        guard configuration.credential != nil else { throw PluginConnectionError.notConfigured }
        let vault = try JiraCredentialVault(configuration: configuration, store: store)
        guard let tokens = try await vault.load() else { throw PluginConnectionError.authenticationExpired }
        return try await open(configuration, tokens: tokens, vault: vault)
    }
    func validate(_ tokens: JiraOAuthTokens, configuration: JiraConnectionConfiguration) async throws -> JiraCloudAccount {
        guard configuration.enabled else { throw PluginConnectionError.disabled }
        let vault = try JiraCredentialVault(configuration: configuration, store: store)
        let session = try await open(configuration, tokens: tokens, vault: vault)
        let account = await session.account
        await session.close()
        return account
    }
    private func open(_ configuration: JiraConnectionConfiguration, tokens: JiraOAuthTokens, vault: JiraCredentialVault) async throws -> JiraCloudSession {
        try Task.checkCancellation()
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite, tokens.expiresAt > instant else {
            throw PluginConnectionError.authenticationExpired
        }
        let discovery = try makeTransport(URL(string: "https://api.atlassian.com/oauth/token/accessible-resources")!)
        var api: JiraHTTPTransport?
        do {
            var request = URLRequest(url: URL(string: "https://api.atlassian.com/oauth/token/accessible-resources")!)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            tokens.accessToken.withBytes {
                request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization")
            }
            let response = try await discovery.send(request, maximumResponseBytes: 262_144)
            await discovery.close()
            try Task.checkCancellation()
            let resource = try JiraCloudResource.select(response, site: configuration.instance)
            let transport = try makeTransport(resource.apiOrigin)
            api = transport
            let account = try await JiraAccountRequest.load(resource: resource, tokens: tokens, now: now(), transport: transport)
            try Task.checkCancellation()
            return JiraCloudSession(account: account, transport: transport, configuration: configuration, resource: resource, tokens: tokens, vault: vault, now: now)
        } catch {
            await discovery.close()
            await api?.close()
            if Task.isCancelled { throw CancellationError() }
            if error as? JiraServiceError == .authenticationRequired { throw PluginConnectionError.authenticationExpired }
            throw error
        }
    }
}

/// Session execution is called only from the trusted runtime's policy-gated operation closure.
public actor JiraCloudSession: PluginConnectionSession {
    public nonisolated let capabilities: Set<PluginCapability>
    public let account: JiraCloudAccount
    private let transport: JiraHTTPTransport
    private let configuration: JiraConnectionConfiguration
    private let resource: JiraCloudResource
    private let tokens: JiraOAuthTokens
    private let vault: JiraCredentialVault
    private let now: @Sendable () -> Date
    private var closed = false
    init(account: JiraCloudAccount, transport: JiraHTTPTransport, configuration: JiraConnectionConfiguration,
         resource: JiraCloudResource, tokens: JiraOAuthTokens, vault: JiraCredentialVault, now: @escaping @Sendable () -> Date) {
        self.capabilities = Self.availableCapabilities(tokenScopes: tokens.scopes, siteScopes: resource.scopes)
        self.account = account; self.transport = transport; self.configuration = configuration
        self.resource = resource; self.tokens = tokens; self.vault = vault; self.now = now
    }
    /// Scope discovery describes available implementations; runtime policy still authorizes each call.
    static func availableCapabilities(tokenScopes: Set<String>, siteScopes: Set<String>) -> Set<PluginCapability> {
        var result: Set<PluginCapability> = []
        if tokenScopes.contains("read:jira-work") && siteScopes.contains("read:jira-work") {
            result.formUnion([.issuesRead, .commentsRead, .attachmentsRead])
        }
        if tokenScopes.contains("write:jira-work") && siteScopes.contains("write:jira-work") {
            result.insert(.commentsWrite)
        }
        return result
    }
    public func prepare(_ operation: JiraReadOperation, id: UUID = UUID(), configurationRevision: Int,
                        permissions: PluginPermissions, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard !closed else { throw JiraTransportError.closed }
        return try operation.prepare(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, cloudID: resource.id, runID: runID, agentID: agentID)
    }

    /// Exact-action validation is defense in depth, not a substitute for PolicyGate authorization.
    public func executePrepared(_ operation: JiraReadOperation, prepared: PreparedPluginAction,
                                permissions: PluginPermissions, context: RedactionContext,
                                redactor: ContentRedactor) async throws -> JiraReadResult {
        guard let runID = prepared.action.runID, runID == context.runID else { throw AuthorizationError.scopeMismatch }
        let expected = try prepare(operation, id: prepared.action.id, configurationRevision: prepared.configurationRevision,
            permissions: permissions, runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        guard context.scope == configuration.scope, context.environmentID == configuration.environmentID else {
            throw AuthorizationError.scopeMismatch
        }
        let secureRedactor = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        let instant = now()
        switch operation {
        case .issue(let identifier):
            let value = try await JiraIssueRead.load(identifier: identifier, configuration: configuration, resource: resource,
                tokens: current, context: context, redactor: secureRedactor, now: instant, transport: transport)
            return .json(value.content)
        case .comments(let identifier, let startAt, let limit):
            let value = try await JiraCommentsRead.load(identifier: identifier, startAt: startAt, limit: limit,
                configuration: configuration, resource: resource, tokens: current, context: context, redactor: secureRedactor, now: instant, transport: transport)
            return .comments(content: value.content, nextStartAt: value.nextStartAt)
        case .attachmentSettings:
            let request = try JiraAttachmentSettingsRead.make(resource: resource, tokens: current, now: instant)
            let response = try await transport.send(request, maximumResponseBytes: 16_384)
            try Task.checkCancellation()
            return .attachmentSettings(try JiraAttachmentSettingsRead.decode(response, context: context, cloudID: resource.id, observedAt: now()))
        case .attachmentMetadata(let id):
            let value = try await JiraAttachmentRead.load(id: id, configuration: configuration, resource: resource,
                tokens: current, context: context, redactor: secureRedactor, now: instant, transport: transport)
            return .json(value.content)
        case .attachmentContent(let id, let size, let maximum):
            let metadata = try await JiraAttachmentRead.load(id: id, configuration: configuration, resource: resource,
                tokens: current, context: context, redactor: secureRedactor, now: instant, transport: transport)
            guard metadata.size == size else { throw AuthorizationError.stalePolicy }
            let downloadGrant = try await currentGrant()
            return .attachment(try await JiraAttachmentDownload.load(metadata: metadata, configuration: configuration,
                resource: resource, tokens: downloadGrant, now: now(), maximumBytes: maximum, transport: transport))
        }
    }
    /// Runtime callers must execute this through the independently authorized issue-read action.
    public func executeIssueSnapshot(identifier: String, prepared: PreparedPluginAction,
                                     permissions: PluginPermissions, context: RedactionContext,
                                     redactor: ContentRedactor) async throws -> JiraIssueSnapshot {
        guard let runID = prepared.action.runID, runID == context.runID,
              context.scope == configuration.scope, context.environmentID == configuration.environmentID,
              redactor.context == context else { throw AuthorizationError.scopeMismatch }
        let expected = try prepare(.issue(identifier: identifier), id: prepared.action.id,
            configurationRevision: prepared.configurationRevision, permissions: permissions,
            runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        let secure = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        let evidence = try await JiraIssueRead.load(identifier: identifier, configuration: configuration, resource: resource,
            tokens: current, context: context, redactor: secure, now: now(), transport: transport)
        return try JiraIssueSnapshot(evidence)
    }

    public func reconcileComment(_ draft: JiraCommentDraft, startAt: Int, limit: Int,
                                 preparedRead: PreparedPluginAction, permissions: PluginPermissions,
                                 redactor: ContentRedactor) async throws -> JiraCommentCandidates {
        let operation = JiraReadOperation.comments(identifier: draft.identifier, startAt: startAt, limit: limit)
        let result = try await executePrepared(operation, prepared: preparedRead, permissions: permissions,
            context: draft.content.context, redactor: redactor)
        guard case .comments(let content, let nextStartAt) = result else { throw JiraServiceError.invalidResponse }
        return try JiraCommentReconciliation.compare(draft, content: content, nextStartAt: nextStartAt)
    }

    public func prepareComment(_ draft: JiraCommentDraft, id: UUID = UUID(), configurationRevision: Int,
                        permissions: PluginPermissions, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard !closed else { throw JiraTransportError.closed }
        return try draft.prepare(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, cloudID: resource.id, runID: runID, agentID: agentID)
    }

    public func executeComment(_ draft: JiraCommentDraft, prepared: PreparedPluginAction,
                        permissions: PluginPermissions, redactor: ContentRedactor,
                        beforeDispatch: @Sendable () async throws -> Void = {}) async throws -> JiraCommentReceipt {
        let context = draft.content.context
        guard let runID = prepared.action.runID, runID == context.runID, redactor.context == context else {
            throw AuthorizationError.scopeMismatch
        }
        let expected = try prepareComment(draft, id: prepared.action.id, configurationRevision: prepared.configurationRevision,
            permissions: permissions, runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        let secure = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        let checked = try secure.redactText(draft.content.text, in: context)
        guard checked.text == draft.content.text else { throw AuthorizationError.stalePolicy }
        try await beforeDispatch()
        // Evidence checks may suspend while logout or token rotation removes the grant.
        let dispatchGrant = try await currentGrant()
        let request = try JiraCommentWrite.make(draft, resource: resource, tokens: dispatchGrant, now: now())
        let response: JiraHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: 262_144) }
        catch { throw JiraMutationError.outcomeUnknown }
        return try JiraCommentWrite.decode(response, context: context, redactor: secure)
    }

    public func prepareTextAttachment(_ draft: JiraTextAttachmentDraft, id: UUID = UUID(), configurationRevision: Int,
                        permissions: PluginPermissions, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard !closed else { throw JiraTransportError.closed }
        return try draft.prepare(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, cloudID: resource.id, runID: runID, agentID: agentID)
    }

    public func executeTextAttachment(_ draft: JiraTextAttachmentDraft, prepared: PreparedPluginAction,
                        permissions: PluginPermissions, redactor: ContentRedactor,
                        readSettings: @Sendable () async throws -> JiraAttachmentSettings,
                        beforeDispatch: @Sendable () async throws -> Void = {}) async throws -> JiraAttachmentReceipt {
        let context = draft.content.context
        guard let runID = prepared.action.runID, runID == context.runID, redactor.context == context else {
            throw AuthorizationError.scopeMismatch
        }
        let expected = try prepareTextAttachment(draft, id: prepared.action.id, configurationRevision: prepared.configurationRevision,
            permissions: permissions, runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        let secure = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        for content in [draft.filename, draft.content] {
            guard try secure.redactText(content.text, in: context).text == content.text else { throw AuthorizationError.stalePolicy }
        }
        let startedAt = now()
        guard startedAt.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        let settings = try await readSettings()
        guard settings.context == context, settings.cloudID == resource.id else { throw AuthorizationError.scopeMismatch }
        guard settings.observedAt >= startedAt else { throw AuthorizationError.stalePolicy }
        guard settings.permitsSize(Int64(draft.content.text.utf8.count)) else { throw AuthorizationError.denied }
        try await beforeDispatch()
        // Evidence checks may suspend while logout or token rotation removes the grant.
        let dispatchGrant = try await currentGrant()
        let dispatchAt = now()
        guard dispatchAt.timeIntervalSince1970.isFinite, dispatchAt >= settings.observedAt else { throw AuthorizationError.stalePolicy }
        let request = try JiraAttachmentWrite.make(draft, resource: resource, tokens: dispatchGrant, now: dispatchAt)
        let response: JiraHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: 262_144) }
        catch { throw JiraMutationError.outcomeUnknown }
        return try JiraAttachmentWrite.decode(response, draft: draft, redactor: secure)
    }

    public func prepareImageAttachment(_ draft: JiraImageAttachmentDraft, id: UUID = UUID(), configurationRevision: Int,
                        permissions: PluginPermissions, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard !closed else { throw JiraTransportError.closed }
        return try draft.prepare(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, cloudID: resource.id, runID: runID, agentID: agentID)
    }

    public func executeImageAttachment(_ draft: JiraImageAttachmentDraft, prepared: PreparedPluginAction,
                        permissions: PluginPermissions, redactor: ContentRedactor,
                        readSettings: @Sendable () async throws -> JiraAttachmentSettings,
                        beforeDispatch: @Sendable () async throws -> Void = {}) async throws -> JiraAttachmentReceipt {
        let context = draft.context
        guard let runID = prepared.action.runID, runID == context.runID, redactor.context == context else {
            throw AuthorizationError.scopeMismatch
        }
        let expected = try prepareImageAttachment(draft, id: prepared.action.id, configurationRevision: prepared.configurationRevision,
            permissions: permissions, runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        let secure = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        for content in [draft.filename] {
            guard try secure.redactText(content.text, in: context).text == content.text else { throw AuthorizationError.stalePolicy }
        }
        let startedAt = now()
        guard startedAt.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        let settings = try await readSettings()
        guard settings.context == context, settings.cloudID == resource.id else { throw AuthorizationError.scopeMismatch }
        guard settings.observedAt >= startedAt else { throw AuthorizationError.stalePolicy }
        guard settings.permitsSize(Int64(draft.byteCount)) else { throw AuthorizationError.denied }
        try await beforeDispatch()
        // Evidence checks may suspend while logout or token rotation removes the grant.
        let dispatchGrant = try await currentGrant()
        let dispatchAt = now()
        guard dispatchAt.timeIntervalSince1970.isFinite, dispatchAt >= settings.observedAt else { throw AuthorizationError.stalePolicy }
        let request = try JiraAttachmentWrite.make(draft, resource: resource, tokens: dispatchGrant, now: dispatchAt)
        let response: JiraHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: 262_144) }
        catch { throw JiraMutationError.outcomeUnknown }
        return try JiraAttachmentWrite.decode(response, draft: draft, redactor: secure)
    }

    public func prepareIssueEdit(_ draft: JiraIssueEditDraft, id: UUID = UUID(), configurationRevision: Int,
                                 permissions: PluginPermissions, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard !closed else { throw JiraTransportError.closed }
        return try draft.prepare(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, cloudID: resource.id, runID: runID, agentID: agentID)
    }

    /// The runtime supplies an independently authorized fresh read and rechecks write authority.
    public func executeIssueEdit(_ draft: JiraIssueEditDraft, prepared: PreparedPluginAction,
                                 permissions: PluginPermissions, redactor: ContentRedactor,
                                 readCurrent: @Sendable () async throws -> JiraIssueSnapshot,
                                 beforeDispatch: @Sendable () async throws -> Void) async throws -> JiraIssueEditReceipt {
        let context = draft.context
        guard let runID = prepared.action.runID, runID == context.runID, redactor.context == context else {
            throw AuthorizationError.scopeMismatch
        }
        let expected = try prepareIssueEdit(draft, id: prepared.action.id, configurationRevision: prepared.configurationRevision,
            permissions: permissions, runID: runID, agentID: prepared.action.agentID)
        guard expected.action == prepared.action else { throw AuthorizationError.stalePolicy }
        let current = try await currentGrant()
        let secure = try redactor.includingKnownSecrets([current.accessToken] + (current.refreshToken.map { [$0] } ?? []), in: context)
        for content in [draft.summary, draft.description].compactMap({ $0 }) {
            guard try secure.redactText(content.text, in: context).text == content.text else { throw AuthorizationError.stalePolicy }
        }
        let started = now()
        guard started.timeIntervalSince1970.isFinite else { throw AuthorizationError.clockRegression }
        let snapshot = try await readCurrent()
        guard snapshot.content.context == context, snapshot.cloudID == resource.id,
              snapshot.identifier == draft.identifier, snapshot.fingerprint == draft.expectedIssue,
              snapshot.observedAt >= started else { throw AuthorizationError.stalePolicy }
        try await beforeDispatch()
        let dispatchGrant = try await currentGrant()
        let instant = now()
        guard instant >= snapshot.observedAt else { throw AuthorizationError.clockRegression }
        let request = try JiraIssueEdit.make(draft, resource: resource, tokens: dispatchGrant, now: instant)
        let response: JiraHTTPResponse
        do { response = try await transport.send(request, maximumResponseBytes: 262_144) }
        catch { throw JiraMutationError.outcomeUnknown }
        try JiraIssueEdit.validateAcknowledgment(response)
        return JiraIssueEditReceipt(identifier: draft.identifier)
    }

    private func currentGrant() async throws -> JiraOAuthTokens {
        try Task.checkCancellation()
        guard !closed else { throw JiraTransportError.closed }
        guard let current = try await vault.load(),
              current.accessToken.withBytes({ $0 }) == tokens.accessToken.withBytes({ $0 }),
              current.scopes == tokens.scopes, current.expiresAt == tokens.expiresAt else {
            throw PluginConnectionError.authenticationExpired
        }
        try Task.checkCancellation()
        guard !closed else { throw JiraTransportError.closed }
        return current
    }
    public func close() async { closed = true; await transport.close() }
}

public enum JiraReadResult: Sendable {
    case json(RedactedText)
    case comments(content: RedactedText, nextStartAt: Int?)
    case attachment(JiraAttachmentBytes)
    case attachmentSettings(JiraAttachmentSettings)
}
