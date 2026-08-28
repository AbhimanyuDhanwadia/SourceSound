import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation
import SourceSoundAtomics

final class RealtimeUInt32 {
    private let storage: OpaquePointer

    init(_ value: UInt32 = 0) {
        guard let storage = SourceSoundAtomicUInt32Create(value) else {
            preconditionFailure("Unable to allocate atomic storage")
        }
        self.storage = storage
    }

    deinit {
        SourceSoundAtomicUInt32Destroy(storage)
    }

    var value: UInt32 {
        get { SourceSoundAtomicUInt32LoadRelaxed(storage) }
        set { SourceSoundAtomicUInt32StoreRelaxed(storage, newValue) }
    }

    var acquiredValue: UInt32 {
        SourceSoundAtomicUInt32LoadAcquire(storage)
    }

    func storeRelease(_ value: UInt32) {
        SourceSoundAtomicUInt32StoreRelease(storage, value)
    }

    @discardableResult
    func increment(by value: UInt32 = 1) -> UInt32 {
        SourceSoundAtomicUInt32FetchAddRelaxed(storage, value)
    }
}

final class RealtimeVolume {
    private let bits: RealtimeUInt32

    init(_ value: Float = 1) {
        bits = RealtimeUInt32(Self.clamped(value).bitPattern)
    }

    var value: Float {
        get { Float(bitPattern: bits.value) }
        set { bits.value = Self.clamped(newValue).bitPattern }
    }

    private static func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }
}

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

