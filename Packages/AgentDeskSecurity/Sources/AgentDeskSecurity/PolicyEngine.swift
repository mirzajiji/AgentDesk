import AgentDeskCore
import Foundation

/// Constructed by the trusted Mac authentication boundary, never decoded from an action payload.
public struct PolicyAuthority: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case localUser, agent(AgentID), pairedDevice(UUID) }
    public let id: UUID
    public let revision: UUID
    public let kind: Kind
    public let scopes: Set<ProjectScope>
    public let environments: Set<EnvironmentID>
    public let operations: Set<PolicyOperation>
    public let canApprove: Bool
    public let expiresAt: Date
    public let revoked: Bool

    public init(id: UUID, revision: UUID = UUID(), kind: Kind, scopes: Set<ProjectScope>, environments: Set<EnvironmentID>,
                operations: Set<PolicyOperation>, canApprove: Bool = false, expiresAt: Date, revoked: Bool = false) throws {
        guard scopes.count <= 256, environments.count <= 256, expiresAt.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        self.id = id; self.revision = revision; self.kind = kind; self.scopes = scopes; self.environments = environments
        self.operations = operations; self.canApprove = canApprove; self.expiresAt = expiresAt; self.revoked = revoked
    }
    public func permitsContext(_ action: PolicyAction, at now: Date) -> Bool {
        now.timeIntervalSince1970.isFinite && !revoked && now < expiresAt && scopes.contains(action.scope) && environments.contains(action.environmentID)
    }
}

public struct PolicyEvaluation: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case allowed, reviewRequired, missingAuthority, authorityExpired, scopeMismatch, operationNotGranted
        case mobileRestriction, agentRestriction, workspaceLocked, productionRestriction, ruleDenied
    }
    public let disposition: PolicyDisposition
    public let reason: Reason
    init(_ disposition: PolicyDisposition, _ reason: Reason) { self.disposition = disposition; self.reason = reason }
}

public enum PolicyEngine {
    public static func evaluate(_ action: PolicyAction, policy: PolicySnapshot, authority: PolicyAuthority?, at now: Date) throws -> PolicyEvaluation {
        try action.validate(); try policy.validate()
        guard now.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        guard action.scope == policy.scope, action.environmentID == policy.environmentID else { return PolicyEvaluation(.deny, .scopeMismatch) }
        guard let authority else { return PolicyEvaluation(.deny, .missingAuthority) }
        guard !authority.revoked, now < authority.expiresAt else { return PolicyEvaluation(.deny, .authorityExpired) }
        guard authority.scopes.contains(action.scope), authority.environments.contains(action.environmentID) else { return PolicyEvaluation(.deny, .scopeMismatch) }
        guard authority.operations.contains(action.operation) else { return PolicyEvaluation(.deny, .operationNotGranted) }
        switch authority.kind {
        case .localUser: break
        case .pairedDevice:
            // Future mobile command adapters must map predefined operations explicitly. No raw project,
            // secret, shell, provider-prompt or configuration authority is granted by a device connection.
            guard action.operation == .readEvidence else { return PolicyEvaluation(.deny, .mobileRestriction) }
        case .agent(let id):
            guard action.agentID == id else { return PolicyEvaluation(.deny, .scopeMismatch) }
            guard ![.readSecret, .updateSecret, .changeConfiguration, .runShell].contains(action.operation) else {
                return PolicyEvaluation(.deny, .agentRestriction)
            }
        }
        if policy.workspaceLocked, action.operation != .readEvidence { return PolicyEvaluation(.deny, .workspaceLocked) }
        if policy.environmentKind == .production, action.operation.isMutation { return PolicyEvaluation(.deny, .productionRestriction) }
        let rules = [policy.workspace, policy.project, policy.environment].map { $0.disposition(for: action.operation) }
        if rules.contains(.deny) { return PolicyEvaluation(.deny, .ruleDenied) }
        if rules.contains(.approval) || [.destructiveAction, .runShell].contains(action.operation) ||
            (policy.environmentKind == .production && action.operation == .readSecret) {
            return PolicyEvaluation(.approval, .reviewRequired)
        }
        return PolicyEvaluation(.allow, .allowed)
    }

    public static func mayReview(_ action: PolicyAction, authority: PolicyAuthority?, at now: Date) -> Bool {
        guard let authority, authority.canApprove, authority.permitsContext(action, at: now) else { return false }
        if case .agent = authority.kind { return false }
        if case .pairedDevice = authority.kind,
           [.readSecret, .updateSecret, .changeConfiguration, .runShell, .destructiveAction].contains(action.operation) { return false }
        // A paired reviewer may review an exact prepared action, but never obtain its privileged execution capability.
        return true
    }
}

public enum PolicyPreset: String, CaseIterable, Sendable {
    case readOnly, qaSafe, development
    public var rules: [PolicyRule] {
        PolicyOperation.allCases.map { operation in
            let disposition: PolicyDisposition
            switch operation {
            case .readEvidence, .runReadOnlyAgent: disposition = .allow
            case .writeProject: disposition = self == .readOnly ? .deny : (self == .development ? .allow : .approval)
            case .externalMutation: disposition = self == .readOnly ? .deny : .approval
            case .readSecret, .updateSecret, .changeConfiguration, .runShell:
                disposition = self == .development ? .approval : .deny
            case .destructiveAction: disposition = .deny
            }
            return PolicyRule(operation, disposition)
        }
    }
}
