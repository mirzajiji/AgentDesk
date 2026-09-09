import Darwin
import Foundation

/// An already-authorized workspace, anchored to an open directory descriptor.
/// This enforces storage scope; operation approval remains the service's responsibility.
public actor WorkspaceFileSystem {
    public nonisolated let workspaceID: WorkspaceID
    private let directory: Int32

    /// The trusted container must exist. Workspace directories use their UUID identity.
    /// Canonicalize only this caller-authorized root, never a requested relative path.
    public init(container: URL, workspaceID: WorkspaceID) throws {
        guard container.isFileURL else { throw ScopedFileError.invalidRoot }
        guard !container.path.utf8.contains(0), let canonical = realpath(container.path, nil) else {
            throw ScopedFileError.invalidRoot
        }
        defer { free(canonical) }
        let containerFD = try Self.openAbsoluteDirectory(String(cString: canonical))
        defer { Darwin.close(containerFD) }
        let workspaceFD = openat(containerFD, workspaceID.rawValue,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workspaceFD >= 0 else { throw Self.failure(errno) }
        self.workspaceID = workspaceID
        directory = workspaceFD
    }

    deinit { Darwin.close(directory) }

    /// Read bounded, regular, single-link files. Never opens a symlink, pipe or device.
    /// Each component is opened relative to the previous descriptor to avoid a
    /// check-then-open race through a substituted symlink.
    public func read(_ reference: WorkspacePath, maximumBytes: Int = 1_048_576) throws -> Data {
        try Task.checkCancellation()
        guard reference.workspaceID == workspaceID else { throw ScopedFileError.scopeMismatch }
        guard maximumBytes >= 0, maximumBytes <= 67_108_864 else { throw ScopedFileError.sizeLimit }
        let components = reference.components
        let parent = try openDirectory(components.dropLast())
        defer { Darwin.close(parent) }
        guard let name = components.last else { throw ScopedFileError.invalidPath }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure(errno) }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw Self.failure(errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            throw ScopedFileError.unsafeFile
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else { throw ScopedFileError.sizeLimit }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure(errno)
            }
            if count == 0 { return result }
            guard count <= maximumBytes - result.count else { throw ScopedFileError.sizeLimit }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func openDirectory(_ components: ArraySlice<String>) throws -> Int32 {
        var current = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw Self.failure(errno) }
        do {
            for name in components {
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure(errno) }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func openAbsoluteDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ScopedFileError.invalidRoot }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw failure(errno) }
        do {
            for name in path.split(separator: "/").map(String.init) {
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure(errno) }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func failure(_ code: Int32) -> ScopedFileError {
        switch code {
        case ENOENT: .notFound
        case ELOOP, ENOTDIR: .unsafeFile
        default: .system(code)
        }
    }
}
