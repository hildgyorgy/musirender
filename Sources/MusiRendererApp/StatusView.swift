import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    @State private var draftPosition: TimeInterval?
    @State private var editingURI: String?

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
            }

            if case let .failed(message) = model.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            Divider()
            if !model.renderer.currentURI.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.renderer.title.isEmpty ? "Current track" : model.renderer.title)
                        .font(.headline).lineLimit(1)
                    if !model.renderer.artist.isEmpty {
                        Text(model.renderer.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(model.renderer.transportState.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.renderer.duration > 0 {
                        seekControl
                    }
                }
            }

            Divider()
            Text("Diagnostics").font(.caption).foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.entries.suffix(30).reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.timestampFormatter.string(from: entry.date))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)

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
        .frame(width: 430)
        .task {
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
        case .failed: return .red
        }
    }
}
