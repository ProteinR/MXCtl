import CoreAudio
import Foundation

/// The mic mute key: the mute flag of the default input device, the same flag Logi Options+ set
/// (MeetRec reads it to tell a muted mic from a broken one). A device without a mute flag gets its
/// input volume set to 0 and back.
enum Microphone {
    private static var volumeBeforeMute: [AudioDeviceID: Float32] = [:]

    /// Toggles; returns the new state (true = muted), nil when there is no input device.
    static func toggle() -> Bool? {
        guard let device = defaultInput() else {
            Log.warning("Mic mute: no default input device", "mic")
            return nil
        }
        let name = deviceName(device) ?? "?"
        var mute: UInt32 = 0
        if read(device, kAudioDevicePropertyMute, &mute), isSettable(device, kAudioDevicePropertyMute) {
            var value: UInt32 = mute == 0 ? 1 : 0
            let ok = write(device, kAudioDevicePropertyMute, &value)
            Log.info("Mic \(name): mute flag → \(value)\(ok ? "" : " FAILED")", "mic")
            return ok ? value == 1 : mute != 0
        }
        var volume: Float32 = 1
        guard read(device, kAudioDevicePropertyVolumeScalar, &volume), isSettable(device, kAudioDevicePropertyVolumeScalar) else {
            Log.warning("Mic \(name): neither mute nor volume can be set", "mic")
            return nil
        }
        var target: Float32
        if volume < 0.01 {
            target = volumeBeforeMute[device] ?? 0.75
        } else {
            volumeBeforeMute[device] = volume
            target = 0
        }
        let ok = write(device, kAudioDevicePropertyVolumeScalar, &target)
        Log.info("Mic \(name): input volume \(volume) → \(target)\(ok ? "" : " FAILED")", "mic")
        return target < 0.01
    }

    /// The same test as MeetRec's: the mute flag, or input volume at zero.
    static func isMuted() -> Bool {
        guard let device = defaultInput() else { return false }
        var mute: UInt32 = 0
        if read(device, kAudioDevicePropertyMute, &mute), mute != 0 { return true }
        var volume: Float32 = 1
        if read(device, kAudioDevicePropertyVolumeScalar, &volume), volume < 0.01 { return true }
        return false
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func read<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }

    private static func write<T: BitwiseCopyable>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
