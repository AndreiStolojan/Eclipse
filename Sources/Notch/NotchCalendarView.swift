import AppKit
import SwiftUI

/// Calendar.app, opened by the date and by events whose identifier EventKit withholds.
private let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")

private func openURL(_ url: URL?) {
    if let url { NSWorkspace.shared.open(url) }
}

/// The Calendar page of the open notch: the weekday in red in the
/// left wing, the date under it, today's remaining events and tomorrow's first one, and the month on the right
/// with today in a red disc. A click on a day in the month shows that day on the left instead, until a click on it or
/// on today, or a while after the notch closes. Relative times move once a minute, only while the page is on screen.
struct NotchCalendarPage: View {
    @ObservedObject var calendar: NotchCalendar
    let topHeight: CGFloat
    /// Width of the open notch beside the camera on each side; the weekday must fit in it.
    let wing: CGFloat
    /// The page is on screen rather than waiting beside it on the strip, where its minutes do not move.
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the last move went later in time, so the new day or month comes in from the trailing side.
    @State private var forward = true

    /// Rows that fit under the date beside the footer.
    private static let rows = 2

    var body: some View {
        // Off screen the minute stands still; coming back on screen starts the ticks over from the current minute.
        TimelineView(NotchTicks(start: Calendar.current.dateInterval(of: .minute, for: .now)?.start ?? .now,
                                interval: visible ? 60 : nil)) { context in
            let now = calendar.previewNow ?? context.date
            let day = calendar.selection.shownDay(today: now)
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    column(day, now: now).id(day).transition(transition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                NotchMonthGrid(month: calendar.selection.shownMonth(today: now), today: now,
                               picked: calendar.selection.isToday(now) ? nil : day, busy: calendar.busyDays,
                               transition: transition,
                               select: { picked in move(now: now) { $0.select(picked, today: now) } },
                               page: { months in move(now: now) { $0.page(by: months, today: now) } },
                               showToday: { move(now: now) { $0 = NotchCalendarSelection() } })
                    .padding(.top, topHeight + 4)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
    }

    /// A gentle spring between days and months; a plain crossfade under Reduce Motion.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.12)
    }

    /// The new day or month fades in from a few points to the side it lies on; the old one fades where it is.
    private var transition: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 8 : -8)), removal: .opacity)
    }

    /// Applies a click to the selection with the spring. The direction is set first, from the day on the left or else
    /// the month, so the view coming in already slides from the right side.
    private func move(now: Date, _ change: (inout NotchCalendarSelection) -> Void) {
        let old = calendar.selection
        var new = old
        change(&new)
        let (from, to) = (old.shownDay(today: now), new.shownDay(today: now))
        forward = from != to ? to > from : new.shownMonth(today: now).start > old.shownMonth(today: now).start
        withAnimation(motion) { calendar.selection = new }
    }

    /// The weekday and date of `day` with its events. Today keeps its red weekday, the live agenda with ended events
    /// gone and tomorrow's first event; another day reads the month's events and shows them all.
    private func column(_ day: Date, now: Date) -> some View {
        let clock = Calendar.current
        let isToday = clock.isDate(day, inSameDayAs: now)
        let events = isToday ? calendar.agenda.day(now, now: now) : calendar.browsed.day(day, now: now)
        let rows = Array((events.timed.isEmpty ? events.allDay : events.timed).prefix(Self.rows))
        let tomorrow = isToday ? clock.date(byAdding: .day, value: 1, to: now).map { calendar.agenda.day($0, now: now) } : nil
        let next = tomorrow.flatMap { $0.timed.first ?? $0.allDay.first }
        // Another month's day names its month, and its year when that differs too.
        let month: Date.FormatStyle? = clock.isDate(day, equalTo: now, toGranularity: .month) ? nil
            : clock.isDate(day, equalTo: now, toGranularity: .year) ? .dateTime.month(.abbreviated)
            : .dateTime.month(.abbreviated).year()
        return VStack(alignment: .leading, spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundStyle(isToday ? Color(nsColor: .systemRed) : .white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: wing - 16, maxHeight: topHeight, alignment: .bottomLeading)
            Button { openURL(calendarApp) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(day.formatted(.dateTime.day())).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    if let month {
                        Text(day.formatted(month)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .buttonStyle(NotchPressStyle()).help("Open Calendar").accessibilityLabel("Open Calendar")
            .padding(.bottom, 4)
            if calendar.access != .granted {
                // Another day shows just its date; the way to access stays with today.
                if isToday { access }
            } else if rows.isEmpty {
                Text(isToday ? "Your day is clear" : day > now ? "Nothing planned" : "No events")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { NotchEventRow(event: $0, now: now) }
                }
            }
            Spacer(minLength: 0)
            let more = more(events, shown: rows.count)
            if !more.isEmpty {
                Text(more).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            if let next, let tomorrow {
                let count = tomorrow.timed.count + tomorrow.allDay.count
                Text("\(Text("TMRW").bold())  \(next.title)\(next.allDay ? "" : " " + next.start.formatted(date: .omitted, time: .shortened))\(count > 1 ? "  +\(count - 1)" : "")")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .padding(.top, 2)
            }
        }
    }

    /// "+2 more" for timed events past the rows, "1 all-day" when timed rows hide the all-day ones.
    private func more(_ day: (timed: [NotchEvent], allDay: [NotchEvent]), shown: Int) -> String {
        guard calendar.access == .granted else { return "" }
        let listed = day.timed.isEmpty ? day.allDay : day.timed
        var parts: [String] = []
        if listed.count > shown { parts.append("+\(listed.count - shown) more") }
        if !day.timed.isEmpty, !day.allDay.isEmpty { parts.append("\(day.allDay.count) all-day") }
        return parts.joined(separator: " · ")
    }

    /// Before the first grant the button asks macOS; after a refusal it opens the Calendars privacy pane.
    private var access: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calendar.access == .denied ? "Calendar access is off" : "Show your events here")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            Button(calendar.access == .denied ? "Open Settings" : "Allow access", action: calendar.requestAccess)
                .font(.system(size: 10, weight: .semibold)).buttonStyle(.plain)
                .padding(.horizontal, 8).frame(height: 20).background(.white.opacity(0.15), in: Capsule())
        }
    }
}

