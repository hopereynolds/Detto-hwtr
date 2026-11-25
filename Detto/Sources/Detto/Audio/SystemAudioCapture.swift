@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    /// Which audio a recording captures. Decided once at the first open and
    /// kept for every reconnect, so a reconnect never widens an app-only
    /// recording to everything the Mac is playing.
    private enum Scope {
        case app(String)
        case allSystemAudio
    }

    /// Everything about the current recording, under one lock, so Stop
    /// invalidates the stream, its readiness and the consumer in one step,
    /// and a callback that passed the identity check can only yield into
    /// the recording it belongs to.
    private struct State {
        /// Bumped by bufferStream() and stop(); an open in flight checks it.
        var generation = 0
        var scope: Scope?
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        /// The stream currently allowed to deliver.
        var stream: SCStream?
        var hasAudio = false
        var sampleCount = 0
        /// When the last real sample arrived, for filling a reconnect's gap.
        var lastSampleAt: Date?
        /// The current stream is a replacement that hasn't delivered yet.
        var fillGapOnFirstSample = false
        /// The current stream finished starting. Only a started stream's
        /// death is reported; one that dies while starting fails its open.
        var streamStarted = false
        /// Opens and closes that haven't finished; stop() waits for them,
        /// so nothing is still capturing (or shutting down) after it.
        var busy = 0
    }
    private let _state = OSAllocatedUnfairLock<State>(uncheckedState: State())
    private let _micContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _audioLevel = AudioLevel()
    /// Raw RMS of the latest buffer, for the device panel's meter.
    private let _rms = AudioLevel()
    /// Uptime (ns) of the last buffer with sound in it, or of the current
    /// stream's first buffer; 0 before any.
    private let _lastSoundAt = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Serial, so a replacement's gap silence and first buffer go out
    /// before anything that follows them.
    private let sampleQueue = DispatchQueue(label: "detto.system-audio", qos: .userInteractive)
    /// Longest gap filled with silence after a reconnect.
    private static let maxGapFill: TimeInterval = 120

    var audioLevel: Float { _audioLevel.value }
    /// Raw RMS of the latest buffer (0...1).
    var rms: Float { _rms.value }
    /// Seconds the call audio has carried nothing but silence, or nil
    /// before its first buffer. Silence is normal when nobody's talking.
    var secondsSinceSound: Double? {
        let last = _lastSoundAt.withLock { $0 }
        guard last > 0 else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000_000
    }

    private func resetLevels() {
        _audioLevel.value = 0
        _rms.value = 0
        _lastSoundAt.withLock { $0 = 0 }
    }
    /// True once the current stream has delivered audio, until it stops.
    var hasAudio: Bool { _state.withLock { $0.hasAudio } }
    /// Identifies the current recording; stop-notices carry it.
    var generation: Int { _state.withLock { $0.generation } }

    /// Called (on a capture thread) when macOS stops the current stream
    /// with an error, e.g. -3815, with the recording's generation. Not
    /// called for stop().
    private let _onStreamStopped = OSAllocatedUnfairLock<(@Sendable (Int, any Error) -> Void)?>(uncheckedState: nil)
    func setOnStreamStopped(_ handler: (@Sendable (Int, any Error) -> Void)?) {
        _onStreamStopped.withLock { $0 = handler }
    }

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    enum CaptureError: Error, LocalizedError {
        case noDisplay
        case appNotFound(String)
        case stopped
        case diedWhileStarting

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display to capture from."
            case .appNotFound(let id): return "\(id) isn't available to capture."
            case .stopped: return "Recording stopped."
            case .diedWhileStarting: return "macOS stopped the capture while it was starting."
            }
        }
    }

    /// Start capturing system audio. Pass a bundle ID to filter to a specific app.
    ///
    /// The returned stream outlives any one SCStream: `restart()` replaces
    /// a stream macOS stopped and keeps feeding the same consumer.
    func bufferStream(appBundleID: String? = nil) async throws -> CaptureStreams {
        let (sysStream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (generation, previous) = _state.withLock { state -> (Int, AsyncStream<AVAudioPCMBuffer>.Continuation?) in
            let previous = state.continuation
            let generation = state.generation + 1
            state = State(generation: generation, continuation: continuation, busy: state.busy)
            return (generation, previous)
        }
        previous?.finish()
        resetLevels()
        try await open(generation: generation, requestedAppBundleID: appBundleID)
        return CaptureStreams(systemAudio: sysStream)
    }

    /// Replace a stream macOS stopped (or a replacement that never
    /// delivered), with the same scope, feeding the same consumer.
    /// Throws if the attempt fails; returns false if Stop ran meanwhile.
    func restart() async throws -> Bool {
        let (generation, previous) = _state.withLock { state -> (Int?, SCStream?) in
            guard state.continuation != nil, state.scope != nil else { return (nil, nil) }
            let previous = state.stream
            state.stream = nil
            state.streamStarted = false
            state.hasAudio = false
            state.sampleCount = 0
            if previous != nil { state.busy += 1 }
            return (state.generation, previous)
        }
        if let previous {
            try? await previous.stopCapture()
            _state.withLock { $0.busy -= 1 }
        }
        guard let generation else { return false }
        do {
            try await open(generation: generation, requestedAppBundleID: nil)
        } catch CaptureError.stopped {
            return false
        }
        return true
    }

    /// After a replacement missed its deadline: if it still hasn't
    /// delivered, close it so it can't come alive behind a retry or after
    /// giving up. Returns true if it's live after all.
    func closeReplacementIfSilent() async -> Bool {
        let silent = _state.withLock { state -> SCStream? in
            guard !state.hasAudio, let stream = state.stream else { return nil }
            state.stream = nil
            state.streamStarted = false
            state.busy += 1
            return stream
        }
        if let silent {
            engineLog("[SYS-RESTART] closing a replacement that never delivered")
            try? await silent.stopCapture()
            _state.withLock { $0.busy -= 1 }
            return false
        }
        return hasAudio
    }

    /// Opens a stream for `generation`. The first open resolves the scope
    /// (per-app when the app is there, otherwise all system audio, as
    /// before); later opens keep it and fail if the app is missing.
    private func open(generation: Int, requestedAppBundleID: String?) async throws {
        _state.withLock { $0.busy += 1 }
        defer { _state.withLock { $0.busy -= 1 } }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // A scope already set means an earlier open of this recording ran.
        let (savedScope, isReplacement) = _state.withLock { ($0.scope, $0.scope != nil) }
        let filter: SCContentFilter
        let scope: Scope
        switch savedScope {
        case .app(let bundleID):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                engineLog("[SYS-FILTER] \(bundleID) not in shareable content; not widening to all system audio")
                throw CaptureError.appNotFound(bundleID)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            scope = .app(bundleID)
        case .allSystemAudio:
            filter = SCContentFilter(display: display, excludingWindows: [])
            scope = .allSystemAudio
        case nil:
            if let bundleID = requestedAppBundleID,
               let matchedApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                engineLog("[SYS-FILTER] Per-app filter: \(bundleID)")
                filter = SCContentFilter(display: display, including: [matchedApp], exceptingWindows: [])
                scope = .app(bundleID)
            } else {
                if let bundleID = requestedAppBundleID {
                    engineLog("[SYS-FILTER] App \(bundleID) not found in shareable content, falling back to all system audio")
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                scope = .allSystemAudio
            }
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48000

        // Minimal video — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        // Commit the stream to this recording in the same step that checks
        // the recording is still current.
        let committed = _state.withLock { state -> Bool in
            guard state.generation == generation, state.continuation != nil else { return false }
            state.scope = scope
            state.stream = scStream
            state.streamStarted = false
            state.hasAudio = false
            state.sampleCount = 0
            state.fillGapOnFirstSample = isReplacement
            return true
        }
        guard committed else { throw CaptureError.stopped }

        do {
            try await scStream.startCapture()
        } catch {
            _state.withLock { state in
                if state.stream === scStream { state.stream = nil }
            }
            throw error
        }
        // Stop may have run while it was starting, or macOS may have
        // stopped it already. Mark it started in the same step.
        let outcome = _state.withLock { state -> CaptureError? in
            guard state.generation == generation, state.continuation != nil else { return .stopped }
            guard state.stream === scStream else { return .diedWhileStarting }
            state.streamStarted = true
            return nil
        }
        if let outcome {
            try? await scStream.stopCapture()
            if case .diedWhileStarting = outcome {
                engineLog("[SYS-STOP] stream stopped while starting; counts as a failed attempt")
            }
            throw outcome
        }
    }

    func stop() async {
        let (stream, continuation) = _state.withLock { state -> (SCStream?, AsyncStream<AVAudioPCMBuffer>.Continuation?) in
            let taken = (state.stream, state.continuation)
            state = State(generation: state.generation + 1, busy: state.busy)
            return taken
        }
        continuation?.finish()
        resetLevels()
        try? await stream?.stopCapture()
        // An open in flight stops its own stream once it sees Stop, and a
        // close in flight finishes on its own; wait for both (up to 5 s)
        // so nothing is capturing or shutting down after stop() returns.
        let deadline = ContinuousClock.now + .seconds(5)
        while _state.withLock({ $0.busy > 0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              var asbd = formatDesc.audioStreamBasicDescription else { return }

        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // A replacement's first buffer: work out the gap it left, then
        // build the silence outside the lock. The queue is serial, so no
        // later buffer from this stream can go out first.
        let now = Date()
        let pendingGap = _state.withLock { state -> TimeInterval? in
            guard state.stream === stream, state.fillGapOnFirstSample else { return nil }
            guard let last = state.lastSampleAt else { return 0 }
            let bufferDuration = Double(frameCount) / format.sampleRate
            return min(max(now.timeIntervalSince(last) - bufferDuration, 0), Self.maxGapFill)
        }
        let silence = (pendingGap ?? 0) > 0.05 ? Self.silence(seconds: pendingGap!, format: format) : []

        // Deliver only if this is still the current stream, into its own
        // recording, and mark it live only once the gap and the first
        // buffer are out.
        let counted = _state.withLock { state -> Int? in
            guard state.stream === stream, let continuation = state.continuation else { return nil }
            for buffer in silence { continuation.yield(buffer) }
            continuation.yield(pcmBuffer)
            state.fillGapOnFirstSample = false
            state.lastSampleAt = now
            state.sampleCount += 1
            state.hasAudio = true
            return state.sampleCount
        }
        guard let count = counted else { return }
        if !silence.isEmpty {
            engineLog("[SYS-RESTART] filled \(String(format: "%.1f", pendingGap ?? 0))s gap with silence")
        }

        // Update audio level for visualizer
        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.value = min(rms * 25, 1.0)
        _rms.value = rms
        if count == 1 || rms >= MicCapture.soundFloor {
            _lastSoundAt.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        }

        // Diagnostic: log raw system audio levels periodically
        if count <= 5 || count % 200 == 0 {
            engineLog("[SYS-RAW] #\(count) frames=\(frameCount) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) rms=\(rms)")
        }
    }

    /// Zeroed buffers, at most one second each, covering `seconds`.
    private static func silence(seconds: TimeInterval, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        let chunk = AVAudioFrameCount(format.sampleRate)
        var buffers: [AVAudioPCMBuffer] = []
        while remaining > 0 {
            let frames = min(remaining, chunk)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            buffer.frameLength = frames
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for audioBuffer in list {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            buffers.append(buffer)
            remaining -= frames
        }
        return buffers
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        enum Kind { case old, starting, running(Int) }
        let kind = _state.withLock { state -> Kind in
            guard state.stream === stream else { return .old }
            let started = state.streamStarted
            state.stream = nil
            state.streamStarted = false
            state.hasAudio = false
            state.sampleCount = 0
            return started ? .running(state.generation) : .starting
        }
        let generation: Int
        switch kind {
        case .old:
            engineLog("[SYS-STOP] an old stream stopped with error (ignored): \(error)")
            return
        case .starting:
            // open() sees it's gone and fails the attempt.
            engineLog("[SYS-STOP] stream stopped while starting: \(error)")
            return
        case .running(let current):
            generation = current
        }
        engineLog("[SYS-STOP] stream stopped with error: \(error)")
        _audioLevel.value = 0
        _rms.value = 0
        // Keep the consumer's stream open: restart() feeds it again.
        _onStreamStopped.withLock { $0 }?(generation, error)
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channelData[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(frameLength))
    }

}
