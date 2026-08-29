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

    func testApplicationVolumePreferencesClampAndRoundTrip() {
        let decoded = ApplicationVolumePreferences.decode([
            "com.example.quiet": 0.25,
            "com.example.loud": 0.8,
            "com.example.tooLoud": 2.0,
            "com.example.negative": -1.0,
            "com.example.invalid": Double.nan
        ])

        XCTAssertEqual(decoded["com.example.quiet"], 0.25)
        XCTAssertEqual(decoded["com.example.loud"], 0.8)
        XCTAssertEqual(decoded["com.example.tooLoud"], 1)
        XCTAssertEqual(decoded["com.example.negative"], 0)
        XCTAssertEqual(decoded["com.example.invalid"], 1)
        XCTAssertEqual(
            ApplicationVolumePreferences.encode(decoded)["com.example.quiet"],
            0.25
        )
    }

    func testRealtimeVolumeClampsAndPublishesChanges() {
        let volume = RealtimeVolume(0.4)
        XCTAssertEqual(volume.value, 0.4, accuracy: 0.0001)

        volume.value = 1.5
        XCTAssertEqual(volume.value, 1)

        volume.value = -0.5
        XCTAssertEqual(volume.value, 0)

        volume.value = .nan
        XCTAssertEqual(volume.value, 1)
    }

    func testRealtimeUInt32PublishesChanges() {
        let value = RealtimeUInt32(42)
        XCTAssertEqual(value.value, 42)
        value.value = 9001
        XCTAssertEqual(value.value, 9001)
        XCTAssertEqual(value.increment(), 9001)
        XCTAssertEqual(value.value, 9002)
    }

    func testRealtimeRingBufferPrefillsAndRendersCompleteStereoFrames() {
        let ring = RealtimeAudioRingBuffer(
            capacityFrames: 16,
            channels: 2,
            initialGain: 0.5
        )
        var input: [Float] = [
            0.2, -0.2,
            0.4, -0.4,
            0.6, -0.6,
            0.8, -0.8,
            1.0, -1.0,
            0.8, -0.8,
            0.6, -0.6,
            0.4, -0.4
        ]
        var output = Array(repeating: Float.zero, count: 8)

        input.withUnsafeMutableBufferPointer { pointer in
            ring.write(AudioBuffer(pointer, numberOfChannels: 2))
        }
        let status = output.withUnsafeMutableBufferPointer { pointer -> OSStatus in
            var outputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(pointer, numberOfChannels: 2)
            )
            return ring.render(frameCount: 4, to: &outputList, targetGain: 0.5)
        }

        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output, [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4])
        XCTAssertFalse(output.suffix(2).allSatisfy { $0 == 0 })
    }

    func testCaptureAggregateDescriptionContainsOnlyTheTap() {
        let description = AudioRoute.makeCaptureAggregateDescription(
            tapUID: "tap",
            routeUID: "route"
        )

        XCTAssertNil(description[kAudioAggregateDeviceMainSubDeviceKey])
        XCTAssertNil(description[kAudioAggregateDeviceSubDeviceListKey])
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(taps?.count, 1)
        XCTAssertEqual(taps?.first?[kAudioSubTapUIDKey] as? String, "tap")
        XCTAssertEqual(taps?.first?[kAudioSubTapDriftCompensationKey] as? Bool, false)
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
        XCTAssertEqual(description.processes, [])
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

    func testSafariWebKitAudioServiceUsesVisibleSafariApplication() {
        let owner = CoreAudioSystem.routingOwnerBundleID(
            for: "com.apple.WebKit.GPU",
            openBundleIDs: ["com.apple.Safari", "com.openai.codex"]
        )

        XCTAssertEqual(owner, "com.apple.Safari")
    }

    func testWebKitAudioServiceIsNotClaimedWhenSafariIsClosed() {
        let owner = CoreAudioSystem.routingOwnerBundleID(
            for: "com.apple.WebKit.GPU",
            openBundleIDs: ["com.openai.codex"]
        )

        XCTAssertEqual(owner, "com.apple.WebKit.GPU")
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
        XCTAssertEqual(description.processes, [189])
    }

    func testAudioApplicationRetainsAllRoutingBundleIdentifiers() {
        let edge = AudioApplication(
            processObjectID: 189,
            pid: 33078,
            bundleID: "com.microsoft.edgemac",
            routingProcessObjectIDs: [189, 190],
            routingBundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.helper"],
            name: "Microsoft Edge",
            isProducingAudio: true
        )

        XCTAssertEqual(edge.routingBundleIDs, [
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.helper"
        ])
        XCTAssertEqual(edge.routingProcessObjectIDs, [189, 190])
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

        let processDeadline = Date().addingTimeInterval(3)
        var helperProcessIDs = Set<AudioObjectID>()
        repeat {
            let processIDs = try CoreAudioSystem.audioObjectIDArrayProperty(
                objectID: CoreAudioSystem.systemObject,
                selector: kAudioHardwarePropertyProcessObjectList
            )
            helperProcessIDs = Set(processIDs.filter { processID in
                let bundleID = try? CoreAudioSystem.stringProperty(
                    objectID: processID,
                    selector: kAudioProcessPropertyBundleID
                )
                return bundleID == "com.microsoft.edgemac.helper"
            })
            if helperProcessIDs.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        } while helperProcessIDs.isEmpty && Date() < processDeadline
        XCTAssertFalse(helperProcessIDs.isEmpty)
        let routedEdge = AudioApplication(
            processObjectID: helperProcessIDs.first,
            pid: edge.pid,
            bundleID: edge.bundleID,
            routingProcessObjectIDs: helperProcessIDs,
            routingBundleIDs: edge.routingBundleIDs,
            name: edge.name,
            isProducingAudio: true
        )

        let outputs = try CoreAudioSystem.outputDevices()
        let selectedOutput = try XCTUnwrap(
            outputs.first { $0.uid == "BuiltInSpeakerDevice" } ?? outputs.first
        )
        let route = try AudioRoute(application: routedEdge, outputDevices: [selectedOutput])

        XCTAssertTrue(route.isRunning)
        XCTAssertEqual(route.deviceUIDs, [selectedOutput.uid])
        XCTAssertTrue(route.routingBundleIDs.contains("com.microsoft.edgemac.helper"))

        route.stop()
        XCTAssertFalse(route.isRunning)
    }

    func testLiveSafariAudioReachesNonDefaultExternalOutputRoute() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let liveProcessIDs = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: CoreAudioSystem.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
        let webKitAudioProcessIDs = Set(liveProcessIDs.filter { processID in
            let bundleID = try? CoreAudioSystem.stringProperty(
                objectID: processID,
                selector: kAudioProcessPropertyBundleID
            )
            return bundleID == "com.apple.WebKit.GPU"
        })
        let applications = try CoreAudioSystem.audioApplications()
        print("Live Safari discovery:", applications.filter {
            $0.bundleID == "com.apple.Safari" || $0.bundleID.contains("WebKit")
        }.map {
            "\($0.bundleID): producing=\($0.isProducingAudio), process=\(String(describing: $0.processObjectID)), routingProcesses=\($0.routingProcessObjectIDs), routingBundles=\($0.routingBundleIDs)"
        })
        let safari = try XCTUnwrap(
            applications.first { $0.bundleID == "com.apple.Safari" }
        )
        XCTAssertFalse(webKitAudioProcessIDs.isEmpty)
        XCTAssertTrue(webKitAudioProcessIDs.isSubset(of: safari.routingProcessObjectIDs))
        XCTAssertTrue(safari.routingBundleIDs.contains("com.apple.WebKit.GPU"))

        let defaultOutputID: AudioObjectID = try CoreAudioSystem.scalarProperty(
            objectID: CoreAudioSystem.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let knownVirtualDeviceNames = ["BlackHole", "Microsoft Teams Audio", "SourceSound Route"]
        let nonDefaultOutputs = try CoreAudioSystem.outputDevices().filter { device in
            device.objectID != defaultOutputID
                && !knownVirtualDeviceNames.contains(where: {
                    device.name.localizedCaseInsensitiveContains($0)
                })
        }
        print("Safari non-default outputs:", nonDefaultOutputs.map { "\($0.name) [\($0.uid)]" })
        let externalOutput = try XCTUnwrap(
            nonDefaultOutputs.first { $0.uid.hasPrefix("AppleUSBAudioEngine:") }
                ?? nonDefaultOutputs.first,
            "A connected non-default physical output is required for the live Safari route test."
        )

        let route = try AudioRoute(
            application: safari,
            outputDevices: [externalOutput],
            diagnosticsEnabled: true
        )
        defer { route.stop() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !(route.renderDiagnostics.receivedNonSilentAudio
                && route.renderDiagnostics.outputFrames > 0) {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let diagnostics = route.renderDiagnostics
        print(
            "Safari external route: \(externalOutput.name), input frames: \(diagnostics.inputFrames), "
                + "output frames: \(diagnostics.outputFrames), signal: \(diagnostics.receivedNonSilentAudio)"
        )
        guard diagnostics.receivedNonSilentAudio else {
            throw XCTSkip("Safari is not currently producing audio.")
        }
        XCTAssertGreaterThan(diagnostics.inputFrames, 0)
        XCTAssertGreaterThan(diagnostics.outputFrames, 0)
        XCTAssertTrue(diagnostics.receivedNonSilentAudio)
    }

    func testLiveEdgeBrowserAudioReachesNonDefaultExternalOutputRoute() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Persistent bundle routing requires macOS 26.")
        }
        let edge = try XCTUnwrap(
            CoreAudioSystem.audioApplications().first { $0.bundleID == "com.microsoft.edgemac" }
        )
        XCTAssertTrue(edge.routingBundleIDs.contains("com.microsoft.edgemac.helper"))

        let processDeadline = Date().addingTimeInterval(3)
        var helperProcessIDs = Set<AudioObjectID>()
        repeat {
            let processIDs = try CoreAudioSystem.audioObjectIDArrayProperty(
                objectID: CoreAudioSystem.systemObject,
                selector: kAudioHardwarePropertyProcessObjectList
            )
            helperProcessIDs = Set(processIDs.filter { processID in
                let bundleID = try? CoreAudioSystem.stringProperty(
                    objectID: processID,
                    selector: kAudioProcessPropertyBundleID
                )
                return bundleID == "com.microsoft.edgemac.helper"
            })
            if helperProcessIDs.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        } while helperProcessIDs.isEmpty && Date() < processDeadline
        let routedEdge = AudioApplication(
            processObjectID: helperProcessIDs.first,
            pid: edge.pid,
            bundleID: edge.bundleID,
            routingProcessObjectIDs: helperProcessIDs,
            routingBundleIDs: edge.routingBundleIDs,
            name: edge.name,
            isProducingAudio: !helperProcessIDs.isEmpty
        )

        let defaultOutputID: AudioObjectID = try CoreAudioSystem.scalarProperty(
            objectID: CoreAudioSystem.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let deviceIDs = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: CoreAudioSystem.systemObject,
            selector: kAudioHardwarePropertyDevices
        )
        print("Live browser test devices:", deviceIDs.map { deviceID in
            let transport: UInt32 = (try? CoreAudioSystem.scalarProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType
            )) ?? kAudioDeviceTransportTypeUnknown
            let name = (try? CoreAudioSystem.stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName
            )) ?? "unknown"
            return "\(deviceID):\(transport):\(name)"
        })
        let builtInDeviceID = try XCTUnwrap(
            deviceIDs.first { deviceID in
                let uid = (try? CoreAudioSystem.stringProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                )) ?? ""
                return uid == "BuiltInSpeakerDevice"
            }
        )
        let builtInOutput = AudioOutputDevice(
            objectID: builtInDeviceID,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Air Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn
        )
        let builtInRoute = try AudioRoute(
            application: routedEdge,
            outputDevices: [builtInOutput],
            diagnosticsEnabled: true
        )
        let builtInDeadline = Date().addingTimeInterval(3)
        while Date() < builtInDeadline,
              !(builtInRoute.renderDiagnostics.receivedNonSilentAudio
                && builtInRoute.renderDiagnostics.outputFrames > 0) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let builtInDiagnostics = builtInRoute.renderDiagnostics
        print(
            "Edge built-in route: input frames: \(builtInDiagnostics.inputFrames), "
                + "output frames: \(builtInDiagnostics.outputFrames), "
                + "signal: \(builtInDiagnostics.receivedNonSilentAudio)"
        )
        builtInRoute.stop()
        XCTAssertGreaterThan(builtInDiagnostics.inputFrames, 0)
        XCTAssertGreaterThan(builtInDiagnostics.outputFrames, 0)
        XCTAssertTrue(builtInDiagnostics.receivedNonSilentAudio)

        let externalDeviceID = try XCTUnwrap(
            deviceIDs.first { deviceID in
                let uid = (try? CoreAudioSystem.stringProperty(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyDeviceUID
                )) ?? ""
                return deviceID != defaultOutputID && uid.hasPrefix("AppleUSBAudioEngine:")
            },
            "A non-default USB output is required for the live browser-route test."
        )
        let externalOutput = AudioOutputDevice(
            objectID: externalDeviceID,
            uid: try CoreAudioSystem.stringProperty(
                objectID: externalDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            ),
            name: try CoreAudioSystem.stringProperty(
                objectID: externalDeviceID,
                selector: kAudioObjectPropertyName
            ),
            transportType: kAudioDeviceTransportTypeUSB
        )
        let route = try AudioRoute(
            application: routedEdge,
            outputDevices: [externalOutput],
            diagnosticsEnabled: true
        )
        defer { route.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !(route.renderDiagnostics.receivedNonSilentAudio
                && route.renderDiagnostics.outputFrames > 0) {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let diagnostics = route.renderDiagnostics
        print(
            "Edge browser route: \(externalOutput.name), input frames: \(diagnostics.inputFrames), "
                + "output frames: \(diagnostics.outputFrames), signal: \(diagnostics.receivedNonSilentAudio)"
        )
        XCTAssertGreaterThan(diagnostics.inputFrames, 0)
        XCTAssertGreaterThan(diagnostics.outputFrames, 0)
        XCTAssertTrue(diagnostics.receivedNonSilentAudio)
        route.stop()

        let mirroredRoute = try AudioRoute(
            application: routedEdge,
            outputDevices: [builtInOutput, externalOutput],
            diagnosticsEnabled: true
        )
        defer { mirroredRoute.stop() }
        let mirroredDeadline = Date().addingTimeInterval(5)
        while Date() < mirroredDeadline {
            let counts = mirroredRoute.outputRenderFrameCounts
            if mirroredRoute.renderDiagnostics.receivedNonSilentAudio,
               counts[builtInOutput.uid, default: 0] > 0,
               counts[externalOutput.uid, default: 0] > 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let mirroredCounts = mirroredRoute.outputRenderFrameCounts
        print("Edge mirrored output frames:", mirroredCounts)
        XCTAssertTrue(mirroredRoute.renderDiagnostics.receivedNonSilentAudio)
        XCTAssertGreaterThan(mirroredCounts[builtInOutput.uid, default: 0], 0)
        XCTAssertGreaterThan(mirroredCounts[externalOutput.uid, default: 0], 0)

        Thread.sleep(forTimeInterval: 2)
        let callbackCounts = mirroredRoute.outputRenderCallbackCounts
        print("Edge mirrored callback counts after stress window:", callbackCounts)
        XCTAssertGreaterThan(callbackCounts[builtInOutput.uid, default: 0], 50)
        XCTAssertGreaterThan(callbackCounts[externalOutput.uid, default: 0], 50)
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
        let aggregateDescription = AudioRoute.makeCaptureAggregateDescription(
            tapUID: tapUID,
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
        let volume = RealtimeVolume(1)
        let hardwareOutputs = try selectedOutputs.map {
            try HardwareAudioOutput(
                device: $0,
                sourceFormat: tapFormat,
                volume: volume,
                diagnosticOutputFrames: nil
            )
        }

        print("Tap format: \(Self.describe(tapFormat))")
        print("Input formats: \(inputFormats.map(Self.describe).joined(separator: "; "))")
        XCTAssertFalse(inputFormats.isEmpty)
        XCTAssertTrue(outputStreams.isEmpty)
        XCTAssertEqual(hardwareOutputs.count, 2)
        for output in hardwareOutputs {
            try output.start()
            XCTAssertTrue(output.isRunning)
            output.stop()
            XCTAssertFalse(output.isRunning)
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
        let route = try AudioRoute(
            application: application,
            outputDevices: selectedOutputs,
            volume: 0.35
        )

        XCTAssertTrue(route.isRunning)
        XCTAssertEqual(route.deviceUIDs, Set(selectedOutputs.map(\.uid)))
        XCTAssertEqual(route.volume, 0.35, accuracy: 0.0001)

        route.volume = 0.62
        XCTAssertEqual(route.volume, 0.62, accuracy: 0.0001)

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

    func testMatchingFormatRendererAppliesIndependentApplicationVolume() throws {
        let format = Self.floatStereoFormat(sampleRate: 48_000)
        let renderer = try AudioStreamRenderer(
            inputFormat: format,
            outputFormat: format,
            initialGain: 0.5
        )
        var input: [Float] = [1, -1, 0.8, -0.8, 0.4, -0.4, 0.2, -0.2]
        var output = Array(repeating: Float.zero, count: input.count)

        let status = input.withUnsafeMutableBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                renderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2),
                    gain: 0.5
                )
            }
        }

        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output, input.map { $0 * 0.5 })
    }

    func testVolumeChangeRampsAcrossBufferWithoutAClick() throws {
        let format = Self.floatStereoFormat(sampleRate: 48_000)
        let renderer = try AudioStreamRenderer(
            inputFormat: format,
            outputFormat: format,
            initialGain: 1
        )
        var input = Array(repeating: Float(1), count: 8)
        var output = Array(repeating: Float.zero, count: input.count)

        let status = input.withUnsafeMutableBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                renderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2),
                    gain: 0
                )
            }
        }

        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output, [0.75, 0.75, 0.5, 0.5, 0.25, 0.25, 0, 0])
    }

    func testSampleRateConverterAppliesVolumeToEveryMirroredOutput() throws {
        let inputFormat = Self.floatStereoFormat(sampleRate: 48_000)
        let outputFormat = Self.floatStereoFormat(sampleRate: 44_100)
        let firstRenderer = try AudioStreamRenderer(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            initialGain: 0.25
        )
        let secondRenderer = try AudioStreamRenderer(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            initialGain: 0.25
        )
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
                    output: AudioBuffer(outputPointer, numberOfChannels: 2),
                    gain: 0.25
                )
            }
        }
        let secondStatus = input.withUnsafeMutableBufferPointer { inputPointer in
            secondOutput.withUnsafeMutableBufferPointer { outputPointer in
                secondRenderer.render(
                    input: AudioBuffer(inputPointer, numberOfChannels: 2),
                    output: AudioBuffer(outputPointer, numberOfChannels: 2),
                    gain: 0.25
                )
            }
        }

        XCTAssertEqual(firstStatus, noErr)
        XCTAssertEqual(secondStatus, noErr)
        XCTAssertEqual(firstOutput, secondOutput)
        XCTAssertGreaterThan(firstOutput.map { abs($0) }.max() ?? 0, 0.02)
        XCTAssertLessThanOrEqual(firstOutput.map { abs($0) }.max() ?? 0, 0.15)
    }

    func testSampleRateConverterHandlesConsecutiveRealtimeBuffers() throws {
        let inputFormat = Self.floatStereoFormat(sampleRate: 48_000)
        let outputFormat = Self.floatStereoFormat(sampleRate: 44_100)
        let renderer = try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        let inputFrames = 480
        let outputFrames = 441

        for chunk in 0..<1_000 {
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

    func testSampleRateConverterDoesNotLeaveEqualSizedExternalOutputBuffersSilent() throws {
        let inputFormat = Self.floatStereoFormat(sampleRate: 48_000)
        let outputFormat = Self.floatStereoFormat(sampleRate: 44_100)
        let renderer = try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        let frameCount = 512

        for chunk in 0..<20 {
            var input = (0..<(frameCount * 2)).map { sample -> Float in
                let frame = chunk * frameCount + sample / 2
                return sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.5
            }
            var output = Array(repeating: Float.zero, count: frameCount * 2)
            let status = input.withUnsafeMutableBufferPointer { inputPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    renderer.render(
                        input: AudioBuffer(inputPointer, numberOfChannels: 2),
                        output: AudioBuffer(outputPointer, numberOfChannels: 2)
                    )
                }
            }

            XCTAssertEqual(status, noErr)
            let silentTail = output.suffix(64).allSatisfy { abs($0) < 0.000_001 }
            XCTAssertFalse(silentTail, "Chunk \(chunk) ended with a silent conversion gap")
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
