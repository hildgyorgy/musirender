import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let openPlayer: (() -> Void)?
    @State private var draftPosition: TimeInterval?
    @State private var editingURI: String?
    @State private var showsDiagnostics = false
    @State private var showsSettings = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: model.status.symbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.configuration.friendlyName).font(.headline)
                    Text(model.status.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let openPlayer {
                    Button(action: openPlayer) {
                        Label("Open player window", systemImage: "macwindow")
                    }
                    .labelStyle(.iconOnly)
                    .help("Open player window")
                }
            }

            if case let .failed(message) = model.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.renderer.title.isEmpty
                         ? (model.renderer.currentURI.isEmpty ? "No track loaded" : "Current track")
                         : model.renderer.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !model.renderer.artist.isEmpty {
                        Text(model.renderer.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                let source = ([model.sourceName ?? "—"] + audioDetails(model.renderer.audioFormat)).joined(separator: " • ")
                Text("SOURCE: \(source)").lineLimit(1).help(source)
                let output = outputDetails
                Text("OUTPUT: \(output)").lineLimit(1).help(output)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.selectedOutputUID != nil, model.activeOutput == nil {
                Text("Selected audio output is disconnected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.renderer.duration > 0 {
                seekControl
            }
            if let error = model.renderer.sampleRateError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.renderer.transportStatus == "ERROR_OCCURRED" {
                Text("Playback interrupted. Press Play to retry from the beginning.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            controls

            Divider()
            DisclosureGroup("Diagnostics", isExpanded: $showsDiagnostics) {
                diagnostics
            }
            DisclosureGroup("Settings", isExpanded: $showsSettings) {
                audioOutputSettings
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                .padding(.top, 6)
                if model.loginStatus == .requiresApproval {
                    Text("Approve MusiRender in System Settings → Login Items & Extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()
            HStack {
                Text("HTTP :\(model.configuration.httpPort)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 380)
        .task {
            model.refreshLoginStatus()
            while !Task.isCancelled {
                model.refreshPlayback()
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = model.artworkImage {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func audioDetails(_ format: StreamAudioFormat?) -> [String] {
        guard let format else { return [] }
        var fields = [format.codec]
        var resolution: [String] = []
        if let rate = format.sampleRateHz { resolution.append("\((rate / 1000).formatted()) kHz") }
        if let depth = format.bitDepth { resolution.append("\(depth) bit") }
        if !resolution.isEmpty { fields.append(resolution.joined(separator: " / ")) }
        if let bitrate = format.estimatedBitrateBps {
            fields.append("≈\((bitrate / 1000).formatted(.number.precision(.fractionLength(0)))) kb/s")
        }
        return fields
    }

    private var outputDetails: String {
        guard let name = model.activeOutput?.name else { return "Unavailable" }
        guard let rate = model.outputSampleRate else { return name }
        return "\(name) • \((rate / 1000).formatted()) kHz"
    }

    private var audioOutputSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Audio output", selection: Binding(
                get: { model.selectedOutputUID },
                set: model.selectAudioOutput
            )) {
                Text("System Default").tag(nil as String?)
                ForEach(model.audioOutputs, id: \.uid) { output in
                    Text(output.name).tag(Optional(output.uid))
                }
                if let uid = model.selectedOutputUID, model.activeOutput == nil {
                    Text("Selected output disconnected").tag(Optional(uid))
                }
            }
            .disabled(!model.canChangeAudioOutput)
            Toggle("Fixed digital volume (100%)", isOn: Binding(
                get: { model.fixedVolume },
                set: model.setFixedVolume
            ))
            .disabled(!model.canChangeAudioOutput || model.selectedOutputUID == nil)
            Toggle("Match source sample rate", isOn: Binding(
                get: { model.matchesSourceSampleRate },
                set: model.setMatchesSourceSampleRate
            ))
            .disabled(!model.canChangeAudioOutput || model.selectedOutputUID == nil)
            .help("Switch the selected device to the track’s sample rate before playback. Tracks with different rates require a brief pause.")
            if model.fixedVolume {
                Text("Adjust listening volume on the DAC or amplifier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.outputError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.top, 6)
    }

    private var controls: some View {
        let track = model.renderer
        let active = track.transportState == .playing || track.transportState == .transitioning
        return HStack(spacing: 8) {
            Button(action: model.togglePlayback) {
                Label(active ? "Pause" : "Play", systemImage: active ? "pause.fill" : "play.fill")
            }
            .disabled(track.currentURI.isEmpty || (!active && model.selectedOutputUID != nil && model.activeOutput == nil))
            Button(action: model.stopPlayback) { Label("Stop", systemImage: "stop.fill") }
                .disabled(track.currentURI.isEmpty)
            Button(action: model.nextTrack) { Label("Next", systemImage: "forward.end.fill") }
                .disabled(!track.canAdvanceToNext)
            Spacer()
            Button(action: model.toggleMute) {
                Label(track.isMuted ? "Unmute" : "Mute", systemImage: track.isMuted ? "speaker.slash" : "speaker.wave.2")
            }
            .disabled(model.fixedVolume)
            Slider(value: Binding(get: { Double(model.renderer.volume) },
                                  set: { model.setVolume(UInt16($0.rounded())) }), in: 0...100) {
                Text("Volume")
            }
            .labelsHidden()
            .frame(width: 96)
            .disabled(model.fixedVolume)
        }
        .labelStyle(.iconOnly)
    }

    private var diagnostics: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(model.entries.suffix(30).reversed()) { entry in
                    Text("\(Self.timestampFormatter.string(from: entry.date))  \(entry.level.rawValue)  \(entry.message)")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 130)
        .padding(.top, 6)
    }

    private var seekControl: some View {
        let track = model.renderer
        let position = editingURI == track.currentURI ? draftPosition ?? track.position : track.position
        return VStack(spacing: 4) {
            Slider(value: Binding(
                get: { min(position, track.duration) },
                set: { value in
                    if editingURI != nil {
                        draftPosition = value
                    } else {
                        model.seek(to: value, expectedURI: track.currentURI)
                    }
                }
            ), in: 0...track.duration, onEditingChanged: { isEditing in
                if isEditing {
                    editingURI = track.currentURI
                    draftPosition = nil
                } else {
                    if let editingURI, let draftPosition {
                        model.seek(to: draftPosition, expectedURI: editingURI)
                    }
                    editingURI = nil
                    draftPosition = nil
                }
            }) {
                Text("Playback position")
            }
            .labelsHidden()
            .disabled(track.transportStatus != "OK")

            HStack {
                Text(UPnPTime.format(position))
                Spacer()
                Text(UPnPTime.format(track.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .starting: return .orange
        case .online: return .green
        case .waitingForLAN: return .orange
        case .failed: return .red
        }
    }
}
