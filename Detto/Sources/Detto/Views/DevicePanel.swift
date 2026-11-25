import SwiftUI
import AppKit
import CoreAudio

/// Mid-recording audio panel: which mic and output are in use, a level
/// meter and status for each side, a warning when a side goes silent,
/// reconnect buttons, and a mic switcher. Plain on purpose; styling comes
/// later.
struct DevicePanel: View {
    let engine: TranscriptionEngine

    @AppStorage("devicePanelExpanded") private var expanded = true
    @State private var inputs: [AudioDeviceInfo] = []
    @State private var output: AudioDeviceInfo?
    @State private var defaultInput: AudioDeviceInfo?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            content
        }
        .task {
            while !Task.isCancelled {
                refreshDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshDevices() {
        let newInputs = AudioDeviceInfo.inputs()
        if newInputs != inputs { inputs = newInputs }
        let newOutput = AudioDeviceInfo.defaultOutput()
        if newOutput != output { output = newOutput }
        let newDefault = MicCapture.defaultInputDeviceID().flatMap(AudioDeviceInfo.read)
        if newDefault != defaultInput { defaultInput = newDefault }
    }

    private var micHealth: AudioSideHealth {
        .mic(status: engine.micStatus, isLive: engine.micIsLive, secondsSinceSound: engine.micSecondsSinceSound)
    }

    private var callHealth: AudioSideHealth {
        .call(
            isCallCapture: engine.sessionIsCallCapture,
            unavailable: engine.callAudioUnavailable,
            stopped: engine.systemAudioStopped,
            reconnecting: engine.systemAudioReconnecting,
            hasAudio: engine.systemHasAudio,
            secondsSinceSound: engine.systemSecondsSinceSound
        )
    }

    @ViewBuilder
    private var content: some View {
        let mic = micHealth
        let call = callHealth
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("AUDIO")
                        .font(.dMono(size: 9, weight: .bold))
                        .tracking(1)
                    if !expanded {
                        summary("YOU", mic)
                        if call != .off { summary("CALL", call) }
                    }
                    Spacer()
                }
                .foregroundStyle(Color.dDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide audio devices" : "Show audio devices")

            if expanded {
                micSection(mic)
                if call != .off {
                    Divider()
                    callSection(call)
                }
            } else {
                // Warnings stay visible when the panel is folded.
                if let warning = micWarning(mic) { warningText(warning) }
                if let warning = callWarning(call) { warningText(warning) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dSurface)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Your mic

    @ViewBuilder
    private func micSection(_ health: AudioSideHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sideHeader("YOU", health: health, rms: engine.micRMS, meterLabel: "Your mic level")
            HStack(spacing: 8) {
                Picker("Mic", selection: micSelection) {
                    Text(automaticLabel).tag(AudioDeviceID(0))
                    ForEach(inputs) { device in
                        Text(device.displayName).tag(device.id)
                    }
                    if engine.userSelectedDeviceID != 0, !inputs.contains(where: { $0.id == engine.userSelectedDeviceID }) {
                        Text("Disconnected mic").tag(engine.userSelectedDeviceID)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .font(.dMono(size: 10, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!engine.canUseMicControls)
                .help("Pick another mic for the rest of this recording. The call audio keeps recording.")
                .accessibilityLabel("Microphone for this recording")

                reconnectButton("Reconnect mic", disabled: !engine.canUseMicControls || health == .reconnecting || health == .starting) {
                    engine.reconnectMic()
                }
            }
            if let note = micNote { noteText(note) }
            if let warning = micWarning(health) { warningText(warning) }
        }
    }

    private var micSelection: Binding<AudioDeviceID> {
        Binding(
            get: { engine.userSelectedDeviceID },
            set: { engine.switchMic(to: $0) }
        )
    }

    private var currentMic: AudioDeviceInfo? {
        let id = engine.currentMicDeviceID
        return inputs.first { $0.id == id }
    }

    private var automaticLabel: String {
        guard engine.userSelectedDeviceID == 0 else { return "Automatic" }
        return "Automatic: \(currentMic?.displayName ?? "starting…")"
    }

    /// Explains a mic choice that would otherwise look wrong.
    private var micNote: String? {
        if engine.userSelectedDeviceID == 0,
           let current = currentMic, current.kind == .builtIn,
           let systemDefault = defaultInput, systemDefault.kind == .bluetooth, systemDefault.id != current.id {
            return "Using the built-in mic, not \(systemDefault.name), so the headset keeps its call sound. To change it, pick the headset above."
        }
        if engine.sessionIsCallCapture, let current = currentMic, current.kind == .bluetooth {
            return "Recording from a Bluetooth mic can make the call sound worse in your headset."
        }
        return nil
    }

    private func micWarning(_ health: AudioSideHealth) -> String? {
        switch health {
        case .quiet(let seconds):
            return "No sound from your mic for \(AudioSideHealth.duration(seconds)). If you're talking, check it isn't muted, or pick another mic."
        case .lost:
            return "Your mic stopped. Press Reconnect or pick another mic."
        default:
            return nil
        }
    }

    // MARK: - Call audio

    @ViewBuilder
    private func callSection(_ health: AudioSideHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sideHeader("CALL", health: health, rms: engine.systemRMS, meterLabel: "Call audio level")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    detailText("Recording: \(scopeLabel)")
                    detailText("Mac default output: \(output?.displayName ?? "unknown")")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                reconnectButton("Reconnect call audio", disabled: !engine.canReconnectCallAudio) {
                    engine.reconnectCallAudio()
                }
            }
            if let warning = callWarning(health) { warningText(warning) }
        }
    }

    /// What the call recorder actually opened, not what was asked for:
    /// a requested app that wasn't found means all Mac audio.
    private var scopeLabel: String {
        switch engine.callAudioScope {
        case .app(let bundleID):
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            return "\(name ?? bundleID) only"
        case .allSystemAudio:
            return "all Mac audio"
        case nil:
            return engine.callAudioUnavailable ? "nothing" : "starting…"
        }
    }

    private func callWarning(_ health: AudioSideHealth) -> String? {
        switch health {
        case .quiet(let seconds):
            return "No sound from the call for \(AudioSideHealth.duration(seconds)). If people are talking, press Reconnect."
        case .lost where engine.callAudioUnavailable:
            return "Call audio isn't being recorded. See the message above."
        case .lost:
            return "Call audio stopped. Press Reconnect to try again."
        default:
            return nil
        }
    }

    // MARK: - Pieces

    private func sideHeader(_ title: String, health: AudioSideHealth, rms: Float, meterLabel: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.dMono(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color.dSecondary)
                .frame(width: 34, alignment: .leading)
            LevelMeter(fraction: health == .live || health.isQuiet ? LevelMeter.fraction(rms: rms) : 0)
                .accessibilityLabel(meterLabel)
            Text(health.label)
                .font(.dMono(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(color(for: health))
                .frame(width: 92, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ title: String, _ health: AudioSideHealth) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(for: health)).frame(width: 6, height: 6)
            Text("\(title) \(health.label)")
                .font(.dMono(size: 9, weight: .bold))
        }
    }

    private func color(for health: AudioSideHealth) -> Color {
        switch health {
        case .live: return .dGreen
        case .quiet, .starting, .reconnecting: return .dAmber
        case .lost: return .dRed
        case .off: return .dDim
        }
    }

    private func reconnectButton(_ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Reconnect", action: action)
            .controlSize(.small)
            .font(.dMono(size: 10, weight: .medium))
            .disabled(disabled)
            .accessibilityLabel(label)
            .fixedSize()
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.dMono(size: 10, weight: .medium))
            .foregroundStyle(Color.dSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.dMono(size: 9, weight: .regular))
            .foregroundStyle(Color.dDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warningText(_ text: String) -> some View {
        Text(text)
            .font(.dMono(size: 10, weight: .medium))
            .foregroundStyle(Color.dAmber)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension AudioSideHealth {
    var isQuiet: Bool {
        if case .quiet = self { return true }
        return false
    }
}

/// A plain horizontal level bar.
struct LevelMeter: View {
    /// 0...1
    let fraction: Double

    /// Maps RMS to the bar on a -60...0 dBFS scale, so room noise moves
    /// it a little and speech fills about half to three quarters.
    static func fraction(rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(max((db + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dRule)
                Capsule()
                    .fill(Color.dGreen)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
