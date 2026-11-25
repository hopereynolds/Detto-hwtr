import Foundation

/// How one side of a recording (your mic, or the call audio) is doing, for
/// the device panel. Built only from signals the engine already tracks:
/// the mic watchdog's status, the call-audio reconnect state, and how long
/// each side has carried only silence.
enum AudioSideHealth: Equatable {
    /// This recording doesn't capture this side (voice memo: no call audio).
    case off
    /// Opening; no audio yet.
    case starting
    case live
    /// Audio is arriving but has been silent for this many seconds.
    case quiet(seconds: Int)
    case reconnecting
    case lost

    /// Your mic has been sending only silence this long. A working mic
    /// picks up room noise, so this usually means it's muted or dead.
    static let micQuietAfter: Double = 20
    /// The call has been silent this long. Pauses are normal, so it waits
    /// longer and only suggests a reconnect.
    static let callQuietAfter: Double = 60

    static func mic(status: TranscriptionEngine.MicStatus, isLive: Bool, secondsSinceSound: Double?) -> AudioSideHealth {
        guard isLive else {
            switch status {
            case .lost: return .lost
            case .reconnecting: return .reconnecting
            case .starting, .live: return .starting
            }
        }
        if let quiet = secondsSinceSound, quiet >= micQuietAfter { return .quiet(seconds: Int(quiet)) }
        return .live
    }

    /// `unavailable`: the recording started without call audio (e.g. no
    /// Screen Recording permission), so it will never arrive.
    static func call(isCallCapture: Bool, unavailable: Bool = false, stopped: Bool, reconnecting: Bool, hasAudio: Bool, secondsSinceSound: Double?) -> AudioSideHealth {
        guard isCallCapture else { return .off }
        if unavailable { return .lost }
        if stopped { return reconnecting ? .reconnecting : .lost }
        guard hasAudio else { return .starting }
        if let quiet = secondsSinceSound, quiet >= callQuietAfter { return .quiet(seconds: Int(quiet)) }
        return .live
    }

    var label: String {
        switch self {
        case .off: return "OFF"
        case .starting: return "STARTING"
        case .live: return "LIVE"
        case .quiet: return "SILENT"
        case .reconnecting: return "RECONNECTING"
        case .lost: return "LOST"
        }
    }

    /// Something's wrong enough to show a warning line.
    var needsAttention: Bool {
        switch self {
        case .quiet, .lost: return true
        case .off, .starting, .live, .reconnecting: return false
        }
    }

    /// "45 s", "2 min"
    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }
}
