import AppKit

/// One calendar event as the notch shows it, copied out of EventKit so the logic below runs without it.
struct NotchEvent: Equatable, Identifiable {
    /// Unique per occurrence: a repeating event shares its EventKit identifier across days.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    /// The calendar's colour.
    var color = NSColor.systemRed
    var location: String?
    /// Where the event is on the map, when Calendar has it (a place picked from its suggestions). Time to leave
    /// searches for `location` otherwise.
    var coordinate: NotchCoordinate?
    /// A Zoom, Google Meet, Teams, Webex or FaceTime link found in the event, opened by its Join button.
    var meeting: URL?
    /// Shows the event in Calendar.
    var open: URL?

    /// Hosts whose links join a call. Other links in an event, such as an agenda document, are left alone.
    static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                               "facetime.apple.com"]

    /// Names that make a location field a call rather than a place, such as "Microsoft Teams Meeting" or "Zoom".
    static let callPlaces = ["teams", "zoom", "google meet", "webex", "facetime", "skype", "online"]

    static func namesCall(_ location: String) -> Bool {
        callPlaces.contains { location.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Whether the event overlaps the span from `start` to `end`; one spanning midnight touches both days.
    func touches(_ start: Date, _ end: Date) -> Bool {
        self.start < end && self.end > start
    }

    /// The first call link in the event's URL, location or notes, in that order.
    static func meetingLink(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            if let link = links.first(where: { url in
                guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
                return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            }) { return link }
        }
        return nil
    }
}

/// A point on the map, kept free of Core Location so the agenda logic runs in the checks.
struct NotchCoordinate: Equatable {
    var latitude: Double
    var longitude: Double
}

/// The closed wings count down to `event`, which starts in `minutes`, rounded up.
struct NotchCountdown: Equatable {
    var event: NotchEvent
    var minutes: Int

    /// "12m", or "1h 5m" past an hour.
    var label: String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h" + (minutes % 60 > 0 ? " \(minutes % 60)m" : "")
    }
}

/// A Quick Peek: the notch drops a row for `event` when its countdown begins, and again when it starts.
struct NotchEventPeek: Equatable, Identifiable {
    var event: NotchEvent
    var starting: Bool

    /// One per event and moment, so each peek shows once however often the agenda is read.
    var id: String { "\(event.id) \(starting ? "start" : "soon")" }

    /// Whether a peek held back by an open, busy or hidden notch is still worth showing: one before the event until it
    /// starts, one at the start for its first five minutes, while joining late still makes sense.
    func due(at now: Date) -> Bool {
        starting ? now < event.start.addingTimeInterval(5 * 60) && now < event.end : now < event.start
    }
}

/// Today's and tomorrow's events and what the notch makes of them at a given moment: the rows of the open Calendar
/// page, the countdown in the closed wings and the Quick Peeks. A month's events for the page's grid and picked day
/// use it too. Pure, so the checks drive it with fixed dates.
struct NotchAgenda: Equatable {
    /// Sorted by start.
    var events: [NotchEvent] = []

    init(events: [NotchEvent] = []) {
        self.events = events.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The events touching a day, split into timed and all-day. On `now`'s own day, events that already ended drop
    /// out; an event spanning midnight belongs to both days.
    func day(_ day: Date, now: Date, calendar: Calendar = .current) -> (timed: [NotchEvent], allDay: [NotchEvent]) {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return ([], []) }
        let today = calendar.isDate(day, inSameDayAs: now)
        let touching = events.filter { $0.touches(start, end) && (!today || $0.allDay || $0.end > now) }
        return (touching.filter { !$0.allDay }, touching.filter(\.allDay))
    }

    /// The days among `days`, each a midnight, that hold an event, ended or not: the dots under the month's days.
    func busyDays(_ days: [Date], calendar: Calendar = .current) -> Set<Date> {
        Set(days.filter { day in
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return events.contains { $0.touches(day, end) }
        })
    }

