import Foundation

public final class PlaybackCoordinator: @unchecked Sendable {
    private struct Track {
        let uri: String
        let url: URL
        let metadata: String

        init(uri: String, metadata: String) throws {
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
                throw PlaybackError.invalidURI
            }
            self.uri = uri
            self.url = url
            self.metadata = metadata
        }
    }

    public let state: RendererState
    private let player: AudioPlayer
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "com.musirenderer.playback")
    private var requestedState: TransportState = .noMediaPresent
    private var itemID = UUID()
    private var nextTrack: Track?
    private var reachedEnd = false

    init(state: RendererState, player: AudioPlayer = AVPlayerAudioPlayer(), log: DiagnosticLog) {
        self.state = state
        self.player = player
        self.log = log
        player.setVolume(0.5)
        player.onEvent = { [weak self] id, event in
            self?.queue.async { [weak self] in self?.handle(event, id: id) }
        }
    }

    public func setURI(_ uri: String, metadata: String) throws {
        let track = try Track(uri: uri, metadata: metadata)
        queue.sync { load(track, autoplay: false) }
    }

    func setNextURI(_ uri: String, metadata: String) throws {
        let track = uri.isEmpty ? nil : try Track(uri: uri, metadata: metadata)
        queue.sync {
            nextTrack = track
            player.preload(url: track?.url)
            state.update {
                $0.nextURI = track?.uri ?? ""
                $0.nextMetadata = track?.metadata ?? ""
            }
        }
    }

    func next() throws {
        try queue.sync {
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty else { throw PlaybackError.noMedia }
            guard let nextTrack else { throw PlaybackError.invalidSeekTarget }
            guard snapshot.transportState == .playing || snapshot.transportState == .stopped else {
                throw PlaybackError.noMedia
            }
            load(nextTrack, autoplay: snapshot.transportState == .playing)
        }
    }

    func previous() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            throw PlaybackError.invalidSeekTarget
        }
    }

    private func load(_ track: Track, autoplay: Bool) {
        let parsed = DIDLMetadata.parse(track.metadata)
        itemID = UUID()
        reachedEnd = false
        requestedState = autoplay ? .playing : .stopped
        nextTrack = nil
        state.update {
            $0.transportState = autoplay ? .transitioning : .stopped
            $0.transportStatus = "OK"
            $0.currentURI = track.uri
            $0.currentMetadata = track.metadata
            $0.nextURI = ""
            $0.nextMetadata = ""
            $0.title = parsed.title
            $0.artist = parsed.artist
            $0.duration = 0
            $0.position = 0
        }
        player.prepare(url: track.url, id: itemID)
        if autoplay { player.play() }
        log.record(autoplay ? "Advanced to next track" : "Prepared media URI")
    }

    public func play() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            if requestedState == .playing { return }
            if reachedEnd { player.seek(to: 0) }
            reachedEnd = false
            requestedState = .playing
            state.update { $0.transportState = .transitioning; $0.transportStatus = "OK" }
            player.play()
        }
    }

    public func pause() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            requestedState = .pausedPlayback
            player.pause()
            state.update { $0.transportState = .pausedPlayback; refreshTimes(&$0) }
        }
    }

    public func stop() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            requestedState = .stopped
            reachedEnd = false
            player.stop()
            state.update { $0.transportState = .stopped; $0.position = 0; $0.duration = player.duration }
        }
    }

    public func seek(to position: TimeInterval, expectedURI: String? = nil) throws {
        try queue.sync {
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty, snapshot.transportStatus == "OK",
                  expectedURI == nil || snapshot.currentURI == expectedURI,
                  player.duration > 0 else { throw PlaybackError.noMedia }
            guard position.isFinite, position >= 0, position <= player.duration else {
                throw PlaybackError.invalidSeekTarget
            }
            reachedEnd = false
            player.seek(to: position)
        }
    }

    public func setVolume(_ value: UInt16) {
        queue.sync {
            let clamped = min(100, value)
            player.setVolume(Float(clamped) / 100)
            state.update { $0.volume = clamped }
        }
    }

    public func setMuted(_ muted: Bool) {
        queue.sync {
            player.setMuted(muted)
            state.update { $0.isMuted = muted }
        }
    }

    public func currentSnapshot() -> RendererSnapshot {
        queue.sync {
            var snapshot = state.snapshot()
            refreshTimes(&snapshot)
            return snapshot
        }
    }

    private func handle(_ event: AudioPlaybackEvent, id: UUID) {
        guard id == itemID else { return }
        switch event {
        case .ready:
            state.update { refreshTimes(&$0) }
        case .playing:
            guard requestedState == .playing else { return }
            state.update { $0.transportState = .playing; $0.transportStatus = "OK"; refreshTimes(&$0) }
            log.record("Playback started")
        case .waiting:
            guard requestedState == .playing else { return }
            state.update { $0.transportState = .transitioning; refreshTimes(&$0) }
        case .paused:
            guard requestedState == .pausedPlayback || requestedState == .stopped else { return }
            state.update { $0.transportState = requestedState; refreshTimes(&$0) }
        case .ended:
            guard requestedState == .playing else { return }
            if let nextTrack {
                load(nextTrack, autoplay: true)
            } else {
                requestedState = .stopped
                reachedEnd = true
                player.pause()
                state.update { $0.transportState = .stopped; refreshTimes(&$0) }
                log.record("Playback reached end of queue")
            }
        case let .failed(message):
            requestedState = .stopped
            state.update { $0.transportState = .stopped; $0.transportStatus = "ERROR_OCCURRED" }
            log.record("Playback failed: \(message)", level: .error)
        }
    }

    private func refreshTimes(_ snapshot: inout RendererSnapshot) {
        snapshot.duration = player.duration
        snapshot.position = player.position
    }

    public enum PlaybackError: Error { case invalidURI, noMedia, invalidSeekTarget }
}

private enum DIDLMetadata {
    static func parse(_ xml: String) -> (title: String, artist: String) {
        guard !xml.isEmpty else { return ("", "") }
        let parser = LeafXMLParser(data: Data(xml.utf8))
        return (parser.values["title"] ?? "", parser.values["artist"] ?? "")
    }
}
