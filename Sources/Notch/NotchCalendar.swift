import AppKit
import Combine
import EventKit

/// A calendar the user can show or hide on the Calendar settings page.
struct NotchCalendarSource: Identifiable, Equatable {
    var id: String
    var title: String
    /// The account it belongs to, such as iCloud or a Google address.
    var account: String
    var color: NSColor
}

/// Reads today's and tomorrow's events from EventKit and keeps the countdown current. Event-driven: it reloads
/// when the calendar database, the time zone or the clock changes and otherwise sleeps until the agenda's next
/// change, never on an interval. The Calendar page's month and picked day are read off the main thread, once per
/// change of either or of the store.
/// Access is asked for only from an explicit button, so launching the app or `--probe` never shows the prompt.
@MainActor
final class NotchCalendar: ObservableObject {
    enum Access: Equatable {
        case undetermined, granted, denied
    }

    @Published private(set) var access: Access
    @Published private(set) var agenda: NotchAgenda {
        didSet { if agenda != oldValue { onAgendaChange?() } }
    }
    @Published private(set) var countdown: NotchCountdown? {
        didSet { if countdown != oldValue { onCountdownChange?() } }
    }
    /// The Calendar page's month and day, set by its clicks and back on today once the notch has stayed closed a while.
    @Published var selection = NotchCalendarSelection() {
        didSet { if selection != oldValue { browse() } }
    }
    /// Events of the shown month's weeks, and of the picked day when it lies outside them.
    @Published private(set) var browsed = NotchAgenda()
    /// Days of the shown weeks holding an event, for the dots under them.
    @Published private(set) var busyDays: Set<Date> = []
    /// Every event calendar, for the settings list, sorted by account and title.
    @Published private(set) var calendars: [NotchCalendarSource] = []
    var onCountdownChange: (() -> Void)?
    /// A Quick Peek is due; each one is reported once.
    var onPeek: ((NotchEventPeek) -> Void)?
    /// The agenda was read again, for time to leave.
    var onAgendaChange: (() -> Void)?
    /// How long before a timed event the countdown starts.
    var lead: TimeInterval = 15 * 60 {
        didSet { if lead != oldValue { update() } }
    }
    /// Calendars turned off on the settings page, by EventKit identifier.
    var hiddenCalendars: Set<String> = [] {
        didSet { if hiddenCalendars != oldValue { reload() } }
    }
    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var wake: Task<Void, Never>?
    /// The day the agenda was read on; the first wake on a later day reads it again.
    private var loadedDay: Date?
    /// Quick Peeks already reported, by `NotchEventPeek.id`, with the end of their event. Kept until the event ends,
    /// so an event that leaves the agenda for a moment, such as its calendar being hidden and shown, does not peek again.
    private var shownPeeks: [String: Date] = [:]
    private var running = false
    /// The calendars not hidden in the settings, as of the last reload.
    private var shownCalendars: [EKCalendar] = []
    /// What `browsed` was read for, so picking a day inside the shown weeks reads nothing.
    private var browsedIntervals: [DateInterval] = []
    private var browsing: Task<Void, Never>?
    private var closedAt: Date?
    /// Fixtures pin the clock, so a render shows the same day whenever it runs. Nil in the live app.
    let previewNow: Date?

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    init() {
        access = Self.currentAccess
        agenda = NotchAgenda()
        previewNow = nil
    }

    /// Fixed events and calendars for fixtures, shown as of `now`; the store is never read.
    init(preview events: [NotchEvent], calendars: [NotchCalendarSource] = [], access: Access = .granted, now: Date,
         lead: TimeInterval = 15 * 60) {
        self.access = access
        self.calendars = calendars
        previewNow = now
        agenda = NotchAgenda(events: events)
        self.lead = lead
        countdown = agenda.countdown(at: now, lead: lead)
        browse(force: true)
    }

