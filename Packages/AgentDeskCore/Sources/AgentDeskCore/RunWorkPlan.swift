import Foundation

public enum WorkItemEntity: Sendable {}
public typealias WorkItemID = EntityID<WorkItemEntity>

public enum WorkPlanError: Error, Equatable, Sendable {
    case invalidPlan, missingItem, invalidTransition, incompleteWork, invalidMeasurement, limitExceeded
}

public enum WorkItemState: String, Codable, CaseIterable, Sendable {
    case pending, running, waitingForApproval, completed, failed, skipped, cancelled
    public var isFinished: Bool { [.completed, .failed, .skipped, .cancelled].contains(self) }
    public var countsAsCompleted: Bool { self == .completed || self == .skipped }
    func canTransition(to next: WorkItemState) -> Bool {
        switch self {
        case .pending: [.running, .failed, .skipped, .cancelled].contains(next)
        case .running: [.waitingForApproval, .completed, .failed, .cancelled].contains(next)
        case .waitingForApproval: [.running, .failed, .cancelled].contains(next)
        case .completed, .failed, .skipped, .cancelled: false
        }
    }
}

public struct MeasuredProgress: Codable, Equatable, Sendable {
    public let completedUnits: Int64
    public let totalUnits: Int64
    public init(completedUnits: Int64, totalUnits: Int64) throws {
        guard totalUnits > 0, totalUnits <= 1_000_000_000_000, completedUnits >= 0, completedUnits <= totalUnits else {
            throw WorkPlanError.invalidMeasurement
        }
        self.completedUnits = completedUnits; self.totalUnits = totalUnits
    }
    public var fractionCompleted: Double { Double(completedUnits) / Double(totalUnits) }
    private enum CodingKeys: CodingKey { case completedUnits, totalUnits }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(completedUnits: container.decode(Int64.self, forKey: .completedUnits),
                      totalUnits: container.decode(Int64.self, forKey: .totalUnits))
    }
}

public struct WorkItemDefinition: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case stage, step }
    public let id: WorkItemID
    public let kind: Kind
    public let parentStageID: WorkItemID?
    public let title: String
    public init(id: WorkItemID = WorkItemID(), kind: Kind, parentStageID: WorkItemID? = nil, title: String) {
        self.id = id; self.kind = kind; self.parentStageID = parentStageID; self.title = title
    }
}

public struct RunWorkItem: Codable, Equatable, Sendable, Identifiable {
    public let definition: WorkItemDefinition
    public fileprivate(set) var state: WorkItemState = .pending
    public fileprivate(set) var progress: MeasuredProgress?
    public fileprivate(set) var startedAt: Date?
    public fileprivate(set) var finishedAt: Date?
    public var id: WorkItemID { definition.id }
}

public enum WorkPlanChange: Sendable {
    case add(WorkItemDefinition)
    case transition(WorkItemID, to: WorkItemState)
    case measure(WorkItemID, completed: Int64, total: Int64)
}

