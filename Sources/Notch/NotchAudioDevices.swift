import AppKit
import Combine
import CoreAudio
import os

/// An output device as the indicator sees it: Core Audio's stable UID, its name and the SF Symbol drawn for it.
struct NotchAudioDevice: Equatable {
    let uid: String
    let name: String
    let transport: UInt32

    /// Built-in speakers, virtual devices (Teams, BlackHole) and aggregates are never announced; headphones in the
    /// jack are, although macOS reports them as built-in too.
    var announced: Bool {
        switch transport {
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeUnknown: false
        case kAudioDeviceTransportTypeBuiltIn: name.localizedCaseInsensitiveContains("headphone")
        default: true
        }
    }

    /// Product names first, since AirPods, Beats and HomePod all arrive over Bluetooth or AirPlay; then the transport.
    var symbol: String {
        let products: [(String, String)] = [
            ("AirPods Max", "airpods.max"), ("AirPods Pro", "airpods.pro"), ("AirPods", "airpods"),
            ("Powerbeats", "beats.powerbeats.pro"), ("Studio Buds", "beats.studiobuds"), ("Beats Fit", "beats.fitpro"),
            ("Beats", "beats.headphones"), ("HomePod mini", "homepodmini.fill"), ("HomePod", "homepod.fill"),
            ("Buds", "earbuds"), ("Headphone", "headphones")
        ]
        if let match = products.first(where: { name.localizedCaseInsensitiveContains($0.0) }) { return match.1 }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// What the closed notch shows for an output device: it became the output, or a device that had been the output
/// went away.
struct NotchAudioChange: Equatable {
    let device: NotchAudioDevice
    let connected: Bool
}

/// The output devices and the default output at one moment.
struct NotchAudioRoute: Equatable {
    var devices: [NotchAudioDevice]
    var output: NotchAudioDevice?
}

/// Decides which route changes deserve an indicator. Switching the output to an announced device shows it as
/// connected; removing a device that was the output at some point since it appeared shows it as disconnected,
/// whether macOS moved the output away before or after removing it. A device that only appears, such as a display
/// that is not made the output, shows nothing; the first route is the baseline. When both happen at once, the new
/// output wins.
struct NotchAudioWatch: Equatable {
    private(set) var last: NotchAudioRoute?
    private var used: [String: NotchAudioDevice] = [:]

    mutating func update(_ route: NotchAudioRoute) -> NotchAudioChange? {
        defer { last = route }
        let present = Set(route.devices.map(\.uid))
        let gone = used.values.filter { !present.contains($0.uid) }.sorted { $0.uid < $1.uid }
        for device in gone { used[device.uid] = nil }
        if let output = route.output { used[output.uid] = output }
        guard let last else { return nil }
        if let output = route.output, output.uid != last.output?.uid, output.announced {
            return NotchAudioChange(device: output, connected: true)
        }
        return gone.first(where: \.announced).map { NotchAudioChange(device: $0, connected: false) }
    }
}

/// Watches the default output device and the device list through Core Audio property listeners, with no polling,
/// and reports changes `NotchAudioWatch` keeps. Battery levels are not shown: no public macOS API reports them for
/// audio accessories.
@MainActor
final class NotchAudioDevices: ObservableObject {
    /// The current output, for the Connectivity page and the player's Output button.
    @Published private(set) var output: NotchAudioDevice?
    /// Every device that can play sound, for the Output button's menu.
    @Published private(set) var devices: [NotchAudioDevice] = []
    var onChange: ((NotchAudioChange) -> Void)?
    private var watch = NotchAudioWatch()
    private var listener: AudioObjectPropertyListenerBlock?
    private var running = false
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "audio")

    private static let addresses = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard !running else { return }
        running = true
        // Each start reads a fresh baseline, so nothing that changed during sleep is announced on wake.
        watch = NotchAudioWatch()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh(notify: true) }
        }
        self.listener = listener
        for var address in Self.addresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        refresh(notify: false)
    }

    func stop() {
        guard running else { return }
        running = false
        if let listener {
            for var address in Self.addresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
        listener = nil
    }

    private func refresh(notify: Bool) {
        guard running else { return }
        let route = Self.read()
        output = route.output
        devices = route.devices
        let change = watch.update(route)
        if notify {
            log.notice("Output \(route.output?.name ?? "none", privacy: .public), \(route.devices.count) devices; \(change.map { "\($0.device.name) \($0.connected ? "connected" : "gone")" } ?? "nothing to show", privacy: .public)")
        }
        if let change, notify { onChange?(change) }
    }

    /// Makes `device` the default output, as picking it in Control Center does. The listener then reports the change
    /// like any other, so the wings announce it once the notch closes.
    func select(_ device: NotchAudioDevice) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = device.uid as CFString
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard status == noErr, id != 0 else { return }
        address = Self.addresses[0]
        AudioObjectSetPropertyData(system, &address, 0, nil, size, &id)
    }

    /// Devices with at least one output stream, and the default output among them. A device that is going away can
    /// fail to answer; it is left out rather than reported half-read.
    private static func read() -> NotchAudioRoute {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = addresses[1]
        var size: UInt32 = 0
        var ids: [AudioObjectID] = []
        if AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr {
            ids = Array(repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) != noErr { ids = [] }
        }
        address = addresses[0]
        var outputID = AudioObjectID(0)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &outputID) != noErr { outputID = 0 }
        var devices: [NotchAudioDevice] = []
        var output: NotchAudioDevice?
        for id in ids where hasOutput(id) {
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { continue }
            let device = NotchAudioDevice(uid: uid, name: name, transport: transport(id))
            devices.append(device)
            if id == outputID { output = device }
        }
        return NotchAudioRoute(devices: devices, output: output)
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func transport(_ id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : kAudioDeviceTransportTypeUnknown
    }
}
