import XCTest
import CoreAudio
@testable import SourceSound

final class SourceSoundTests: XCTestCase {
    func testRouteStateReportsOnlyActiveRouteAsActive() {
        XCTAssertFalse(RouteState.inactive.isActive)
        XCTAssertFalse(RouteState.waiting(deviceUIDs: ["speaker"]).isActive)
        XCTAssertFalse(RouteState.starting.isActive)
        XCTAssertFalse(RouteState.failed(message: "No device").isActive)
        XCTAssertTrue(RouteState.active(deviceUIDs: ["speaker", "headphones"]).isActive)
    }

    func testRoutingChoiceRoundTripsThroughJSON() throws {
        let choice = RoutingChoice(
            bundleID: "com.example.music",
            deviceUIDs: ["device-1", "device-2"]
        )
        let data = try JSONEncoder().encode(choice)
        XCTAssertEqual(try JSONDecoder().decode(RoutingChoice.self, from: data), choice)
    }

    func testPreferencesDecodeLegacyAndMultipleOutputs() {
        let decoded = RoutingPreferences.decode([
            "com.example.legacy": "speaker",
            "com.example.multi": ["speaker", "headphones", "speaker"]
        ])

        XCTAssertEqual(decoded["com.example.legacy"], ["speaker"])
        XCTAssertEqual(decoded["com.example.multi"], ["speaker", "headphones"])
        XCTAssertEqual(
            RoutingPreferences.encode(decoded)["com.example.multi"],
            ["headphones", "speaker"]
        )
    }

