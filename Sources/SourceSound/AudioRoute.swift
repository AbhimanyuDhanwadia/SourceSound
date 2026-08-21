import AudioToolbox
import CoreAudio
import Foundation

final class AudioConverterInputContext {
    let bytesPerFrame: Int
    let channels: UInt32
    var buffer = AudioBuffer()
    var frameOffset = 0
    var frameCount = 0

    init(format: AudioStreamBasicDescription) {
        bytesPerFrame = Int(format.mBytesPerFrame)
        channels = format.mChannelsPerFrame
    }

    func reset(with buffer: AudioBuffer) {
        self.buffer = buffer
        frameOffset = 0
        frameCount = bytesPerFrame == 0 ? 0 : Int(buffer.mDataByteSize) / bytesPerFrame
    }
}

private let sourceSoundConverterInputProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, _, userData in
    guard
        let userData,
        let baseAddress = Unmanaged<AudioConverterInputContext>
            .fromOpaque(userData)
            .takeUnretainedValue()
            .buffer.mData
    else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    let context = Unmanaged<AudioConverterInputContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let remaining = max(0, context.frameCount - context.frameOffset)
    let supplied = min(Int(ioNumberDataPackets.pointee), remaining)
    guard supplied > 0 else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = AudioBuffer(
        mNumberChannels: context.channels,
        mDataByteSize: UInt32(supplied * context.bytesPerFrame),
        mData: baseAddress.advanced(by: context.frameOffset * context.bytesPerFrame)
    )
    context.frameOffset += supplied
    ioNumberDataPackets.pointee = UInt32(supplied)
    return noErr
}

final class AudioStreamRenderer {
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
    let requiresConversion: Bool

    private let inputContext: AudioConverterInputContext
    private var converter: AudioConverterRef?