/// An event in the calendar's colour: the title over its time, place or countdown. A click shows it in Calendar;
/// a call link adds a Join button.
private struct NotchEventRow: View {
    let event: NotchEvent
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Button { openURL(event.open ?? calendarApp) } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.color)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(detail).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressStyle()).help("Show in Calendar")
            if let meeting = event.meeting, event.end > now {
                Button { NSWorkspace.shared.open(meeting) } label: {
                    Image(systemName: "video.fill").font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 18).background(Color(nsColor: .systemGreen).opacity(0.85), in: Capsule())
                }
                .buttonStyle(NotchPressStyle()).help("Join").accessibilityLabel("Join \(event.title)")
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    /// "Now · until 11:15" under way, "11:00 · in 12m" within the hour, otherwise the time range, as for a past
    /// day's events; then the place.
    private var detail: String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        var parts: [String]
        if event.allDay {
            parts = ["All day"]
        } else if event.start <= now, event.end > now {
            parts = ["Now", "until \(time(event.end))"]
        } else if event.start > now, event.start.timeIntervalSince(now) <= 3600 {
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            parts = [time(event.start), "in \(NotchCountdown(event: event, minutes: minutes).label)"]
        } else {
            parts = ["\(time(event.start))–\(time(event.end))"]
        }
        if let location = event.location { parts.append(location) }
        return parts.joined(separator: " · ")
    }
}

/// The page's month: its name in red, with the year when it is not this one, chevrons to the months either side,
/// one-letter weekdays, weekends and the neighbouring months' days dimmed, today in a red disc, the picked day in a
/// soft white one that springs from day to day (fades under Reduce Motion), and a dot under each day holding an event.
private struct NotchMonthGrid: View {
    let month: NotchMonth
    let today: Date
    /// The day on the left when it is not today.
    let picked: Date?
    let busy: Set<Date>
    let transition: AnyTransition
    let select: (Date) -> Void
    let page: (Int) -> Void
    let showToday: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Date?
    @Namespace private var selection

    private static let cell: CGFloat = 18
    private static let row: CGFloat = 14
    /// A week's row, a point taller than the headers so the dot fits under the lifted number.
    private static let week: CGFloat = 15

