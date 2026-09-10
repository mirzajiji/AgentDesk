#if os(macOS)
import AgentDeskCore
import Foundation

public enum RepositoryRegistrationError: String, Error, Sendable {
    case invalidSelection, unavailable, staleBookmark, changedDirectory, invalidRecord, staleRevision, busy, storageUnavailable
}
public struct RegisteredRepository: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let scope: ProjectScope
    public let revision: Int
    public let path: String
    public let name: String
}

protocol RepositoryBookmarkCoding: Sendable {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool)
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}
struct NativeRepositoryBookmarkCoding: RepositoryBookmarkCoding {
    func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Retain this value for the complete run/service lifetime. Deallocation balances the OS grant.
/// A shared project lease prevents another window/process replacing this registration during use.
public final class RepositoryAccess: Sendable {
    public let registration: RegisteredRepository
    public let directory: URL
    private let securityURL: URL
    private let started: Bool
    private let codec: any RepositoryBookmarkCoding
    private let lease: RunCoordinatorLease
    init(registration: RegisteredRepository, directory: URL, securityURL: URL, started: Bool,
         codec: any RepositoryBookmarkCoding, lease: RunCoordinatorLease) {
        self.registration = registration; self.directory = directory; self.securityURL = securityURL
        self.started = started; self.codec = codec; self.lease = lease
    }
    deinit { if started { codec.stop(securityURL) } }
}

struct RepositoryRegistrationRecord: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let scope: ProjectScope
    let revision: Int
    let path: String
    let name: String
    let resource: ExecutionResource
    let bookmark: Data
    var registration: RegisteredRepository {
        RegisteredRepository(id: id, scope: scope, revision: revision, path: path, name: name)
    }
    func validate(in expected: ProjectScope) throws {
        guard schemaVersion == 1, scope == expected, resource.scope == scope, (1...1_000_000).contains(revision),
              path.hasPrefix("/"), path.utf8.count <= 4_096, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !name.isEmpty, name.utf8.count <= 255, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...65_536).contains(bookmark.count) else { throw RepositoryRegistrationError.invalidRecord }
    }
}
#endif
