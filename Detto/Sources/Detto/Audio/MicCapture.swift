@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

final class MicCapture: @unchecked Sendable {
    /// Only touched on `queue`.
    private var engine = AVAudioEngine()
    /// Whether `engine`'s input node exists. Creating it binds the system
    /// default input (waking a Bluetooth headset), so teardown mustn't
    /// create it just to stop it. Only touched on `queue`.
    private var engineInUse = false
    /// The direct-device capture, when used instead of `engine`. Only
    /// touched on `queue`.
    private var direct: DirectDeviceCapture?
    /// Serializes engine setup and teardown, off the main thread.
    private let queue = DispatchQueue(label: "detto.mic-capture", qos: .userInitiated)
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()
    private let _tapActive = AtomicBool()
    /// Bumped by every bufferStream() and stop(). Setup work and tap
    /// callbacks from an older generation do nothing, so a Stop cancels a
    /// setup still waiting on the queue, and a retired engine's last
    /// callbacks can't mark the mic live or move the level meter.
    private let _generation = OSAllocatedUnfairLock<Int>(initialState: 0)

    private func isCurrent(_ generation: Int) -> Bool {
        _generation.withLock { $0 == generation }
    }

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }
    var tapIsActive: Bool { _tapActive.value }

    func bufferStream(deviceID: AudioDeviceID? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error
        let tapActive = _tapActive
        tapActive.value = false
        let generation = _generation.withLock { value -> Int in value += 1; return value }
        let generationLock = _generation

        return AsyncStream { continuation in
            errorHolder.value = nil

            // Set up off the caller's thread. Opening an input device can
            // block for seconds (about 3 s per step when the default input is
            // a Bluetooth headset), and the caller is the main thread: the
            // window froze and system audio waited behind it.
            self.queue.async {
                guard self.isCurrent(generation) else {
                    engineLog("[MIC-1] setup cancelled before it started (stopped)")
                    continuation.finish()
                    return
                }
                engineLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

                // Shared by both capture paths: count, report live, meter, yield.
                var tapCallCount = 0
                let deliver: (AVAudioPCMBuffer) -> Void = { buffer in
                    // Captures the lock, not self: the engine retains this
                    // block, and self owns the engine.
                    guard generationLock.withLock({ $0 == generation }) else { return }
                    tapCallCount += 1
                    if tapCallCount == 1 { tapActive.value = true }
                    let rms = Self.normalizedRMS(from: buffer)
                    level.value = min(rms * 25, 1.0)

                    if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                        engineLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                    }

                    continuation.yield(buffer)
                }

                // A specific device: open it directly, so the system default
                // input (often the Bluetooth headset) is never touched. Opening
                // it through AVAudioEngine first wakes the default device, then
                // switches: about 3 s each with a headset.
                if let id = deviceID {
                    do {
                        let started = Date()
                        self.direct = try DirectDeviceCapture.start(deviceID: id, onBuffer: deliver)
                        engineLog("[MIC-DIRECT] opened device \(id) directly (\(Int(Date().timeIntervalSince(started) * 1000))ms)")
                        if !self.isCurrent(generation) {
                            engineLog("[MIC-DIRECT] stopped while opening; closing")
                            self.direct?.stop()
                            self.direct = nil
                            continuation.finish()
                            return
                        }
                        // Safety net: if the direct path opens but sends no
                        // audio, fall back to the old AVAudioEngine path.
                        let opened = self.direct
                        self.queue.asyncAfter(deadline: .now() + Self.directFirstAudioTimeout) {
                            guard self.isCurrent(generation), !tapActive.value,
                                  let opened, self.direct === opened else { return }
                            engineLog("[MIC-DIRECT-FAIL] no audio after \(Self.directFirstAudioTimeout); falling back to AVAudioEngine")
                            opened.stop()
                            self.direct = nil
                            self.startEngine(
                                deviceID: deviceID,
                                generation: generation,
                                errorHolder: errorHolder,
                                continuation: continuation,
                                deliver: deliver
                            )
                        }
                        return
                    } catch {
                        engineLog("[MIC-DIRECT-FAIL] \(error.localizedDescription); falling back to AVAudioEngine")
                    }
                }
                self.startEngine(
                    deviceID: deviceID,
                    generation: generation,
                    errorHolder: errorHolder,
                    continuation: continuation,
                    deliver: deliver
                )
            }
        }
    }

    /// Opens the mic through AVAudioEngine. Only on `queue`.
    private func startEngine(
        deviceID: AudioDeviceID?,
        generation: Int,
        errorHolder: SyncString,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        deliver: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        self.engineInUse = true

        // Set input device before accessing inputNode format
        if let id = deviceID {
            let inputNode = self.engine.inputNode
            guard let audioUnit = inputNode.audioUnit else {
                errorHolder.value = "Failed to access audio unit for input device"
                continuation.finish()
                return
            }
            var devID = id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            engineLog("[MIC-2] setInputDevice status=\(status) (0=ok)")
            guard status == noErr else {
                let msg = "Failed to set input device (OSStatus \(status))"
                engineLog("[MIC-2-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }
        } else {
            engineLog("[MIC-2] no deviceID, using system default")
        }

        let inputNode = self.engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        engineLog("[MIC-3] inputNode format: sr=\(format.sampleRate) ch=\(format.channelCount) interleaved=\(format.isInterleaved) commonFormat=\(format.commonFormat.rawValue)")

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            let msg = "Invalid audio format: sr=\(format.sampleRate) ch=\(format.channelCount)"
            engineLog("[MIC-3-FAIL] \(msg)")
            errorHolder.value = msg
            continuation.finish()
            return
        }

        guard let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: format.channelCount
        ) else {
            let msg = "Failed to build tap format from input format"
            engineLog("[MIC-4-FAIL] \(msg)")
            errorHolder.value = msg
            continuation.finish()
            return
        }

        engineLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")

        // Opening the device can take seconds; Stop may have come in
        // meanwhile. Don't turn the mic on for a stopped session.
        guard self.isCurrent(generation) else {
            engineLog("[MIC-4] setup cancelled (stopped while opening the device)")
            continuation.finish()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            deliver(buffer)
        }

        engineLog("[MIC-5] tap installed, preparing engine...")

        do {
            self.engine.prepare()
            engineLog("[MIC-7] engine prepared, starting...")
            try self.engine.start()
            engineLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
        } catch {
            let msg = "Mic failed: \(error.localizedDescription)"
            engineLog("[MIC-8-FAIL] \(msg)")
            errorHolder.value = msg
            continuation.finish()
        }
    }

    /// Stops capture without waiting. Cancels a setup that hasn't turned
    /// the mic on yet; teardown runs on `queue`, after any setup step in
    /// progress, so a following `bufferStream` always gets a fresh engine.
    func stop() {
        beginStop()
        queue.async { self.tearDown() }
    }

    /// Stops capture and returns once the engine is actually stopped.
    func stopAndWait() async {
        beginStop()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.tearDown()
                done.resume()
            }
        }
    }

    private func beginStop() {
        _generation.withLock { $0 += 1 }
        _audioLevel.value = 0
        _tapActive.value = false
    }

    /// Only on `queue`.
    private func tearDown() {
        if let direct {
            direct.stop()
            self.direct = nil
            engineLog("[MIC-STOP] direct capture stopped")
        }
        guard engineInUse else { return }
        engineInUse = false
        let stopped = engine
        stopped.inputNode.removeTap(onBus: 0)
        stopped.stop()
        engine = AVAudioEngine()
        Self.retire(stopped)
        engineLog("[MIC-STOP] engine stopped")
    }

    /// How long the direct path gets to deliver its first buffer.
    private static let directFirstAudioTimeout: DispatchTimeInterval = .seconds(2)

    /// How long a stopped engine is kept alive before it's released.
    private static let retiredEngineLifetime: DispatchTimeInterval = .seconds(10)

    /// Keeps a stopped engine alive for a while instead of releasing it
    /// right away.
    ///
    /// CoreAudio can already have a "device changed" notification queued for
    /// the engine's input unit when we stop it (Stop, or a mic switch, often
    /// lands mid device-change storm). If the engine is freed first, that
    /// notification messages a dead object and the app crashes
    /// (EXC_BAD_ACCESS in AVAudioIOUnit::IOUnitPropertyListener).
    private static func retire(_ engine: AVAudioEngine) {
        let retired = RetiredEngine(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + retiredEngineLifetime) {
            retired.release()
        }
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let s = sampleAt(frame, channel)
                sum += s * s
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferListSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            let bufferListPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, raw)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr else { continue }

            result.append((id: deviceID, name: name as String))
        }

        return result
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        return status == noErr ? uid as String : nil
    }

    /// CoreAudio transport type for a device (e.g. Bluetooth, built-in), or nil.
    static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let transport = transportType(for: deviceID) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The built-in microphone's device ID, if this Mac has one.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        availableInputDevices().first {
            transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn
        }?.id
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}

