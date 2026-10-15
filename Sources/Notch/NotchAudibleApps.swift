import AppKit
import CoreAudio

/// Which apps make sound, from Core Audio's process objects. A process's audio is credited to the app responsible
/// for it, so Safari's WebKit GPU process counts as Safari and a browser's helpers as the browser. Event driven:
/// on macOS 27 `kAudioProcessPropertyIsRunningOutput` posts no change notifications, but `kAudioProcessPropertyIsRunning`
/// does whenever a process starts or stops output, also for other processes (measured 7 October), so each process
/// object is watched for both and its output read again. A process whose audio keeps running for input, as during a
/// call, starts and stops output without either notifying, and so does one already outputting that starts or stops
/// input. `kAudioProcessPropertyIsRunningInput` posts no change notifications either; the default input device's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` does when the first process starts input or the last stops, so it
/// is watched and every process's input read again. While the pick waits on some apps (`polled`) and that device
/// runs somewhere, or one of them runs input elsewhere, every process is read again every `pollInterval`. Reads only;
/// no permission is needed.
@MainActor
final class NotchAudibleApps {
    /// Apps with a process running output now; nil until started, or when Core Audio cannot list processes.
    private(set) var heard: Set<String>?
    /// Apps Core Audio has a process object for, playing or not.
    private(set) var voiced: Set<String> = []
    /// Called after `heard` or `voiced` changes, or a process starts or stops input or output, with the apps whose
    /// processes did.
    var onChange: ((_ stirred: Set<String>) -> Void)?
    /// Apps whose output the pick waits on, see `NotchSourcePick.watched`. Polls only while input runs, on the
    /// default input device or in one of them, which keeps their input or output changing from being announced.
    var polled: Set<String> = [] {
        didSet { if polled != oldValue { updatePoll() } }
    }
    static let pollInterval: Duration = .seconds(3)
    /// Apps with a process running input, as Safari on a call.
    private(set) var capturing: Set<String> = []
    /// Whether the default input device runs for any process, which can be another app than the one starting input.
    private var inputRunning = false
    /// The processes running input or output by app, so an app with one process starting or stopping while another
    /// keeps it heard counts as stirred.
    private var streams: [String: Set<Stream>] = [:]
    private struct Stream: Hashable {
        var pid: pid_t
        var input: Bool
    }
    private var poll: Task<Void, Never>?
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// Watches the system's process list and default input device, and that device running somewhere.
    private var listWatch: AudioObjectPropertyListenerBlock?
    private var input: AudioObjectID?
    private var apps: [pid_t: String] = [:]
    private var pending = false

    func start() {
        guard listWatch == nil else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.schedule() } }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr else {
            return
        }
        var inputAddress = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, .main, block)
        listWatch = block
        read()
    }

    func stop() {
        if let listWatch {
            for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultInputDevice] {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listWatch)
            }
        }
        watchInput(nil)
        listWatch = nil
        for object in Array(watched.keys) { unwatch(object) }
        apps = [:]
        heard = nil
        voiced = []
        capturing = []
        inputRunning = false
        streams = [:]
        updatePoll()
    }

    /// Moves the watch for input running somewhere to `device`, the default input device, or removes it for nil.
    private func watchInput(_ device: AudioObjectID?) {
        guard device != input, let listWatch else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if let input { AudioObjectRemovePropertyListenerBlock(input, &address, .main, listWatch) }
        input = device.flatMap { AudioObjectAddPropertyListenerBlock($0, &address, .main, listWatch) == noErr ? $0 : nil }
    }

    /// Starts or stops the poll as `polled`, `capturing` and `inputRunning` change.
    private func updatePoll() {
        guard listWatch != nil, !polled.isEmpty, inputRunning || !polled.isDisjoint(with: capturing) else {
            poll?.cancel()
            poll = nil
            return
        }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.read()
            }
        }
    }

    /// Several processes often change at once; one read on a later turn of the main actor takes them all.
    private func schedule() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            self?.pending = false
            self?.read()
        }
    }

    private func read() {
        guard listWatch != nil else { return }
        guard let objects = Self.processObjects() else {
            if heard != nil { heard = nil; onChange?([]) }
            return
        }
        let device = Self.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                as: AudioObjectID.self)
        watchInput(device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 })
        let inputRunning = input.flatMap { Self.value($0, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32.self) } == 1
        for object in Set(watched.keys).subtracting(objects) { unwatch(object) }
        var voiced = Set<String>(), streams: [String: Set<Stream>] = [:], pids = Set<pid_t>()
        for object in objects {
            watch(object)
            let pid = Self.value(object, kAudioProcessPropertyPID, as: pid_t.self) ?? -1
            guard pid > 0, let app = app(for: pid, object: object) else { continue }
            pids.insert(pid)
            voiced.insert(app)
            for (selector, input) in [(kAudioProcessPropertyIsRunningInput, true), (kAudioProcessPropertyIsRunningOutput, false)]
            where Self.value(object, selector, as: UInt32.self) == 1 {
                streams[app, default: []].insert(Stream(pid: pid, input: input))
            }
        }
        apps = apps.filter { pids.contains($0.key) }
        let stirred = Set(streams.keys).union(self.streams.keys).filter { streams[$0] != self.streams[$0] }
        self.streams = streams
        let capturing = Set(streams.filter { $0.value.contains(where: \.input) }.keys)
        if capturing != self.capturing || inputRunning != self.inputRunning {
            (self.capturing, self.inputRunning) = (capturing, inputRunning)
            updatePoll()
        }
        let heard = Set(streams.filter { $0.value.contains { !$0.input } }.keys)
        guard heard != self.heard || voiced != self.voiced || !stirred.isEmpty else { return }
        self.heard = heard
        self.voiced = voiced
        onChange?(stirred)
    }

    /// The process properties watched: output's own, in case a later macOS notifies for it, and audio running at all.
    private static let watchedProperties = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]

    private func watch(_ object: AudioObjectID) {
        guard watched[object] == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.schedule() } }
        for selector in Self.watchedProperties {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        }
        watched[object] = block
    }

    private func unwatch(_ object: AudioObjectID) {
        guard let block = watched.removeValue(forKey: object) else { return }
        for selector in Self.watchedProperties {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    /// The bundle identifier of the app responsible for `pid`, else of the process itself, cached per process.
    private func app(for pid: pid_t, object: AudioObjectID) -> String? {
        if let app = apps[pid] { return app }
        let responsible = Self.responsible.map { $0(pid) } ?? -1
        let app = (responsible > 0 ? NSRunningApplication(processIdentifier: responsible)?.bundleIdentifier : nil)
            ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            ?? Self.string(object, kAudioProcessPropertyBundleID)
        guard let app, !app.isEmpty else { return nil }
        apps[pid] = app
        return app
    }

    /// libsystem's `responsibility_get_pid_responsible_for_pid`, private but present since macOS 10.14; looked up
    /// at run time so a system without it only loses the credit for helper processes.
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func value<T: BinaryInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                as type: T.Type) -> T? {
        var address = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
