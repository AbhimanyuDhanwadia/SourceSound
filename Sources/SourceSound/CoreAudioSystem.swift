import AppKit
import CoreAudio
import Foundation

enum CoreAudioSystem {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func audioApplications() throws -> [AudioApplication] {
        let processIDs = try audioObjectIDArrayProperty(
            objectID: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )

        let ownBundleID = Bundle.main.bundleIdentifier
        let openApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            !$0.isTerminated &&
            $0.bundleIdentifier != nil &&
            $0.bundleIdentifier != ownBundleID
        }
        let openBundleIDs = Set(openApplications.compactMap(\.bundleIdentifier))

        struct AudioProcess {
            let objectID: AudioObjectID
            let pid: pid_t
            let bundleID: String
            let isProducingAudio: Bool
        }

        var audioProcessesByOwnerBundleID: [String: [AudioProcess]] = [:]

        for processObjectID in processIDs {
            guard
                let pid: pid_t = try? scalarProperty(
                    objectID: processObjectID,
                    selector: kAudioProcessPropertyPID
                ),
                let bundleID: String = try? stringProperty(
                    objectID: processObjectID,
                    selector: kAudioProcessPropertyBundleID
                ),
                !bundleID.isEmpty,
                bundleID != Bundle.main.bundleIdentifier
            else { continue }

            let isRunning: UInt32 = (try? scalarProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            )) ?? 0

            let process = AudioProcess(
                objectID: processObjectID,
                pid: pid,
                bundleID: bundleID,
                isProducingAudio: isRunning != 0
            )
            let ownerBundleID = routingOwnerBundleID(
                for: bundleID,
                openBundleIDs: openBundleIDs
            )
            audioProcessesByOwnerBundleID[ownerBundleID, default: []].append(process)
        }

        var seenOpenBundleIDs = Set<String>()
        var applications: [AudioApplication] = openApplications.compactMap { runningApp in
            guard
                let bundleID = runningApp.bundleIdentifier,
                seenOpenBundleIDs.insert(bundleID).inserted
            else { return nil }
            let audioProcesses = audioProcessesByOwnerBundleID.removeValue(forKey: bundleID) ?? []
            let audioProcess = audioProcesses.first(where: \.isProducingAudio) ?? audioProcesses.first
            return AudioApplication(
                processObjectID: audioProcess?.objectID,
                pid: runningApp.processIdentifier,
                bundleID: bundleID,
                routingProcessObjectIDs: Set(audioProcesses.map(\.objectID)),
                routingBundleIDs: Set(audioProcesses.map(\.bundleID)).union([
                    bundleID,
                    bundleID + ".helper"
                ]),
                name: runningApp.localizedName ?? displayName(for: bundleID),
                isProducingAudio: audioProcesses.contains(where: \.isProducingAudio)
            )
        }

        // Keep audio-only helper applications visible even when they don't own a normal window.
        applications.append(contentsOf: audioProcessesByOwnerBundleID.compactMap { ownerBundleID, processes in
            guard let process = processes.first(where: \.isProducingAudio) ?? processes.first else {
                return nil
            }
            return AudioApplication(
                processObjectID: process.objectID,
                pid: process.pid,
                bundleID: ownerBundleID,
                routingProcessObjectIDs: Set(processes.map(\.objectID)),
                routingBundleIDs: Set(processes.map(\.bundleID)).union([
                    ownerBundleID,
                    ownerBundleID + ".helper"
                ]),
                name: NSRunningApplication(processIdentifier: process.pid)?.localizedName
                    ?? displayName(for: ownerBundleID),
                isProducingAudio: processes.contains(where: \.isProducingAudio)
            )
        })

        return applications.sorted {
            if $0.isProducingAudio != $1.isProducingAudio { return $0.isProducingAudio }
            if $0.isConnectedToAudio != $1.isConnectedToAudio { return $0.isConnectedToAudio }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func routingOwnerBundleID(
        for audioBundleID: String,
        openBundleIDs: Set<String>
    ) -> String {
        if openBundleIDs.contains(audioBundleID) { return audioBundleID }

        // Safari's audio is rendered by a launchd-owned WebKit GPU service. Its bundle
        // identifier is not a descendant of com.apple.Safari, so the normal prefix
        // association below cannot discover it. Associate the shared WebKit audio
        // services with Safari only while Safari itself is open.
        if openBundleIDs.contains("com.apple.Safari"), safariAudioBundleIDs.contains(audioBundleID) {
            return "com.apple.Safari"
        }

        return openBundleIDs
            .filter { audioBundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
            ?? audioBundleID
    }

    static let safariAudioBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.Networking",
        "com.apple.WebKit.WebContent"
    ]

    private static func displayName(for bundleID: String) -> String {
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap(Bundle.init(url:))
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }

    static func outputDevices() throws -> [AudioOutputDevice] {
        let deviceIDs = try audioObjectIDArrayProperty(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDevices
        )

        return deviceIDs.compactMap { objectID in
            do {
                let channelCount = try outputChannelCount(deviceID: objectID)
                guard channelCount > 0 else { return nil }

                let uid: String = try stringProperty(
                    objectID: objectID,
                    selector: kAudioDevicePropertyDeviceUID
                )
                guard
                    !uid.hasPrefix("SourceSound.Route."),
                    !uid.hasPrefix("SoundSource.Route.")
                else { return nil }

                let name: String = try stringProperty(
                    objectID: objectID,
                    selector: kAudioObjectPropertyName
                )
                let transport: UInt32 = (try? scalarProperty(
                    objectID: objectID,
                    selector: kAudioDevicePropertyTransportType
                )) ?? kAudioDeviceTransportTypeUnknown

                return AudioOutputDevice(
                    objectID: objectID,
                    uid: uid,
                    name: name,
                    transportType: transport
                )
            } catch {
                return nil
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func outputChannelCount(deviceID: AudioObjectID) throws -> Int {
        var address = propertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeOutput
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "Read output channel layout size"
        )

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw),
            operation: "Read output channel layout"
        )

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    static func scalarProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage)
        try check(status, operation: "Read Core Audio property")
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw SourceSoundError.missingProperty("a scalar value of the expected size")
        }
        return storage.load(as: T.self)
    }

    static func audioObjectIDArrayProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            operation: "Read Core Audio list size"
        )
        guard size > 0 else { return [] }
        guard size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.stride)) else {
            throw SourceSoundError.missingProperty("a valid Core Audio object list")
        }
        var values = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.stride
        )
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(status, operation: "Read Core Audio list")
        return values
    }

    static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
            },
            operation: "Read Core Audio text property"
        )
        return value as String
    }

    static func tapUIDProperty(objectID: AudioObjectID) throws -> String {
        let maximumAttempts = 50
        var lastError: Error?
        for attempt in 0..<maximumAttempts {
            do {
                return try stringProperty(objectID: objectID, selector: kAudioTapPropertyUID)
            } catch {
                lastError = error
                if attempt < maximumAttempts - 1 {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        throw lastError ?? SourceSoundError.routeUnavailable("The audio tap did not become ready.")
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw SourceSoundError.coreAudio(operation: operation, status: status)
        }
    }
}
