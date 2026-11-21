import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case online
        case waitingForLAN
        case failed(String)

        var title: String {
            switch self {
            case .starting: return "Starting…"
            case .online: return "Online"
            case .waitingForLAN: return "Waiting for LAN"
            case .failed: return "Offline"
            }
        }

        var symbol: String {
            switch self {
            case .starting: return "hourglass"
            case .online: return "checkmark.circle.fill"
            case .waitingForLAN: return "wifi.slash"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var renderer = RendererSnapshot()
    @Published private(set) var outputName = DefaultAudioOutput.currentName()
    @Published private(set) var sourceName: String?
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginError: String?

    let configuration: RendererConfiguration
    private let runtime: RendererRuntime
    private let nowPlaying: SystemNowPlaying
    private var defaultAudioOutput: DefaultAudioOutput?
    private var observerID: UUID?
    private var stateObserverID: UUID?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sourceStream: URL?
    private var sourceLookup: Task<Void, Never>?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?

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
            friendlyName: configuredName.flatMap { $0.isEmpty ? nil : $0 } ?? RendererConfiguration.productName,
            uuid: uuid
        )
        runtime = RendererRuntime(configuration: configuration)
        nowPlaying = SystemNowPlaying(playback: runtime.playback)
        defaultAudioOutput = DefaultAudioOutput { [weak self] name in
            self?.updateOutputName(name)
        }
        updateOutputName(DefaultAudioOutput.currentName())

        observerID = runtime.log.observe { [weak self] snapshot in
            DispatchQueue.main.async { self?.entries = snapshot }
        }
        stateObserverID = runtime.state.observe { [weak self] _ in
            // The state update may concern volume or metadata. Read the current
            // player clock so it cannot overwrite a newer position from polling.
            DispatchQueue.main.async { self?.refreshPlayback() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak runtime] _ in
            runtime?.stop()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak runtime] _ in
            runtime?.refreshAfterWake()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, runtime] in
            do {
                try runtime.start { message in
                    DispatchQueue.main.async { self?.status = .failed(message) }
                }
                let readyStatus: Status = runtime.hasLANInterface ? .online : .waitingForLAN
                DispatchQueue.main.async {
                    if self?.status == .starting { self?.status = readyStatus }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.status = .failed(message) }
            }
        }
    }

    deinit {
        sourceLookup?.cancel()
        artworkTask?.cancel()
        if let observerID { runtime.log.removeObserver(observerID) }
        if let stateObserverID { runtime.state.removeObserver(stateObserverID) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        runtime.stop()
    }

    func refreshPlayback() {
        let snapshot = runtime.playback.currentSnapshot()
        if renderer != snapshot { renderer = snapshot }
        refreshSource(for: snapshot.currentURI)
        refreshArtwork(for: snapshot.artworkURL)
    }

    private func refreshArtwork(for url: URL?) {
        guard url != artworkURL else { return }
        artworkTask?.cancel()
        artworkURL = url
        artworkImage = nil
        nowPlaying.setArtwork(nil, for: url)
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let image = await ArtworkLoader.image(from: url),
                  !Task.isCancelled, let self, self.artworkURL == url else { return }
            self.artworkImage = image
            self.nowPlaying.setArtwork(image, for: url)
        }
    }

    private func refreshSource(for uri: String) {
        let url = URL(string: uri).flatMap { $0.host == nil ? nil : $0 }
        guard url != sourceStream else { return }
        sourceLookup?.cancel()
        sourceStream = url
        let fallback = url?.host.map { host in
            host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." } ? "Network stream" : host
        }
        sourceName = fallback
        guard let url else { return }
        sourceLookup = Task { [weak self, runtime] in
            guard let name = await runtime.mediaSourceName(for: url),
                  !Task.isCancelled, self?.sourceStream == url else { return }
            self?.sourceName = name
        }
    }

    func refreshStatus() {
        switch status {
        case .online, .waitingForLAN:
            let actual: Status = runtime.hasLANInterface ? .online : .waitingForLAN
            if status != actual { status = actual }
        case .starting, .failed:
            break
        }
    }

    private func updateOutputName(_ name: String?) {
        if outputName != name { outputName = name }
    }

    func togglePlayback() {
        perform {
            let state = runtime.playback.currentSnapshot().transportState
            if state == .playing || state == .transitioning {
                try runtime.playback.pause()
            } else {
                try runtime.playback.play()
            }
        }
    }

    func stopPlayback() { perform { try runtime.playback.stop() } }
    func nextTrack() { perform { try runtime.playback.next() } }
    func toggleMute() { perform { runtime.playback.setMuted(!runtime.state.snapshot().isMuted) } }
    func setVolume(_ value: UInt16) { runtime.playback.setVolume(value) }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            runtime.log.record("Playback command unavailable", level: .warning)
        }
        refreshPlayback()
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
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
