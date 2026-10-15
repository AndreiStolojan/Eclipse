import AppKit

/// Where the Mac's lock stands for the notch. Unlocking plays in two steps before the notch is back to normal:
/// the shackle opens while the wing is still out, then the wing retracts.
enum NotchLockPhase: Equatable {
    case unlocked, locked, opening, retracting
}

/// Conditions under which nothing can be seen on the lock screen, so its windows are taken down.
enum NotchLockCover: Hashable {
    /// The Mac sleeps.
    case asleep
    /// The displays are off while the Mac stays awake.
    case displaysAsleep
    case screenSaver
    /// Fast user switching moved this session off the console; another user's login window must never show it.
    case sessionInactive
}

/// The lock screen's state machine, free of system calls so the checks can drive it. A lock always wins, also in the
/// middle of the unlock animation; the animation's steps only advance from the step they end, so a late timer from an
/// earlier unlock does nothing.
struct NotchLockState: Equatable {
    /// The shackle opening and the beat after it, with the wing still out.
    static let openingDuration: Double = 0.7
    /// The wing retracting on the closing spring.
    static let retractDuration: Double = 0.5

    private(set) var phase = NotchLockPhase.unlocked
    private(set) var covers: Set<NotchLockCover> = []

    /// Locked or still unlocking: the notch stays concealed, so nothing private can be opened or shown.
    var secured: Bool { phase != .unlocked }
    /// The lock-level windows are wanted on screen.
    var presented: Bool { secured && covers.isEmpty }

    mutating func lock() { phase = .locked }

    /// Plays the unlock animation if the lock was on screen; with nothing to see it ends at once.
    mutating func unlock() {
        guard phase == .locked else { return }
        phase = covers.isEmpty ? .opening : .unlocked
    }

    /// The shackle has opened: the wing retracts next.
    mutating func opened() { if phase == .opening { phase = .retracting } }

    /// The wing is back: the notch returns to normal.
    mutating func retracted() { if phase == .retracting { phase = .unlocked } }

    /// Takes the system's own answer, at launch, on wake and when the session returns.
    mutating func reconcile(locked: Bool) { if locked { lock() } else { unlock() } }

    /// An animation nobody can see is skipped rather than played into the dark.
    mutating func cover(_ cover: NotchLockCover, _ on: Bool) {
        if on { covers.insert(cover) } else { covers.remove(cover) }
        if on, phase == .opening || phase == .retracting { phase = .unlocked }
    }
}

/// Where the media widget and the enlarged artwork sit on the lock screen. Measured on macOS 27 at 1470 × 956: the
/// date and clock end 24 % down, and the user picture starts 82.6 % down, with the name and "Touch ID or Enter
/// Password" below it. The widget sits in the lower part like an iPhone's Now Playing card, a comfortable gap above
/// the picture; the enlarged artwork fills the band between the clock and the widget. An offset moves the widget up,
/// or a little down, never into the clock or within `minimumGap` of the picture. A screen too short for that band
/// shows no widget.
enum NotchLockScreenLayout {
    static let widgetSize = CGSize(width: 340, height: 140)
    static let cornerRadius: CGFloat = 28
    /// The artwork tile inside the widget, from the widget's top left.
    static let tile = CGRect(x: 18, y: 14, width: 52, height: 52)
    static let tileRadius: CGFloat = 10
    static let artRadius: CGFloat = 20
    /// The clock's bottom edge from the top of the screen: 26 % of the height, never less than 250 pt.
    static let clockFraction: CGFloat = 0.26
    static let clockMinimum: CGFloat = 250
    /// The login block's top edge from the top of the screen: the higher of 82 % of the height and 172 pt above the
    /// bottom, so the widget stays clear whether macOS places the block by proportion or from the bottom edge.
    static let loginFraction: CGFloat = 0.82
    static let loginFromBottom: CGFloat = 172
    /// The space between the widget and the user picture at offset 0, and the least any offset leaves.
    static let gap: CGFloat = 56
    static let minimumGap: CGFloat = 32
    /// The offset slider's range in points from the default place; positive moves the widget down.
    static let offsetRange: ClosedRange<Double> = -160...Double(gap - minimumGap)
    /// Room around the enlarged artwork, inside its window, for the shadow (30 pt, 12 pt down) and the spring's
    /// overshoot (under 1 %). It is also the least space below the clock, for the artwork and a raised widget alike,
    /// so the window never reaches into the clock.
    static let artPadding: CGFloat = 32
    /// The enlarged artwork's space above the widget, which holds its padding, and its largest side.
    static let artGap: CGFloat = 32
    static let artMaximum: CGFloat = 420

