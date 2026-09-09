import Foundation

/// An already-authorized workspace, anchored to an open directory descriptor.
/// This enforces storage scope; operation approval remains the service's responsibility.
public actor WorkspaceFileSystem {
    public nonisolated let workspaceID: WorkspaceID
    private let directory: ConfigurationDirectory

    public init(container: URL, workspaceID: WorkspaceID) throws {
        directory = try ConfigurationDirectory(trustedContainer: container).child(workspaceID.rawValue)
        self.workspaceID = workspaceID
    }

    /// Reads bounded regular files through no-follow descriptor-relative operations.
    public func read(_ reference: WorkspacePath, maximumBytes: Int = 1_048_576) throws -> Data {
        try Task.checkCancellation()
        guard reference.workspaceID == workspaceID else { throw ScopedFileError.scopeMismatch }
        guard (0...67_108_864).contains(maximumBytes) else { throw ScopedFileError.sizeLimit }
        var parent = directory
        for name in reference.components.dropLast() { parent = try parent.child(name) }
        guard let name = reference.components.last else { throw ScopedFileError.invalidPath }
        return try parent.read(name, maximumBytes: maximumBytes)
    }
}
