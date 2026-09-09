import Foundation

public enum SkillError: Error, Equatable, Sendable, LocalizedError {
    case invalidBundle, scopeMismatch, staleRevision, duplicateName, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidBundle: "This skill bundle or reference is invalid. Existing files have been preserved."
        case .scopeMismatch: "This skill does not belong to the selected workspace or project."
        case .staleRevision: "This skill changed. Reload it before saving."
        case .duplicateName: "A skill with that name already exists at this scope."
        case .unavailable: "A referenced skill is disabled, archived or unavailable."
        }
    }
}
public struct SkillScope: Codable, Hashable, Sendable {
    public let workspaceID: WorkspaceID
    /// Nil deliberately shares the skill with projects in this workspace only.
    public let projectID: ProjectID?
    public init(workspaceID: WorkspaceID, projectID: ProjectID? = nil) { self.workspaceID = workspaceID; self.projectID = projectID }
    private enum CodingKeys: String, CodingKey, CaseIterable { case workspaceID, projectID }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decode(WorkspaceID.self, forKey: .workspaceID)
        projectID = try c.decodeIfPresent(ProjectID.self, forKey: .projectID)
    }
    public func validate(in project: ProjectScope) throws {
        guard workspaceID == project.workspaceID, projectID == nil || projectID == project.projectID else { throw SkillError.scopeMismatch }
    }
}
public struct SkillReference: Codable, Hashable, Sendable {
    public let scope: SkillScope
    public let id: SkillID
    public let revision: Int
    public init(scope: SkillScope, id: SkillID, revision: Int) throws {
        self.scope = scope; self.id = id; self.revision = revision
        try validate()
    }
    public func validate() throws { guard (1...1_000_000).contains(revision) else { throw SkillError.invalidBundle } }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: ["scope", "id", "revision"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(SkillScope.self, forKey: .scope), id: c.decode(SkillID.self, forKey: .id), revision: c.decode(Int.self, forKey: .revision))
    }
    private enum CodingKeys: CodingKey { case scope, id, revision }
    static func validate(_ references: [SkillReference], in scope: ProjectScope? = nil) throws {
        guard references.count <= 16, Set(references.map { "\($0.scope.workspaceID)/\($0.scope.projectID?.rawValue ?? "workspace")/\($0.id)" }).count == references.count else { throw SkillError.invalidBundle }
        for reference in references { try reference.validate(); if let scope { try reference.scope.validate(in: scope) } }
    }
}
public struct SkillAttachment: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case example, script }
    public var kind: Kind
    public var name: String
    public var text: String
    public init(kind: Kind, name: String, text: String) { self.kind = kind; self.name = name; self.text = text }
    public var relativeFile: String { "\(kind == .example ? "examples" : "scripts")/\(name)" }
    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 100, !name.hasPrefix("."), !name.contains(".."),
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              !text.utf8.contains(0), text.utf8.count <= 65_536 else { throw SkillError.invalidBundle }
        if kind == .example { guard name.hasSuffix(".md") || name.hasSuffix(".json") else { throw SkillError.invalidBundle } }
        // Script bytes are data for review. This store never executes them or infers an interpreter.
    }
}
public struct SkillDraft: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var instructions: String
    public var enabled: Bool
    public var requiredPermissions: [PolicyOperation]
    public var attachments: [SkillAttachment]
    public init(name: String, summary: String = "", instructions: String, enabled: Bool = true,
                requiredPermissions: [PolicyOperation] = [], attachments: [SkillAttachment] = []) {
        self.name = name; self.summary = summary; self.instructions = instructions; self.enabled = enabled
        self.requiredPermissions = requiredPermissions; self.attachments = attachments
    }
    /// Edits one attachment in an unfinished editor draft without partially applying invalid content.
    public mutating func setAttachment(_ attachment: SkillAttachment, at index: Int? = nil) throws {
        var copy = self
        if let index {
            guard copy.attachments.indices.contains(index) else { throw SkillError.invalidBundle }
            copy.attachments[index] = attachment
        } else { copy.attachments.append(attachment) }
        try copy.validateAttachments()
        self = copy
    }
    private func validateAttachments() throws {
        guard attachments.count <= 16, Set(attachments.map { $0.relativeFile.lowercased() }).count == attachments.count else { throw SkillError.invalidBundle }
        for attachment in attachments { try attachment.validate() }
        guard attachments.reduce(instructions.utf8.count, { $0 + $1.text.utf8.count }) <= 262_144 else { throw SkillError.invalidBundle }
    }
    public func validated() throws -> SkillDraft {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !copy.name.isEmpty, copy.name.count <= 100, !copy.name.contains("/"), !copy.name.contains("\\"),
              !copy.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              summary.utf8.count <= 4_096, !summary.utf8.contains(0),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.utf8.count <= 65_536, !instructions.utf8.contains(0),
              requiredPermissions.count <= PolicyOperation.allCases.count, Set(requiredPermissions).count == requiredPermissions.count else { throw SkillError.invalidBundle }
        try validateAttachments()
        return copy
    }
}
public struct SkillDefinition: Codable, Equatable, Sendable, Identifiable {
    public struct File: Codable, Equatable, Sendable {
        public let kind: SkillAttachment.Kind
        public let name: String
        public let relativeFile: String
        public let fingerprint: ActionFingerprint
    }
    public let schemaVersion: Int
    public let id: SkillID
    public let scope: SkillScope
    public let revision: Int
    public let name: String
    public let summary: String
    public let enabled: Bool
    public let archived: Bool
    public let requiredPermissions: [PolicyOperation]
    public let instructionsFile: String
    public let instructionsFingerprint: ActionFingerprint
    public let files: [File]
    public let createdAt: Date
    public let updatedAt: Date
    public var reference: SkillReference { get throws { try SkillReference(scope: scope, id: id, revision: revision) } }
}
public struct SkillSnapshot: Equatable, Sendable, Identifiable {
    public let definition: SkillDefinition
    public let instructions: String
    public let attachments: [SkillAttachment]
    public var id: SkillID { definition.id }
    public var draft: SkillDraft { SkillDraft(name: definition.name, summary: definition.summary, instructions: instructions,
        enabled: definition.enabled, requiredPermissions: definition.requiredPermissions, attachments: attachments) }
}
/// A request to policy, never an access grant.
public struct SkillPermissionRequest: Equatable, Sendable {
    public let skillName: String
    public let reference: SkillReference
    public let operations: [PolicyOperation]
}

