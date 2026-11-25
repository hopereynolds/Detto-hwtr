import CoreAudio
import XCTest
@testable import Detto

final class AudioSideHealthTests: XCTestCase {
    // MARK: Mic

    func testMicFollowsWatchdogWhenNoAudioIsFlowing() {
        XCTAssertEqual(AudioSideHealth.mic(status: .starting, isLive: false, secondsSinceSound: nil), .starting)
        XCTAssertEqual(AudioSideHealth.mic(status: .reconnecting, isLive: false, secondsSinceSound: 5), .reconnecting)
        XCTAssertEqual(AudioSideHealth.mic(status: .lost, isLive: false, secondsSinceSound: 90), .lost)
        // LIVE status but the tap stalled a moment ago: not live yet.
        XCTAssertEqual(AudioSideHealth.mic(status: .live, isLive: false, secondsSinceSound: 1), .starting)
    }

    func testMicIsLiveUntilSilentLongEnough() {
        XCTAssertEqual(AudioSideHealth.mic(status: .live, isLive: true, secondsSinceSound: 0), .live)
        XCTAssertEqual(AudioSideHealth.mic(status: .live, isLive: true, secondsSinceSound: 19.9), .live)
        XCTAssertEqual(AudioSideHealth.mic(status: .live, isLive: true, secondsSinceSound: 20), .quiet(seconds: 20))
    }

    func testFlowingAudioBeatsAStaleLostStatus() {
        // The watchdog flips LOST back to LIVE within a second; meanwhile
        // audio flowing counts.
        XCTAssertEqual(AudioSideHealth.mic(status: .lost, isLive: true, secondsSinceSound: 0), .live)
    }

    // MARK: Call audio

    func testVoiceMemoHasNoCallSide() {
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: false, stopped: true, reconnecting: true, hasAudio: true, secondsSinceSound: 0), .off)
    }

    func testCallLossBeatsEverythingElse() {
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: true, stopped: true, reconnecting: true, hasAudio: true, secondsSinceSound: 0), .reconnecting)
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: true, stopped: true, reconnecting: false, hasAudio: false, secondsSinceSound: nil), .lost)
    }

    func testCallWaitsLongerBeforeCallingItSilent() {
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: true, stopped: false, reconnecting: false, hasAudio: false, secondsSinceSound: nil), .starting)
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: true, stopped: false, reconnecting: false, hasAudio: true, secondsSinceSound: 59), .live)
        XCTAssertEqual(AudioSideHealth.call(isCallCapture: true, stopped: false, reconnecting: false, hasAudio: true, secondsSinceSound: 61), .quiet(seconds: 61))
    }

    func testOnlySilenceAndLossAskForAttention() {
        XCTAssertTrue(AudioSideHealth.quiet(seconds: 30).needsAttention)
        XCTAssertTrue(AudioSideHealth.lost.needsAttention)
        XCTAssertFalse(AudioSideHealth.reconnecting.needsAttention)
        XCTAssertFalse(AudioSideHealth.live.needsAttention)
    }

    func testDurationText() {
        XCTAssertEqual(AudioSideHealth.duration(25), "25 s")
        XCTAssertEqual(AudioSideHealth.duration(60), "1 min")
        XCTAssertEqual(AudioSideHealth.duration(150), "2 min")
    }

    // MARK: Devices

    func testDeviceKindLabels() {
        XCTAssertEqual(AudioDeviceKind(transportType: kAudioDeviceTransportTypeBluetooth).label, "Bluetooth")
        XCTAssertEqual(AudioDeviceKind(transportType: kAudioDeviceTransportTypeBluetoothLE).label, "Bluetooth")
        XCTAssertEqual(AudioDeviceKind(transportType: kAudioDeviceTransportTypeBuiltIn).label, "Built-in")
        XCTAssertEqual(AudioDeviceKind(transportType: kAudioDeviceTransportTypeUSB).label, "USB")
        XCTAssertEqual(AudioDeviceKind(transportType: kAudioDeviceTransportTypeContinuityCaptureWireless).label, "iPhone")
        XCTAssertEqual(AudioDeviceKind(transportType: nil).label, "Other")
    }

    func testDisplayNameKeepsAnUnreadableNameAndAddsTheType() {
        let headset = AudioDeviceInfo(id: 42, name: "A1-B2-C3-D4", kind: .bluetooth)
        XCTAssertEqual(headset.displayName, "A1-B2-C3-D4 · Bluetooth")
    }

    func testLevelMeterScale() {
        XCTAssertEqual(LevelMeter.fraction(rms: 0), 0)
        XCTAssertEqual(LevelMeter.fraction(rms: 0.0001), 0)        // -80 dBFS: below the bar
        XCTAssertEqual(LevelMeter.fraction(rms: 1), 1)
        XCTAssertEqual(LevelMeter.fraction(rms: 0.03), 0.492, accuracy: 0.001)  // about -30 dBFS: half
    }
}