    /// The clock's bottom and the login block's top, in points from the top of a screen this tall.
    static func clockBottom(_ height: CGFloat) -> CGFloat { max(height * clockFraction, clockMinimum) }
    static func loginTop(_ height: CGFloat) -> CGFloat { min(height * loginFraction, height - loginFromBottom) }

    /// The widget's frame on a screen, in AppKit coordinates (origin bottom left), centred horizontally; nil when the
    /// band between the clock and the login block cannot hold it with both gaps.
    static func widgetFrame(in screen: CGRect, offset: Double) -> CGRect? {
        let size = widgetSize
        // The widget's bottom edge from the top of the screen, kept between the clock and the login block.
        let login = loginTop(screen.height)
        let highest = clockBottom(screen.height) + artPadding + size.height
        let lowest = login - minimumGap
        guard highest <= lowest else { return nil }
        let bottom = min(max(login - gap + CGFloat(offset), highest), lowest)
        return CGRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.maxY - bottom).rounded(),
                      width: size.width, height: size.height)
    }

    /// The widget, the enlarged artwork and the window holding both on a screen; nil when the widget does not fit.
    static func stage(in screen: CGRect, offset: Double) -> NotchLockStage? {
        guard let widget = widgetFrame(in: screen, offset: offset) else { return nil }
        // The art's band, from below the clock down to the widget, in points from the top of the screen.
        let top = clockBottom(screen.height) + artPadding
        let bottom = screen.maxY - widget.maxY - artGap
        // An even side keeps the art and the widget centred on the same point.
        let side = max(0, (min(bottom - top, artMaximum, screen.width - 2 * artPadding) / 2).rounded(.down) * 2)
        let art = CGRect(x: (screen.midX - side / 2).rounded(), y: widget.maxY + artGap, width: side, height: side)
        return NotchLockStage(screen: screen, widget: widget, art: art)
    }
}

/// The lock screen's media layout on one screen, in AppKit coordinates.
struct NotchLockStage: Equatable {
    var screen: CGRect
    var widget: CGRect
    var art: CGRect

    /// Whether the band above the widget can hold artwork worth enlarging.
    var canEnlarge: Bool { art.width >= NotchLockScreenLayout.tile.width * 2 }
    /// The widget's window while the artwork is enlarged: the widget and the artwork with its padding, which reaches
    /// up to the clock's edge at most and down into the gap above the widget. Just the widget when there is no room.
    var frame: CGRect {
        let padding = NotchLockScreenLayout.artPadding
        return canEnlarge ? widget.union(art.insetBy(dx: -padding, dy: -padding)) : widget
    }

