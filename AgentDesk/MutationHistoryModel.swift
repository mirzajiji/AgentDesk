#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import Combine
import Foundation

@MainActor final class MutationHistoryModel: ObservableObject {
    @Published private(set) var records: [MutationAttemptRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasMore = false
    private var cursor: UUID?
    private var generation = UUID()
    private var service: NativeMutationHistory?
    private let open: () async throws -> NativeMutationHistory

    init(open: @escaping () async throws -> NativeMutationHistory) { self.open = open }

    func load(more: Bool = false) async {
        guard !loading, !more || hasMore else { return }
        let request = generation
        loading = true
        if !more { records = []; cursor = nil; hasMore = false }
        errorMessage = nil
        defer { if generation == request { loading = false } }
        do {
            let current: NativeMutationHistory
            if let service { current = service }
            else {
                current = try await open()
                guard generation == request, !Task.isCancelled else { await current.close(); return }
                service = current
            }
            let page = try await current.page(after: more ? cursor : nil)
            guard generation == request, !Task.isCancelled else { return }
            records = more ? records + page.records : page.records
            cursor = page.nextActionID; hasMore = cursor != nil
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            records = []; cursor = nil; hasMore = false
            errorMessage = "Mutation history could not be read. Check the selected environment and its read permissions."
        }
    }
    func close() async {
        generation = UUID(); loading = false
        records = []; cursor = nil; hasMore = false; errorMessage = nil
        let previous = service; service = nil
        await previous?.close()
    }
}
#endif
