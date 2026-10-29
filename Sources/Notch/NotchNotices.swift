import Foundation

/// Recent script notices and a bounded FIFO of alerts. Time comes from the caller so queue checks need no sleeps.
struct NotchNotices: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: UInt64
        var notice: NotchNotice
        var received: Date
    }

    private struct Pending: Equatable {
        let id: Entry.ID
        let arrived: ContinuousClock.Instant
        var remaining: Double = NotchNotices.duration
    }

    static let historyLimit = 20
    static let alertLimit = 8
    static let duration: Double = 8
    static let patience: Double = 60
    private(set) var history: [Entry] = []
    private var pending: [Pending] = []
    private var nextID: UInt64 = 0

    var next: Entry? { pending.first.flatMap { first in history.first { $0.id == first.id } } }
    var remaining: Double { pending.first?.remaining ?? 0 }
    var waitingCount: Int { max(0, pending.count - 1) }

    /// Matching IDs update in place. Identical repeats, with or without an ID, never re-alert while in history.
    mutating func receive(_ notice: NotchNotice, at now: ContinuousClock.Instant = .now,
                          date: Date = .now, alert: Bool = true) {
        prune(at: now)
        let index = history.firstIndex {
            if let id = notice.id { return $0.notice.id == id }
            return $0.notice == notice
        }
        if let index, history[index].notice == notice { return }
        let id: Entry.ID
        if let index {
            id = history[index].id
            history.remove(at: index)
        } else {
            nextID += 1
            id = nextID
        }
        history.insert(Entry(id: id, notice: notice, received: date), at: 0)
        history = Array(history.prefix(Self.historyLimit))
        pending.removeAll { item in !history.contains { $0.id == item.id } }
        guard alert, !pending.contains(where: { $0.id == id }) else { return }
        if pending.count == Self.alertLimit {
            // Keep the current alert; the oldest waiting alert still remains available in history.
            pending.remove(at: 1)
        }
        pending.append(Pending(id: id, arrived: now))
    }

    /// Only visible time spends the alert's remaining budget. Covered or hovered alerts wait without ticking.
    mutating func consume(_ seconds: Double, for id: Entry.ID) {
        guard pending.first?.id == id else { return }
        pending[0].remaining -= max(0, seconds)
        if pending[0].remaining <= 0 { pending.removeFirst() }
    }

    /// Stale alerts leave the queue, but remain in history until dismissed, cleared or evicted by newer notices.
    mutating func prune(at now: ContinuousClock.Instant = .now) {
        pending.removeAll { now - $0.arrived >= .seconds(Self.patience) }
    }

    mutating func dismissAlert() {
        if !pending.isEmpty { pending.removeFirst() }
    }

    mutating func remove(_ id: Entry.ID) {
        history.removeAll { $0.id == id }
        pending.removeAll { $0.id == id }
    }

    mutating func clearPending() { pending.removeAll() }
    mutating func clear() { history.removeAll(); pending.removeAll() }
}