    /// A rect on the screen in the top-left coordinates of a view filling `container`.
    func local(_ rect: CGRect, in container: CGRect) -> CGRect {
        CGRect(x: rect.minX - container.minX, y: container.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the colour wash shows, as opacities at fractions of the screen height from the top: faint over the
    /// clock and the login block, which sit underneath the wash and must stay readable, full around the artwork and
    /// the widget, clear at both edges where the menu bar and the bottom of the login block are.
    var washStops: [NotchLockWashStop] {
        let height = max(screen.height, 1)
        let clock = NotchLockScreenLayout.clockBottom(height)
        let login = NotchLockScreenLayout.loginTop(height)
        let artMid = screen.maxY - art.midY
        let widgetBottom = screen.maxY - widget.minY
        let stops = [(0, 0), (clock * 0.4, 0.12), (clock, 0.25), (artMid, 1), (widgetBottom, 0.8), (login, 0.15),
                     (height, 0)]
        // Locations must not run backwards, even on a screen too short for the layout.
        var last: CGFloat = 0
        return stops.map { location, opacity in
            last = max(last, min(max(location / height, 0), 1))
            return NotchLockWashStop(location: last, opacity: opacity)
        }
    }

    /// The wash's opacity at a fraction of the screen height from the top, between the stops.
    func washOpacity(at location: CGFloat) -> CGFloat {
        let stops = washStops
        guard let after = stops.firstIndex(where: { $0.location >= location }) else { return stops.last?.opacity ?? 0 }
        guard after > 0 else { return stops[0].opacity }
        let (a, b) = (stops[after - 1], stops[after])
        let span = b.location - a.location
        return span > 0 ? a.opacity + (b.opacity - a.opacity) * (location - a.location) / span : b.opacity
    }
}

/// One stop of the wash's vertical fade.
struct NotchLockWashStop: Equatable {
    var location: CGFloat
    var opacity: CGFloat
}

/// The enlarged artwork: a tap on the widget's artwork grows it into the band above the widget over a wash of
/// its colours; a tap on it, on the widget's title or `idleTimeout` without a tap shrinks it back. A new track
/// restarts the wait. Unlocking, sleep, the screen saver or the switch going off cut it at once, so a relock starts
/// small. `generation` changes with every step, so a late timer from an earlier one does nothing.
struct NotchLockArtState: Equatable {
    static let idleTimeout: Double = 12
    /// How long the window keeps its large frame after a shrink starts: until the spring has settled on the tile.
    static let settleDuration: Double = 1.1

    enum Phase: Equatable { case collapsed, expanded, collapsing }

    private(set) var phase = Phase.collapsed
    private(set) var generation = 0
    /// False after a cut, so the change shows at once instead of on the spring.
    private(set) var animated = true

    var expanded: Bool { phase == .expanded }
    /// The artwork is out or still on its way back, so the window keeps its large frame.
    var staged: Bool { phase != .collapsed }

    /// A tap on the artwork or, while it is enlarged, on the widget's title. A tap while it shrinks grows it again.
    mutating func tap() {
        phase = phase == .expanded ? .collapsing : .expanded
        generation += 1
        animated = true
    }

    /// Shrinks the artwork on the spring.
    mutating func collapse() {
        guard phase == .expanded else { return }
        phase = .collapsing
        generation += 1
        animated = true
    }

    /// A new track while enlarged keeps it enlarged and starts the idle wait over.
    mutating func trackChanged() { if phase == .expanded { generation += 1 } }

    /// The idle wait of `generation` has passed.
    mutating func idle(_ generation: Int) { if generation == self.generation { collapse() } }

    /// The shrink of `generation` has settled on the tile.
    mutating func settled(_ generation: Int) {
        if phase == .collapsing, generation == self.generation { phase = .collapsed }
    }

    /// Back to the tile at once, with no animation.
    mutating func cut() {
        guard phase != .collapsed else { return }
        phase = .collapsed
        generation += 1
        animated = false
    }

    /// Follows the lock screen: `available` while locked and presented with media and the effect on, `shown` while
    /// the widget shows. Losing the lock screen cuts; the widget leaving, with its track gone, shrinks on the spring.
    mutating func follow(available: Bool, shown: Bool) {
        if !available { cut() } else if !shown { collapse() }
    }
}

/// The colours of the wash behind the enlarged artwork: the averages of the artwork's 3 × 3 regions, deepened so the
/// white clock and text over the wash stay readable. Computed off the main thread, once per artwork.
struct NotchLockPalette: Hashable, Sendable {
    /// Row by row from the top left, sRGB components from 0 to 1.
    let colors: [SIMD3<Double>]

    /// Dark greys, for artwork that cannot be read.
    static let neutral = NotchLockPalette(colors: Array(repeating: SIMD3(0.16, 0.16, 0.18), count: 9))

    init(colors: [SIMD3<Double>]) { self.colors = colors }

    init?(artwork base64: String) {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48
              ] as CFDictionary) else { return nil }
        self.init(image: image)
    }

    /// Averages the regions of a 12 × 12 copy of the image, stretched to a square as the tile crops it.
    init?(image: CGImage) {
        let side = 12, region = side / 3
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // The context's first row is the image's top.
        colors = (0..<9).map { index in
            let (row, column) = (index / 3, index % 3)
            var sum = SIMD3<Double>(0, 0, 0)
            for y in row * region..<(row + 1) * region {
                for x in column * region..<(column + 1) * region {
                    let pixel = (y * side + x) * 4
                    sum += SIMD3(Double(pixels[pixel]), Double(pixels[pixel + 1]), Double(pixels[pixel + 2]))
                }
            }
            return Self.deepened(sum / Double(region * region * 255))
        }
    }

