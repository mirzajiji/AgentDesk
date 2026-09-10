#if os(macOS)
import AgentDeskCore
import Foundation

enum NativeCommandAction: Hashable {
    case settings, createWorkspace
    case switchWorkspace(WorkspaceID), createProject(WorkspaceID)
    case agents(ProjectScope), setup(ProjectScope), run(ProjectScope), requirements(ProjectScope), memory(ProjectScope), bugs(ProjectScope)
    case traceability(ProjectScope)
}

struct NativeCommand: Identifiable, Equatable {
    let action: NativeCommandAction
    let title: String
    let context: String
    let symbol: String
    var id: NativeCommandAction { action }
}

/// Names are presentation only. Routing always resolves the scope again from the live catalog.
struct NativeCommandCatalog {
    let commands: [NativeCommand]

    init(workspaces: [WorkspaceRecord], projects: [ProjectRecord]) {
        var commands: [NativeCommand] = [
            .init(action: .settings, title: "Settings", context: "AgentDesk", symbol: "gearshape"),
            .init(action: .createWorkspace, title: "Create Workspace", context: "AgentDesk", symbol: "plus")
        ]
        for workspace in workspaces {
            commands.append(.init(action: .switchWorkspace(workspace.id), title: "Switch Workspace",
                context: workspace.name, symbol: "square.stack.3d.up"))
            commands.append(.init(action: .createProject(workspace.id), title: "Create Project",
                context: workspace.name, symbol: "folder.badge.plus"))
            for project in projects where project.workspaceID == workspace.id {
                let context = "\(workspace.name) / \(project.name)"
                commands += [
                    .init(action: .run(project.scope), title: "Run Agent", context: context, symbol: "play"),
                    .init(action: .agents(project.scope), title: "Manage Agents and Skills", context: context, symbol: "person.crop.rectangle.stack"),
                    .init(action: .requirements(project.scope), title: "Manage Requirements", context: context, symbol: "doc.text"),
                    .init(action: .memory(project.scope), title: "Project Memory, Notes and Inbox", context: context, symbol: "brain"),
                    .init(action: .bugs(project.scope), title: "Bug Registry", context: context, symbol: "ladybug"),
                    .init(action: .traceability(project.scope), title: "Traceability and Requirement Impact", context: context, symbol: "point.3.connected.trianglepath.dotted"),
                    .init(action: .setup(project.scope), title: "Project Setup", context: context, symbol: "slider.horizontal.3")
                ]
            }
        }
        self.commands = commands
    }

    func search(_ query: String, limit: Int = 50) -> [NativeCommand] {
        guard limit > 0 else { return [] }
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(commands.filter { command in
            let text = "\(command.title) \(command.context)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return tokens.allSatisfy(text.contains)
        }.prefix(min(limit, 100)))
    }
}
#endif
