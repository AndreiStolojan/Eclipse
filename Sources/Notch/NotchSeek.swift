import Foundation

/// A seek sent to the player from the progress bar. Players report the new position a moment later, so until one
/// reports a position near it the bar keeps showing the chosen one, moving on with playback, instead of jumping back
/// to where the track was. A player that never confirms is believed after `patience`.
struct NotchSeek: Equatable {
    /// How close a reported position must be to count as the player having caught up.
    static let tolerance: TimeInterval = 1.5
    /// How long the chosen position is shown without confirmation.
    static let patience: TimeInterval = 2.5

    let target: TimeInterval
    let at: Date
    /// Whether the track was playing, so the shown position runs on from the target.
    let playing: Bool
    /// The track sought in; another track forgets the seek.
    let track: String?

    /// When the chosen position stops being shown if the player has not confirmed it.
    var deadline: Date { at.addingTimeInterval(Self.patience) }

    /// The position to show at `now`, or nil once the player reports one near it or patience runs out.
    func position(reported: TimeInterval, at now: Date) -> TimeInterval? {
        let waited = now.timeIntervalSince(at)
        guard waited < Self.patience else { return nil }
        let expected = target + (playing ? max(0, waited) : 0)
        return abs(reported - expected) <= Self.tolerance ? nil : expected
    }
}

/// The seek the progress bar waits on, if any. It ends when the player confirms it, its deadline passes or another
/// track plays. A newer seek replaces it, so the older one's deadline no longer counts. The view settles it whenever
/// the reported position or track changes and expires it from a task keyed to `pending`, because a paused bar never
/// redraws on its own and would otherwise keep an unconfirmed position indefinitely.
struct NotchSeekHold: Equatable {
    private(set) var pending: NotchSeek?

    mutating func send(_ target: TimeInterval, at now: Date, playing: Bool, track: String?) {
        pending = NotchSeek(target: target, at: now, playing: playing, track: track)
    }

    /// The position to show, or nil to show the reported one.
    func position(reported: TimeInterval, track: String?, at now: Date) -> TimeInterval? {
        guard let pending, pending.track == track else { return nil }
        return pending.position(reported: reported, at: now)
    }

    /// Forgets the pending seek once the player confirms it, its patience runs out or the track changes.
    mutating func settle(reported: TimeInterval, track: String?, at now: Date) {
        if position(reported: reported, track: track, at: now) == nil { pending = nil }
    }

    /// Forgets `seek` at its deadline, unless a newer seek has replaced it.
    mutating func expire(_ seek: NotchSeek) {
        if pending == seek { pending = nil }
    }
}
