import AppKit
import CoreLocation
import MapKit
import os

extension NotchTravelMode {
    /// Transit falls back to driving where MapKit has no transit directions, such as Bucharest.
    var transportTypes: [MKDirectionsTransportType] {
        switch self {
        case .driving: [.automobile]
        case .walking: [.walking]
        case .transit: [.transit, .automobile]
        }
    }
}

/// Says when to leave for events with a place: start minus the travel time from where the Mac is minus
/// `buffer`. `NotchTripPlan` decides what to measure and when to look again; this class measures with Core Location
/// and MapKit, sleeps in one task in between and never polls. Leave is asked for every minute until it has been on
/// screen (`shown`) or the event starts, so a busy or hidden notch only delays it. Location access is asked only
/// from an explicit button, like calendar access.
@MainActor
final class NotchTravel: NSObject, ObservableObject {
    enum Access: Equatable {
        case undetermined, granted, denied
    }

    @Published private(set) var access: Access = .undetermined
    /// Time to leave for this event; asked again a minute later until `shown` reports it.
    var onLeave: ((NotchEvent) -> Void)?
    var mode = NotchTravelMode.driving {
        didSet { if mode != oldValue { measures = [:]; plan() } }
    }
    var buffer: TimeInterval = 10 * 60 {
        didSet { if buffer != oldValue { plan() } }
    }
    /// Today's and tomorrow's events. Only a change to the trips themselves starts over, so calendar sync churn
    /// does not interrupt a measurement under way.
    var agenda = NotchAgenda() {
        didSet {
            let keys = agenda.trips(after: .now, done: []).map(NotchTripKey.init)
            guard keys != oldValue.trips(after: .now, done: []).map(NotchTripKey.init) else { return }
            measures = measures.filter { keys.contains($0.key) }
            places = places.filter { keys.contains($0.key) }
            plan()
        }
    }

    /// How far ahead of an event travel is first measured; a longer trip plus the buffer alerts late.
    static let horizon: TimeInterval = 3 * 3600
    /// A travel time measured earlier than this before leaving is measured again.
    static let remeasure: TimeInterval = 15 * 60
    /// After a failed fix, search or route, the next try.
    static let retry: TimeInterval = 5 * 60
    /// With the Mac already there or out of reach, the next look, in case it has moved.
    static let away: TimeInterval = 30 * 60
    /// Closer than this, the Mac is already there.
    static let arrived: CLLocationDistance = 300
    /// Farther than this, the place is another kind of trip (a train, a flight) or a wrong search match, such as
    /// "Room 2.14" finding a street abroad.
    static let reach: CLLocationDistance = 100_000
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    private enum Destination {
        case found(CLLocation), missing, failed
    }

