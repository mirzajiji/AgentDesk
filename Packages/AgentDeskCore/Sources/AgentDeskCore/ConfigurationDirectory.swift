import Darwin
import Foundation

/// Internal descriptor ownership for configuration storage. Never exposes an unchecked file URL.
final class ConfigurationDirectory: Sendable {
    let descriptor: Int32

    init(trustedContainer: URL) throws {
        guard trustedContainer.isFileURL, !trustedContainer.path.utf8.contains(0),
              let canonical = realpath(trustedContainer.path, nil) else { throw ScopedFileError.invalidRoot }
        defer { free(canonical) }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure() }
        do {
            for name in String(cString: canonical).split(separator: "/") {
                let next = openat(current, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure() }
                Darwin.close(current)
                current = next
            }
        } catch { Darwin.close(current); throw error }
        descriptor = current
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    func child(_ name: String) throws -> ConfigurationDirectory {
        try Self.validate(name)
        let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Self.failure() }
        return ConfigurationDirectory(descriptor: next)
    }

    func createChild(_ name: String) throws -> ConfigurationDirectory {
        try Self.validate(name)
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw Self.failure() }
        return try child(name)
    }

    func names() throws -> [String] {
        // A new open description avoids sharing directory offsets between repeated enumerations.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Self.failure() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure() }
                return result.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        try Self.validate(name)
        guard (0...67_108_864).contains(maximumBytes) else { throw ScopedFileError.sizeLimit }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw Self.failure() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw ScopedFileError.unsafeFile }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else { throw ScopedFileError.sizeLimit }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
            if count == 0 { return data }
            guard count <= maximumBytes - data.count else { throw ScopedFileError.sizeLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func write(_ data: Data, to name: String, replacing: Bool = false) throws {
        try Task.checkCancellation()
        try Self.validate(name)
        guard data.count <= 1_048_576 else { throw ScopedFileError.sizeLimit }
        if replacing {
            // Reject malformed existing destinations. The atomic rename itself never follows a link.
            _ = try read(name, maximumBytes: 1_048_576)
        }
        let temporary = ".write-\(UUID().uuidString)"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
                guard count > 0 else { throw ScopedFileError.system(EIO) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Self.failure() }
        try Task.checkCancellation()
        guard renameatx_np(descriptor, temporary, descriptor, name, replacing ? 0 : UInt32(RENAME_EXCL)) == 0 else {
            throw Self.failure()
        }
    }

    func publishChild(_ temporary: String, as name: String) throws {
        try Self.validate(temporary); try Self.validate(name)
        try Task.checkCancellation()
        guard renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.failure() }
    }

    /// Only call for the known contents of an unpublished staging directory.
    func remove(_ name: String, directory: Bool = false) {
        guard (try? Self.validate(name)) != nil else { return }
        unlinkat(descriptor, name, directory ? AT_REMOVEDIR : 0)
    }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CatalogError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf8.count <= 255 else { throw ScopedFileError.invalidPath }
    }

    private static func failure() -> ScopedFileError {
        switch errno {
        case ENOENT: .notFound
        case ELOOP, ENOTDIR: .unsafeFile
        default: .system(errno)
        }
    }
}
