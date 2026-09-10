#if os(macOS)
import AgentDeskCore
import Darwin
import Foundation

/// Private machine-local configuration; bookmark bytes stay outside public metadata and portable workspace configuration.
final class RepositoryRegistryFiles {
    let container: URL
    private let descriptor: Int32
    init(container: URL) throws {
        guard container.isFileURL, !container.path.utf8.contains(0), let path = realpath(container.path, nil) else {
            throw RepositoryRegistrationError.storageUnavailable
        }
        defer { free(path) }
        var info = stat()
        guard lstat(container.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw RepositoryRegistrationError.storageUnavailable }
        self.container = URL(fileURLWithPath: String(cString: path))
        descriptor = open(self.container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RepositoryRegistrationError.storageUnavailable }
    }
    deinit { close(descriptor) }
    func validate() throws {
        var held = stat(), current = stat()
        guard fstat(descriptor, &held) == 0, lstat(container.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR, held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw RepositoryRegistrationError.storageUnavailable
        }
    }
    private func name(_ scope: ProjectScope) -> String { "\(scope.workspaceID.rawValue).\(scope.projectID.rawValue).json" }
    func read(_ scope: ProjectScope) throws -> RepositoryRegistrationRecord? {
        try Task.checkCancellation(); try validate()
        let fd = openat(descriptor, name(scope), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RepositoryRegistrationError.storageUnavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, (1...131_072).contains(info.st_size) else {
            throw RepositoryRegistrationError.invalidRecord
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw RepositoryRegistrationError.storageUnavailable }
            if count == 0 { break }
            guard count <= 131_072 - result.count else { throw RepositoryRegistrationError.invalidRecord }
            result.append(contentsOf: buffer.prefix(count))
        }
        try validate()
        do {
            let record = try ConfigurationJSON.decode(RepositoryRegistrationRecord.self, from: result)
            try record.validate(in: scope); return record
        } catch { throw RepositoryRegistrationError.invalidRecord }
    }
    func write(_ record: RepositoryRegistrationRecord, replacing: Bool) throws {
        try validate(); try record.validate(in: record.scope)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= 131_072 else { throw RepositoryRegistrationError.invalidRecord }
        let temporary = ".registration-\(UUID().uuidString)"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RepositoryRegistrationError.storageUnavailable }
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw RepositoryRegistrationError.storageUnavailable }
                guard count > 0 else { throw RepositoryRegistrationError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw RepositoryRegistrationError.storageUnavailable }
        try Task.checkCancellation()
        try validate()
        let result = replacing ? renameat(descriptor, temporary, descriptor, name(record.scope))
            : renameatx_np(descriptor, temporary, descriptor, name(record.scope), UInt32(RENAME_EXCL))
        guard result == 0, fsync(descriptor) == 0 else { throw RepositoryRegistrationError.storageUnavailable }
    }
    func remove(_ scope: ProjectScope) throws {
        try Task.checkCancellation(); try validate()
        guard unlinkat(descriptor, name(scope), 0) == 0, fsync(descriptor) == 0 else { throw RepositoryRegistrationError.storageUnavailable }
    }
}
#endif