    /// The next timed event starting within `lead`, unless one is under way: during a meeting the wings stay quiet
    ///.
    func countdown(at now: Date, lead: TimeInterval) -> NotchCountdown? {
        let timed = events.filter { !$0.allDay }
        guard !timed.contains(where: { $0.start <= now && $0.end > now }),
              let next = timed.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= lead }) else { return nil }
        return NotchCountdown(event: next, minutes: Int((next.start.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The Quick Peek due at `now` that is not in `shown`: an event that started within the last minute, else the
    /// one the countdown is running for. The minute covers a wake that lands late, such as after sleep; an event
    /// that started earlier is old news. A countdown already under way at launch still peeks once.
    func peek(at now: Date, lead: TimeInterval, shown: Set<String>) -> NotchEventPeek? {
        let starting = events.filter { !$0.allDay && $0.start <= now && now.timeIntervalSince($0.start) < 60 }
            .map { NotchEventPeek(event: $0, starting: true) }
        let soon = countdown(at: now, lead: lead).map { NotchEventPeek(event: $0.event, starting: false) }
        return (starting + [soon].compactMap { $0 }).first { !shown.contains($0.id) }
    }

    /// Events to travel to: timed ones with a place still to start, in order, without those in `done`. A
    /// location that names a call service, such as "Microsoft Teams Meeting", is no place unless Calendar pinned it.
    func trips(after now: Date, done: Set<String>) -> [NotchEvent] {
        events.filter { event in
            guard let location = event.location, !event.allDay, event.start > now, !done.contains(event.id) else { return false }
            return event.coordinate != nil || !NotchEvent.namesCall(location)
        }
    }

    /// The next moment the countdown can change: its minute ticking over, an event entering the lead window,
    /// starting or ending, or midnight, when the days move on. Nothing in between needs a wake-up.
    func nextChange(after now: Date, lead: TimeInterval, calendar: Calendar = .current) -> Date {
        var moments = [calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)]
        if let countdown = countdown(at: now, lead: lead) {
            // The label shows whole minutes rounded up, so it drops exactly when a multiple of 60 s remains.
            let remaining = countdown.event.start.timeIntervalSince(now)
            moments.append(now.addingTimeInterval(remaining - Double(countdown.minutes - 1) * 60))
        }
        for event in events where !event.allDay {
            moments += [event.start.addingTimeInterval(-lead), event.start, event.end]
        }
        return moments.filter { $0 > now }.min() ?? now.addingTimeInterval(60)
    }
}

/// An event together with its place, so editing the place starts time to leave over for it. The id carries the start.
struct NotchTripKey: Hashable {
    var id: String
    var location: String?
    var latitude: Double?
    var longitude: Double?

    init(_ event: NotchEvent) {
        id = event.id
        location = event.location
        latitude = event.coordinate?.latitude
        longitude = event.coordinate?.longitude
    }
}

/// What time to leave knows about getting to one event.
enum NotchTripMeasure: Equatable {
    case travel(TimeInterval, measured: Date)
    /// No such place, or no route in this mode: left alone until the place or the mode changes.
    case unreachable
    /// A failed try, or the Mac already there or out of reach for now: looked at again from this moment.
    case retry(at: Date)
}

/// Time to leave's decision at a moment: which trips within `horizon` to measure, which are due to leave, and
/// when to look again. Pure, so the checks drive it with fixed dates.
struct NotchTripPlan: Equatable {
    var measure: [NotchEvent] = []
    var leave: [NotchEvent] = []
    var wake: Date?

    /// A trip is first measured within `horizon` of its start, then again `remeasure` before leaving if the travel
    /// time is older than that. It is due once start minus travel minus `buffer` has come.
    init(trips: [NotchEvent], measures: [NotchTripKey: NotchTripMeasure], now: Date, buffer: TimeInterval,
         horizon: TimeInterval, remeasure: TimeInterval) {
        var wakes = trips.map { $0.start.addingTimeInterval(-horizon) }
        for event in trips where event.start.timeIntervalSince(now) <= horizon {
            switch measures[NotchTripKey(event)] {
            case nil:
                measure.append(event)
            case .unreachable:
                break
            case .retry(let at):
                if at <= now { measure.append(event) } else { wakes.append(at) }
            case .travel(let travel, let measured):
                let leaveAt = event.start.addingTimeInterval(-travel - buffer)
                let remeasureAt = leaveAt.addingTimeInterval(-remeasure)
                if measured < remeasureAt, now >= remeasureAt {
                    measure.append(event)
                } else if leaveAt <= now {
                    leave.append(event)
                } else {
                    wakes.append(measured < remeasureAt ? remeasureAt : leaveAt)
                }
            }
        }
        wake = wakes.filter { $0 > now }.min()
    }
}

/// A month as whole weeks of days, starting on the calendar's first weekday: the last days of the month before and the
/// first of the month after fill its first and last week.
struct NotchMonth: Equatable {
    /// Midnight of the month's first day.
    var start: Date
    /// Midnight of every day shown, a week per row.
    var weeks: [[Date]]
    /// From the first day shown to the midnight after the last: what the grid marks events for.
    var interval: DateInterval

    init(containing date: Date, calendar: Calendar = .current) {
        let month = calendar.dateInterval(of: .month, for: date)
        let first = month?.start ?? calendar.startOfDay(for: date)
        let count = calendar.range(of: .day, in: .month, for: date)?.count ?? 0
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells = lead + count + (7 - (lead + count) % 7) % 7
        let days = (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - lead, to: first) }
        start = first
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let end = days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? month?.end ?? first
        interval = DateInterval(start: days.first ?? first, end: end)
    }

    /// Whether a day belongs to this month rather than to a neighbour filling the first or last week.
    func contains(_ day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, equalTo: start, toGranularity: .month)
    }

    /// One-letter weekday headers in the grid's column order.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whether a column falls on a weekend, for dimming.
    static func isWeekend(column: Int, calendar: Calendar = .current) -> Bool {
        let weekday = (calendar.firstWeekday - 1 + column) % 7 + 1
        return weekday == 1 || weekday == 7
    }
}

