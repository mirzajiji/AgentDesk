import AgentDeskSecurity
import Darwin
import Foundation

/// Actor-confined descriptor ownership below a caller-authorized operational database container.
/// The public API never accepts a caller-supplied artifact filename or exports an unchecked URL.
final class ArtifactFiles {
    private let descriptor: Int32
    init(container: URL, context: RedactionContext) throws {
        guard container.isFileURL, !container.path.utf8.contains(0), let canonical = realpath(container.path, nil) else {
            throw EvidenceStoreError.invalidLocation
        }
        defer { free(canonical) }
        var current = Darwin.open("/", O_SEARCH | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure() }
        do {
            for name in String(cString: canonical).split(separator: "/") {
                let next = openat(current, String(name), O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure() }
                Darwin.close(current); current = next
            }
            let readable = openat(current, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard readable >= 0 else { throw Self.failure() }
            Darwin.close(current); current = readable
            for name in ["Evidence", context.scope.workspaceID.rawValue, context.scope.projectID.rawValue,
                         context.environmentID.rawValue, context.runID.rawValue] {
                let created = mkdirat(current, name, 0o700) == 0
                guard created || errno == EEXIST else { throw Self.failure() }
                if created { guard fsync(current) == 0 else { throw Self.failure() } }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure() }
                Darwin.close(current); current = next
            }
        } catch { Darwin.close(current); throw error }
        descriptor = current
    }
    deinit { Darwin.close(descriptor) }

    func read(_ id: UUID) throws -> Data {
        try Task.checkCancellation()
        let file = openat(descriptor, name(id), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw Self.failure() }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else { throw EvidenceStoreError.unsafeFile }
        guard (0...1_048_576).contains(metadata.st_size) else { throw EvidenceStoreError.corruptArtifact }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
            if count == 0 { return result }
            guard count <= 1_048_576 - result.count else { throw EvidenceStoreError.corruptArtifact }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    /// A retry may adopt an exact orphan or repair a missing file. Existing different bytes never change.
    func publish(_ data: Data, id: UUID) throws {
        try Task.checkCancellation()
        guard data.count <= 1_048_576 else { throw EvidenceStoreError.limitExceeded }
        do {
            guard try read(id) == data else { throw EvidenceStoreError.conflictingRecord }
            guard fsync(descriptor) == 0 else { throw Self.failure() }
            return
        } catch EvidenceStoreError.missingArtifact { /* Create the absent file below. */ }
        let temporary = ".stage-\(UUID().uuidString)"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
                guard count > 0 else { throw EvidenceStoreError.fileSystem(EIO) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Self.failure() }
        try Task.checkCancellation()
        guard renameatx_np(descriptor, temporary, descriptor, name(id), UInt32(RENAME_EXCL)) == 0 else { throw Self.failure() }
        guard fsync(descriptor) == 0 else { throw Self.failure() }
    }

    func inventory() throws -> (ids: [UUID], staged: Int, unexpected: Int) {
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Self.failure() }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Self.failure() }
        defer { closedir(stream) }
        var ids: [UUID] = [], staged = 0, unexpected = 0
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure() }
                return (ids.sorted { $0.uuidString < $1.uuidString }, staged, unexpected)
            }
            let value = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if value == "." || value == ".." { continue }
            if value.hasSuffix(".txt"), let id = UUID(uuidString: String(value.dropLast(4))), value == name(id) { ids.append(id) }
            else if value.hasPrefix(".stage-"), UUID(uuidString: String(value.dropFirst(7))) != nil { staged += 1 }
            else { unexpected += 1 }
            guard ids.count + staged + unexpected <= 4_096 else { throw EvidenceStoreError.limitExceeded }
        }
    }
    private func name(_ id: UUID) -> String { id.uuidString.lowercased() + ".txt" }
    private static func failure() -> EvidenceStoreError {
        switch errno {
        case ENOENT: .missingArtifact
        case ELOOP, ENOTDIR: .unsafeFile
        default: .fileSystem(errno)
        }
    }
}
