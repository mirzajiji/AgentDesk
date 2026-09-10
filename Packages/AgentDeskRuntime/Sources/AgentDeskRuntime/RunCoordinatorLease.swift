import AgentDeskCore
import Darwin
import Foundation

/// One execution owner per project and operational container, including across processes/environments.
/// The file remains after release; unlinking a lock would allow simultaneous owners of different inodes.
final class RunCoordinatorLease: Sendable {
    private let directory: Int32
    private let descriptor: Int32
    private let name: String
    private let root: String
    enum Purpose { case runOwner, repositoryAccess }
    init(container: URL, scope: ProjectScope, purpose: Purpose = .runOwner, shared: Bool = false) throws {
        guard container.isFileURL, !shared || purpose == .repositoryAccess else { throw RunCoordinatorError.unsafeStorage }
        let path = container.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let canonical = realpath(path, nil) else { throw RunCoordinatorError.unsafeStorage }
        root = String(cString: canonical); free(canonical)
        let dir = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw RunCoordinatorError.unsafeStorage }
        let prefix = purpose == .runOwner ? "run-owner" : "repository-access"
        name = ".\(prefix)-\(scope.workspaceID.rawValue).\(scope.projectID.rawValue).lock"
        let fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(dir); throw RunCoordinatorError.unsafeStorage }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); close(dir); throw RunCoordinatorError.unsafeStorage
        }
        guard flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            close(fd); close(dir); throw RunCoordinatorError.busy
        }
        directory = dir; descriptor = fd
        try validate()
    }
    func validate() throws {
        var held = stat(), current = stat(), heldRoot = stat(), currentRoot = stat()
        guard fstat(descriptor, &held) == 0, fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino, current.st_nlink == 1,
              current.st_mode & S_IFMT == S_IFREG, current.st_mode & 0o077 == 0,
              fstat(directory, &heldRoot) == 0, lstat(root, &currentRoot) == 0,
              currentRoot.st_mode & S_IFMT == S_IFDIR, heldRoot.st_dev == currentRoot.st_dev,
              heldRoot.st_ino == currentRoot.st_ino else { throw RunCoordinatorError.unsafeStorage }
    }
    deinit { close(descriptor); close(directory) }
}