    func testAggregateDescriptionMirrorsToMultipleOutputs() {
        let outputs = [
            AudioOutputDevice(objectID: 1, uid: "speaker", name: "Speakers", transportType: 0),
            AudioOutputDevice(objectID: 2, uid: "headphones", name: "Headphones", transportType: 0)
        ]
        let description = AudioRoute.makeAggregateDescription(
            tapUID: "tap",
            outputDevices: outputs,
            routeUID: "route"
        )

        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "speaker")
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
        let subdevices = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(subdevices?.count, 2)
        XCTAssertEqual(subdevices?[0][kAudioSubDeviceDriftCompensationKey] as? Bool, false)
        XCTAssertEqual(subdevices?[1][kAudioSubDeviceDriftCompensationKey] as? Bool, true)
    }

    func testPersistentTapDescriptionRoutesByBundleIdentifier() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let safari = AudioApplication(
            processObjectID: nil,
            pid: 0,
            bundleID: "com.apple.Safari",
            name: "Safari",
            isProducingAudio: false
        )
        let description = AudioRoute.makePersistentTapDescription(for: safari)

        XCTAssertEqual(description.bundleIDs, ["com.apple.Safari"])
        XCTAssertTrue(description.isProcessRestoreEnabled)
        XCTAssertTrue(description.isMixdown)
        XCTAssertFalse(description.isExclusive)
        XCTAssertEqual(description.muteBehavior, .mutedWhenTapped)
    }

    func testDescendantAudioBundleUsesVisibleParentApplication() {
        let owner = CoreAudioSystem.routingOwnerBundleID(
            for: "com.microsoft.edgemac.helper",
            openBundleIDs: ["com.microsoft.edgemac", "com.microsoft"]
        )

        XCTAssertEqual(owner, "com.microsoft.edgemac")
    }

    func testPersistentTapIncludesEdgeAudioHelperBundle() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let edge = AudioApplication(
            processObjectID: 189,
            pid: 33078,
            bundleID: "com.microsoft.edgemac",
            routingBundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.helper"],
            name: "Microsoft Edge",
            isProducingAudio: true
        )
        let description = AudioRoute.makePersistentTapDescription(for: edge)

        XCTAssertEqual(
            Set(description.bundleIDs),
            ["com.microsoft.edgemac", "com.microsoft.edgemac.helper"]
        )
    }

    func testAudioApplicationRetainsAllRoutingBundleIdentifiers() {
        let edge = AudioApplication(
            processObjectID: 189,
            pid: 33078,
            bundleID: "com.microsoft.edgemac",
            routingBundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.helper"],
            name: "Microsoft Edge",
            isProducingAudio: true
        )

        XCTAssertEqual(edge.routingBundleIDs, [
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.helper"
        ])
    }

    func testLiveEdgeAudioHelperRouteStartsOnSelectedOutput() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let processIDs = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: CoreAudioSystem.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
        let edgeHelperIsRegistered = processIDs.contains { processID in
            let bundleID = try? CoreAudioSystem.stringProperty(
                objectID: processID,
                selector: kAudioProcessPropertyBundleID
            )
            return bundleID == "com.microsoft.edgemac.helper"
        }
        guard edgeHelperIsRegistered else {
            throw XCTSkip("Edge's Core Audio helper is not currently registered.")
        }

        let edge = try XCTUnwrap(
            CoreAudioSystem.audioApplications().first { $0.bundleID == "com.microsoft.edgemac" }
        )
        XCTAssertTrue(edge.routingBundleIDs.contains("com.microsoft.edgemac.helper"))

        let outputs = try CoreAudioSystem.outputDevices()
        let selectedOutput = try XCTUnwrap(
            outputs.first { $0.uid == "BuiltInSpeakerDevice" } ?? outputs.first
        )
        let route = try AudioRoute(application: edge, outputDevices: [selectedOutput])

        XCTAssertTrue(route.isRunning)
        XCTAssertEqual(route.deviceUIDs, [selectedOutput.uid])
        XCTAssertTrue(route.routingBundleIDs.contains("com.microsoft.edgemac.helper"))

        route.stop()
        XCTAssertFalse(route.isRunning)
    }

    func testMacOS26IdleApplicationCanRouteWithoutProcessObject() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let idleSafari = AudioApplication(
            processObjectID: nil,
            pid: 0,
            bundleID: "com.apple.Safari",
            name: "Safari",
            isProducingAudio: false
        )

        XCTAssertTrue(AudioRoute.canCreateRoute(for: idleSafari))
    }

    func testLivePersistentBundleTapDoesNotNeedProcessObject() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        guard !(try CoreAudioSystem.outputDevices()).isEmpty else {
            throw XCTSkip("The live Core Audio service is unavailable in this test environment.")
        }
        let safari = AudioApplication(
            processObjectID: nil,
            pid: 0,
            bundleID: "com.apple.Safari",
            name: "Safari Waiting-State Test",
            isProducingAudio: false
        )
        let description = AudioRoute.makePersistentTapDescription(for: safari)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioSystem.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "Create a persistent Safari tap without a process object"
        )
        defer {
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
        }
        XCTAssertNotEqual(tapID, kAudioObjectUnknown)
    }

    func testLivePrivateAggregateAcceptsTwoConnectedOutputs() throws {
        let allOutputs = try CoreAudioSystem.outputDevices()
        print("Live outputs: \(allOutputs.map { "\($0.name) [\($0.transportType)]" }.joined(separator: ", "))")
        let knownVirtualDeviceNames = ["BlackHole", "Microsoft Teams Audio", "SourceSound Route"]
        let outputs = allOutputs.filter { device in
            !knownVirtualDeviceNames.contains(where: { device.name.localizedCaseInsensitiveContains($0) })
        }
        guard outputs.count >= 2 else {
            throw XCTSkip("Two connected outputs are required for the live aggregate test.")
        }
        let selected = Array(outputs.prefix(2))
        let subdevices: [[String: Any]] = selected.enumerated().map { index, device in
            [
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceDriftCompensationKey: index != 0,
                kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
            ]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SourceSound Live Multi-Output Test",
            kAudioAggregateDeviceUIDKey: "SourceSound.Test.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: selected[0].uid,
            kAudioAggregateDeviceSubDeviceListKey: subdevices
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioSystem.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            operation: "Create the live multi-output test device"
        )
        defer {
            if aggregateID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            }
        }

        let activeSubdevices = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: aggregateID,
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )
        XCTAssertEqual(activeSubdevices.count, 2)
    }

    func testLiveTwoOutputRouteFormatsAreCompatible() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let knownVirtualDeviceNames = ["BlackHole", "Microsoft Teams Audio", "SourceSound Route"]
        let outputs = try CoreAudioSystem.outputDevices().filter { device in
            !knownVirtualDeviceNames.contains(where: { device.name.localizedCaseInsensitiveContains($0) })
        }
        guard outputs.count >= 2 else {
            throw XCTSkip("Two connected outputs are required for the live route-format test.")
        }

        let safari = AudioApplication(
            processObjectID: nil,
            pid: 0,
            bundleID: "com.apple.Safari",
            name: "Safari Format Test",
            isProducingAudio: false
        )
        let tapDescription = AudioRoute.makePersistentTapDescription(for: safari)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        defer {
            if aggregateID != kAudioObjectUnknown { _ = AudioHardwareDestroyAggregateDevice(aggregateID) }
            if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        }
        try CoreAudioSystem.check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "Create the route-format test tap"
        )
        let tapUID = try CoreAudioSystem.tapUIDProperty(objectID: tapID)
        let selectedOutputs = Array(outputs.prefix(2))
        let aggregateDescription = AudioRoute.makeAggregateDescription(
            tapUID: tapUID,
            outputDevices: selectedOutputs,
            routeUID: "SourceSound.FormatTest.\(UUID().uuidString)"
        )
        try CoreAudioSystem.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            operation: "Create the route-format test aggregate"
        )

        let tapFormat: AudioStreamBasicDescription = try CoreAudioSystem.scalarProperty(
            objectID: tapID,
            selector: kAudioTapPropertyFormat
        )
        let inputStreams = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: aggregateID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        let outputStreams = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: aggregateID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        )
        let inputFormats: [AudioStreamBasicDescription] = try inputStreams.map {
            try CoreAudioSystem.scalarProperty(objectID: $0, selector: kAudioStreamPropertyVirtualFormat)
        }
        let outputFormats: [AudioStreamBasicDescription] = try outputStreams.map {
            try CoreAudioSystem.scalarProperty(objectID: $0, selector: kAudioStreamPropertyVirtualFormat)
        }
        let renderers = try outputFormats.map {
            try AudioStreamRenderer(inputFormat: tapFormat, outputFormat: $0)
        }

        print("Tap format: \(Self.describe(tapFormat))")
        print("Input formats: \(inputFormats.map(Self.describe).joined(separator: "; "))")
        print("Output formats: \(outputFormats.map(Self.describe).joined(separator: "; "))")
        XCTAssertFalse(inputFormats.isEmpty)
        XCTAssertEqual(renderers.count, 2)
        for renderer in renderers {
            if renderer.requiresConversion {
                XCTAssertNotEqual(
                    Self.describe(renderer.inputFormat),
                    Self.describe(renderer.outputFormat)
                )
            } else {
                XCTAssertEqual(
                    Self.describe(renderer.inputFormat),
                    Self.describe(renderer.outputFormat)
                )
            }
        }
    }

    func testLiveTwoOutputAudioRouteStartsAndStopsIO() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let knownVirtualDeviceNames = ["BlackHole", "Microsoft Teams Audio", "SourceSound Route"]
        let outputs = try CoreAudioSystem.outputDevices().filter { device in
            !knownVirtualDeviceNames.contains(where: { device.name.localizedCaseInsensitiveContains($0) })
        }
        guard outputs.count >= 2 else {
            throw XCTSkip("Two connected outputs are required for the live route lifecycle test.")
        }

        let application = AudioApplication(
            processObjectID: nil,
            pid: 0,
            bundleID: "com.apple.Safari",
            name: "Safari Route Lifecycle Test",
            isProducingAudio: false
        )
        let selectedOutputs = Array(outputs.prefix(2))
        let route = try AudioRoute(application: application, outputDevices: selectedOutputs)

        XCTAssertTrue(route.isRunning)
        XCTAssertEqual(route.deviceUIDs, Set(selectedOutputs.map(\.uid)))

        route.stop()
        XCTAssertFalse(route.isRunning)
    }

    func testSampleRateConverterMirrorsStereoWithoutDistortion() throws {
        let inputFormat = Self.floatStereoFormat(sampleRate: 48_000)
        let outputFormat = Self.floatStereoFormat(sampleRate: 44_100)
        let firstRenderer = try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        let secondRenderer = try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        let inputFrames = 480
        let outputFrames = 441
        var input = (0..<(inputFrames * 2)).map { sample -> Float in
            let frame = sample / 2
            return sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
        }
        var firstOutput = Array(repeating: Float.zero, count: outputFrames * 2)
        var secondOutput = Array(repeating: Float.zero, count: outputFrames * 2)

        let firstStatus = input.withUnsafeMutableBufferPointer { inputPointer in
            firstOutput.withUnsafeMutableBufferPointer { outputPointer in
                firstRenderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2)
                )
            }
        }
        let secondStatus = input.withUnsafeMutableBufferPointer { inputPointer in
            secondOutput.withUnsafeMutableBufferPointer { outputPointer in
                secondRenderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2)
                )
            }
        }

        XCTAssertEqual(firstStatus, noErr)
        XCTAssertEqual(secondStatus, noErr)
        XCTAssertTrue(firstOutput.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(firstOutput.map { abs($0) }.max() ?? 0, 0.1)
        XCTAssertLessThanOrEqual(firstOutput.map { abs($0) }.max() ?? 0, 0.6)
        XCTAssertEqual(firstOutput, secondOutput)
    }

    func testMatchingFormatRendererMirrorsCompleteStereoToEveryOutput() throws {
        let format = Self.floatStereoFormat(sampleRate: 48_000)
        let firstRenderer = try AudioStreamRenderer(inputFormat: format, outputFormat: format)
        let secondRenderer = try AudioStreamRenderer(inputFormat: format, outputFormat: format)
        var input: [Float] = [
            0.1, -0.8,
            0.2, -0.7,
            0.3, -0.6,
            0.4, -0.5
        ]
        var firstOutput = Array(repeating: Float.zero, count: input.count)
        var secondOutput = Array(repeating: Float.zero, count: input.count)

        let firstStatus = input.withUnsafeMutableBufferPointer { inputPointer in
            firstOutput.withUnsafeMutableBufferPointer { outputPointer in
                firstRenderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2)
                )
            }
        }
        let secondStatus = input.withUnsafeMutableBufferPointer { inputPointer in
            secondOutput.withUnsafeMutableBufferPointer { outputPointer in
                secondRenderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2)
                )
            }
        }

        XCTAssertEqual(firstStatus, noErr)
        XCTAssertEqual(secondStatus, noErr)
        XCTAssertEqual(firstOutput, input)
        XCTAssertEqual(secondOutput, input)
    }

    func testSampleRateConverterHandlesConsecutiveRealtimeBuffers() throws {
        let inputFormat = Self.floatStereoFormat(sampleRate: 48_000)
        let outputFormat = Self.floatStereoFormat(sampleRate: 44_100)
        let renderer = try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        let inputFrames = 480
        let outputFrames = 441

        for chunk in 0..<20 {
            var input = (0..<(inputFrames * 2)).map { sample -> Float in
                let frame = chunk * inputFrames + sample / 2
                return sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
            }
            var output = Array(repeating: Float.zero, count: outputFrames * 2)
            let status = input.withUnsafeMutableBufferPointer { inputPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    renderer.render(
                        input: AudioBuffer(inputPointer, numberOfChannels: 2),
                        output: AudioBuffer(outputPointer, numberOfChannels: 2)
                    )
                }
            }

            XCTAssertEqual(status, noErr, "Converter failed on realtime chunk \(chunk)")
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(
                output.map { abs($0) }.max() ?? 0,
                0.1,
                "Converter produced silence on realtime chunk \(chunk)"
            )
        }
    }

    func testCoreAudioEnumerationDoesNotThrow() throws {
        _ = try CoreAudioSystem.audioApplications()
        _ = try CoreAudioSystem.outputDevices()
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        "rate=\(format.mSampleRate), id=\(format.mFormatID), flags=0x\(String(format.mFormatFlags, radix: 16)), bytes/frame=\(format.mBytesPerFrame), channels=\(format.mChannelsPerFrame), bits=\(format.mBitsPerChannel)"
    }

    private static func floatStereoFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
