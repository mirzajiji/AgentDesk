#if os(macOS)
import AgentDeskCore
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
    private let preferences: UserDefaults
    private var selectionGeneration = 0

    init(catalog: WorkspaceCatalog? = nil, preferences: UserDefaults? = nil) {
        self.preferences = preferences ?? Self.applicationPreferences()
        self.catalog = catalog
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

    func reload() async {
        guard let catalog else { return }
        isLoading = true
        defer { isLoading = false }
        do {
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

    func agentStore(for project: ProjectRecord) async throws -> ProjectAgentStore {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.agentStore(in: project.scope)
    }

    func instructionStore(for project: ProjectRecord) async throws -> ProjectInstructionStore {
        guard let catalog else { throw CatalogError.invalidConfiguration }
        return try await catalog.instructionStore(in: project.scope)
    }

    static func message(for error: any Error) -> String {
        if let error = error as? CatalogError { return error.localizedDescription }
        return "AgentDesk couldn’t open or save this workspace. Check that its local files are available and try again."
    }
}
#endif
