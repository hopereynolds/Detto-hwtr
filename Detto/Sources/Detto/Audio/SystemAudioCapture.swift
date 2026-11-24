@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    /// The current stream and whether it has delivered audio, under one
    /// lock: a stream that stops is invalidated in the same step that
    /// clears readiness, so a sample callback already in flight can't mark
    /// it live again.
    private struct StreamState {
        var stream: SCStream?
        var hasAudio = false
        var sampleCount = 0
    }
    private let _state = OSAllocatedUnfairLock<StreamState>(uncheckedState: StreamState())

    /// What survives a stream being replaced: the app the session filters
    /// to, a counter that stop() bumps so a restart in flight can't outlive
    /// it, and when the last sample arrived, so the gap a replacement
    /// leaves can be filled with silence (keeps the timeline, temp audio
    /// and speaker labels in step with the mic side).
    private struct SessionState {
        var appBundleID: String?
        var generation = 0
        var lastSampleAt: Date?
        var fillGapOnNextSample = false
    }
    private let _session = OSAllocatedUnfairLock<SessionState>(uncheckedState: SessionState())
    /// Longest gap filled with silence after a restart.
    private static let maxGapFill: TimeInterval = 120
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _micContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _audioLevel = AudioLevel()

    var audioLevel: Float { _audioLevel.value }
    /// True once the current stream has delivered audio, until it stops.
    var hasAudio: Bool { _state.withLock { $0.hasAudio } }

    /// Called (on a capture thread) when macOS stops the current stream
    /// with an error, e.g. -3815. Not called for stop().
    private let _onStreamStopped = OSAllocatedUnfairLock<(@Sendable (any Error) -> Void)?>(uncheckedState: nil)
    func setOnStreamStopped(_ handler: (@Sendable (any Error) -> Void)?) {
        _onStreamStopped.withLock { $0 = handler }
    }


    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    /// Start capturing system audio. Pass a bundle ID to filter to a specific app.
    ///
    /// The returned stream outlives any one SCStream: `restart()` replaces
    /// a stream macOS stopped and keeps feeding the same consumer.
    func bufferStream(appBundleID: String? = nil) async throws -> CaptureStreams {
        _state.withLock { $0 = StreamState() }
        let generation = _session.withLock { session -> Int in
            session.generation += 1
            session.appBundleID = appBundleID
            session.lastSampleAt = nil
            session.fillGapOnNextSample = false
            return session.generation
        }
        let sysStream = AsyncStream<AVAudioPCMBuffer> { cont in
            self._sysContinuation.withLock { $0 = cont }
        }
        try await startStream(appBundleID: appBundleID, generation: generation)
        return CaptureStreams(systemAudio: sysStream)
    }

    /// Replace a stream macOS stopped, with the same filter, feeding the
    /// same consumer. Returns false if the session was stopped meanwhile.
    func restart() async throws -> Bool {
        guard _sysContinuation.withLock({ $0 != nil }) else { return false }
        // A previous attempt's stream that never delivered: stop it first.
        let previous = _state.withLock { state -> SCStream? in
            let stream = state.stream
            state = StreamState()
            return stream
        }
        let (appBundleID, generation) = _session.withLock { session in
            session.fillGapOnNextSample = true
            return (session.appBundleID, session.generation)
        }
        try? await previous?.stopCapture()
        guard isCurrent(generation) else { return false }
        try await startStream(appBundleID: appBundleID, generation: generation)
        return isCurrent(generation)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        _session.withLock { $0.generation == generation } && _sysContinuation.withLock { $0 != nil }
    }

    private func startStream(appBundleID: String?, generation: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Build content filter — per-app if possible, otherwise all system audio
        let filter: SCContentFilter
        if let bundleID = appBundleID,
           let matchedApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            engineLog("[SYS-FILTER] Per-app filter: \(bundleID)")
            filter = SCContentFilter(display: display, including: [matchedApp], exceptingWindows: [])
        } else {
            if let bundleID = appBundleID {
                engineLog("[SYS-FILTER] App \(bundleID) not found in shareable content, falling back to all system audio")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
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
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        // stop() may have run while shareable content was loading.
        guard isCurrent(generation) else { return }
        _state.withLock { $0 = StreamState(stream: scStream) }
        do {
            try await scStream.startCapture()
        } catch {
            _state.withLock { state in
                if state.stream === scStream { state = StreamState() }
            }
            throw error
        }
        // And while it was starting: don't leave it running.
        if !isCurrent(generation) {
            _state.withLock { state in
                if state.stream === scStream { state = StreamState() }
            }
            try? await scStream.stopCapture()
        }
    }

    func stop() async {
        _session.withLock { session in
            session.generation += 1
            session.appBundleID = nil
            session.lastSampleAt = nil
            session.fillGapOnNextSample = false
        }
        let stream = _state.withLock { state -> SCStream? in
            let stream = state.stream
            state = StreamState()
            return stream
        }
        try? await stream?.stopCapture()
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
        _audioLevel.value = 0
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

        // Count the sample and mark the stream live, only if it is still
        // the current stream.
        let counted = _state.withLock { state -> Int? in
            guard state.stream === stream else { return nil }
            state.sampleCount += 1
            state.hasAudio = true
            return state.sampleCount
        }
        guard let count = counted else { return }

        // Update audio level for visualizer
        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.value = min(rms * 25, 1.0)

        // Diagnostic: log raw system audio levels periodically
        if count <= 5 || count % 200 == 0 {
            engineLog("[SYS-RAW] #\(count) frames=\(frameCount) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) rms=\(rms)")
        }

        // First sample from a replacement stream: fill the gap with silence
        // first, so everything after it stays at the right time.
        let now = Date()
        let gap = _session.withLock { session -> TimeInterval in
            defer {
                session.lastSampleAt = now
                session.fillGapOnNextSample = false
            }
            guard session.fillGapOnNextSample, let last = session.lastSampleAt else { return 0 }
            let bufferDuration = Double(frameCount) / format.sampleRate
            return min(max(now.timeIntervalSince(last) - bufferDuration, 0), Self.maxGapFill)
        }
        if gap > 0.05 {
            engineLog("[SYS-RESTART] filling \(String(format: "%.1f", gap))s gap with silence")
            for silence in Self.silence(seconds: gap, format: format) {
                _ = _sysContinuation.withLock { $0?.yield(silence) }
            }
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
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
        let wasCurrent = _state.withLock { state -> Bool in
            guard state.stream === stream else { return false }
            state = StreamState()
            return true
        }
        guard wasCurrent else {
            engineLog("[SYS-STOP] an old stream stopped with error (ignored): \(error)")
            return
        }
        engineLog("[SYS-STOP] stream stopped with error: \(error)")
        _audioLevel.value = 0
        // Keep the consumer's stream open: restart() feeds it again.
        _onStreamStopped.withLock { $0 }?(error)
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

    enum CaptureError: Error {
        case noDisplay
    }
}