/// Where the Calendar page is in time: the month in the grid and the day on the left. Nil follows today, so an
/// untouched page moves on at midnight by itself.
struct NotchCalendarSelection: Equatable {
    /// Midnight of the first day of a month other than today's.
    var month: Date?
    /// Midnight of a picked day other than today.
    var day: Date?

    /// How long the notch may stay closed before it opens on today again: a pointer slipping off the notch keeps the
    /// picked day, a later glance starts from now.
    static let keep: TimeInterval = 10

    /// The day on the left.
    func shownDay(today: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day ?? today)
    }

    func isToday(_ today: Date, calendar: Calendar = .current) -> Bool {
        day.map { calendar.isDate($0, inSameDayAs: today) } ?? true
    }

    /// The month in the grid.
    func shownMonth(today: Date, calendar: Calendar = .current) -> NotchMonth {
        NotchMonth(containing: month ?? today, calendar: calendar)
    }

    /// A click on a day picks it; a click on the picked day or on today goes back to today, month included.
    mutating func select(_ date: Date, today: Date, calendar: Calendar = .current) {
        if calendar.isDate(date, inSameDayAs: today) || day.map({ calendar.isDate(date, inSameDayAs: $0) }) == true {
            self = NotchCalendarSelection()
        } else {
            day = calendar.startOfDay(for: date)
        }
    }

    /// Moves the grid by whole months and leaves the day on the left alone. Back on today's month, the grid follows
    /// today again.
    mutating func page(by months: Int, today: Date, calendar: Calendar = .current) {
        guard let next = calendar.date(byAdding: .month, value: months, to: shownMonth(today: today, calendar: calendar).start)
        else { return }
        month = calendar.isDate(next, equalTo: today, toGranularity: .month) ? nil : next
    }

    /// Opening the notch again after `keep` starts from today.
    mutating func reopen(closedFor: TimeInterval) {
        if closedFor >= Self.keep { self = NotchCalendarSelection() }
    }

    /// The spans to read events for: the grid's weeks, and the picked day when paging has left it outside them.
    func intervals(today: Date, calendar: Calendar = .current) -> [DateInterval] {
        let grid = shownMonth(today: today, calendar: calendar).interval
        let start = shownDay(today: today, calendar: calendar)
        // `DateInterval.contains` counts its end, which is the first day after the grid.
        guard start < grid.start || start >= grid.end, let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [grid] }
        return [grid, DateInterval(start: start, end: end)]
    }
}
