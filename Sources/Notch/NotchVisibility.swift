import AppKit
import os

/// What is happening around the notch that may hide it. The monitor reports it; the settings decide.
struct NotchSurroundings: Equatable {
    /// The notch's display shows a fullscreen Space.
    var fullscreen = false
    var missionControl = false
    /// The frontmost app is a game.
    var game = false

    func hide(_ settings: NotchSettings) -> Bool {
        (fullscreen && settings.hideInFullscreen) || (missionControl && settings.hideInMissionControl)
            || (game && settings.hideWhileGaming)
    }

    /// A fullscreen Space is type 4 in the private managed Spaces list, with a tile layout for split view; the
    /// approach MacroVisionKit (MIT) takes for boring.notch. With "Displays have separate Spaces" off, the one entry
    /// is called "Main" and covers every display.
    static func fullscreen(spaces: [[String: Any]], display id: String) -> Bool {
        guard let entry = spaces.first(where: { $0["Display Identifier"] as? String == id })
                ?? spaces.first(where: { $0["Display Identifier"] as? String == "Main" }),
              let current = entry["Current Space"] as? [String: Any] else { return false }
        return current["type"] as? Int == 4 || current["TileLayoutManager"] != nil
    }

    /// Mission Control is drawn by WindowManager, the process behind Stage Manager, as a display-sized backdrop at
    /// a positive window level (19 on macOS 27) under the Spaces bar; otherwise its windows sit below the desktop
    /// icons at negative levels. The Dock is no help: on macOS 27 it keeps one display-sized window at level 20
    /// whenever it is visible, Mission Control or not. Bounds are top-left based, so only sizes are compared.
    static func missionControl(windows: [[String: Any]], windowManager pid: pid_t, displays: [CGSize]) -> Bool {
        windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return displays.contains(rect.size)
        }
    }

    /// Games declare a games category in their Info.plist (`public.app-category.games` or a subcategory such as
    /// `public.app-category.action-games`). Steam games often declare none, so anything in a Steam library counts too.
    static func game(category: String?, path: String) -> Bool {
        if let category, category.hasPrefix("public.app-category."), category.hasSuffix("games") { return true }
        return path.contains("/steamapps/common/")
    }
}

/// Watches the conditions of `NotchSurroundings` without timers. Fullscreen and games are read on Space changes,
/// app activation and display changes. Mission Control has no public event, and on macOS 27 the Dock no longer
/// posts the `AXExpose…` accessibility notifications yabai relied on, so two private WindowServer notifications that
/// fire as windows order in and out (1325 and 1326, found by experiment on 3 October 2026) wake a check of the public
/// window list for Mission Control's backdrop; one trailing check after a burst catches the backdrop leaving once its
/// closing animation ends. If a later macOS renumbers those events, Mission Control is no longer noticed and the
/// notch simply stays visible there.
@MainActor
final class NotchVisibilityMonitor {
    private(set) var surroundings = NotchSurroundings()
    var onChange: ((NotchSurroundings) -> Void)?
    /// The display whose Spaces count for fullscreen, as `NotchDisplay.id`.
    var display = "" { didSet { if display != oldValue { refresh() } } }
    /// The window list is only read while hiding in Mission Control is on.
    var watchesMissionControl = false { didSet { if watchesMissionControl != oldValue { refresh() } } }
    private var observers: [NSObjectProtocol] = []
    private var trailingCheck: Task<Void, Never>?
    private var running = false
    private static let skyLight = SkyLightAPI()
    private static var registered = false
    /// The C callback carries no context, so it reaches the one live monitor through this reference.
    private static weak var current: NotchVisibilityMonitor?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "visibility")

    func start() {
        guard !running else { return }
        running = true
        Self.current = self
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchVisibilityMonitor.current?.refresh() }
            })
        }
        if !Self.registered, let api = Self.skyLight.functions {
            // Registration lasts for the process; a stopped monitor ignores the callbacks.
            let callback: SkyLightAPI.NotifyProc = { _, _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { NotchVisibilityMonitor.current?.windowsChanged() } }
            }
            let connection = api.mainConnection()
            Self.registered = [1325, 1326].allSatisfy { api.register(connection, callback, $0, nil) == 0 }
            if !Self.registered { log.notice("WindowServer notifications unavailable; Mission Control is not detected") }
        }
        refresh()
    }

    func stop() {
        running = false
        trailingCheck?.cancel()
        trailingCheck = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        update(NotchSurroundings())
    }

    /// Reads every condition again.
    func refresh() {
        guard running else { return }
        var next = NotchSurroundings()
        if let spaces = Self.skyLight.functions?.managedSpaces() {
            next.fullscreen = NotchSurroundings.fullscreen(spaces: spaces, display: display)
        }
        if let app = NSWorkspace.shared.frontmostApplication, let url = app.bundleURL {
            let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String
            next.game = NotchSurroundings.game(category: category, path: url.path)
        }
        next.missionControl = watchesMissionControl && Self.missionControlOpen()
        update(next)
    }

    private func windowsChanged() {
        guard running, watchesMissionControl else { return }
        refresh()
        trailingCheck?.cancel()
        trailingCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func update(_ next: NotchSurroundings) {
        guard next != surroundings else { return }
        log.notice("Fullscreen \(next.fullscreen), Mission Control \(next.missionControl), game \(next.game)")
        surroundings = next
        onChange?(next)
    }

    private static func missionControlOpen() -> Bool {
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return NotchSurroundings.missionControl(windows: windows, windowManager: manager.processIdentifier,
                                                displays: NSScreen.screens.map(\.frame.size))
    }
}

/// The private SkyLight calls the monitor needs, looked up at runtime so a macOS release without them only turns
/// fullscreen and Mission Control detection off.
private struct SkyLightAPI {
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void

    struct Functions {
        let mainConnection: @convention(c) () -> Int32
        let copySpaces: @convention(c) (Int32) -> Unmanaged<CFArray>?
        let register: @convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

        func managedSpaces() -> [[String: Any]]? {
            copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        }
    }

    let functions: Functions?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let spaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let register = dlsym(handle, "SLSRegisterConnectionNotifyProc") else {
            functions = nil
            return
        }
        functions = Functions(mainConnection: unsafeBitCast(connection, to: (@convention(c) () -> Int32).self),
                              copySpaces: unsafeBitCast(spaces, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self),
                              register: unsafeBitCast(register, to: (@convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32).self))
    }
}