@available(macOS 26.0, *)
private let sourceSoundRealtimeConverterInputProc: AudioConverterComplexInputDataProcRealtimeSafe = {
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
    private var currentGain: Float

    init(
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription,
        initialGain: Float = 1
    ) throws {
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
        currentGain = Self.clampedGain(initialGain)

        if requiresConversion {
            var source = inputFormat
            var destination = outputFormat
            var newConverter: AudioConverterRef?
            try CoreAudioSystem.check(
                AudioConverterNew(&source, &destination, &newConverter),
                operation: "Create a sample-rate converter"
            )
            if inputFormat.mSampleRate != outputFormat.mSampleRate, let newConverter {
                var complexity = UInt32(kAudioConverterSampleRateConverterComplexity_MinimumPhase)
                _ = AudioConverterSetProperty(
                    newConverter,
                    kAudioConverterSampleRateConverterComplexity,
                    UInt32(MemoryLayout<UInt32>.size),
                    &complexity
                )
                var quality = UInt32(kAudioConverterQuality_Low)
                _ = AudioConverterSetProperty(
                    newConverter,
                    kAudioConverterSampleRateConverterQuality,
                    UInt32(MemoryLayout<UInt32>.size),
                    &quality
                )
            }
            converter = newConverter
        }
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    @discardableResult
    func render(input: AudioBuffer, output: AudioBuffer, gain: Float = 1) -> OSStatus {
        guard let inputData = input.mData, let outputData = output.mData else { return noErr }

        guard let converter else {
            let byteCount = min(Int(input.mDataByteSize), Int(output.mDataByteSize))
            memcpy(outputData, inputData, byteCount)
            var renderedOutput = output
            renderedOutput.mDataByteSize = UInt32(byteCount)
            applyGain(to: renderedOutput, targetGain: gain)
            return noErr
        }

        let inputFrameCount = Int(input.mDataByteSize) / Int(inputFormat.mBytesPerFrame)
        let outputFrameCapacity = Int(output.mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        guard inputFrameCount > 0, outputFrameCapacity > 0 else { return noErr }

        // Aggregate devices can occasionally provide the tap and a non-default
        // hardware output with equal frame counts even though their advertised sample
        // rates differ. A nominal-rate AudioConverter can only fill part of that output
        // buffer, leaving a periodic silent tail. When callback geometry and nominal
        // rates disagree, both buffers represent the same IO cycle, so adapt the whole
        // input block to the whole output block instead.
        if callbackFrameRatioRequiresAdaptation(
            inputFrames: inputFrameCount,
            outputFrames: outputFrameCapacity
        ), renderAdaptiveBlock(input: input, output: output) {
            applyGain(to: output, targetGain: gain)
            return noErr
        }

        inputContext.reset(with: input)

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
        let status: OSStatus
        if #available(macOS 26.0, *) {
            status = AudioConverterFillComplexBufferRealtimeSafe(
                converter,
                sourceSoundRealtimeConverterInputProc,
                contextPointer,
                &outputPackets,
                &outputList,
                nil
            )
        } else {
            status = AudioConverterFillComplexBuffer(
                converter,
                sourceSoundConverterInputProc,
                contextPointer,
                &outputPackets,
                &outputList,
                nil
            )
        }
        if status == noErr {
            applyGain(to: outputList.mBuffers, targetGain: gain)
        }
        return status
    }

    private func callbackFrameRatioRequiresAdaptation(
        inputFrames: Int,
        outputFrames: Int
    ) -> Bool {
        let nominalOutputFrames = Double(inputFrames)
            * outputFormat.mSampleRate / inputFormat.mSampleRate
        let tolerance = max(2, nominalOutputFrames * 0.02)
        return abs(Double(outputFrames) - nominalOutputFrames) > tolerance
    }

    private func renderAdaptiveBlock(input: AudioBuffer, output: AudioBuffer) -> Bool {
        guard
            let inputData = input.mData,
            let outputData = output.mData,
            inputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            inputFormat.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
            inputFormat.mChannelsPerFrame > 0
        else { return false }

        let inputFrames = Int(input.mDataByteSize) / Int(inputFormat.mBytesPerFrame)
        let outputFrames = Int(output.mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        let channels = Int(inputFormat.mChannelsPerFrame)
        guard inputFrames > 0, outputFrames > 0 else { return false }

        let inputBits = inputFormat.mBitsPerChannel
        let outputBits = outputFormat.mBitsPerChannel
        let sourceScale = outputFrames > 1
            ? Double(max(0, inputFrames - 1)) / Double(outputFrames - 1)
            : 0

        switch (inputBits, outputBits) {
        case (32, 32):
            let source = inputData.assumingMemoryBound(to: Float.self)
            let destination = outputData.assumingMemoryBound(to: Float.self)
            interpolate(
                source: source,
                destination: destination,
                inputFrames: inputFrames,
                outputFrames: outputFrames,
                channels: channels,
                sourceScale: sourceScale
            )
        case (64, 64):
            let source = inputData.assumingMemoryBound(to: Double.self)
            let destination = outputData.assumingMemoryBound(to: Double.self)
            interpolate(
                source: source,
                destination: destination,
                inputFrames: inputFrames,
                outputFrames: outputFrames,
                channels: channels,
                sourceScale: sourceScale
            )
        case (32, 64):
            let source = inputData.assumingMemoryBound(to: Float.self)
            let destination = outputData.assumingMemoryBound(to: Double.self)
            interpolateConverting(
                source: source,
                destination: destination,
                inputFrames: inputFrames,
                outputFrames: outputFrames,
                channels: channels,
                sourceScale: sourceScale
            )
        case (64, 32):
            let source = inputData.assumingMemoryBound(to: Double.self)
            let destination = outputData.assumingMemoryBound(to: Float.self)
            interpolateConverting(
                source: source,
                destination: destination,
                inputFrames: inputFrames,
                outputFrames: outputFrames,
                channels: channels,
                sourceScale: sourceScale
            )
        default:
            return false
        }
        return true
    }

    private func interpolate<T: BinaryFloatingPoint>(
        source: UnsafePointer<T>,
        destination: UnsafeMutablePointer<T>,
        inputFrames: Int,
        outputFrames: Int,
        channels: Int,
        sourceScale: Double
    ) {
        for outputFrame in 0..<outputFrames {
            let sourcePosition = Double(outputFrame) * sourceScale
            let firstFrame = min(Int(sourcePosition), inputFrames - 1)
            let secondFrame = min(firstFrame + 1, inputFrames - 1)
            let fraction = T(sourcePosition - Double(firstFrame))
            for channel in 0..<channels {
                let first = source[firstFrame * channels + channel]
                let second = source[secondFrame * channels + channel]
                destination[outputFrame * channels + channel] = first + (second - first) * fraction
            }
        }
    }

    private func interpolateConverting<Source: BinaryFloatingPoint, Destination: BinaryFloatingPoint>(
        source: UnsafePointer<Source>,
        destination: UnsafeMutablePointer<Destination>,
        inputFrames: Int,
        outputFrames: Int,
        channels: Int,
        sourceScale: Double
    ) {
        for outputFrame in 0..<outputFrames {
            let sourcePosition = Double(outputFrame) * sourceScale
            let firstFrame = min(Int(sourcePosition), inputFrames - 1)
            let secondFrame = min(firstFrame + 1, inputFrames - 1)
            let fraction = sourcePosition - Double(firstFrame)
            for channel in 0..<channels {
                let first = Double(source[firstFrame * channels + channel])
                let second = Double(source[secondFrame * channels + channel])
                destination[outputFrame * channels + channel] = Destination(
                    first + (second - first) * fraction
                )
            }
        }
    }

    private func applyGain(to buffer: AudioBuffer, targetGain: Float) {
        let targetGain = Self.clampedGain(targetGain)
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
            currentGain = targetGain
            return
        }

        let isFloat = outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytesPerSample = Int(outputFormat.mBitsPerChannel / 8)
        guard isFloat, bytesPerSample == 4 || bytesPerSample == 8 else {
            if targetGain == 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            currentGain = targetGain
            return
        }

        let channelCount = max(1, Int(buffer.mNumberChannels))
        let sampleCount = Int(buffer.mDataByteSize) / bytesPerSample
        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else {
            currentGain = targetGain
            return
        }

        if currentGain == 1, targetGain == 1 { return }

        let gainStep = (targetGain - currentGain) / Float(frameCount)
        if bytesPerSample == 4 {
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let frameGain = currentGain + gainStep * Float(frame + 1)
                let firstSample = frame * channelCount
                for channel in 0..<channelCount {
                    samples[firstSample + channel] *= frameGain
                }
            }
        } else {
            let samples = data.assumingMemoryBound(to: Double.self)
            for frame in 0..<frameCount {
                let frameGain = Double(currentGain + gainStep * Float(frame + 1))
                let firstSample = frame * channelCount
                for channel in 0..<channelCount {
                    samples[firstSample + channel] *= frameGain
                }
            }
        }
        currentGain = targetGain
    }

    private static func clampedGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return 1 }
        return min(max(gain, 0), 1)
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

