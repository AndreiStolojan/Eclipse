import Foundation

/// Where the notch appears: the built-in display with the camera housing, the main display (the one with the menu
/// bar), or one display remembered by its stable ID. The name is kept to label a disconnected display.
enum NotchDisplayChoice: Codable, Hashable {
    case notch, main
    case display(id: String, name: String)
}

/// How time to leave measures the way to an event.
enum NotchTravelMode: String, Codable, CaseIterable {
    case driving, walking, transit

    var label: String {
        switch self {
        case .driving: "Driving"
        case .walking: "Walking"
        case .transit: "Transit"
        }
    }

    /// The symbol in the left wing when it is time to leave.
    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        }
    }
}

/// The lock screen media widget's material: Liquid Glass, its clear variant, or a frosted blur.
enum NotchLockGlass: String, Codable, CaseIterable {
    case glass, clear, frosted

    var label: String {
        switch self {
        case .glass: "Glass"
        case .clear: "Clear"
        case .frosted: "Frosted"
        }
    }
}

/// What a secondary slot either side of the open player's transport holds.
enum NotchPlayerButton: String, Codable, CaseIterable {
    case none, shuffle, `repeat`, like, playlist, volume, output

    var label: String {
        switch self {
        case .none: "Nothing"
        case .shuffle: "Shuffle"
        case .repeat: "Repeat"
        case .like: "Like"
        case .playlist: "Playlist"
        case .volume: "Volume"
        case .output: "Output"
        }
    }
}

/// The right wing's wave while music plays: bars like the dictation pill's, one soft line, or a row of dots.
enum NotchWaveStyle: String, Codable, CaseIterable {
    case bars, line, dots

    var label: String {
        switch self {
        case .bars: "Bars"
        case .line: "Line"
        case .dots: "Dots"
        }
    }
}

/// How the player's artwork turns to a new track's. Under Reduce Motion every style but None crossfades.
enum NotchArtworkTransition: String, Codable, CaseIterable {
    case flip, slide, crossfade, blur, none

    var label: String {
        switch self {
        case .flip: "Flip"
        case .slide: "Slide"
        case .crossfade: "Fade"
        case .blur: "Blur"
        case .none: "None"
        }
    }
}

