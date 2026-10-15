// Private SkyLight API, adapted from two sources:
// - SkyLightWindow by Lakr Aream, `Sources/SkyLightWindow/SkyLightOperator.swift` (MIT License, copyright 2025
//   Lakr Aream), https://github.com/Lakr233/SkyLightWindow: the space at an absolute level above the lock screen
//   and the call that moves a window into it.
// - boring.notch, `boringNotch/components/Notch/BoringNotchSkyLightWindow.swift` (GNU General Public License v3.0),
//   https://github.com/TheBoredTeam/boring.notch: taking the window back out with `SLSRemoveWindowsFromSpaces`.
// Changes: symbols resolve one by one and a missing one disables the feature instead of crashing; space IDs are
// 64 bit as in the window server's own headers; the space is created per lock and destroyed after unlock rather
// than living for the whole process. See docs/lock-screen.md for what is private and how it fails.
//
// The parts adapted from SkyLightWindow keep its license notice:
//
// MIT License
//
// Copyright (c) 2025 Lakr Aream
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit

/// A window server space shown above the lock screen. The lock screen is itself a space at absolute level 300;
/// windows moved into a space at 400, the level macOS uses for notifications over the lock screen, draw above it.
/// Nothing here touches authentication: the windows only draw, and the lock screen keeps the keyboard.
@MainActor
final class NotchLockSpace {
    /// `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`.
    private static let level: Int32 = 400
    private static let calls = SkyLight()
    /// False when this macOS lacks one of the calls; the lock screen windows then stay in the normal window list,
    /// hidden by the lock screen and seen only after unlocking.
    static var available: Bool { calls != nil }

    private var id: UInt64?
    private var windows: [Int] = []

    /// A space exists and must still be destroyed.
    var active: Bool { id != nil }

    /// Moves a window into the space, creating and showing the space on first use. Returns false if it could not.
    @discardableResult
    func adopt(_ window: NSWindow) -> Bool {
        guard let calls = Self.calls, window.windowNumber > 0 else { return false }
        let connection = calls.mainConnection()
        if id == nil {
            let created = calls.create(connection, 1, nil)
            guard created != 0 else { return false }
            calls.setLevel(connection, created, Self.level)
            calls.show(connection, [NSNumber(value: created)] as CFArray)
            id = created
        }
        guard let id else { return false }
        let window = window.windowNumber
        // 7 moves the window out of every other space at once, as SkyLightWindow does.
        calls.addWindows(connection, id, [NSNumber(value: window)] as CFArray, 7)
        if !windows.contains(window) { windows.append(window) }
        // The calls report nothing useful (macOS 27.2 returns 3 even when the move works), so ask where it landed.
        return calls.spaces(connection, window).contains(id)
    }

    /// Takes one adopted window back out before it closes; the last one out releases the space, so closing the windows
    /// one by one leaves no space behind.
    func remove(_ window: NSWindow) {
        let number = window.windowNumber
        guard let index = windows.firstIndex(of: number) else { return }
        windows.remove(at: index)
        if let calls = Self.calls, let id {
            calls.removeWindows(calls.mainConnection(), [NSNumber(value: number)] as CFArray, [NSNumber(value: id)] as CFArray)
        }
        if windows.isEmpty { release() }
    }

    /// Takes the adopted windows back out, then hides and destroys the space, so no space outlives a lock. Call it
    /// before closing the windows. Safe to call when nothing was adopted.
    func release() {
        guard let calls = Self.calls, let id else { return }
        let connection = calls.mainConnection()
        let spaces = [NSNumber(value: id)] as CFArray
        if !windows.isEmpty {
            calls.removeWindows(connection, windows.map { NSNumber(value: $0) } as CFArray, spaces)
        }
        calls.hide(connection, spaces)
        calls.destroy(connection, id)
        windows.removeAll()
        self.id = nil
    }
}

/// The SkyLight functions this needs, resolved by name at run time. Nil if the framework or any symbol is missing.
/// Their results are declared away: the window server's answers are not documented and not reliable.
private struct SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias Create = @convention(c) (Int32, Int, UnsafeRawPointer?) -> UInt64
    typealias Destroy = @convention(c) (Int32, UInt64) -> Void
    typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Void
    typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    let mainConnection: MainConnection
    let create: Create
    let destroy: Destroy
    let setLevel: SetLevel
    let show: Spaces
    let hide: Spaces
    let addWindows: AddWindows
    let removeWindows: RemoveWindows
    let copySpaces: CopySpaces

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let mainConnection = load("SLSMainConnectionID", as: MainConnection.self),
              let create = load("SLSSpaceCreate", as: Create.self),
              let destroy = load("SLSSpaceDestroy", as: Destroy.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = load("SLSShowSpaces", as: Spaces.self),
              let hide = load("SLSHideSpaces", as: Spaces.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self),
              let removeWindows = load("SLSRemoveWindowsFromSpaces", as: RemoveWindows.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpaces.self) else { return nil }
        self.mainConnection = mainConnection
        self.create = create
        self.destroy = destroy
        self.setLevel = setLevel
        self.show = show
        self.hide = hide
        self.addWindows = addWindows
        self.removeWindows = removeWindows
        self.copySpaces = copySpaces
    }

    /// The spaces a window is in; 0xF includes spaces this app created, which the user's own Spaces mask leaves out.
    func spaces(_ connection: Int32, _ window: Int) -> [UInt64] {
        let list = copySpaces(connection, 0xF, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return list?.map(\.uint64Value) ?? []
    }
}
