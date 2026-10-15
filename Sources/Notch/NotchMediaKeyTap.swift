import AppKit
import Combine
import os

/// Swallows volume and brightness keys before macOS sees them, so its own indicator never appears, and hands
/// each press to the app. A press the app reports as unhandled passes through, so macOS keeps behaving as
/// usual for a display or output device the app cannot adjust. Needs the Accessibility permission: without it
/// `available` stays false and the tap is created as soon as macOS reports the grant; a revoked grant drops it
/// again. Only these five keys are affected; nothing is recorded. The same tap observes Caps Lock: it reads the
/// Caps Lock bit of modifier changes and passes every one of them on untouched.
@MainActor
final class NotchMediaKeyTap: ObservableObject {
    @Published private(set) var available = false
    /// Returns true when the press was handled and must not reach macOS.
    var onPress: ((NotchMediaKeyPress) -> Bool)?
    /// Called with the new state when Caps Lock turns on or off.
    var onCapsLock: ((Bool) -> Void)?
    private var capsLock = NotchCapsLockWatch(flags: [])
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Present from `start()` to `stop()`: it is both the permission watcher and the sign that the tap is wanted.
    private var grantObserver: NSObjectProtocol?
    private var retry: Task<Void, Never>?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "keys")
    private static weak var current: NotchMediaKeyTap?

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// Posted by macOS whenever the Accessibility list changes, including the user's switch for this app.
    private static let grantChanged = Notification.Name("com.apple.accessibility.api")

    /// Whether macOS lists the app as trusted under Accessibility right now.
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS permission dialog, which also lists the app under Accessibility; afterwards the user
    /// grants it in System Settings.
    static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    func start() {
        Self.current = self
        if grantObserver == nil {
            grantObserver = DistributedNotificationCenter.default().addObserver(forName: Self.grantChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.grantDidChange() }
            }
        }
        if tap == nil, !createTap() { reconcileShortly() }
    }

    func stop() {
        retry?.cancel()
        retry = nil
        if let grantObserver { DistributedNotificationCenter.default().removeObserver(grantObserver) }
        grantObserver = nil
        dropTap()
    }

    private func createTap() -> Bool {
        // NX_SYSDEFINED is event type 14, which CGEventType does not name. Modifier changes are only observed;
        // an active tap needs Accessibility alone, where a listen-only one for them would need Input Monitoring.
        let mask: CGEventMask = 1 << 14 | 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in NotchMediaKeyTap.current?.reenable(after: type) }
                return Unmanaged.passUnretained(event)
            }
            if type == .flagsChanged {
                let flags = event.flags
                MainActor.assumeIsolated { NotchMediaKeyTap.current?.flagsChanged(flags) }
                return Unmanaged.passUnretained(event)
            }
            guard let nsEvent = NSEvent(cgEvent: event),
                  let press = NotchMediaKeyPress(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1,
                                                 modifiers: nsEvent.modifierFlags) else {
                return Unmanaged.passUnretained(event)
            }
            // The tap's source sits on the main run loop, so this already runs on the main thread. The decision
            // has to be synchronous: once the callback returns, the event is either gone or delivered.
            let handled = MainActor.assumeIsolated { NotchMediaKeyTap.current?.onPress?(press) ?? false }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            if available { available = false }
            log.notice("\(Self.trusted ? "Tap not created although Accessibility is granted" : "Tap not created: Accessibility not granted yet", privacy: .public)")
            return false
        }
        self.tap = tap
        // Whatever Caps Lock did while the tap was away is the new baseline, not a change.
        capsLock = NotchCapsLockWatch(flags: CGEventSource.flagsState(.combinedSessionState))
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        available = true
        log.notice("Tap created")
        return true
    }

    private func dropTap() {
        if tap != nil { log.notice("Tap dropped; trusted \(Self.trusted)") }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        available = false
    }

    private func grantDidChange() { reconcileShortly() }

    private func flagsChanged(_ flags: CGEventFlags) {
        if let on = capsLock.update(flags) { onCapsLock?(on) }
    }

    /// Brings the tap in line with the grant over the next three seconds: created once a new grant is readable,
    /// dropped once a revoked one is. tccd reports a change slightly before the list reads that way, and a tap
    /// that failed at launch may only need a later attempt, hence the repeated checks.
    private func reconcileShortly() {
        retry?.cancel()
        retry = Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, grantObserver != nil else { return }
                if Self.trusted {
                    if tap != nil || createTap() { return }
                } else if tap != nil {
                    dropTap()
                }
            }
        }
    }

    /// macOS switches a tap off when its callback is slow; switching it back on keeps the keys working.
    private func reenable(after type: CGEventType) {
        guard let tap else { return }
        log.notice("Tap disabled by macOS (\(type == .tapDisabledByTimeout ? "slow callback" : "user input", privacy: .public)); re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
