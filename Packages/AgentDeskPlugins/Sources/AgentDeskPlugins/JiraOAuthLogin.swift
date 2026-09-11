import AgentDeskSecurity
import Foundation

/// One configuration owns one login operation. Logout waits for writes before deleting the grant.
public actor JiraOAuthLogin {
    private let configuration: JiraConnectionConfiguration
    private let broker: JiraOAuthBrokerClient
    private let adapter: JiraCloudAdapter
    private let vault: JiraCredentialVault
    private var active: Task<JiraCloudAccount, any Error>?
    private var loggingOut = false
    private var closed = false
    public init(configuration: JiraConnectionConfiguration, registration: JiraOAuthRegistration, store: any SecretStore) throws {
        self.configuration = configuration
        broker = try JiraOAuthBrokerClient(origin: registration.brokerOrigin, clientID: registration.clientID, callback: registration.callback, access: registration.access)
        adapter = JiraCloudAdapter(store: store)
        vault = try JiraCredentialVault(configuration: configuration, store: store)
    }
    init(configuration: JiraConnectionConfiguration, broker: JiraOAuthBrokerClient, adapter: JiraCloudAdapter,
         store: any SecretStore) throws {
        self.configuration = configuration; self.broker = broker; self.adapter = adapter
        vault = try JiraCredentialVault(configuration: configuration, store: store)
    }
    public func signIn(validateConfiguration: @escaping @Sendable () async throws -> Void = {},
                       openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws -> JiraCloudAccount {
        guard !closed, active == nil, !loggingOut, configuration.enabled else { throw JiraServiceError.unavailable }
        let configuration = configuration, broker = broker, adapter = adapter, vault = vault
        let registration = broker.registrationFingerprint
        let job = Task {
            try await validateConfiguration()
            try Task.checkCancellation()
            let proof = try JiraOAuthClaimProof()
            let attempt = try await broker.start(proof: proof)
            var attemptedSave = false
            do {
                try Task.checkCancellation()
                try await openBrowser(attempt.authorizationURL)
                let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if let tokens = try await broker.claim(attempt, proof: proof, now: Date()) {
                        let account = try await adapter.validate(tokens, configuration: configuration)
                        try await validateConfiguration()
                        try Task.checkCancellation()
                        attemptedSave = true
                        try await vault.save(tokens, registration: registration)
                        try await validateConfiguration()
                        try Task.checkCancellation()
                        return account
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw JiraOAuthError.expired
            } catch {
                // Cleanup is a separate task so caller cancellation cannot skip deletion/cancellation.
                let shouldDelete = attemptedSave
                let deleted = await Task {
                    var deleted = true
                    if shouldDelete {
                        do { try await vault.logout() }
                        catch { deleted = false }
                    }
                    // Remote attempts expire independently; local deletion must be reported separately.
                    try? await broker.cancel(attempt, proof: proof)
                    return deleted
                }.value
                guard deleted else { throw JiraOAuthError.credentialCleanupFailed }
                throw error
            }
        }
        active = job
        defer { active = nil }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    public func refresh() async throws -> JiraCloudAccount {
        guard !closed, active == nil, !loggingOut, configuration.enabled else { throw JiraServiceError.unavailable }
        let configuration = configuration, broker = broker, adapter = adapter, vault = vault
        let registration = broker.registrationFingerprint
        let job = Task {
            guard let current = try await vault.load(registration: registration), let refreshToken = current.refreshToken else {
                throw JiraServiceError.authenticationRequired
            }
            // Persist consumption before any remote exchange. A crash or ambiguous response requires sign-in.
            try await vault.logout()
            var attemptedSave = false
            do {
                try Task.checkCancellation()
                let tokens = try await broker.refresh(refreshToken, now: Date())
                let account = try await adapter.validate(tokens, configuration: configuration)
                try Task.checkCancellation()
                attemptedSave = true
                try await vault.save(tokens, registration: registration)
                try Task.checkCancellation()
                return account
            } catch {
                if attemptedSave {
                    let deleted = await Task {
                        do { try await vault.logout(); return true }
                        catch { return false }
                    }.value
                    guard deleted else { throw JiraOAuthError.credentialCleanupFailed }
                }
                throw error
            }
        }
        active = job
        defer { active = nil }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    /// Releases transports and cancels active work without logging out an already saved grant.
    public func close() async {
        closed = true
        let pending = active
        pending?.cancel()
        _ = try? await pending?.value
        await broker.close()
    }
    public func logout() async throws {
        guard !loggingOut else { throw JiraServiceError.unavailable }
        loggingOut = true
        defer { loggingOut = false }
        let pending = active
        pending?.cancel()
        _ = try? await pending?.value
        try await vault.logout()
    }
}
