#if os(macOS)
import AgentDeskCore
import Foundation

/// Native local administrative service. Only an explicit folder selection registers access.
/// Use an app-private machine-local directory, separate from portable workspace configuration.
public actor ProjectRepositoryRegistry {
    private let catalog: WorkspaceCatalog
    private let files: RepositoryRegistryFiles
    private let codec: any RepositoryBookmarkCoding
    public init(catalog: WorkspaceCatalog, container: URL) throws {
        self.catalog = catalog; files = try RepositoryRegistryFiles(container: container); codec = NativeRepositoryBookmarkCoding()
    }
    init(catalog: WorkspaceCatalog, container: URL, codec: any RepositoryBookmarkCoding) throws {
        self.catalog = catalog; files = try RepositoryRegistryFiles(container: container); self.codec = codec
    }
    public func registration(in scope: ProjectScope) async throws -> RegisteredRepository? {
        _ = try await catalog.project(scope)
        let lease = try lock(scope, shared: true); defer { withExtendedLifetime(lease) {} }
        return try files.read(scope)?.registration
    }
    public func register(_ selected: URL, in scope: ProjectScope, expectedRevision: Int?) async throws -> RegisteredRepository {
        _ = try await catalog.project(scope)
        let lease = try lock(scope, shared: false); defer { withExtendedLifetime(lease) {} }
        let existing = try files.read(scope)
        guard existing?.revision == expectedRevision else { throw RepositoryRegistrationError.staleRevision }
        guard selected.isFileURL, selected.path.utf8.count <= 4_096,
              !selected.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw RepositoryRegistrationError.invalidSelection }
        let started = codec.start(selected); defer { if started { codec.stop(selected) } }
        do {
            // A false start result can mean no extension was needed for an already accessible app-owned
            // location. Opening and validating the directory still has to succeed under the actual sandbox.
            let repository = try GitRepositoryFiles(root: selected)
            let inspected = try await GitRepositoryRegistrationInspection.inspect(root: repository.root, scope: scope)
            guard try repository.resource(in: scope) == inspected else { throw RepositoryRegistrationError.changedDirectory }
            let bookmark = try codec.create(for: selected)
            let record = RepositoryRegistrationRecord(schemaVersion: 1, id: UUID(), scope: scope, revision: (existing?.revision ?? 0) + 1,
                path: repository.root.path, name: repository.root.lastPathComponent, resource: try repository.resource(in: scope), bookmark: bookmark)
            try record.validate(in: scope); try repository.validateRoot(); try lease.validate()
            guard try files.read(scope) == existing else { throw RepositoryRegistrationError.staleRevision }
            try files.write(record, replacing: existing != nil)
            return record.registration
        } catch let error as RepositoryRegistrationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw RepositoryRegistrationError.invalidSelection }
    }
    public func access(in scope: ProjectScope) async throws -> RepositoryAccess {
        _ = try await catalog.project(scope)
        let lease = try lock(scope, shared: true)
        guard let record = try files.read(scope) else { throw RepositoryRegistrationError.unavailable }
        let resolved: (url: URL, stale: Bool)
        do { resolved = try codec.resolve(record.bookmark) }
        catch { throw RepositoryRegistrationError.unavailable }
        guard !resolved.stale else { throw RepositoryRegistrationError.staleBookmark }
        let started = codec.start(resolved.url)
        do {
            let repository = try GitRepositoryFiles(root: resolved.url)
            guard repository.root.path == record.path, try repository.resource(in: scope) == record.resource else {
                throw RepositoryRegistrationError.changedDirectory
            }
            _ = try repository.metadataFingerprint(); try lease.validate()
            return RepositoryAccess(registration: record.registration, directory: repository.root, securityURL: resolved.url,
                started: started, codec: codec, lease: lease)
        } catch {
            if started { codec.stop(resolved.url) }
            if let known = error as? RepositoryRegistrationError { throw known }
            if error is CancellationError { throw CancellationError() }
            throw RepositoryRegistrationError.unavailable
        }
    }
    public func remove(in scope: ProjectScope, expectedRevision: Int) async throws {
        _ = try await catalog.project(scope)
        let lease = try lock(scope, shared: false); defer { withExtendedLifetime(lease) {} }
        guard let record = try files.read(scope), record.revision == expectedRevision else { throw RepositoryRegistrationError.staleRevision }
        try lease.validate(); try files.remove(scope)
    }
    private func lock(_ scope: ProjectScope, shared: Bool) throws -> RunCoordinatorLease {
        try Task.checkCancellation(); try files.validate()
        do { return try RunCoordinatorLease(container: files.container, scope: scope, purpose: .repositoryAccess, shared: shared) }
        catch RunCoordinatorError.busy { throw RepositoryRegistrationError.busy }
        catch { throw RepositoryRegistrationError.storageUnavailable }
    }
}
#endif