    /// Keeps the hue, lifts a muted colour's saturation a little and holds the brightness between 0.18 and 0.5.
    static func deepened(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let color = NSColor(srgbRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let deep = NSColor(hue: hue, saturation: min(0.85, saturation * 1.25),
                           brightness: min(0.5, max(0.18, brightness * 0.8)), alpha: 1)
        guard let srgb = deep.usingColorSpace(.sRGB) else { return rgb }
        return SIMD3(srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }
}

/// Follows the system's lock, sleep, screen saver, display and session signals and runs the unlock animation's
/// timing. Event driven: distributed and workspace notifications, never polling.
@MainActor
final class NotchLockMonitor: ObservableObject {
    @Published private(set) var state = NotchLockState() {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called after every change, once `state` holds the new value.
    var onChange: (() -> Void)?
    /// Reads whether the session is locked; the checks pass their own.
    private let sessionLocked: () -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var step: Task<Void, Never>?
    private var recheck: Task<Void, Never>?
    /// How long a lock notification may run ahead of the session before the session is read again.
    static let recheckDelay: Double = 0.5

    init(sessionLocked: @escaping () -> Bool = { NotchLockMonitor.systemLocked }) {
        self.sessionLocked = sessionLocked
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLockChanged(true) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLockChanged(false) }
        observe(distributed, "com.apple.screensaver.didstart") { $0.cover(.screenSaver, true) }
        observe(distributed, "com.apple.screensaver.didstop") { $0.cover(.screenSaver, false) }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.cover(.asleep, true) }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.cover(.asleep, false); $0.reconcile() }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.cover(.displaysAsleep, true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.cover(.displaysAsleep, false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.cover(.sessionInactive, true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) {
            $0.cover(.sessionInactive, false)
            $0.reconcile()
        }
        reconcile()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        step?.cancel()
        step = nil
        recheck?.cancel()
        recheck = nil
        state = NotchLockState()
    }

    /// Whether the console session's screen is locked, from the window server's session dictionary; the key is
    /// present only while locked.
    nonisolated static var systemLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Ends an unlock at once, for when there is no lock on screen to animate.
    func skipUnlockAnimation() { apply { $0.opened(); $0.retracted() } }

    /// A lock or unlock notification. They can arrive late, after the opposite one, so the session decides, not the
    /// notification: a stale unlock never releases the notch while the Mac is locked, and a stale lock never conceals
    /// it after an unlock. Should the session not agree yet, it is read again with growing pauses (0.5, 1 and 2 s
    /// after the first), so a slow session flag cannot leave the notch hidden after an unlock. Internal so the checks
    /// can drive it.
    func screenLockChanged(_ locked: Bool) {
        recheck?.cancel()
        recheck = nil
        reconcile()
        guard sessionLocked() != locked else { return }
        recheck = Task { [weak self] in
            for factor in [1.0, 2, 4] {
                try? await Task.sleep(for: .seconds(Self.recheckDelay * factor))
                guard !Task.isCancelled, let self else { return }
                self.reconcile()
                if self.sessionLocked() == locked { break }
            }
            self?.recheck = nil
        }
    }

    private func cover(_ cover: NotchLockCover, _ on: Bool) { apply { $0.cover(cover, on) } }
    private func reconcile() {
        let locked = sessionLocked()
        apply { $0.reconcile(locked: locked) }
    }

    /// Changes the state and schedules the next animation step when a step begins; a lock cancels the pending one.
    /// Internal so the checks can drive it without posting system-wide lock notifications.
    func apply(_ change: (inout NotchLockState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let previous = state.phase
        state = next
        // The observer may have moved the state on again; the step follows wherever it ended up.
        guard state.phase != previous else { return }
        step?.cancel()
        step = nil
        switch state.phase {
        case .opening: schedule(after: NotchLockState.openingDuration) { $0.opened() }
        case .retracting: schedule(after: NotchLockState.retractDuration) { $0.retracted() }
        case .locked, .unlocked: break
        }
    }

    private func schedule(after seconds: Double, _ change: @escaping (inout NotchLockState) -> Void) {
        step = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.apply(change)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, action: @escaping (NotchLockMonitor) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
}