    func start() {
        guard !running else { return }
        running = true
        // A new time zone or a clock change moves midnight and what today holds, as an edit in Calendar does.
        let sources: [(Notification.Name, AnyObject?)] = [(.EKEventStoreChanged, store), (.NSSystemTimeZoneDidChange, nil),
                                                         (.NSSystemClockDidChange, nil)]
        observers = sources.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The picked day and month are midnights of the old zone, which name other days in the new one.
                    if name == .NSSystemTimeZoneDidChange { self?.selection = NotchCalendarSelection() }
                    self?.reload()
                }
            }
        }
        reload()
    }

    func stop() {
        guard running else { return }
        running = false
        wake?.cancel()
        wake = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        countdown = nil
        browsing?.cancel()
        selection = NotchCalendarSelection()
        shownCalendars = []
        browsed = NotchAgenda()
        busyDays = []
    }

    /// The notch closed: the page keeps its day for `NotchCalendarSelection.keep`.
    func notchClosed() {
        closedAt = .now
    }

    /// The notch opened: after a longer close the page is back on today.
    func notchOpened() {
        if let closedAt { selection.reopen(closedFor: Date().timeIntervalSince(closedAt)) }
        closedAt = nil
    }

    /// Shows the macOS prompt the first time; once it has been answered, only System Settings can change it.
    func requestAccess() {
        guard access == .undetermined else { NSWorkspace.shared.open(Self.privacySettingsURL); return }
        Task {
            // A store made before the grant can keep answering with no calendars until it is reset.
            if (try? await store.requestFullAccessToEvents()) == true { store.reset() }
            access = Self.currentAccess
            reload()
        }
    }

    /// Picks up access granted or withdrawn in System Settings, which macOS announces to nobody. Called when the
    /// notch opens and when the Calendar settings page appears.
    func refreshAccess() {
        if running, access != Self.currentAccess { reload() }
    }

    /// Reads both days again, after a database change, a calendar being shown or hidden, or a new day.
    func reload() {
        guard running else { return }
        access = Self.currentAccess
        let today = Calendar.current.startOfDay(for: .now)
        loadedDay = today
        guard access == .granted else {
            calendars = []
            shownCalendars = []
            agenda = NotchAgenda()
            browse(force: true)
            update()
            return
        }
        let all = store.calendars(for: .event)
        calendars = all.map { NotchCalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: $0.color) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let shown = all.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
        shownCalendars = shown
        var events: [NotchEvent] = []
        // An empty list would mean every calendar to EventKit, so all hidden reads nothing instead.
        if !shown.isEmpty, let end = Calendar.current.date(byAdding: .day, value: 2, to: today) {
            let predicate = store.predicateForEvents(withStart: today, end: end, calendars: shown)
            events = store.events(matching: predicate).filter(Self.attending).map(Self.event)
        }
        agenda = NotchAgenda(events: events)
        shownPeeks = shownPeeks.filter { $0.value > .now }
        browse(force: true)
        update()
    }

    /// Reads the page's month on a background thread when the grid or the picked day left what was read, or with
    /// `force` after the store, the shown calendars or the day changed. One read runs at a time and each request
    /// cancels the one before it, so paging quickly through months reads the month in progress and then only the last.
    private func browse(force: Bool = false) {
        let today = previewNow ?? .now
        let intervals = selection.intervals(today: today)
        guard force || intervals != browsedIntervals else { return }
        browsedIntervals = intervals
        let previous = browsing
        previous?.cancel()
        let days = selection.shownMonth(today: today).weeks.flatMap { $0 }
        if previewNow != nil {
            browsed = agenda
            busyDays = agenda.busyDays(days)
            return
        }
        // An empty list would mean every calendar to EventKit, so all hidden reads nothing instead.
        guard running, access == .granted, !shownCalendars.isEmpty else {
            browsed = NotchAgenda()
            busyDays = []
            return
        }
        let store = store, calendars = shownCalendars
        browsing = Task.detached(priority: .userInitiated) { [weak self] in
            // EventKit cannot stop a fetch halfway, so wait for the one before; a request replaced meanwhile reads nothing.
            await previous?.value
            var events: [NotchEvent] = []
            // A picked day outside the grid is a second span.
            for interval in intervals {
                guard !Task.isCancelled else { return }
                events += store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars))
                    .filter(Self.attending).map(Self.event)
            }
            guard !Task.isCancelled else { return }
            // An event reaching into both spans is kept once.
            var seen = Set<String>()
            let agenda = NotchAgenda(events: events.filter { seen.insert($0.id).inserted })
            guard !Task.isCancelled else { return }
            let busy = agenda.busyDays(days)
            await MainActor.run {
                // Cancellation happens on the main actor too, so this check cannot race a newer request.
                guard !Task.isCancelled, let self else { return }
                self.browsed = agenda
                self.busyDays = busy
            }
        }
    }

    /// Recomputes the countdown, reports a Quick Peek that fell due and sleeps until the agenda's next change. A little past it, so the wake never
    /// lands a hair early and finds nothing changed.
    private func update() {
        guard running else { return }
        wake?.cancel()
        let now = Date()
        if let loadedDay, !Calendar.current.isDate(loadedDay, inSameDayAs: now) { reload(); return }
        countdown = agenda.countdown(at: now, lead: lead)
        if let peek = agenda.peek(at: now, lead: lead, shown: Set(shownPeeks.keys)) {
            shownPeeks[peek.id] = peek.event.end
            onPeek?(peek)
        }
        let delay = agenda.nextChange(after: now, lead: lead).timeIntervalSince(now) + 0.05
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    /// Cancelled events and invitations the user declined stay out.
    nonisolated private static func attending(_ event: EKEvent) -> Bool {
        event.status != .canceled && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }

    nonisolated private static func event(_ event: EKEvent) -> NotchEvent {
        let meeting = NotchEvent.meetingLink(in: [event.url?.absoluteString, event.location, event.notes])
        // A location that is only the call link would repeat the Join button.
        let location = event.location.flatMap { $0.isEmpty || $0.contains("://") ? nil : $0 }
        let title = event.title ?? ""
        let identifier = event.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return NotchEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)",
                          title: title.isEmpty ? "Untitled" : title, start: event.startDate,
                          end: event.endDate, allDay: event.isAllDay, color: event.calendar.color, location: location,
                          coordinate: location == nil ? nil : event.structuredLocation?.geoLocation.map {
                              NotchCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                          },
                          meeting: meeting, open: identifier.flatMap { URL(string: "ical://ekevent/\($0)?method=show&options=more") })
    }
}