final class RealtimeAudioRingBuffer {
    private let capacityFrames: Int
    private let channels: Int
    private let samples: UnsafeMutablePointer<Float>
    private let readIndex = RealtimeUInt32()
    private let writeIndex = RealtimeUInt32()
    private var isPrimed = false
    private var currentGain: Float

    init(capacityFrames: Int = 32_768, channels: Int, initialGain: Float) {
        precondition(capacityFrames > 0 && capacityFrames < Int(UInt32.max / 2))
        precondition(channels > 0)
        self.capacityFrames = capacityFrames
        self.channels = channels
        currentGain = min(max(initialGain, 0), 1)
        samples = .allocate(capacity: capacityFrames * channels)
        samples.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit {
        samples.deinitialize(count: capacityFrames * channels)
        samples.deallocate()
    }

    func write(_ buffer: AudioBuffer) {
        guard
            let source = buffer.mData?.assumingMemoryBound(to: Float.self),
            Int(buffer.mNumberChannels) == channels
        else { return }

        let frameCount = Int(buffer.mDataByteSize)
            / (MemoryLayout<Float>.size * channels)
        guard frameCount > 0 else { return }

        let read = readIndex.acquiredValue
        let write = writeIndex.value
        let used = min(Int(write &- read), capacityFrames)
        let writableFrames = min(frameCount, capacityFrames - used)
        guard writableFrames > 0 else { return }

        let startFrame = Int(write % UInt32(capacityFrames))
        let firstFrames = min(writableFrames, capacityFrames - startFrame)
        memcpy(
            samples.advanced(by: startFrame * channels),
            source,
            firstFrames * channels * MemoryLayout<Float>.size
        )
        let remainingFrames = writableFrames - firstFrames
        if remainingFrames > 0 {
            memcpy(
                samples,
                source.advanced(by: firstFrames * channels),
                remainingFrames * channels * MemoryLayout<Float>.size
            )
        }
        writeIndex.storeRelease(write &+ UInt32(writableFrames))
    }

    func render(
        frameCount: Int,
        to outputData: UnsafeMutablePointer<AudioBufferList>,
        targetGain: Float
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        guard frameCount > 0, !buffers.isEmpty else { return noErr }

        let read = readIndex.value
        let write = writeIndex.acquiredValue
        let availableFrames = min(Int(write &- read), capacityFrames)
        let prefillFrames = min(capacityFrames / 2, max(frameCount * 2, 512))
        if !isPrimed {
            guard availableFrames >= prefillFrames else { return noErr }
            isPrimed = true
        }

        let readableFrames = min(frameCount, availableFrames)
        guard readableFrames > 0 else {
            isPrimed = false
            return noErr
        }

        let gain = targetGain.isFinite ? min(max(targetGain, 0), 1) : 1
        let gainStep = (gain - currentGain) / Float(max(1, readableFrames))
        let startFrame = Int(read % UInt32(capacityFrames))

        if buffers.count == 1,
           let destination = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let outputChannels = max(1, Int(buffers[0].mNumberChannels))
            for frame in 0..<readableFrames {
                let sourceFrame = (startFrame + frame) % capacityFrames
                let frameGain = currentGain + gainStep * Float(frame + 1)
                for channel in 0..<outputChannels {
                    let sourceChannel = min(channel, channels - 1)
                    destination[frame * outputChannels + channel]
                        = samples[sourceFrame * channels + sourceChannel] * frameGain
                }
            }
        } else {
            let outputChannels = min(buffers.count, channels)
            for frame in 0..<readableFrames {
                let sourceFrame = (startFrame + frame) % capacityFrames
                let frameGain = currentGain + gainStep * Float(frame + 1)
                for channel in 0..<outputChannels {
                    guard let destination = buffers[channel].mData?
                        .assumingMemoryBound(to: Float.self) else { continue }
                    destination[frame] = samples[sourceFrame * channels + channel] * frameGain
                }
            }
        }

        currentGain = gain
        readIndex.storeRelease(read &+ UInt32(readableFrames))
        if readableFrames < frameCount { isPrimed = false }
        return noErr
    }
}

