import Foundation

public enum InstructionEntity: Sendable {}
public typealias InstructionID = EntityID<InstructionEntity>

public enum InstructionError: Error, Equatable, Sendable, LocalizedError {
    case invalidBundle, missingReference, circularReference, sizeLimit, staleRevision

    public var errorDescription: String? {
        switch self {
        case .invalidBundle: "This instruction set is invalid or unsupported. Its saved files have been preserved."
        case .missingReference: "An included instruction no longer exists in this set. Update its references before saving."
        case .circularReference: "These instructions include each other in a cycle. Remove the circular reference."
        case .sizeLimit: "This instruction set exceeds its size or nesting limit."
        case .staleRevision: "These shared instructions changed in another window. Reload before saving."
        }
    }
}

public enum InstructionLevel: String, CaseIterable, Codable, Sendable {
    case workspace, project
    public var title: String { self == .workspace ? "Workspace" : "Project" }
}

public struct InstructionDocument: Identifiable, Equatable, Sendable {
    public let id: InstructionID
    public var title: String
    public var text: String
    public var includes: [InstructionID]

    public init(id: InstructionID = InstructionID(), title: String, text: String, includes: [InstructionID] = []) {
        self.id = id; self.title = title; self.text = text; self.includes = includes
    }
}

public struct InstructionBundleDraft: Equatable, Sendable {
    public var documents: [InstructionDocument]
    public var roots: [InstructionID]

    public init(documents: [InstructionDocument] = [], roots: [InstructionID] = []) {
        self.documents = documents; self.roots = roots
    }

    /// Includes resolve only inside this bundle, before the referring document, once each.
    public func resolvedDocuments() throws -> [InstructionDocument] {
        guard documents.count <= 64, roots.count <= 64 else { throw InstructionError.sizeLimit }
        guard Set(documents.map(\.id)).count == documents.count, Set(roots).count == roots.count else {
            throw InstructionError.invalidBundle
        }
        var bytes = 0
        for document in documents {
            guard !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  document.title.count <= 100,
                  !document.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !document.text.utf8.contains(0), Set(document.includes).count == document.includes.count else {
                throw InstructionError.invalidBundle
            }
            guard document.text.utf8.count <= 65_536, document.includes.count <= 64 else { throw InstructionError.sizeLimit }
            bytes += document.text.utf8.count
        }
        guard bytes <= 262_144 else { throw InstructionError.sizeLimit }
        let lookup = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        var visited: Set<InstructionID> = [], visiting: Set<InstructionID> = []
        var output: [InstructionDocument] = []
        func visit(_ id: InstructionID, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32 else { throw InstructionError.sizeLimit }
            guard !visiting.contains(id) else { throw InstructionError.circularReference }
            if visited.contains(id) { return }
            guard let document = lookup[id] else { throw InstructionError.missingReference }
            visiting.insert(id)
            for include in document.includes { try visit(include, depth: depth + 1) }
            visiting.remove(id); visited.insert(id); output.append(document)
        }
        // Validate unused documents too, so latent broken references cannot be saved.
        for document in documents {
            visited.removeAll(); output.removeAll()
            try visit(document.id, depth: 0)
        }
        visited.removeAll(); output.removeAll()
        for id in roots { try visit(id, depth: 0) }
        return output
    }
}

public struct InstructionBundleSnapshot: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let projectID: ProjectID?
    public let revision: Int
    public let createdAt: Date
    public let draft: InstructionBundleDraft
    public var level: InstructionLevel { projectID == nil ? .workspace : .project }
}
