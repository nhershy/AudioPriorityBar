import Foundation
import CoreAudio

enum AudioDeviceType: String, Codable, CaseIterable {
    case input
    case output
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    /// CoreAudio object ID. Only meaningful while connected; every disconnected device has 0,
    /// so lists must use `uid` for identity.
    let id: AudioObjectID
    let uid: String
    let name: String
    let type: AudioDeviceType
    var transportType: UInt32 = 0
    var isConnected: Bool = true

    /// A placeholder for a remembered device that is not connected right now.
    static func disconnected(_ stored: StoredDevice) -> AudioDevice {
        AudioDevice(
            id: AudioObjectID(kAudioObjectUnknown),
            uid: stored.uid,
            name: stored.name,
            type: stored.isInput ? .input : .output,
            transportType: stored.transport ?? 0,
            isConnected: false
        )
    }

    /// SF Symbol that hints at what kind of device this is.
    var symbolName: String {
        let looksLikeHeadphones = HeadphoneDetection.isHeadphone(deviceName: name)

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return looksLikeHeadphones ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            if looksLikeHeadphones {
                return "headphones"
            }
            return type == .input ? "mic" : "hifispeaker"
        }
    }
}