private let sourceSoundHardwareOutputCallback: AURenderCallback = {
    context, _, _, _, frameCount, outputData in
    guard let outputData else { return noErr }
    return Unmanaged<HardwareAudioOutput>
        .fromOpaque(context)
        .takeUnretainedValue()
        .render(frameCount: Int(frameCount), outputData: outputData)
}

final class HardwareAudioOutput {
    let device: AudioOutputDevice
    let ringBuffer: RealtimeAudioRingBuffer

    private let volume: RealtimeVolume
    private let diagnosticOutputFrames: RealtimeUInt32?
    private let renderedFrameCount = RealtimeUInt32()
    private let renderCallbackCount = RealtimeUInt32()
    private var audioUnit: AudioUnit?
    private(set) var isRunning = false

    var lastRenderFrameCount: UInt32 { renderedFrameCount.value }
    var callbackCount: UInt32 { renderCallbackCount.value }

    init(
        device: AudioOutputDevice,
        sourceFormat: AudioStreamBasicDescription,
        volume: RealtimeVolume,
        diagnosticOutputFrames: RealtimeUInt32?
    ) throws {
        guard
            sourceFormat.mFormatID == kAudioFormatLinearPCM,
            sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            sourceFormat.mBitsPerChannel == 32,
            sourceFormat.mChannelsPerFrame > 0
        else {
            throw SourceSoundError.routeUnavailable(
                "The captured audio format cannot be sent to \(device.name)."
            )
        }

        self.device = device
        self.volume = volume
        self.diagnosticOutputFrames = diagnosticOutputFrames
        ringBuffer = RealtimeAudioRingBuffer(
            channels: Int(sourceFormat.mChannelsPerFrame),
            initialGain: volume.value
        )

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw SourceSoundError.routeUnavailable("Core Audio output is unavailable.")
        }

