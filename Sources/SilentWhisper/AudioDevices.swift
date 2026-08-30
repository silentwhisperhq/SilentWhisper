import CoreAudio
import Foundation

/// The input devices CoreAudio can see, for the mic picker in Settings.
///
/// Devices are identified by UID rather than AudioDeviceID: the numeric id is reassigned
/// across reboots and replugs, so a stored one would silently point at the wrong mic.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: String      // the UID
        let name: String
    }

    /// Every device with at least one input channel, in the order CoreAudio reports them.
    static func inputs() -> [Device] {
        ids().compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return Device(id: uid, name: name)
        }
    }

    static func systemDefault() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    /// nil when the UID is empty (follow the system) or names a device that is not here.
    static func id(forUID wanted: String) -> AudioDeviceID? {
        guard !wanted.isEmpty else { return nil }
        return ids().first { uid(of: $0) == wanted && hasInput($0) }
    }

    // MARK: - CoreAudio plumbing

    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func ids() -> [AudioDeviceID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffers = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffers.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffers) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffers.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        // Non-optional CFString: pointing at an Optional of a class type is what the compiler
        // warns about, and CoreAudio writes an unconditional reference here anyway.
        var value = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    private static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
}
