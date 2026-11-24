@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreMedia
import os

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamDelegate, SCStreamOutput {
    private let _stream = OSAllocatedUnfairLock<SCStream?>(uncheckedState: nil)
    private let _sysContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _micContinuation = OSAllocatedUnfairLock<AsyncStream<AVAudioPCMBuffer>.Continuation?>(uncheckedState: nil)
    private let _audioLevel = AudioLevel()
    private let _hasAudio = AtomicBool()

    var audioLevel: Float { _audioLevel.value }
    /// True once the current stream has delivered audio, until it stops.
    var hasAudio: Bool { _hasAudio.value }

    /// Called (on a capture thread) when macOS stops the current stream
    /// with an error, e.g. -3815. Not called for stop().
    private let _onStreamStopped = OSAllocatedUnfairLock<(@Sendable (any Error) -> Void)?>(uncheckedState: nil)
    func setOnStreamStopped(_ handler: (@Sendable (any Error) -> Void)?) {
        _onStreamStopped.withLock { $0 = handler }
    }

    private func isCurrent(_ stream: SCStream) -> Bool {
        _stream.withLock { $0 === stream }
    }

    struct CaptureStreams {
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    /// Start capturing system audio. Pass a bundle ID to filter to a specific app.
    func bufferStream(appBundleID: String? = nil) async throws -> CaptureStreams {
        _hasAudio.value = false
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

        let sysStream = AsyncStream<AVAudioPCMBuffer> { cont in
            self._sysContinuation.withLock { $0 = cont }
        }

        _stream.withLock { $0 = scStream }
        try await scStream.startCapture()

        return CaptureStreams(systemAudio: sysStream)
    }

    func stop() async {
        try? await _stream.withLock { $0 }?.stopCapture()
        _stream.withLock { $0 = nil }
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
        _audioLevel.value = 0
        _hasAudio.value = false
        _sampleCount.withLock { $0 = 0 }
    }

    // MARK: - SCStreamOutput

    private let _sampleCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isCurrent(stream) else { return }
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

        // Update audio level for visualizer
        let rms = Self.normalizedRMS(from: pcmBuffer)
        _audioLevel.value = min(rms * 25, 1.0)

        // Diagnostic: log raw system audio levels periodically
        let count = _sampleCount.withLock { val -> Int in val += 1; return val }
        if count == 1 { _hasAudio.value = true }
        if count <= 5 || count % 200 == 0 {
            engineLog("[SYS-RAW] #\(count) frames=\(frameCount) sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) rms=\(rms)")
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard isCurrent(stream) else {
            engineLog("[SYS-STOP] an old stream stopped with error (ignored): \(error)")
            return
        }
        engineLog("[SYS-STOP] stream stopped with error: \(error)")
        _hasAudio.value = false
        _audioLevel.value = 0
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
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