/// Captures one specific input device with AVCaptureSession.
///
/// AVAudioEngine's input node always binds the system default input first
/// and only then switches to the requested device. With a Bluetooth
/// headset as the default, that wakes the headset's mic (about 3 s) and
/// then switches away (about 3 s more). A capture session opens just the
/// device it's given.
private final class DirectDeviceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noCaptureDevice(AudioDeviceID)
        case cannotAdd(String)
        var errorDescription: String? {
            switch self {
            case .noCaptureDevice(let id): return "no capture device for CoreAudio device \(id)"
            case .cannotAdd(let what): return "capture session can't add \(what)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "detto.mic-capture.samples", qos: .userInitiated)
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var runtimeErrorObserver: NSObjectProtocol?

    private init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    /// Blocks while the device opens; call off the main thread.
    static func start(deviceID: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws -> DirectDeviceCapture {
        // On macOS a capture device's uniqueID is the CoreAudio device UID.
        guard let uid = MicCapture.deviceUID(for: deviceID),
              let device = AVCaptureDevice(uniqueID: uid),
              device.hasMediaType(.audio) else {
            throw Failure.noCaptureDevice(deviceID)
        }
        let capture = DirectDeviceCapture(onBuffer: onBuffer)
        let session = capture.session
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure.cannotAdd("input") }
        session.addInput(input)
        // Mono float32; the transcription resampler converts the rate.
        capture.output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: 1,
        ]
        capture.output.setSampleBufferDelegate(capture, queue: capture.sampleQueue)
        guard session.canAddOutput(capture.output) else { throw Failure.cannotAdd("output") }
        session.addOutput(capture.output)
        session.commitConfiguration()

        capture.runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            engineLog("[MIC-DIRECT-ERR] capture session error: \(error?.localizedDescription ?? "unknown")")
        }
        session.startRunning()
        return capture
    }

    func stop() {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        runtimeErrorObserver = nil
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDesc = sampleBuffer.formatDescription,
              var asbd = formatDesc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return }
        onBuffer(pcm)
    }
}

/// Holds a stopped engine until `release()` is called.
private final class RetiredEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    init(_ engine: AVAudioEngine) { self.engine = engine }
    func release() { engine = nil }
}

// Thread-safe audio level
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe optional string
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe bool
final class AtomicBool: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