/// Every user-adjustable value. Persisted as one JSON blob, so a new setting only needs a default here.
struct NotchSettings: Equatable, Codable {
    /// Expanded player width in points.
    var expandedWidth: Double = 320
    /// Expanded height below the camera row in points.
    var expandedHeight: Double = 136
    var cornerRadius: Double = 28
    /// Visible width on each side of the camera cutout while compact.
    var wingWidth: Double = 40
    /// Sotto's dictation pill and its bars, as multiples of a 220 × 22 pt pill row and 2.5 × 20 pt bars. A
    /// little larger by default.
    var dictationPillScale: Double = 1.1
    var dictationBarScale: Double = 1.2
    /// Off, Eclipse tells Sotto it does not present the dictation, so Sotto shows its own pill at the bottom.
    var dictationInNotch = true
    /// The link to Sotto, the dictation app. Off by default: Eclipse never presents dictation, whatever
    /// `dictationInNotch` says. The local socket stays closed unless Sotto or script notices are enabled.
    var sottoLinked = false
    /// Local script notices, their temporary alerts and their in-memory history. Independent of Sotto, off by default.
    var scriptNotices = false
    /// Seconds the pointer must rest on the notch before it opens.
    var hoverOpenDelay: Double = 0.1
    /// Seconds the pointer may leave before the notch closes.
    var hoverCloseDelay: Double = 0.08
    /// Springs for the outline growing (opening, a peek or alert dropping) and shrinking. Opening is unhurried with
    /// a trace of overshoot; closing is a little quicker and settles without any (never rushed).
    /// New names, so the faster `animationDuration` and `animationBounce` stored before are left behind.
    var openAnimationDuration: Double = 0.55
    var closeAnimationDuration: Double = 0.42
    /// Overshoot of the opening spring: 0 settles without any, higher values bounce. Closing never bounces.
    var openAnimationBounce: Double = 0.08
    var haptics = true
    /// When off, only a click or a file drag opens the notch.
    var expandOnHover = true
    /// Two-finger swipes over the notch: down opens it and up closes it; left and right page the open notch
    /// and skip tracks on the closed one.
    var swipeToToggle = true
    var swipeToPage = true
    var swipeToSkip = true
    var accentHex = "A4D8DF"
    var openWindowAtLaunch = true
    /// Seconds a volume, brightness, Focus or Caps Lock indicator stays after the last change.
    var hudDuration: Double = 1.5
    /// Meter colour; white by default.
    var hudColorHex = "FFFFFF"
    /// Adds a soft shadow in the meter colour behind the meter.
    var hudGlow = false
    /// Takes over the volume and brightness keys so macOS shows no indicator of its own. Needs Accessibility.
    var replaceSystemHUD = true
    var volumeHUD = true
    var brightnessHUD = true
    var focusHUD = true
    /// Caps Lock turning on or off. Read through the key tap, so it needs Accessibility like the key takeover.
    var capsLockHUD = true
    /// Power connected or removed and the 20 %, 10 % and 5 % warnings in the closed notch.
    var batteryHUD = true
    /// Seconds the battery indicator stays; longer than the meters, since nothing follows it.
    var batteryDuration: Double = 5
    /// An output device connecting or going away, such as AirPods or a display.
    var audioDeviceHUD = true
    var audioDeviceDuration: Double = 3
    /// A track change or playback starting shows what plays for `peekDuration` seconds, see `NotchTrackWatch`: the
    /// closed notch drops a slim row with its title. With `trackPeekOpensNotch` it opens the whole notch like a hover instead, as it did before 7 October.
    var peekOnTrackChange = true
    var peekDuration: Double = 3
    var trackPeekOpensNotch = false
    /// The buttons in the open player's two secondary slots, left and right of the transport.
    var playerLeftButton = NotchPlayerButton.shuffle
    var playerRightButton = NotchPlayerButton.repeat
    /// A decorative wave in the closed notch's right wing while a track plays, in the artwork's colour or white.
    /// It is not driven by the audio, so it needs no permission.
    var playingWave = true
    var waveStyle = NotchWaveStyle.bars
    var waveArtworkColor = false
    /// How the artwork turns to a new track's in the open player; the closed wing's small artwork crossfades.
    var artworkTransition = NotchArtworkTransition.slide
    /// A new screenshot drops the closed notch for a moment, to open, shelve or drag it. Off, the
    /// screenshot folder is not watched at all.
    var screenshotThumbnail = true
    /// Every new screenshot also lands on the shelf, whether or not the notch shows it.
    var shelveScreenshots = true
    /// Copied text and images kept on the Shelf page's Clipboard list, in memory only. Off by default: while
    /// on, the clipboard's change count is read twice a second.
    var clipboardHistory = false
    var clipboardLimit: Double = 10
    /// A finished download drops the closed notch for `downloadDuration` seconds with its site and quarantine state
    ///. Off by default: on, the Downloads folder is watched, which macOS asks permission for.
    var downloadAlerts = false
    var downloadDuration: Double = 4
    /// The Calendar page of the open notch and the countdown in the closed wings. Off, the page leaves the swipe
    /// order and EventKit is not read.
    var calendar = true
    /// The closed wings count down to the next timed event from `calendarLead` minutes before it.
    var calendarCountdown = true
    var calendarLead: Double = 15
    /// Quick Peek: the closed notch drops a row for the next event when its countdown begins and when it starts, for
    /// `calendarPeekDuration` seconds.
    var calendarPeekBefore = true
    var calendarPeekAtStart = true
    var calendarPeekDuration: Double = 4
    /// Time to leave: the wings say Leave for `leaveDuration` seconds when the travel time from here to an event's
    /// place, plus `leaveBuffer` minutes, is all that is left. Needs Location access, asked from the Calendar page.
    var timeToLeave = true
    var leaveBuffer: Double = 10
    var leaveDuration: Double = 8
    var travelMode = NotchTravelMode.driving
    /// The Timer page after Calendar and a running timer in the closed wings. Off, the page leaves the swipe
    /// order and a running timer is cancelled.
    var timer = true
    /// "10 min left", "5 min left" and "1 min left" drop from the wings, for timers longer than that.
    var timerPhaseAlerts = true
    /// The system sound a finished timer plays, by name (`NotchTimer.sounds`); empty for none.
    var timerSound = "Glass"
    /// Seconds the Done row stays when neither Stop nor +1 min is pressed.
    var timerDoneDuration: Double = 30
    /// The link to T3 Code: its page after Shelf, alerts when a thread finishes or needs you, and answers from
    /// the notch. Off until Connect is turned on, which asks T3 for access.
    var t3Linked = false
    var agentAlerts = true
    /// Seconds a T3 alert stays (2.5 s).
    var agentAlertDuration: Double = 2.5
    /// A T3 alert as a multiple of its 291 × 74 study.
    var agentAlertScale: Double = 1
    /// A thread's page as a multiple of 360 × 220.
    var agentPageScale: Double = 1
    /// Calendars turned off on the Calendar settings page, by EventKit identifier.
    var hiddenCalendars: Set<String> = []
    /// The panel steps aside while the notch's display shows a fullscreen Space, Mission Control is open or a game is
    /// frontmost. Off by default.
    var hideInFullscreen = false
    var hideInMissionControl = false
    var hideWhileGaming = false
    /// Screenshots and screen recordings leave the panel out. On by default.
    var hideFromScreenCapture = true
    /// The display the notch appears on.
    var display = NotchDisplayChoice.notch
    /// Draws a simulated cutout of `simulatedNotchWidth` even on a display with a camera housing. Displays without
    /// one always use the simulated width.
    var forceSimulatedNotch = false
    var simulatedNotchWidth: Double = 160
    /// The lock screen: a lock in the closed notch that opens on unlock, and the media widget, with its material,
    /// the opacity of a dark layer over it, its offset in points from its place above the user picture (positive moves
    /// it down) and whether a tap on its artwork enlarges it. The offset used to count from 56 % down the screen under
    /// the key `lockScreenOffset`; the new key drops that value, so every widget starts at the new place.
    var lockIcon = true
    var lockScreenMedia = true
    var lockScreenGlass = NotchLockGlass.glass
    var lockScreenDimming: Double = 0.2
    var lockScreenWidgetOffset: Double = 0
    var lockScreenArtTap = true

