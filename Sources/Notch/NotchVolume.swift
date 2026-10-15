import AppKit
import Combine
import CoreAudio
import AudioToolbox

/// Observes the current output device through CoreAudio callbacks, with no idle polling loop.
@MainActor
final class NotchVolume: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var available = false
    /// Called after the level or mute state changed outside this object, such as the Control Center slider.
    /// Own writes and binding a new device read back silently, so neither counts as a change.
    var onChange: (() -> Void)?
    private var audioDevice = AudioDeviceID(0)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.bindOutputDevice() }
        }
        defaultOutputListener = listener
        var address = outputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        bindOutputDevice()
    }

    func stop() {
        guard running else { return }
        running = false
        if let listener = defaultOutputListener {
            var address = outputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        defaultOutputListener = nil
        unbindOutputDevice()
    }

    func setVolume(_ value: Float) {
        guard available, value.isFinite else { return }
        var address = volumeAddress
        var newValue = max(0, min(1, value))
        AudioObjectSetPropertyData(audioDevice, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &newValue)
        refreshVolume(notify: false)
    }

    func setMuted(_ value: Bool) {
        guard available else { return }
        var address = muteAddress
        var newValue: UInt32 = value ? 1 : 0
        AudioObjectSetPropertyData(audioDevice, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &newValue)
        refreshVolume(notify: false)
    }

    private var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func bindOutputDevice() {
        guard running else { return }
        unbindOutputDevice()
        var address = outputAddress
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &audioDevice) == noErr else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshVolume(notify: true) }
        }
        volumeListener = listener
        for var property in [volumeAddress, muteAddress] {
            AudioObjectAddPropertyListenerBlock(audioDevice, &property, .main, listener)
        }
        refreshVolume(notify: false)
    }

    private func unbindOutputDevice() {
        if let listener = volumeListener, audioDevice != 0 {
            for var address in [volumeAddress, muteAddress] {
                AudioObjectRemovePropertyListenerBlock(audioDevice, &address, .main, listener)
            }
        }
        volumeListener = nil
        audioDevice = 0
        available = false
    }

    private func refreshVolume(notify: Bool) {
        guard running, audioDevice != 0 else { return }
        var address = volumeAddress
        var size = UInt32(MemoryLayout<Float>.size)
        var value: Float = 0
        let readable = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &value) == noErr
        var settable = DarwinBoolean(false)
        AudioObjectIsPropertySettable(audioDevice, &address, &settable)
        let previous = (level, muted)
        available = readable && settable.boolValue
        level = readable ? max(0, min(1, value)) : 0
        address = muteAddress
        size = UInt32(MemoryLayout<UInt32>.size)
        var mute: UInt32 = 0
        muted = AudioObjectGetPropertyData(audioDevice, &address, 0, nil, &size, &mute) == noErr && mute != 0
        if notify, previous != (level, muted) { onChange?() }
    }

}
