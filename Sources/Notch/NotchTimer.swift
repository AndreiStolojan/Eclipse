import Combine
import Foundation

/// A set timer: counting down to a wall-clock `end`, or paused with `remaining` left. `total` is its whole
/// length, added minutes included, for the ring and for which phase alerts apply; it never passes `maximum`. The
/// wall-clock end keeps it right across sleep and relaunch. Pure, so the checks drive it with fixed dates.
struct NotchTimerRun: Equatable, Codable {
    enum Clock: Equatable, Codable {
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    var clock: Clock
    var total: TimeInterval

    /// The longest timer, added minutes included: the dial's twelve hours.
    static let maximum = TimeInterval(NotchTimerDial.range.upperBound * 60)
    /// Minutes left at which a phase alert drops from the wings, for timers longer than that.
    static let phases = [10, 5, 1]
    /// A phase crossed longer ago than this, such as during sleep, is old news.
    static let phaseLateness: TimeInterval = 5
    /// Date arithmetic leaves a few ulps of noise; a remainder this close to a whole second counts as that second, so
    /// a five-minute timer starts on 5:00 and never on 5:01.
    private static let tolerance: TimeInterval = 0.001

    static func start(_ duration: TimeInterval, at now: Date) -> NotchTimerRun {
        NotchTimerRun(clock: .running(end: now.addingTimeInterval(duration)), total: duration)
    }

    var paused: Bool { if case .paused = clock { true } else { false } }

    /// Whether a stored run makes sense at `now`: finite, no longer than `maximum`, and with no more time left than
    /// its whole length. Anything else in the defaults is dropped rather than trusted.
    func isValid(at now: Date) -> Bool {
        guard total.isFinite, total > 0, total <= Self.maximum else { return false }
        return switch clock {
        case .running(let end): end.timeIntervalSinceReferenceDate.isFinite && end.timeIntervalSince(now) <= total
        case .paused(let remaining): remaining.isFinite && (0...total).contains(remaining)
        }
    }

    func remaining(at now: Date) -> TimeInterval {
        switch clock {
        case .running(let end): max(0, end.timeIntervalSince(now))
        case .paused(let remaining): max(0, remaining)
        }
    }

    /// Whole seconds left, rounded up: the full length as it starts, 0:01 in its last second and 0 once it is over.
    /// Clamped to `maximum`, so the conversion to `Int` cannot trap.
    func seconds(at now: Date) -> Int {
        Int(min(Self.maximum, max(0, remaining(at: now) - Self.tolerance)).rounded(.up))
    }

    /// When the seconds shown next change, exactly as a whole number of seconds remains; nil while paused or over.
    /// Every label is computed from the end at the moment it shows, so a wake landing a little early only shows
    /// the same second again and a late one the right next second: none is skipped or repeated.
    func nextTick(after now: Date) -> Date? {
        guard case .running(let end) = clock else { return nil }
        let shown = seconds(at: now)
        return shown > 0 ? end.addingTimeInterval(-Double(shown - 1)) : nil
    }

    /// The next moment that matters while nothing shows the seconds: a phase alert's or the end; nil while paused.
    func nextMoment(after now: Date) -> Date? {
        guard case .running(let end) = clock else { return nil }
        let phases = Self.phases.filter { Double($0 * 60) < total }.map { end.addingTimeInterval(-Double($0 * 60)) }
        return (phases + [end]).filter { $0 > now }.min()
    }

    /// The phase alert due at `now` that had not come at `last`, the previous look: the smallest phase crossed in
    /// between, if it was crossed within `phaseLateness`. Only phases shorter than the timer count, so a five-minute
    /// timer announces only its last minute.
    func phase(after last: Date, at now: Date) -> Int? {
        guard case .running(let end) = clock else { return nil }
        return Self.phases.filter { minutes in
            let moment = end.addingTimeInterval(-Double(minutes * 60))
            return Double(minutes * 60) < total && moment > last && moment <= now
                && now.timeIntervalSince(moment) <= Self.phaseLateness
        }.min()
    }

