import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

struct AudioApplication: Identifiable, Hashable {
    let processObjectID: AudioObjectID?
    let routingProcessObjectIDs: Set<AudioObjectID>
    let pid: pid_t
    let bundleID: String
    let routingBundleIDs: Set<String>
    let name: String
    let isProducingAudio: Bool

    init(
        processObjectID: AudioObjectID?,
        pid: pid_t,
        bundleID: String,
        routingProcessObjectIDs: Set<AudioObjectID>? = nil,
        routingBundleIDs: Set<String>? = nil,
        name: String,
        isProducingAudio: Bool
    ) {
        self.processObjectID = processObjectID
        self.routingProcessObjectIDs = routingProcessObjectIDs
            ?? processObjectID.map { [$0] }
            ?? []
        self.pid = pid
        self.bundleID = bundleID
        self.routingBundleIDs = (routingBundleIDs ?? [bundleID]).union([bundleID])
        self.name = name
        self.isProducingAudio = isProducingAudio
    }

    var id: String { bundleID }

    var isConnectedToAudio: Bool { processObjectID != nil }

    var icon: NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

struct AudioOutputDevice: Identifiable, Hashable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    var id: String { uid }

    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer.and.arrow.down"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "hifispeaker"
        }
    }
}

struct RoutingChoice: Codable, Equatable {
    let bundleID: String
    let deviceUIDs: Set<String>
}

enum RoutingPreferences {
    static func decode(_ raw: [String: Any]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (bundleID, value) in raw {
            if let deviceUIDs = value as? [String] {
                let selection = Set(deviceUIDs.filter { !$0.isEmpty })
                if !selection.isEmpty { result[bundleID] = selection }
            } else if let legacyDeviceUID = value as? String, !legacyDeviceUID.isEmpty {
                result[bundleID] = [legacyDeviceUID]
            }
        }
        return result
    }

    static func encode(_ preferences: [String: Set<String>]) -> [String: [String]] {
        preferences.compactMapValues { selection in
            selection.isEmpty ? nil : selection.sorted()
        }
    }
}

enum ApplicationVolumePreferences {
    static let defaultVolume: Float = 1

    static func decode(_ raw: [String: Any]) -> [String: Float] {
        raw.compactMapValues { value in
            guard let number = value as? NSNumber else { return nil }
            return clamped(number.floatValue)
        }
    }

    static func encode(_ volumes: [String: Float]) -> [String: Double] {
        volumes.mapValues { Double(clamped($0)) }
    }

    static func clamped(_ volume: Float) -> Float {
        guard volume.isFinite else { return defaultVolume }
        return min(max(volume, 0), 1)
    }
}

enum PinnedApplicationPreferences {
    static func decode(_ raw: [String]?) -> Set<String> {
        Set((raw ?? []).filter { !$0.isEmpty })
    }

    static func encode(_ bundleIDs: Set<String>) -> [String] {
        bundleIDs.sorted()
    }
}

enum ApplicationListOrdering {
    static func pinnedFirst(
        _ applications: [AudioApplication],
        pinnedBundleIDs: Set<String>
    ) -> [AudioApplication] {
        applications.enumerated().sorted { lhs, rhs in
            let lhsPinned = pinnedBundleIDs.contains(lhs.element.bundleID)
            let rhsPinned = pinnedBundleIDs.contains(rhs.element.bundleID)
            if lhsPinned != rhsPinned { return lhsPinned }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

enum RouteState: Equatable {
    case inactive
    case waiting(deviceUIDs: Set<String>)
    case starting
    case active(deviceUIDs: Set<String>)
    case failed(message: String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

enum SourceSoundError: LocalizedError {
    case unsupportedOS
    case coreAudio(operation: String, status: OSStatus)
    case missingProperty(String)
    case noOutputChannels(String)
    case routeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Per-app routing requires macOS 14.2 or later."
        case let .coreAudio(operation, status):
            let code = Self.fourCharacterCode(status)
            return "\(operation) failed (\(code), \(status))."
        case let .missingProperty(property):
            return "Core Audio did not provide \(property)."
        case let .noOutputChannels(name):
            return "\(name) does not expose any output channels."
        case let .routeUnavailable(message):
            return message
        }
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "OSStatus"
        }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
}