    static let key = "notchSettings"

    func shows(_ hud: NotchHUD) -> Bool {
        switch hud {
        case .volume: volumeHUD
        case .brightness: brightnessHUD
        case .focus: focusHUD
        case .battery: batteryHUD
        case .capsLock: capsLockHUD
        case .audioDevice: audioDeviceHUD
        case .leave: timeToLeave
        case .timer: timer && timerPhaseAlerts
        }
    }

    func duration(for hud: NotchHUD) -> Double {
        switch hud {
        case .battery: batteryDuration
        case .audioDevice: audioDeviceDuration
        case .leave: leaveDuration
        // A timer phase alert is a glance: "5 min left" for 2 s.
        case .timer: 2
        default: hudDuration
        }
    }

    /// The settings sliders' ranges (NotchAppView). A stored value outside its range, edited by hand or written by
    /// another build, is pulled back in on load, so code such as `Int(clipboardLimit)` never sees an absurd number.
    static var ranges: [(WritableKeyPath<NotchSettings, Double>, ClosedRange<Double>)] { [
        (\.expandedWidth, 260...600), (\.expandedHeight, 120...260), (\.cornerRadius, 8...40), (\.wingWidth, 24...80),
        (\.dictationPillScale, 0.9...1.5), (\.dictationBarScale, 0.8...1.8),
        (\.hoverOpenDelay, 0...0.5), (\.hoverCloseDelay, 0...0.5),
        (\.openAnimationDuration, 0.2...1), (\.closeAnimationDuration, 0.15...0.8), (\.openAnimationBounce, 0...0.4),
        (\.hudDuration, 0.5...5), (\.batteryDuration, 1...10), (\.audioDeviceDuration, 1...10), (\.peekDuration, 1...8),
        (\.clipboardLimit, 5...50), (\.downloadDuration, 2...10),
        (\.calendarLead, 5...60), (\.calendarPeekDuration, 1...10), (\.leaveBuffer, 0...30), (\.leaveDuration, 2...15),
        (\.timerDoneDuration, 5...120),
        (\.agentAlertDuration, 1...5), (\.agentAlertScale, 0.9...1.4), (\.agentPageScale, 0.9...1.4),
        (\.simulatedNotchWidth, 100...260), (\.lockScreenDimming, 0...0.8),
        // NotchLockScreenLayout.offsetRange, written out because the logic checks build this file without it.
        (\.lockScreenWidgetOffset, -160...24),
    ] }

    /// Stored values overlay the defaults. A malformed field falls back individually, preserving unrelated settings;
    /// numbers are then clamped to `ranges`. Each failed field is replaced at most once.
    static func load(from defaults: UserDefaults) -> NotchSettings {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fallback = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(NotchSettings())) as? [String: Any]
        else { return NotchSettings() }
        var values = fallback.merging(stored) { $1 }
        var rejected = Set<String>()
        while let merged = try? JSONSerialization.data(withJSONObject: values) {
            do {
                var settings = try JSONDecoder().decode(NotchSettings.self, from: merged)
                for (path, range) in ranges {
                    settings[keyPath: path] = min(max(settings[keyPath: path], range.lowerBound), range.upperBound)
                }
                return settings
            } catch let error as DecodingError {
                let context: DecodingError.Context
                switch error {
                case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found),
                     .dataCorrupted(let found): context = found
                @unknown default: return NotchSettings()
                }
                guard let field = context.codingPath.first?.stringValue, let replacement = fallback[field],
                      rejected.insert(field).inserted else { return NotchSettings() }
                values[field] = replacement
            } catch {
                return NotchSettings()
            }
        }
        return NotchSettings()
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