        var newAudioUnit: AudioUnit?
        try CoreAudioSystem.check(
            AudioComponentInstanceNew(component, &newAudioUnit),
            operation: "Create an output for \(device.name)"
        )
        guard let newAudioUnit else {
            throw SourceSoundError.routeUnavailable("Unable to open \(device.name).")
        }
        audioUnit = newAudioUnit

        do {
            var deviceID = device.objectID
            try CoreAudioSystem.check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioObjectID>.size)
                ),
                operation: "Select \(device.name)"
            )

            var clientFormat = sourceFormat
            try CoreAudioSystem.check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &clientFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: "Configure \(device.name)"
            )

            var callback = AURenderCallbackStruct(
                inputProc: sourceSoundHardwareOutputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try CoreAudioSystem.check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "Prepare \(device.name)"
            )
            try CoreAudioSystem.check(
                AudioUnitInitialize(newAudioUnit),
                operation: "Initialize \(device.name)"
            )
        } catch {
            AudioComponentInstanceDispose(newAudioUnit)
            audioUnit = nil
            throw error
        }
    }

    deinit {
        stop()
        if let audioUnit {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
    }

    func start() throws {
        guard let audioUnit, !isRunning else { return }
        try CoreAudioSystem.check(
            AudioOutputUnitStart(audioUnit),
            operation: "Start \(device.name)"
        )
        isRunning = true
    }

    func stop() {
        guard let audioUnit, isRunning else { return }
        AudioOutputUnitStop(audioUnit)
        isRunning = false
    }

    fileprivate func render(
        frameCount: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        renderCallbackCount.increment()
        renderedFrameCount.value = UInt32(frameCount)
        diagnosticOutputFrames?.value = UInt32(frameCount)
        return ringBuffer.render(
            frameCount: frameCount,
            to: outputData,
            targetGain: volume.value
        )
    }
}

final class AudioRoute {
    struct RenderDiagnostics {
        let inputFrames: UInt32
        let outputFrames: UInt32
        let receivedNonSilentAudio: Bool
    }

    let bundleID: String
    let routingBundleIDs: Set<String>
    let routingProcessObjectIDs: Set<AudioObjectID>
    let deviceUIDs: Set<String>
    let processObjectID: AudioObjectID?
    let usesPersistentBundleRouting: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private var hardwareOutputs: [HardwareAudioOutput] = []
    private let realtimeVolume: RealtimeVolume
    private let diagnosticsEnabled: Bool
    private let diagnosticInputFrames = RealtimeUInt32()
    private let diagnosticOutputFrames = RealtimeUInt32()
    private let diagnosticReceivedAudio = RealtimeUInt32()
    private var tapInputFormat: AudioStreamBasicDescription?

    init(
        application: AudioApplication,
        outputDevices: [AudioOutputDevice],
        volume: Float = 1,
        diagnosticsEnabled: Bool = false,
        persistentBundleRoutingEnabled: Bool = AudioRoute.supportsPersistentBundleRouting
    ) throws {
        guard #available(macOS 14.2, *) else {
            throw SourceSoundError.unsupportedOS
        }

        guard !outputDevices.isEmpty else {
            throw SourceSoundError.routeUnavailable("Select at least one connected output.")
        }

        bundleID = application.bundleID
        routingBundleIDs = application.routingBundleIDs
        routingProcessObjectIDs = application.routingProcessObjectIDs
        deviceUIDs = Set(outputDevices.map(\.uid))
        processObjectID = application.processObjectID
        usesPersistentBundleRouting = persistentBundleRoutingEnabled
            && Self.supportsPersistentBundleRouting
        realtimeVolume = RealtimeVolume(volume)
        self.diagnosticsEnabled = diagnosticsEnabled
        guard Self.canCreateRoute(for: application) else {
            throw SourceSoundError.routeUnavailable(
                "\(application.name) is ready to route as soon as it starts using audio."
            )
        }