    init(inputFormat: AudioStreamBasicDescription, outputFormat: AudioStreamBasicDescription) throws {
        guard
            inputFormat.mFormatID == kAudioFormatLinearPCM,
            outputFormat.mFormatID == kAudioFormatLinearPCM,
            inputFormat.mBytesPerFrame > 0,
            outputFormat.mBytesPerFrame > 0
        else {
            throw SourceSoundError.routeUnavailable("The selected output uses an unsupported audio format.")
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        requiresConversion = !Self.formatsMatch(inputFormat, outputFormat)
        inputContext = AudioConverterInputContext(format: inputFormat)

        if requiresConversion {
            var source = inputFormat
            var destination = outputFormat
            var newConverter: AudioConverterRef?
            try CoreAudioSystem.check(
                AudioConverterNew(&source, &destination, &newConverter),
                operation: "Create a sample-rate converter"
            )
            converter = newConverter
        }
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    @discardableResult
    func render(input: AudioBuffer, output: AudioBuffer) -> OSStatus {
        guard let inputData = input.mData, let outputData = output.mData else { return noErr }

        guard let converter else {
            memcpy(outputData, inputData, min(Int(input.mDataByteSize), Int(output.mDataByteSize)))
            return noErr
        }

        inputContext.reset(with: input)
        let outputFrameCapacity = Int(output.mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        guard outputFrameCapacity > 0 else { return noErr }

        var outputPackets = UInt32(outputFrameCapacity)
        var outputList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputFormat.mChannelsPerFrame,
                mDataByteSize: output.mDataByteSize,
                mData: outputData
            )
        )
        let contextPointer = Unmanaged.passUnretained(inputContext).toOpaque()
        return AudioConverterFillComplexBuffer(
            converter,
            sourceSoundConverterInputProc,
            contextPointer,
            &outputPackets,
            &outputList,
            nil
        )
    }

    private static func formatsMatch(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

final class AudioRoute {
    let bundleID: String
    let routingBundleIDs: Set<String>
    let deviceUIDs: Set<String>
    let processObjectID: AudioObjectID?
    let usesPersistentBundleRouting: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private var outputRenderers: [AudioStreamRenderer] = []

    init(application: AudioApplication, outputDevices: [AudioOutputDevice]) throws {
        guard #available(macOS 14.2, *) else {
            throw SourceSoundError.unsupportedOS
        }

        guard !outputDevices.isEmpty else {
            throw SourceSoundError.routeUnavailable("Select at least one connected output.")
        }

        bundleID = application.bundleID
        routingBundleIDs = application.routingBundleIDs
        deviceUIDs = Set(outputDevices.map(\.uid))
        processObjectID = application.processObjectID
        usesPersistentBundleRouting = Self.supportsPersistentBundleRouting
        guard Self.canCreateRoute(for: application) else {
            throw SourceSoundError.routeUnavailable(
                "\(application.name) is ready to route as soon as it starts using audio."
            )
        }

        do {
            try createTap(for: application)
            try createAggregateDevice(outputDevices: outputDevices)
            try configureOutputRenderers()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func stop() {
        if isRunning, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            isRunning = false
        }
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = kAudioObjectUnknown
        }
        outputRenderers.removeAll()
    }

    @available(macOS 14.2, *)
    private func createTap(for application: AudioApplication) throws {
        let description: CATapDescription
        if #available(macOS 26.0, *) {
            description = Self.makePersistentTapDescription(for: application)
        } else {
            guard let processObjectID = application.processObjectID else {
                throw SourceSoundError.routeUnavailable(
                    "\(application.name) has not connected to Core Audio yet."
                )
            }
            description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
            Self.configureTapDescription(description, applicationName: application.name)
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioSystem.check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            operation: "Create an audio tap for \(application.name)"
        )
        tapID = newTapID
    }

    static var supportsPersistentBundleRouting: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func canCreateRoute(for application: AudioApplication) -> Bool {
        supportsPersistentBundleRouting || application.processObjectID != nil
    }

    @available(macOS 26.0, *)
    static func makePersistentTapDescription(for application: AudioApplication) -> CATapDescription {
        let description = CATapDescription()
        description.bundleIDs = application.routingBundleIDs.sorted()
        description.isProcessRestoreEnabled = true
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = false
        configureTapDescription(description, applicationName: application.name)
        return description
    }

    private static func configureTapDescription(
        _ description: CATapDescription,
        applicationName: String
    ) {
        description.name = "SourceSound – \(applicationName)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.isExclusive = false
    }

    private func createAggregateDevice(outputDevices: [AudioOutputDevice]) throws {
        let tapUID = try CoreAudioSystem.tapUIDProperty(objectID: tapID)
        let routeUID = "SourceSound.Route.\(UUID().uuidString)"
        let description = Self.makeAggregateDescription(
            tapUID: tapUID,
            outputDevices: outputDevices,
            routeUID: routeUID
        )

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let names = outputDevices.map(\.name).joined(separator: ", ")
        try CoreAudioSystem.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID),
            operation: "Create a route to \(names)"
        )
        aggregateDeviceID = newDeviceID
    }

    static func makeAggregateDescription(
        tapUID: String,
        outputDevices: [AudioOutputDevice],
        routeUID: String
    ) -> [String: Any] {
        precondition(!outputDevices.isEmpty)
        let subdevices: [[String: Any]] = outputDevices.enumerated().map { index, device in
            [
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceDriftCompensationKey: index == 0 ? false : true,
                kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
            ]
        }

        return [
            kAudioAggregateDeviceNameKey: "SourceSound Route",
            kAudioAggregateDeviceUIDKey: routeUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevices[0].uid,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
    }

    private func startIO() throws {
        var newIOProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            aggregateDeviceID,
            DispatchQueue(label: "app.sourcesound.route.\(bundleID)", qos: .userInteractive)
        ) { [self] _, inputData, _, outputData, _ in
            renderAudio(from: inputData, to: outputData)
        }
        try CoreAudioSystem.check(status, operation: "Prepare audio route")
        ioProcID = newIOProcID

        try CoreAudioSystem.check(
            AudioDeviceStart(aggregateDeviceID, newIOProcID),
            operation: "Start audio route"
        )
        isRunning = true
    }

    private func configureOutputRenderers() throws {
        let inputFormat: AudioStreamBasicDescription = try CoreAudioSystem.scalarProperty(
            objectID: tapID,
            selector: kAudioTapPropertyFormat
        )
        let outputStreams = try CoreAudioSystem.audioObjectIDArrayProperty(
            objectID: aggregateDeviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard !outputStreams.isEmpty else {
            throw SourceSoundError.routeUnavailable("The selected route has no output streams.")
        }
        outputRenderers = try outputStreams.map { streamID in
            let outputFormat: AudioStreamBasicDescription = try CoreAudioSystem.scalarProperty(
                objectID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            return try AudioStreamRenderer(inputFormat: inputFormat, outputFormat: outputFormat)
        }
    }

    private func renderAudio(
        from inputData: UnsafePointer<AudioBufferList>,
        to outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        for index in outputs.indices {
            guard let outputPointer = outputs[index].mData else { continue }
            memset(outputPointer, 0, Int(outputs[index].mDataByteSize))
        }

        guard inputs.count == 1, !outputs.isEmpty else { return }
        let streamCount = min(outputs.count, outputRenderers.count)
        for index in 0..<streamCount {
            outputRenderers[index].render(input: inputs[0], output: outputs[index])
        }
    }
}