extension SkillDefinition {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, scope, revision, name, summary, enabled, archived, requiredPermissions
        case instructionsFile, instructionsFingerprint, files, createdAt, updatedAt
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(SkillID.self, forKey: .id)
        scope = try c.decode(SkillScope.self, forKey: .scope); revision = try c.decode(Int.self, forKey: .revision)
        name = try c.decode(String.self, forKey: .name); summary = try c.decode(String.self, forKey: .summary)
        enabled = try c.decode(Bool.self, forKey: .enabled); archived = try c.decode(Bool.self, forKey: .archived)
        requiredPermissions = try c.decode([PolicyOperation].self, forKey: .requiredPermissions)
        instructionsFile = try c.decode(String.self, forKey: .instructionsFile)
        instructionsFingerprint = try c.decode(ActionFingerprint.self, forKey: .instructionsFingerprint)
        files = try c.decode([File].self, forKey: .files)
        createdAt = try c.decode(Date.self, forKey: .createdAt); updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
extension SkillDefinition.File {
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, name, relativeFile, fingerprint }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SkillAttachment.Kind.self, forKey: .kind); name = try c.decode(String.self, forKey: .name)
        relativeFile = try c.decode(String.self, forKey: .relativeFile); fingerprint = try c.decode(ActionFingerprint.self, forKey: .fingerprint)
    }
}
