#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Darwin
import Foundation

/// Host-supplied roots must belong to the authenticated project registration.
/// Re-resolve immediately before dispatch; this snapshot does not hold an execution grant.
struct MCPLaunchResource: Sendable {
    let directory: URL
    let executable: URL
    let fingerprint: ActionFingerprint

    static func resolve(_ configuration: MCPStdioConfiguration, scope: ProjectScope,
                        workspaceRoot: URL, projectRoot: URL) throws -> Self {
        try Task.checkCancellation()
        guard configuration.scope == scope else { throw AuthorizationError.scopeMismatch }
        let workspace = try canonical(workspaceRoot)
        let project = try canonical(projectRoot)
        if configuration.directoryBase == .workspace {
            guard contained(project, in: workspace) else { throw AuthorizationError.scopeMismatch }
        }
        let base = configuration.directoryBase == .workspace ? workspace : project
        let directory = try configuration.workingDirectory.map { try canonical(base.appendingPathComponent($0.relativePath)) } ?? project
        guard contained(directory, in: project) else { throw AuthorizationError.scopeMismatch }
        let executable = try canonical(URL(fileURLWithPath: configuration.executable))
        let directoryIdentity = try identity(directory, directory: true)
        let projectIdentity = try identity(project, directory: true)
        let executableIdentity = try identity(executable, directory: false)
        struct Binding: Encodable {
            let scope: ProjectScope
            let project: Identity
            let directory: Identity
            let executable: Identity
        }
        return Self(directory: directory, executable: executable,
            fingerprint: try .canonical(Binding(scope: scope, project: projectIdentity, directory: directoryIdentity, executable: executableIdentity)))
    }
    private static func contained(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
    private static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.utf8.contains(0), let resolved = realpath(url.path, nil) else { throw AuthorizationError.invalidInput }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    private struct Identity: Encodable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    private static func identity(_ url: URL, directory: Bool) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || access(url.path, X_OK) == 0 else { throw AuthorizationError.invalidInput }
        // Directory contents may change during normal work; bind directory identity, not its mtime.
        return Identity(path: url.path, device: info.st_dev, inode: info.st_ino,
            size: directory ? 0 : info.st_size,
            modifiedSeconds: directory ? 0 : info.st_mtimespec.tv_sec,
            modifiedNanos: directory ? 0 : info.st_mtimespec.tv_nsec,
            changedSeconds: directory ? 0 : info.st_ctimespec.tv_sec,
            changedNanos: directory ? 0 : info.st_ctimespec.tv_nsec)
    }
}
#endif
