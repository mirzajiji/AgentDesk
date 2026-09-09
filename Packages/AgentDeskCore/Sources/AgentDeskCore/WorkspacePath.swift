import Foundation

public enum ScopedFileError: Error, Equatable, Sendable {
    case invalidPath
    case scopeMismatch
    case invalidRoot
    case notFound
    case unsafeFile
    case sizeLimit
    case system(Int32)
}

/// A portable configuration path, not a URL. Percent-encoded input is rejected;
/// callers must never decode or normalize a validated path a second time.
public struct WorkspacePath: Hashable, Codable, Sendable {
    public let workspaceID: WorkspaceID
    public let relativePath: String

    public init(workspaceID: WorkspaceID, relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, relativePath.utf8.count <= 4096,
              !relativePath.contains("\\"), !relativePath.contains("%"), !relativePath.contains(":"),
              !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ScopedFileError.invalidPath
        }
        self.workspaceID = workspaceID
        self.relativePath = relativePath
    }

    var components: [String] { relativePath.split(separator: "/").map(String.init) }

    private enum CodingKeys: CodingKey { case workspaceID, relativePath }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspaceID: container.decode(WorkspaceID.self, forKey: .workspaceID),
                      relativePath: container.decode(String.self, forKey: .relativePath))
    }
}