        do {
            try createTap(for: application, usePersistentBundleRouting: usesPersistentBundleRouting)
            try createCaptureAggregateDevice()
            try configureHardwareOutputs(outputDevices)
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    var volume: Float {
        get { realtimeVolume.value }
        set { realtimeVolume.value = newValue }
    }

    var renderDiagnostics: RenderDiagnostics {
        RenderDiagnostics(
            inputFrames: diagnosticInputFrames.value,
            outputFrames: diagnosticOutputFrames.value,
            receivedNonSilentAudio: diagnosticReceivedAudio.value != 0
        )
    }

    var outputRenderFrameCounts: [String: UInt32] {
        Dictionary(uniqueKeysWithValues: hardwareOutputs.map {
            ($0.device.uid, $0.lastRenderFrameCount)
        })
    }

    var outputRenderCallbackCounts: [String: UInt32] {
        Dictionary(uniqueKeysWithValues: hardwareOutputs.map {
            ($0.device.uid, $0.callbackCount)
        })
    }

    func stop() {
        if isRunning, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            isRunning = false
        }
        hardwareOutputs.forEach { $0.stop() }
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
        hardwareOutputs.removeAll()
    }

    @available(macOS 14.2, *)
    private func createTap(
        for application: AudioApplication,
        usePersistentBundleRouting: Bool
    ) throws {
        let description: CATapDescription
        if #available(macOS 26.0, *), usePersistentBundleRouting {
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
        description.processes = application.routingProcessObjectIDs.sorted()
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

    private func createCaptureAggregateDevice() throws {
        let tapUID = try CoreAudioSystem.tapUIDProperty(objectID: tapID)
        let routeUID = "SourceSound.Route.\(UUID().uuidString)"
        let description = Self.makeCaptureAggregateDescription(
            tapUID: tapUID,
            routeUID: routeUID
        )

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioSystem.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID),
            operation: "Create the audio capture route"
        )
        aggregateDeviceID = newDeviceID
    }

    static func makeCaptureAggregateDescription(
        tapUID: String,
        routeUID: String
    ) -> [String: Any] {
        return [
            kAudioAggregateDeviceNameKey: "SourceSound Route",
            kAudioAggregateDeviceUIDKey: routeUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: false
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
        ) { [self] _, inputData, _, _, _ in
            captureAudio(from: inputData)
        }
        try CoreAudioSystem.check(status, operation: "Prepare audio route")
        ioProcID = newIOProcID

        try CoreAudioSystem.check(
            AudioDeviceStart(aggregateDeviceID, newIOProcID),
            operation: "Start audio capture"
        )
        isRunning = true
        for output in hardwareOutputs {
            try output.start()
        }
    }

    private func configureHardwareOutputs(_ outputDevices: [AudioOutputDevice]) throws {
        let inputFormat: AudioStreamBasicDescription = try CoreAudioSystem.scalarProperty(
            objectID: tapID,
            selector: kAudioTapPropertyFormat
        )
        tapInputFormat = inputFormat
        hardwareOutputs = try outputDevices.map { device in
            try HardwareAudioOutput(
                device: device,
                sourceFormat: inputFormat,
                volume: realtimeVolume,
                diagnosticOutputFrames: diagnosticsEnabled ? diagnosticOutputFrames : nil
            )
        }
    }

    private func captureAudio(from inputData: UnsafePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard inputs.count == 1 else { return }

        if diagnosticsEnabled {
            let inputFrames = tapInputFormat.map {
                $0.mBytesPerFrame == 0 ? 0 : inputs[0].mDataByteSize / $0.mBytesPerFrame
            } ?? 0
            diagnosticInputFrames.value = inputFrames
            if diagnosticReceivedAudio.value == 0, Self.containsNonSilentFloatAudio(inputs[0]) {
                diagnosticReceivedAudio.value = 1
            }
        }

        for output in hardwareOutputs {
            output.ringBuffer.write(inputs[0])
        }
    }

    private static func containsNonSilentFloatAudio(_ buffer: AudioBuffer) -> Bool {
        guard let data = buffer.mData else { return false }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for index in 0..<count where abs(samples[index]) > 0.000_001 {
            return true
        }
        return false
    }
}
