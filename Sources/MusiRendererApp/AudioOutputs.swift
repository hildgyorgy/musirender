import CoreAudio
import Foundation

struct AudioOutput: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var nominalSampleRate: Double? { Self.nominalSampleRate(for: id) }

    static func nominalSampleRate(for device: AudioDeviceID) -> Double? {
        var value: Float64 = 0
        var property = AudioOutputs.address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              value.isFinite, value > 0 else { return nil }
        return value
    }
}

@MainActor
final class AudioOutputs {
    private nonisolated static let system = AudioObjectID(kAudioObjectSystemObject)
    private nonisolated static let systemSelectors = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice
    ]

    private let listener: AudioObjectPropertyListenerBlock
    private var observedDevice: AudioDeviceID?

    init(onChange: @escaping @MainActor () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { onChange() }
        }
        self.listener = listener
        for selector in Self.systemSelectors {
            var property = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &property, .main, listener)
        }
    }

    deinit {
        for selector in Self.systemSelectors {
            var property = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(Self.system, &property, .main, listener)
        }
        if let observedDevice {
            var property = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(observedDevice, &property, .main, listener)
        }
    }

    func observeRate(for device: AudioDeviceID?) {
        guard device != observedDevice else { return }
        var property = Self.address(kAudioDevicePropertyNominalSampleRate)
        if let observedDevice {
            AudioObjectRemovePropertyListenerBlock(observedDevice, &property, .main, listener)
        }
        observedDevice = nil
        if let device, AudioObjectAddPropertyListenerBlock(device, &property, .main, listener) == noErr {
            observedDevice = device
        }
    }

    static var defaultDeviceID: AudioDeviceID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &id) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return id
    }

    static func sampleRateControl(for uid: String) -> OutputSampleRateControl {
        OutputSampleRateControl {
            guard let device = deviceID(for: uid) else { return nil }
            return AudioOutput.nominalSampleRate(for: device)
        } request: { rate in
            guard let device = deviceID(for: uid) else { return false }
            var property = address(kAudioDevicePropertyNominalSampleRate)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &property, &settable) == noErr,
                  settable.boolValue else { return false }
            var value = rate
            return AudioObjectSetPropertyData(device, &property, 0, nil,
                                              UInt32(MemoryLayout<Float64>.size), &value) == noErr
        }
    }

    private nonisolated static func deviceID(for uid: String) -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier: CFString = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(system, &property, UInt32(MemoryLayout<CFString>.size),
                                       pointer, &size, &id)
        }
        return result == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func list() -> [AudioOutput]? {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let result = ids.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(system, &property, 0, nil, &size, base)
        }
        guard result == noErr else { return nil }
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride)
            .compactMap { id -> AudioOutput? in
                var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
                var streamSize: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                      streamSize > 0, let uid = string(kAudioDevicePropertyDeviceUID, from: id),
                      let name = string(kAudioObjectPropertyName, from: id) else { return nil }
                return AudioOutput(id: id, uid: uid, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func string(_ selector: AudioObjectPropertySelector, from id: AudioDeviceID) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
