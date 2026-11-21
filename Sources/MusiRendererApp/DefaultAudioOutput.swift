import CoreAudio
import Foundation

/// Observes the default media output. Core Audio has a separate default for alerts.
final class DefaultAudioOutput {
    private let listener: AudioObjectPropertyListenerBlock
    private let isListening: Bool

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @MainActor (String?) -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { onChange(Self.currentName()) }
        }
        self.listener = listener
        var address = Self.outputAddress
        isListening = AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, .main, listener) == noErr
    }

    deinit {
        guard isListening else { return }
        var address = Self.outputAddress
        AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, .main, listener)
    }

    static func currentName() -> String? {
        var address = outputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: name))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        let value = name.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}
