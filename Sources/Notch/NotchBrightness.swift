import AppKit
import Combine

/// Observes the notch display's brightness through the private DisplayServices framework.
/// Symbols are looked up at runtime, so a macOS release without them only leaves `available` false.
/// Registration is never undone: the unregister call's signature is undocumented, and a stale callback is ignored.
@MainActor
final class NotchBrightness: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var available = false
    /// Called after the level changed while running, such as a brightness key press or the Control Center slider.
    var onChange: (() -> Void)?
    private var running = false
    private var registered = false
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private static let api = DisplayServicesAPI()
    /// The C callback carries no context, so it reaches the one live observer through this reference.
    private static weak var current: NotchBrightness?

    func start() {
        guard !running else { return }
        running = true
        Self.current = self
        displayID = Self.notchDisplayID()
        guard let api = Self.api.functions, api.canChange(displayID) else {
            available = false
            return
        }
        if !registered {
            // Only the registration matters; the callback's parameters are not relied on.
            let callback: DisplayServicesAPI.Callback = { _, _, _, _ in
                Task { @MainActor in NotchBrightness.current?.refresh(notify: true) }
            }
            registered = api.register(displayID, displayID, callback) == 0
        }
        refresh(notify: false)
    }

    func stop() {
        running = false
    }

    /// Writes the level the way the brightness keys do and caches it at once, so a held key steps from the new
    /// value rather than waiting for the change notification. The notification then finds nothing to report.
    func setLevel(_ value: Float) {
        guard available, value.isFinite, let api = Self.api.functions else { return }
        let clamped = max(0, min(1, value))
        guard api.set(displayID, clamped) == 0 else { return }
        level = clamped
    }

    private func refresh(notify: Bool) {
        guard running, let api = Self.api.functions else { return }
        var value: Float = 0
        guard api.get(displayID, &value) == 0 else { available = false; return }
        let clamped = max(0, min(1, value))
        let changed = clamped != level
        available = true
        level = clamped
        if notify, changed { onChange?() }
    }

    /// The display with the camera housing, or the main display when there is none.
    private static func notchDisplayID() -> CGDirectDisplayID {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}

/// Function pointers from DisplayServices, resolved once with dlsym.
private struct DisplayServicesAPI {
    typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    struct Functions {
        let get: @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let set: @convention(c) (CGDirectDisplayID, Float) -> Int32
        let canChange: @convention(c) (CGDirectDisplayID) -> Bool
        let register: @convention(c) (CGDirectDisplayID, CGDirectDisplayID, Callback) -> Int32
    }
    let functions: Functions?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") else {
            functions = nil
            return
        }
        functions = Functions(get: unsafeBitCast(get, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self),
                              set: unsafeBitCast(set, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self),
                              canChange: unsafeBitCast(canChange, to: (@convention(c) (CGDirectDisplayID) -> Bool).self),
                              register: unsafeBitCast(register, to: (@convention(c) (CGDirectDisplayID, CGDirectDisplayID, Callback) -> Int32).self))
    }
}
