#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import Combine
import Foundation

struct ProjectNativeServices: Sendable {
    let setup: ProjectExecutionSetupService
    let repositories: ProjectRepositoryRegistry
    let catalog: WorkspaceCatalog
    let database: URL
}

@MainActor
final class ProjectSetupModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var settings: ExecutionSetupSnapshot?
    @Published private(set) var repository: RegisteredRepository?
    @Published private(set) var repositoryAccessAvailable: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private(set) var services: ProjectNativeServices?
    private let open: () async throws -> ProjectNativeServices

    init(project: ProjectRecord, open: @escaping () async throws -> ProjectNativeServices) {
        self.project = project; self.open = open
    }
    func load() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let services: ProjectNativeServices
            if let existing = self.services { services = existing } else { services = try await open() }
            guard services.setup.scope == project.scope else { throw ExecutionSetupError.scopeMismatch }
            let settings = try await services.setup.settings()
            let repository = try await services.repositories.registration(in: project.scope)
            try Task.checkCancellation()
            self.services = services; self.settings = settings; self.repository = repository; errorMessage = nil
            repositoryAccessAvailable = repository == nil ? nil : false
            if repository != nil {
                let access = try await services.repositories.access(in: project.scope)
                withExtendedLifetime(access) {}
                repositoryAccessAvailable = true
            }
        } catch is CancellationError {} catch { errorMessage = Self.message(error) }
    }
    func draft(at level: ExecutionConfigurationLevel) async throws -> ExecutionConfigurationDraft {
        guard let services, !isBusy else { throw CatalogError.busy }
        if let current = settings?.configuration(at: level) { return current.draft }
        return try await services.setup.proposedDefaults(at: level)
    }
    func save(_ draft: ExecutionConfigurationDraft, at level: ExecutionConfigurationLevel, expectedRevision: Int?) async throws {
        guard let services, !isBusy else { throw CatalogError.busy }
        isBusy = true; defer { isBusy = false }
        _ = try await services.setup.save(draft, at: level, expectedRevision: expectedRevision)
        settings = try await services.setup.settings(); errorMessage = nil
    }
    func register(_ selected: URL) async {
        guard let services, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            repository = try await services.repositories.register(selected, in: project.scope, expectedRevision: repository?.revision)
            repositoryAccessAvailable = false
            let access = try await services.repositories.access(in: project.scope)
            withExtendedLifetime(access) {}
            repositoryAccessAvailable = true; errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = Self.message(error) }
    }
    func removeRepository() async {
        guard let services, let repository, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await services.repositories.remove(in: project.scope, expectedRevision: repository.revision)
            self.repository = nil; repositoryAccessAvailable = nil; errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = Self.message(error) }
    }
    static func message(_ error: any Error) -> String {
        if let known = error as? RepositoryRegistrationError {
            switch known {
            case .busy: return "This repository is in use. Finish the active run before changing its registration."
            case .staleRevision: return "The repository registration changed in another window. Reload before trying again."
            case .staleBookmark, .changedDirectory, .unavailable: return "Choose the repository folder again to restore access."
            case .invalidSelection: return "Choose an accessible Git repository root. Linked worktrees and repositories with external Git configuration are not supported yet."
            case .invalidRecord, .storageUnavailable: return "Repository access settings could not be read or saved. Your files have been preserved."
            }
        }
        if error as? ExecutionConfigurationError == .staleRevision || error as? ExecutionSetupError == .alreadyConfigured {
            return "These settings changed in another window. Reload before saving."
        }
        if error as? CatalogError == .busy { return "Another change is in progress. Try again when it finishes." }
        return "These settings could not be opened or saved. Check the values and reload if another window changed them."
    }
}
#endif