    private let manager = CLLocationManager()
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "travel")
    private var running = false
    private var wake: Task<Void, Never>?
    private var measures: [NotchTripKey: NotchTripMeasure] = [:]
    /// Found destinations, so a remeasure aims at the same spot.
    private var places: [NotchTripKey: CLLocation] = [:]
    /// Events whose Leave has been on screen, with their end, kept until then so an event that leaves the agenda for
    /// a moment does not alert again.
    private var shownLeaves: [String: Date] = [:]
    private var locating: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        access = Self.access(manager.authorizationStatus)
    }

    func start() {
        guard !running else { return }
        running = true
        plan()
    }

    func stop() {
        running = false
        wake?.cancel()
        wake = nil
    }

    /// Shows the macOS prompt the first time; once it has been answered, only System Settings can change it.
    func requestAccess() {
        guard access == .undetermined else { NSWorkspace.shared.open(Self.privacySettingsURL); return }
        manager.requestWhenInUseAuthorization()
    }

    /// Leave for this event has been on screen; it is not asked for again.
    func shown(_ event: NotchEvent) {
        shownLeaves = shownLeaves.filter { $0.value > .now }
        shownLeaves[event.id] = event.end
    }

    /// Starts over from the agenda.
    private func plan() {
        wake?.cancel()
        wake = nil
        guard running, access == .granted else { return }
        wake = Task { [weak self] in
            while !Task.isCancelled, let next = await self?.step() {
                try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            }
        }
    }

    /// One look: measure what the plan asks for, then ask for Leave where it is due. Returns when to look again, or
    /// nil when nothing is ahead until the agenda changes.
    private func step() async -> Date? {
        var plan = decide()
        if !plan.measure.isEmpty {
            let here = await currentLocation()
            // A newer plan replaced this one while the fix came in; it searches and routes for itself.
            guard !Task.isCancelled else { return nil }
            for event in plan.measure {
                let key = NotchTripKey(event)
                let measure = await measure(event, key: key, from: here, previous: measures[key])
                guard !Task.isCancelled else { return nil }
                measures[key] = measure
            }
            plan = decide()
        }
        for event in plan.leave {
            log.notice("Time to leave for an event")
            onLeave?(event)
        }
        let again = plan.leave.isEmpty ? nil : Date.now.addingTimeInterval(60)
        return [plan.wake, again].compactMap { $0 }.min()
    }

    private func decide() -> NotchTripPlan {
        NotchTripPlan(trips: agenda.trips(after: .now, done: Set(shownLeaves.keys)), measures: measures, now: .now,
                      buffer: buffer, horizon: Self.horizon, remeasure: Self.remeasure)
    }

    /// The travel time from `here` to the event. A failed fix, search or route keeps an earlier travel time, or
    /// tries again in `retry`; no such place or no route in this mode is unreachable.
    private func measure(_ event: NotchEvent, key: NotchTripKey, from here: CLLocation?,
                         previous: NotchTripMeasure?) async -> NotchTripMeasure {
        let failed: NotchTripMeasure = if case .travel(let travel, _) = previous {
            .travel(travel, measured: .now)
        } else {
            .retry(at: .now.addingTimeInterval(Self.retry))
        }
        guard let here else { log.notice("No position for time to leave"); return failed }
        if places[key] == nil {
            let destination = await destination(of: event, near: here)
            // A newer plan may have dropped this key meanwhile.
            guard !Task.isCancelled else { return failed }
            switch destination {
            case .found(let place): places[key] = place
            case .missing: log.notice("No place found for an event"); return .unreachable
            case .failed: return failed
            }
        }
        guard let there = places[key] else { return failed }
        let distance = here.distance(from: there)
        guard distance > Self.arrived, distance < Self.reach else {
            log.notice("Event place out of range for now")
            return .retry(at: .now.addingTimeInterval(Self.away))
        }
        var transient = false
        for type in mode.transportTypes {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: there.coordinate))
            request.transportType = type
            do {
                return .travel(try await MKDirections(request: request).calculateETA().expectedTravelTime, measured: .now)
            } catch let error as MKError where error.code == .directionsNotFound {
                continue
            } catch {
                transient = true
            }
        }
        log.notice("No route for time to leave")
        return transient ? failed : .unreachable
    }

    /// The place Calendar pinned, or the first search result for the event's location near the Mac. A vague text
    /// such as "Faculty" can still match the wrong building nearby.
    private func destination(of event: NotchEvent, near here: CLLocation) async -> Destination {
        if let point = event.coordinate { return .found(CLLocation(latitude: point.latitude, longitude: point.longitude)) }
        guard let location = event.location else { return .missing }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = location
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 2 * Self.reach, longitudinalMeters: 2 * Self.reach)
        do {
            guard let place = try await MKLocalSearch(request: request).start().mapItems.first?.placemark.location else { return .missing }
            return .found(place)
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .missing
        } catch {
            return .failed
        }
    }

    /// One position fix; callers waiting at the same time share it.
    private func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locating.append(continuation)
            if locating.count == 1 { manager.requestLocation() }
        }
    }

    private func finishLocating(_ location: CLLocation?) {
        let waiting = locating
        locating = []
        waiting.forEach { $0.resume(returning: location) }
    }

    private static func access(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }
}

extension NotchTravel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            access = Self.access(status)
            plan()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        MainActor.assumeIsolated { finishLocating(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finishLocating(nil) }
    }
}