/// Operational progress, not an executable workflow definition or permission grant.
public struct RunWorkPlan: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case fixedStages, openEnded }
    public let schemaVersion: Int
    public let scope: ProjectScope
    public let runID: RunID
    public let mode: Mode
    public private(set) var items: [RunWorkItem]

    public init(scope: ProjectScope, runID: RunID, mode: Mode, definitions: [WorkItemDefinition]) throws {
        schemaVersion = 1; self.scope = scope; self.runID = runID; self.mode = mode
        items = definitions.map { RunWorkItem(definition: $0) }
        try validate()
    }

    private enum CodingKeys: CodingKey { case schemaVersion, scope, runID, mode, items }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        scope = try container.decode(ProjectScope.self, forKey: .scope)
        runID = try container.decode(RunID.self, forKey: .runID)
        mode = try container.decode(Mode.self, forKey: .mode)
        items = try container.decode([RunWorkItem].self, forKey: .items)
        try validate()
    }

    /// Open-ended runs deliberately have no numerical overall percentage.
    public var overallProgress: MeasuredProgress? {
        guard mode == .fixedStages else { return nil }
        let stages = items.filter { $0.definition.kind == .stage }
        return try? MeasuredProgress(completedUnits: Int64(stages.filter { $0.state.countsAsCompleted }.count), totalUnits: Int64(stages.count))
    }

    public func applying(_ change: WorkPlanChange, at date: Date) throws -> RunWorkPlan {
        try Task.checkCancellation()
        try validate()
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw WorkPlanError.invalidPlan }
        var next = self
        switch change {
        case .add(let definition):
            if definition.kind == .stage && mode == .fixedStages { throw WorkPlanError.invalidTransition }
            if let parent = definition.parentStageID,
               items.first(where: { $0.id == parent })?.state.isFinished == true { throw WorkPlanError.invalidTransition }
            next.items.append(RunWorkItem(definition: definition))
        case .transition(let id, let state):
            guard let index = next.items.firstIndex(where: { $0.id == id }) else { throw WorkPlanError.missingItem }
            let current = next.items[index]
            guard current.state.canTransition(to: state), date >= (current.startedAt ?? date) else { throw WorkPlanError.invalidTransition }
            if state == .running, let parent = current.definition.parentStageID {
                guard next.items.first(where: { $0.id == parent })?.state == .running else { throw WorkPlanError.invalidTransition }
            }
            let children = next.items.indices.filter { next.items[$0].definition.parentStageID == id }
            if state == .completed {
                guard children.allSatisfy({ next.items[$0].state.countsAsCompleted }) else { throw WorkPlanError.incompleteWork }
                if let progress = current.progress, progress.completedUnits != progress.totalUnits { throw WorkPlanError.incompleteWork }
            }
            next.items[index].state = state
            if state == .running && current.startedAt == nil { next.items[index].startedAt = date }
            if state.isFinished { next.items[index].finishedAt = date }
            if state == .failed || state == .cancelled || state == .skipped {
                for child in children where !next.items[child].state.isFinished {
                    next.items[child].state = state == .skipped ? .skipped : .cancelled
                    next.items[child].finishedAt = date
                }
            }
        case .measure(let id, let completed, let total):
            guard let index = next.items.firstIndex(where: { $0.id == id }) else { throw WorkPlanError.missingItem }
            guard next.items[index].state == .running, date >= (next.items[index].startedAt ?? date) else {
                throw WorkPlanError.invalidTransition
            }
            let progress = try MeasuredProgress(completedUnits: completed, totalUnits: total)
            if let old = next.items[index].progress {
                guard total == old.totalUnits, completed >= old.completedUnits else { throw WorkPlanError.invalidMeasurement }
            }
            next.items[index].progress = progress
        }
        try next.validate()
        return next
    }

    public func ending(with state: RunState, at date: Date) throws -> RunWorkPlan {
        try validate()
        guard state.isTerminal, date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw WorkPlanError.invalidTransition }
        var next = self
        if state == .completed {
            guard items.allSatisfy({ $0.state.countsAsCompleted }) else { throw WorkPlanError.incompleteWork }
        } else {
            for index in next.items.indices where !next.items[index].state.isFinished {
                next.items[index].state = .cancelled; next.items[index].finishedAt = date
            }
        }
        try next.validate()
        return next
    }

    public func validate() throws {
        guard schemaVersion == 1, Set(items.map(\.id)).count == items.count else { throw WorkPlanError.invalidPlan }
        let stages = items.filter { $0.definition.kind == .stage }
        guard stages.count <= 32, items.count - stages.count <= 128 else { throw WorkPlanError.limitExceeded }
        guard mode != .fixedStages || !stages.isEmpty else { throw WorkPlanError.invalidPlan }
        for item in items {
            let definition = item.definition
            guard !definition.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  definition.title.utf8.count <= 160,
                  !definition.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WorkPlanError.invalidPlan }
            if definition.kind == .stage {
                guard definition.parentStageID == nil else { throw WorkPlanError.invalidPlan }
            } else {
                guard let parentID = definition.parentStageID, let parent = stages.first(where: { $0.id == parentID }) else {
                    throw WorkPlanError.invalidPlan
                }
                if parent.state == .pending, item.state != .pending { throw WorkPlanError.invalidPlan }
                if parent.state.isFinished, !item.state.isFinished { throw WorkPlanError.invalidPlan }
                if let parentStart = parent.startedAt, let start = item.startedAt, start < parentStart { throw WorkPlanError.invalidPlan }
            }
            for date in [item.startedAt, item.finishedAt].compactMap({ $0 }) {
                guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw WorkPlanError.invalidPlan }
            }
            if let start = item.startedAt, let end = item.finishedAt, start > end { throw WorkPlanError.invalidPlan }
            guard item.state.isFinished == (item.finishedAt != nil) else { throw WorkPlanError.invalidPlan }
            if item.state == .pending { guard item.startedAt == nil, item.progress == nil else { throw WorkPlanError.invalidPlan } }
            if [.running, .waitingForApproval, .completed].contains(item.state) {
                guard item.startedAt != nil else { throw WorkPlanError.invalidPlan }
            }
            if let progress = item.progress {
                _ = try MeasuredProgress(completedUnits: progress.completedUnits, totalUnits: progress.totalUnits)
                if item.state == .completed, progress.completedUnits != progress.totalUnits { throw WorkPlanError.incompleteWork }
            }
            if definition.kind == .stage, item.state.countsAsCompleted {
                guard items.filter({ $0.definition.parentStageID == item.id }).allSatisfy({ $0.state.countsAsCompleted }) else {
                    throw WorkPlanError.incompleteWork
                }
            }
        }
    }
}
