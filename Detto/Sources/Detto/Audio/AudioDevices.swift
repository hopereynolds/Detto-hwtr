import CoreAudio
import Foundation

/// What kind of connection an audio device uses, from CoreAudio's
/// transport type. Shown next to the device name, so a headset whose
/// name is a random string still reads as "Bluetooth".
enum AudioDeviceKind: Equatable, Sendable {
    case builtIn, bluetooth, usb, iPhone, airPlay, display, thunderbolt, virtual, aggregate, other

    init(transportType: UInt32?) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .iPhone
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .bluetooth: return "Bluetooth"
        case .usb: return "USB"
        case .iPhone: return "iPhone"
        case .airPlay: return "AirPlay"
        case .display: return "Display"
        case .thunderbolt: return "Thunderbolt"
        case .virtual: return "Virtual"
        case .aggregate: return "Combined"
        case .other: return "Other"
        }
    }
}

/// One audio device as macOS describes it right now.
struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    /// The name macOS gives it (renamable for Bluetooth in System Settings).
    let name: String
    let kind: AudioDeviceKind

    /// "AirPods Pro · Bluetooth"
    var displayName: String { "\(name) · \(kind.label)" }

    /// Reads a device's name and type. Doesn't open the device, so it
    /// never wakes a Bluetooth headset's mic.
    static func read(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard id != 0, let name = deviceName(id) else { return nil }
        return AudioDeviceInfo(id: id, name: name, kind: AudioDeviceKind(transportType: MicCapture.transportType(for: id)))
    }

    /// Every device that can record, in CoreAudio's order.
    static func inputs() -> [AudioDeviceInfo] {
        MicCapture.availableInputDevices().map {
            AudioDeviceInfo(id: $0.id, name: $0.name, kind: AudioDeviceKind(transportType: MicCapture.transportType(for: $0.id)))
        }
    }

    /// Where the Mac is playing sound right now (what you hear).
    static func defaultOutput() -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? read(deviceID) : nil
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return status == noErr ? name as String : nil
    }
}
