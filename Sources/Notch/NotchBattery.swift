import AppKit
import Combine
import IOKit.ps

/// The internal battery at one moment, as IOKit reports it.
struct NotchBatteryReading: Equatable {
    /// 0 to 1.
    var level: Float
    /// Power connected, whether or not the cell is still taking charge.
    var plugged: Bool
    /// On battery at or under the first warning threshold; the indicator turns red.
    var low: Bool { !plugged && level <= NotchBatteryWatch.thresholds[0] }
}

/// Decides which readings deserve an indicator: power connected or removed, or the level reaching 20 %, 10 % and
/// 5 % on battery. Each threshold fires once per discharge; connecting power re-arms them all. A level already
/// under a threshold at the first reading does not fire it, so a launch at 15 % only warns at 10 %. Unplugging
/// under a due threshold is reported as low, not as unplugged.
struct NotchBatteryWatch: Equatable {
    enum Event: Equatable {
        case plugged, unplugged, low
    }

    static let thresholds: [Float] = [0.2, 0.1, 0.05]
    private(set) var last: NotchBatteryReading?
    private var fired: Set<Int> = []

    mutating func update(_ reading: NotchBatteryReading) -> Event? {
        defer { last = reading }
        if reading.plugged {
            fired.removeAll()
            return last?.plugged == false ? .plugged : nil
        }
        let due = Self.thresholds.indices.filter { !fired.contains($0) && reading.level <= Self.thresholds[$0] }
        fired.formUnion(due)
        guard let last else { return nil }
        return !due.isEmpty ? .low : last.plugged ? .unplugged : nil
    }
}

/// Observes the internal battery through IOKit's power source notification, which fires on every level and
/// charger change, with no polling. Macs without a battery leave `available` false.
@MainActor
final class NotchBattery: ObservableObject {
    @Published private(set) var level: Float = 1
    @Published private(set) var plugged = false
    @Published private(set) var available = false
    var low: Bool { NotchBatteryReading(level: level, plugged: plugged).low }
    /// Called when a reading deserves an indicator; the level and charger state are read from the properties.
    var onChange: (() -> Void)?
    private var watch = NotchBatteryWatch()
    private var source: CFRunLoopSource?
    private var running = false
    /// The C callback carries no context, so it reaches the one live observer through this reference.
    private static weak var current: NotchBattery?

    /// A preview reading for fixtures; the real service starts from IOKit.
    init(previewLevel: Float? = nil, plugged: Bool = false) {
        if let previewLevel {
            level = previewLevel
            self.plugged = plugged
            available = true
        }
    }

    func start() {
        guard !running else { return }
        running = true
        Self.current = self
        let callback: IOPowerSourceCallbackType = { _ in
            Task { @MainActor in NotchBattery.current?.refresh(notify: true) }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
        refresh(notify: false)
    }

    func stop() {
        running = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    /// The SF Symbol for a level, filled to the nearest quarter; anything above empty keeps at least a quarter so
    /// a low battery still reads as a battery with a little charge.
    static func symbol(for level: Float) -> String {
        let quarters = level > 0 ? max(1, Int((level * 4).rounded())) : 0
        return "battery.\(min(4, quarters) * 25)percent"
    }

    private func refresh(notify: Bool) {
        guard running else { return }
        guard let reading = Self.read() else { available = false; return }
        available = true
        level = reading.level
        plugged = reading.plugged
        let event = watch.update(reading)
        if notify, event != nil { onChange?() }
    }

    /// The first internal battery in IOKit's power source list.
    private static func read() -> NotchBatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return NotchBatteryReading(level: max(0, min(1, Float(current) / Float(maximum))),
                                       plugged: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