    /// Pausing keeps the exact time left, so resuming shows the same second.
    mutating func pause(at now: Date) {
        if case .running = clock { clock = .paused(remaining: remaining(at: now)) }
    }

    mutating func resume(at now: Date) {
        if case .paused(let remaining) = clock { clock = .running(end: now.addingTimeInterval(remaining)) }
    }

    /// +1 min: more time left and a longer whole, so the ring steps back; nothing past `maximum`.
    mutating func add(_ duration: TimeInterval, at now: Date) {
        let duration = min(duration, Self.maximum - total)
        guard duration > 0 else { return }
        total += duration
        switch clock {
        case .running(let end): clock = .running(end: end.addingTimeInterval(duration))
        case .paused(let remaining): clock = .paused(remaining: remaining + duration)
        }
    }

    /// "4:59", or "1:04:59" from an hour.
    static func label(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let tail = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(tail)" : "\(minutes):\(tail)"
    }
}

/// The length the idle Timer page sets, in minutes: one-minute steps up to an hour, five-minute steps up to twelve.
enum NotchTimerDial {
    static let range = 1...720

    static func clamp(_ minutes: Int) -> Int { min(range.upperBound, max(range.lowerBound, minutes)) }

    /// `minutes` moved by `steps` detents, up for positive steps, clamped to `range`.
    static func step(_ minutes: Int, by steps: Int) -> Int {
        var value = minutes
        for _ in 0..<abs(steps) {
            if steps > 0 {
                value = value < 60 ? value + 1 : (value / 5 + 1) * 5
            } else {
                value = value <= 60 ? value - 1 : (value - 1) / 5 * 5
            }
        }
        return clamp(value)
    }
}

/// A timer that has just finished. `late` marks a finish missed: its end passed while the Mac slept or the app was
/// quit, or it was noticed well after its end. It shows briefly and silently.
struct NotchTimerDone: Equatable {
    var end: Date
    var length: TimeInterval
    var late: Bool

    /// Noticed later than this while the app ran, a finish counts as missed too.
    static let lateness: TimeInterval = 30
}

/// The one timer: the running or paused timer, persisted in the user's defaults so it survives a relaunch,
/// the Done state once it finishes, and the length the idle page sets. Event driven: while a timer runs and something
/// shows it, it wakes once per shown second, aligned to the wall-clock end; while nothing does, only at its phases
/// and its end.
@MainActor
final class NotchTimer: ObservableObject {
    @Published private(set) var run: NotchTimerRun? {
        didSet { if run != oldValue { save(); updateActivity(); if !finishing { onChange?() } } }
    }
    /// Until Stop, +1 min or its time in the notch is up.
    @Published private(set) var done: NotchTimerDone? {
        didSet { if done != oldValue, !finishing { onChange?() } }
    }
    /// Whole seconds left on the running or paused timer: the one value the views tick on.
    @Published private(set) var seconds = 0
    /// Minutes the idle page sets; the length last started is kept.
    @Published var dial: Int {
        didSet {
            // Through `@Published` this assignment runs the observer again, so it only happens out of range.
            if !NotchTimerDial.range.contains(dial) { dial = NotchTimerDial.clamp(dial) }
            if dial != oldValue { save() }
        }
    }
    /// Set by the experience while the wings, a phase alert or the open Timer page show the seconds. Otherwise the
    /// labels go stale until it is set again, which looks at once.
    var displayed = false {
        didSet { if displayed != oldValue { update() } }
    }
    /// When the timer wakes next, for the checks.
    private(set) var wakeAt: Date?
    /// The run or Done changed.
    var onChange: (() -> Void)?
    /// A phase alert is due, in minutes left.
    var onPhase: ((Int) -> Void)?
    var onDone: ((NotchTimerDone) -> Void)?

    /// System sounds in /System/Library/Sounds that can mark the finish.
    static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                         "Sosumi", "Submarine", "Tink"]
    /// Seconds a missed finish shows on return.
    static let missedDuration: Double = 5
    static let key = "notchTimer"

