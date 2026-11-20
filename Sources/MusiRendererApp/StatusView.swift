import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel

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
    }

    private var statusColor: Color {
        switch model.status {
        case .starting: return .orange
        case .online: return .green
        case .failed: return .red
        }
    }
}
