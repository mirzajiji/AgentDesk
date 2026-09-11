import Foundation

/// Global admission budget. The trusted TLS proxy separately owns per-client limits.
struct BrokerRequestBudget: Sendable {
    private let capacity: Double
    private let refillPerSecond: Double
    private var available: Double
    private var last: ContinuousClock.Instant
    init(capacity: Int = 120, refillPerSecond: Double = 20, now: ContinuousClock.Instant = .now) {
        precondition(capacity > 0 && refillPerSecond > 0 && refillPerSecond.isFinite)
        self.capacity = Double(capacity); self.refillPerSecond = refillPerSecond
        available = Double(capacity); last = now
    }
    mutating func admit(now: ContinuousClock.Instant = .now) -> Bool {
        guard now >= last else { return false }
        let elapsed = last.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        available = min(capacity, available + seconds * refillPerSecond)
        last = now
        guard available >= 1 else { return false }
        available -= 1
        return true
    }
}