    var body: some View {
        let clock = Calendar.current
        let current = clock.isDate(month.start, equalTo: today, toGranularity: .month)
        let title = clock.isDate(month.start, equalTo: today, toGranularity: .year)
            ? month.start.formatted(.dateTime.month(.wide)) : month.start.formatted(.dateTime.month(.wide).year())
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // Away from today's month, the name leads back to today.
                Button(action: showToday) {
                    Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(1).contentTransition(.opacity)
                }
                .buttonStyle(NotchPressStyle()).disabled(current && picked == nil).help("Today")
                .padding(.leading, 3)
                Spacer(minLength: 4)
                chevron("chevron.left", by: -1, label: "Previous month")
                chevron("chevron.right", by: 1, label: "Next month")
            }
            .frame(width: 7 * Self.cell, height: Self.row)
            HStack(spacing: 0) {
                ForEach(Array(NotchMonth.weekdaySymbols().enumerated()), id: \.offset) { column, symbol in
                    Text(symbol).frame(width: Self.cell).opacity(NotchMonth.isWeekend(column: column) ? 0.4 : 0.6)
                }
            }
            .font(.system(size: 8.5, weight: .semibold)).frame(height: Self.row).accessibilityHidden(true)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(month.weeks, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.element) { column, day in
                                cell(day, weekend: NotchMonth.isWeekend(column: column), clock: clock)
                            }
                        }
                    }
                }
                .id(month.start).transition(transition)
            }
            .font(.system(size: 9)).monospacedDigit()
            // Dots arrive when the month's read finishes; they fade in rather than pop.
            .animation(.easeOut(duration: 0.25), value: busy)
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .fixedSize()
    }

    private func chevron(_ symbol: String, by months: Int, label: String) -> some View {
        Button { page(months) } label: {
            Image(systemName: symbol).font(.system(size: 7.5, weight: .bold)).opacity(0.6)
                .frame(width: 16, height: Self.row).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle()).help(label).accessibilityLabel(label)
    }

    private func cell(_ day: Date, weekend: Bool, clock: Calendar) -> some View {
        let isToday = clock.isDate(day, inSameDayAs: today)
        let isPicked = picked.map { clock.isDate(day, inSameDayAs: $0) } ?? false
        let inMonth = month.contains(day, calendar: clock)
        let hasEvents = busy.contains(day)
        return Button { select(day) } label: {
            ZStack {
                Group {
                    if isToday {
                        Circle().fill(Color(nsColor: .systemRed)).frame(width: 15, height: 15)
                    } else if isPicked {
                        let disc = Circle().fill(.white.opacity(0.22)).frame(width: 15, height: 15)
                        if reduceMotion {
                            // Fades out on the old day and in on the new one instead of travelling.
                            disc.transition(.opacity)
                        } else {
                            // Keyed by month, so two grids crossing during a page never share it.
                            disc.matchedGeometryEffect(id: month.start, in: selection)
                        }
                    } else if hovered == day {
                        Circle().fill(.white.opacity(0.1)).frame(width: 15, height: 15)
                    }
                    Text("\(clock.component(.day, from: day))")
                        .fontWeight(isToday || isPicked ? .bold : .regular)
                        .opacity(isToday || isPicked ? 1 : !inMonth ? 0.28 : weekend ? 0.45 : 0.9)
                }
                .offset(y: -1)
                if hasEvents {
                    Circle().frame(width: 2.5, height: 2.5).offset(y: 5)
                        .opacity(isToday ? 0.95 : !inMonth ? 0.3 : 0.6)
                }
            }
            .frame(width: Self.cell, height: Self.week).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { inside in
            if inside { hovered = day } else if hovered == day { hovered = nil }
        }
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasEvents ? "Has events" : "")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// Left wing of the countdown: the calendar's colour beside the event's title, nearly flush with the wing's edge as
/// in the approved study, so "Stand-up" fits the indicator's 56 pt.
struct NotchCountdownTitle: View {
    @ObservedObject var calendar: NotchCalendar

    var body: some View {
        if let countdown = calendar.countdown {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: countdown.event.color)).frame(width: 3, height: 14)
                Text(countdown.event.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 2).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Next event, \(countdown.event.title)")
        }
    }
}

/// Right wing of the countdown: minutes until the event starts, rounded up.
struct NotchCountdownTime: View {
    @ObservedObject var calendar: NotchCalendar

    var body: some View {
        if let countdown = calendar.countdown {
            Text(countdown.label).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .accessibilityLabel("Starts in \(countdown.minutes) minutes")
        }
    }
}

/// A Quick Peek: one row under the camera with the calendar's colour, the title and when
/// it starts, the place under them and Join for a call, green once the event has started. A click shows the event in
/// Calendar; either click ends the peek.
struct NotchEventPeekView: View {
    let peek: NotchEventPeek
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat

    var body: some View {
        let event = peek.event
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                Button { open(event.open ?? calendarApp) } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.color)).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(when(now: experience.calendar.previewNow ?? context.date))
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize()
                            }
                            Text(event.location ?? "until \(event.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchRowPressStyle()).help("Show in Calendar")
                if let meeting = event.meeting {
                    Button { open(meeting) } label: {
                        HStack(spacing: 4) { Image(systemName: "video.fill"); Text("Join") }.font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(peek.starting ? .black : .white)
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(peek.starting ? Color(nsColor: .systemGreen) : .white.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(NotchPressStyle()).help("Join").accessibilityLabel("Join \(event.title)")
                }
            }
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: NotchGeometry.eventPeekDrop - 6)
            .padding(.top, topHeight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(peek.starting ? "\(event.title) is starting" : "Next event, \(event.title)")
    }

    /// "11:00 · in 12m" before the event, "Now" once it has started.
    private func when(now: Date) -> String {
        let start = peek.event.start
        guard !peek.starting, start > now else { return "Now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return "\(start.formatted(date: .omitted, time: .shortened)) · in \(NotchCountdown(event: peek.event, minutes: minutes).label)"
    }

    private func open(_ url: URL?) {
        openURL(url)
        experience.dismissEventPeek()
    }
}