    private let defaults: UserDefaults
    private let now: () -> Date
    private var wake: Task<Void, Never>?
    /// The previous look at the clock, so a phase is announced once, as it is crossed.
    private var looked: Date
    private var running = false
    /// Set while `finish` swaps the run for Done, so observers hear of both at once.
    private var finishing = false
    /// Looks again when the wall clock is set, since a wake is a relative sleep towards a wall-clock moment.
    private var clockObserver: NSObjectProtocol?
    /// Keeps App Nap from delaying the wakes while a timer counts down, so the end rings on time with the notch
    /// hidden or locked, when no visible window keeps the app awake. It causes no wakes of its own.
    private var activity: NSObjectProtocol?

    private struct Stored: Codable {
        var run: NotchTimerRun?
        var dial: Int
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let date = now()
        run = stored?.run.flatMap { $0.isValid(at: date) ? $0 : nil }
        // The observer does not run in `init`, so the clamp is applied here.
        dial = NotchTimerDial.clamp(stored?.dial ?? 5)
        looked = date
    }

    /// Share of the timer that has passed, by the seconds shown, so the ring and the digits tick together.
    var progress: Double {
        guard let run, run.total > 0 else { return done == nil ? 0 : 1 }
        return min(1, max(0, 1 - Double(seconds) / run.total))
    }

    /// The moment the running timer ends, for "ends at" on the page.
    var end: Date? { if case .running(let end) = run?.clock { end } else { nil } }

    /// With the app running or awake: a timer that ended meanwhile, however recently, was missed and finishes late.
    /// From then on, setting the clock looks again at once, so a clock moved past the end finishes it.
    func start() {
        guard !running else { return }
        running = true
        looked = now()
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        if case .running(let end)? = run?.clock, end <= looked { finish(end: end, late: true) }
        update()
        updateActivity()
    }

    /// Sleep or quit: the timer stays stored and counts on by the wall clock; Done is dropped with the rest of the
    /// notch.
    func stop() {
        running = false
        wake?.cancel()
        wake = nil
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        clockObserver = nil
        done = nil
        updateActivity()
    }

    func begin(minutes: Int) {
        let now = now()
        done = nil
        dial = minutes
        looked = now
        run = .start(Double(dial * 60), at: now)
        update()
    }

    func pause() {
        run?.pause(at: now())
        update()
    }

    func resume() {
        looked = now()
        run?.resume(at: looked)
        update()
    }

    func cancel() {
        run = nil
        update()
    }

    /// +1 min on a running or paused timer, or a fresh minute from Done.
    func addMinute() {
        if run == nil {
            begin(minutes: 1)
        } else {
            run?.add(60, at: now())
            update()
        }
    }

    func dismissDone() { done = nil }

    /// Recomputes the seconds shown, announces a phase that came, finishes a timer that is over and sleeps until the
    /// next second, or the next phase or the end while nothing shows it, a hair past it so the wake never lands early
    /// and finds nothing changed. Internal so the checks can look again after moving their clock.
    func update() {
        wake?.cancel()
        wake = nil
        wakeAt = nil
        let now = now()
        let last = looked
        looked = now
        guard let run else { seconds = 0; return }
        seconds = run.seconds(at: now)
        guard running else { return }
        if seconds == 0 {
            if case .running(let end) = run.clock { finish(end: end, late: now.timeIntervalSince(end) > NotchTimerDone.lateness) }
            return
        }
        if let phase = run.phase(after: last, at: now) { onPhase?(phase) }
        guard let next = displayed ? run.nextTick(after: now) : run.nextMoment(after: now) else { return }
        wakeAt = next
        let delay = max(0, next.timeIntervalSince(now)) + 0.01
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// The run becomes Done in one step, so the notch goes from the timer straight to the Done row. Observers hear of
    /// it once both are set: an update they cause meanwhile would otherwise find the expired run and finish it again.
    private func finish(end: Date, late: Bool) {
        guard let run else { return }
        let done = NotchTimerDone(end: end, length: run.total, late: late)
        finishing = true
        self.done = done
        self.run = nil
        finishing = false
        onChange?()
        onDone?(done)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(Stored(run: run, dial: dial)), forKey: Self.key)
    }

    private func updateActivity() {
        let counting = running && run?.paused == false
        if counting, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Timer")
        } else if !counting, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
