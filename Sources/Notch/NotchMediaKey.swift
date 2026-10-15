import AppKit

/// The keyboard keys the notch can take over from macOS: volume and display brightness. Caps Lock, below, is only observed.
enum NotchMediaKey: Equatable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    /// One key press moves the level by a sixteenth, like macOS; Option and Shift together make it a quarter of that.
    static let step: Float = 1 / 16
    static let fineStep: Float = 1 / 64
}

/// A decoded media key event. macOS delivers these as system-defined events with the key packed into `data1`.
struct NotchMediaKeyPress: Equatable {
    let key: NotchMediaKey
    let down: Bool
    let fine: Bool

    /// Decodes an `NX_SYSDEFINED` event of subtype 8. The key code sits in the high half of `data1`, the key
    /// state (0xA down, 0xB up) in the next byte. Other keys, such as play/pause, return nil and pass through.
    init?(subtype: Int, data1: Int, modifiers: NSEvent.ModifierFlags) {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        default: return nil
        }
        down = state == 0xA
        fine = modifiers.contains(.option) && modifiers.contains(.shift)
    }

    var stepSize: Float { fine ? NotchMediaKey.fineStep : NotchMediaKey.step }
}

/// Turns the modifier flags of `flagsChanged` events into Caps Lock changes. Every modifier key posts such an
/// event, so only a flip of the Caps Lock bit counts, and the state at start is the baseline, which shows nothing.
/// Nothing but that bit is read: no key codes, no other keys.
struct NotchCapsLockWatch {
    private var on: Bool

    init(flags: CGEventFlags) { on = flags.contains(.maskAlphaShift) }

    /// Returns the new state when Caps Lock flipped, nil for any other modifier change.
    mutating func update(_ flags: CGEventFlags) -> Bool? {
        let now = flags.contains(.maskAlphaShift)
        guard now != on else { return nil }
        on = now
        return now
    }
}
