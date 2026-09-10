#if os(macOS)
import CryptoKit
import AgentDeskCore
import Darwin
import Foundation

struct GitWorkingFile: Equatable, Sendable {
    enum Kind: String { case text, binary, tooLarge, symlink, directory, missing, submodule }
    let kind: Kind
    let digest: Data?
    let text: String?
}

/// Confined to the capture actor. Git metadata is inspected without following links before execution.
final class GitRepositoryFiles {
    let root: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    init(root: URL) throws {
        guard root.isFileURL, !root.path.utf8.contains(0), let canonical = realpath(root.path, nil) else { throw RepositoryCaptureError.invalidRepository }
        defer { free(canonical) }
        var selected = stat()
        guard lstat(root.path, &selected) == 0, selected.st_mode & S_IFMT == S_IFDIR else { throw RepositoryCaptureError.unsafeFile }
        // Resolve authorized ancestor aliases such as macOS /var -> /private/var once; the selected
        // directory itself cannot be a link. Foundation's URL normalization may retain that system alias.
        let canonicalRoot = URL(fileURLWithPath: String(cString: canonical))
        let opened = Darwin.open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw Self.failure() }
        var info = stat()
        guard fstat(opened, &info) == 0 else { Darwin.close(opened); throw Self.failure() }
        descriptor = opened; device = info.st_dev; inode = info.st_ino; self.root = canonicalRoot
    }
    deinit { Darwin.close(descriptor) }
    func resource(in scope: ProjectScope) throws -> ExecutionResource {
        try .directory(in: scope, device: Int64(device), inode: UInt64(inode))
    }

    func validateRoot() throws {
        try Task.checkCancellation()
        guard let canonical = realpath(root.path, nil) else { throw RepositoryCaptureError.changedDuringCapture }
        defer { free(canonical) }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == device, info.st_ino == inode,
              String(cString: canonical) == root.path else { throw RepositoryCaptureError.changedDuringCapture }
    }
    func metadataFingerprint() throws -> Data {
        try validateRoot()
        let git = openat(descriptor, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard git >= 0 else { throw RepositoryCaptureError.unsupportedRepository }
        defer { Darwin.close(git) }
        var count = 0, hash = SHA256()
        try scan(git, path: "", depth: 0, count: &count, hash: &hash)
        return Data(hash.finalize())
    }
    func configuration() throws -> Data {
        let git = openat(descriptor, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard git >= 0 else { throw RepositoryCaptureError.unsupportedRepository }
        defer { Darwin.close(git) }
        let file = openat(git, "config", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        return try read(file, maximum: 65_536)
    }
    func workingFile(_ path: String) throws -> GitWorkingFile {
        try GitStatusParser.validatePath(path); try validateRoot()
        let components = path.split(separator: "/").map(String.init)
        var current = dup(descriptor)
        guard current >= 0 else { throw Self.failure() }
        defer { Darwin.close(current) }
        for part in components.dropLast() {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { if errno == ENOENT { return .init(kind: .missing, digest: nil, text: nil) }; throw Self.failure() }
            Darwin.close(current); current = next
        }
        let name = components.last!
        var metadata = stat()
        if fstatat(current, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .init(kind: .missing, digest: nil, text: nil) }; throw Self.failure()
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [UInt8](repeating: 0, count: 4_097)
            let size = buffer.withUnsafeMutableBytes { readlinkat(current, name, $0.baseAddress, $0.count) }
            guard size >= 0, size <= 4_096 else { throw RepositoryCaptureError.unsafeFile }
            return .init(kind: .symlink, digest: Data(SHA256.hash(data: Data(buffer.prefix(size)))), text: nil)
        case S_IFDIR: return .init(kind: .directory, digest: nil, text: nil)
        case S_IFREG: break
        default: throw RepositoryCaptureError.unsafeFile
        }
        guard metadata.st_nlink == 1 else { throw RepositoryCaptureError.unsafeFile }
        if metadata.st_size > 65_536 { return .init(kind: .tooLarge, digest: nil, text: nil) }
        let file = openat(current, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        let data = try read(file, maximum: 65_536), text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        return .init(kind: text == nil ? .binary : .text, digest: Data(SHA256.hash(data: data)), text: text)
    }
    private func read(_ file: Int32, maximum: Int) throws -> Data {
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw Self.failure() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw RepositoryCaptureError.unsafeFile }
        guard metadata.st_size >= 0, metadata.st_size <= maximum else { throw RepositoryCaptureError.limitExceeded }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try Task.checkCancellation()
            let size = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if size < 0 { if errno == EINTR { continue }; throw Self.failure() }
            if size == 0 { return result }
            guard size <= maximum - result.count else { throw RepositoryCaptureError.limitExceeded }
            result.append(contentsOf: buffer.prefix(size))
        }
    }
    private func scan(_ directory: Int32, path: String, depth: Int, count: inout Int, hash: inout SHA256) throws {
        guard depth <= 64 else { throw RepositoryCaptureError.limitExceeded }
        for name in try names(directory) {
            try Task.checkCancellation(); count += 1
            guard count <= 32_768 else { throw RepositoryCaptureError.limitExceeded }
            let relative = path.isEmpty ? name : path + "/" + name
            guard relative.utf8.count <= 4_096 else { throw RepositoryCaptureError.limitExceeded }
            guard !["commondir", "config.worktree", "objects/info/alternates", "objects/info/http-alternates"].contains(relative) else {
                throw RepositoryCaptureError.unsupportedRepository
            }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure() }
            let kind = metadata.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && metadata.st_nlink == 1) else { throw RepositoryCaptureError.unsafeFile }
            let value = "\(relative.utf8.count):\(relative):\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mode):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec)\n"
            hash.update(data: Data(value.utf8))
            if kind == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Self.failure() }
                defer { Darwin.close(child) }
                try scan(child, path: relative, depth: depth + 1, count: &count, hash: &hash)
            }
        }
    }
    private func names(_ directory: Int32) throws -> [String] {
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Self.failure() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure() }
                return result.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw RepositoryCaptureError.unsupportedRepository }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 32_768 else { throw RepositoryCaptureError.limitExceeded }
        }
    }
    private static func failure() -> RepositoryCaptureError {
        switch errno { case ELOOP, ENOTDIR: .unsafeFile; default: .fileSystem(errno) }
    }
}
#endif
