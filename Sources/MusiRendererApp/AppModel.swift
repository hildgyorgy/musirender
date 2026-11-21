import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case online
        case failed(String)

        var title: String {
            switch self {
            case .starting: return "Starting…"
            case .online: return "Online"
            case .failed: return "Offline"
            }
        }

        var symbol: String {
            switch self {
            case .starting: return "hourglass"
            case .online: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var renderer = RendererSnapshot()

    let configuration: RendererConfiguration
    private let runtime: RendererRuntime
    private var observerID: UUID?
    private var stateObserverID: UUID?
    private var terminationObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        let uuid: UUID
        if let stored = defaults.string(forKey: "rendererUUID"), let parsed = UUID(uuidString: stored) {
            uuid = parsed
        } else {
            uuid = UUID()
            defaults.set(uuid.uuidString, forKey: "rendererUUID")
        }

        let configuredName = defaults.string(forKey: "friendlyName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration = RendererConfiguration(
            friendlyName: configuredName?.isEmpty == false ? configuredName! : "MusiRenderer",
            uuid: uuid
        )
        runtime = RendererRuntime(configuration: configuration)

        observerID = runtime.log.observe { [weak self] snapshot in
            DispatchQueue.main.async { self?.entries = snapshot }
        }
        stateObserverID = runtime.state.observe { [weak self] snapshot in
            DispatchQueue.main.async { self?.renderer = snapshot }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak runtime] _ in
            runtime?.stop()
        }

        do {
            try runtime.start()
            status = .online
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    deinit {
        if let observerID { runtime.log.removeObserver(observerID) }
        if let stateObserverID { runtime.state.removeObserver(stateObserverID) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        runtime.stop()
    }

    func refreshPlayback() {
        let snapshot = runtime.playback.currentSnapshot()
        if renderer != snapshot { renderer = snapshot }
    }

    func seek(to position: TimeInterval, expectedURI: String) {
        do {
            try runtime.playback.seek(to: position, expectedURI: expectedURI)
        } catch {
            runtime.log.record("Seek unavailable for the current track or position", level: .warning)
        }
        refreshPlayback()
    }
}
