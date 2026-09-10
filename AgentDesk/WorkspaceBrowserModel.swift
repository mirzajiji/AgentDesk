#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import Combine
import Foundation
import SwiftUI

@MainActor
final class WorkspaceBrowserModel: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var selectedWorkspace: WorkspaceID?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var catalog: WorkspaceCatalog?
    private var applicationRoot: URL?
    private let preferences: UserDefaults
    private var selectionGeneration = 0

    init(catalog: WorkspaceCatalog? = nil, preferences: UserDefaults? = nil, applicationRoot: URL? = nil) {
        self.preferences = preferences ?? Self.applicationPreferences()
        self.catalog = catalog; self.applicationRoot = applicationRoot
        if catalog == nil {
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
                var container = support.appendingPathComponent("AgentDesk/Workspaces", isDirectory: true)
                #if DEBUG
                // Test launches receive an identity, never an arbitrary path or a reset-data switch.
                if let raw = ProcessInfo.processInfo.environment["AGENTDESK_TEST_CONTAINER_ID"],
                   let id = UUID(uuidString: raw) {
                    container = support.appendingPathComponent("AgentDesk/UITesting/\(id.uuidString)/Workspaces", isDirectory: true)
                }
                #endif
                self.applicationRoot = container.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                self.catalog = try WorkspaceCatalog(container: container)
            } catch { errorMessage = Self.message(for: error) }
        }
    }

    private static func applicationPreferences() -> UserDefaults {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["AGENTDESK_TEST_CONTAINER_ID"],
           let id = UUID(uuidString: raw), let defaults = UserDefaults(suiteName: "AgentDesk.UITesting.\(id.uuidString)") {
            return defaults
        }
        #endif
        return .standard
    }

    var currentWorkspace: WorkspaceRecord? { workspaces.first { $0.id == selectedWorkspace } }

    func commands() async throws -> NativeCommandCatalog {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        let workspaces = try await catalog.workspaces()
        var projects: [ProjectRecord] = []
        for workspace in workspaces {
            try Task.checkCancellation()
            projects += try await catalog.projects(in: workspace.id)
        }
        return NativeCommandCatalog(workspaces: workspaces, projects: projects)
    }

    func resolveWorkspace(_ id: WorkspaceID) async throws -> WorkspaceRecord {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        guard let workspace = try await catalog.workspaces().first(where: { $0.id == id }) else {
            throw CatalogError.invalidConfiguration
        }
        return workspace
    }

    func selectCommandWorkspace(_ id: WorkspaceID) async throws {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        let current = try await catalog.workspaces()
        try Task.checkCancellation()
        guard current.contains(where: { $0.id == id }) else { throw CatalogError.scopeMismatch }
        workspaces = current
        await select(id)
        try Task.checkCancellation()
        guard selectedWorkspace == id, errorMessage == nil else { throw CatalogError.scopeMismatch }
    }

    func resolveProject(_ scope: ProjectScope) async throws -> ProjectRecord {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.project(scope)
    }

    func reload() async {
        guard let catalog else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            #if DEBUG
            if let applicationRoot { try await NativeRunUITestSupport.seed(catalog: catalog, applicationRoot: applicationRoot) }
            #endif
            let records = try await catalog.workspaces()
            try Task.checkCancellation()
            workspaces = records
            let saved = preferences.string(forKey: "selectedWorkspace").flatMap(WorkspaceID.init(rawValue:))
            let preferred = selectedWorkspace ?? saved
            await select(records.first(where: { $0.id == preferred })?.id ?? records.first?.id)
        } catch is CancellationError {} catch { errorMessage = Self.message(for: error) }
    }

    func select(_ id: WorkspaceID?) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedWorkspace = id
        projects = []
        errorMessage = nil
        preferences.set(id?.rawValue, forKey: "selectedWorkspace")
        guard let catalog, let id else { return }
        do {
            let records = try await catalog.projects(in: id)
            try Task.checkCancellation()
            guard selectionGeneration == generation else { return }
            projects = records
        } catch is CancellationError {} catch {
            guard selectionGeneration == generation else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func createWorkspace(name: String) async throws {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        let record = try await catalog.createWorkspace(name: name)
        workspaces = try await catalog.workspaces()
        await select(record.id)
    }

    func createProject(workspaceID: WorkspaceID, name: String) async throws {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        _ = try await catalog.createProject(in: workspaceID, name: name)
        if selectedWorkspace == workspaceID { await select(workspaceID) }
    }

    func renameWorkspace(_ id: WorkspaceID, name: String) async throws {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        _ = try await catalog.renameWorkspace(id, name: name)
        workspaces = try await catalog.workspaces()
    }

    func renameProject(_ scope: ProjectScope, name: String) async throws {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        _ = try await catalog.renameProject(scope, name: name)
        if selectedWorkspace == scope.workspaceID { await select(scope.workspaceID) }
    }

    func requirementServices(for project: ProjectRecord) async throws -> NativeRequirementServices {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        let store = try await catalog.requirementStore(in: project.scope)
        do {
            let settings = try await ProjectExecutionSetupService(catalog: catalog, scope: project.scope).settings()
            return NativeRequirementServices(store: store, environments: settings.project?.draft.environments ?? [], environmentIssue: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return NativeRequirementServices(store: store, environments: [],
                environmentIssue: "Execution environments could not be read. Check project Setup; stored requirement selections are preserved.")
        }
    }

    func memoryServices(for project: ProjectRecord) async throws -> NativeMemoryServices {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        let store = try await catalog.memoryStore(in: project.scope)
        do {
            let settings = try await ProjectExecutionSetupService(catalog: catalog, scope: project.scope).settings()
            return NativeMemoryServices(store: store, environments: settings.project?.draft.environments ?? [], environmentIssue: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return NativeMemoryServices(store: store, environments: [],
                environmentIssue: "Execution environments could not be read. Check project Setup; stored memory selections are preserved.")
        }
    }

    func agentStore(for project: ProjectRecord) async throws -> ProjectAgentStore {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.agentStore(in: project.scope)
    }

    func instructionStore(for project: ProjectRecord) async throws -> ProjectInstructionStore {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.instructionStore(in: project.scope)
    }

    func skillStore(for project: ProjectRecord) async throws -> ProjectSkillStore {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.skillStore(in: project.scope)
    }

    func executionServices(for project: ProjectRecord) async throws -> ProjectNativeServices {
        guard let catalog, let applicationRoot else { throw CatalogError.invalidConfiguration }
        _ = try await catalog.project(project.scope)
        let directories = try NativeProjectStorage.prepare(root: applicationRoot, workspaceID: project.workspaceID)
        let access = directories.access, data = directories.data
        return ProjectNativeServices(setup: ProjectExecutionSetupService(catalog: catalog, scope: project.scope),
            repositories: try ProjectRepositoryRegistry(catalog: catalog, container: access), catalog: catalog,
            database: data.appendingPathComponent("operations.sqlite"))
    }

    static func message(for error: any Error) -> String {
        if let error = error as? CatalogError { return error.localizedDescription }
        return "AgentDesk couldn’t open or save this workspace. Check that its local files are available and try again."
    }
}
#endif
