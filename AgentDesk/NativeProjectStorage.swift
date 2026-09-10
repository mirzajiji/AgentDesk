#if os(macOS)
import AgentDeskCore
import Darwin
import Foundation

/// Creates only fixed private machine-local descendants of the app's authorized support root.
enum NativeProjectStorage {
    static func prepare(root: URL, workspaceID: WorkspaceID) throws -> (access: URL, data: URL) {
        try Task.checkCancellation()
        guard root.isFileURL, !root.path.utf8.contains(0) else { throw CatalogError.invalidConfiguration }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CatalogError.invalidConfiguration }
        defer { close(rootFD) }
        let accessFD = try child("RepositoryAccess", parent: rootFD); defer { close(accessFD) }
        let dataFD = try child("Data", parent: rootFD); defer { close(dataFD) }
        let workspaceFD = try child(workspaceID.rawValue, parent: dataFD); defer { close(workspaceFD) }
        let access = root.appendingPathComponent("RepositoryAccess"), data = root.appendingPathComponent("Data/\(workspaceID)")
        for (fd, url) in [(rootFD, root), (accessFD, access), (dataFD, root.appendingPathComponent("Data")), (workspaceFD, data)] {
            var held = stat(), current = stat()
            guard fstat(fd, &held) == 0, lstat(url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
                  held.st_dev == current.st_dev, held.st_ino == current.st_ino else { throw CatalogError.invalidConfiguration }
        }
        return (access, data)
    }
    private static func child(_ name: String, parent: Int32) throws -> Int32 {
        try Task.checkCancellation()
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw CatalogError.invalidConfiguration }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CatalogError.invalidConfiguration }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw CatalogError.invalidConfiguration
        }
        return fd
    }
}
#endif
