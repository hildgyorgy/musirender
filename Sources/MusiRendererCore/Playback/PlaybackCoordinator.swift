import Foundation

public final class PlaybackCoordinator: @unchecked Sendable {
    private struct Track {
        let uri: String
        let url: URL
        let metadata: String
        let duration: TimeInterval?

        init(uri: String, metadata: String, duration: TimeInterval? = nil) throws {
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
                throw PlaybackError.invalidURI
            }
            self.uri = uri
            self.url = url
            self.metadata = metadata
            self.duration = duration
        }
    }

    private struct Playlist {
        let uri: String
        let metadata: String
        let tracks: [Track]
        let duration: TimeInterval?
        var index = 0

        var next: Track? { index + 1 < tracks.count ? tracks[index + 1] : nil }
    }

    public let state: RendererState
    private let player: AudioPlayer
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "com.musirenderer.playback")
    private var requestedState: TransportState = .noMediaPresent
    private var itemID = UUID()
    private var nextTrack: Track?
    private var playlist: Playlist?
    private var importRevision: UInt64 = 0
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
        queue.sync {
            importRevision &+= 1
            playlist = nil
            load(track, targetState: .stopped)
        }
    }

    func beginPlaylistImport() -> UInt64 {
        queue.sync {
            importRevision &+= 1
            return importRevision
        }
    }

    func importPlaylist(uri: String, metadata: String, entries: [DIDLPlaylist.Entry], revision: UInt64) throws {
        let tracks = try entries.map { try Track(uri: $0.uri, metadata: $0.metadata, duration: $0.duration) }
        guard let first = tracks.first else { throw PlaybackError.invalidURI }
        let durations = tracks.compactMap(\.duration)
        try queue.sync {
            guard importRevision == revision else { throw PlaybackError.noMedia }
            playlist = Playlist(uri: uri, metadata: metadata, tracks: tracks,
                                duration: durations.count == tracks.count ? durations.reduce(0, +) : nil)
            load(first, targetState: .stopped)
            log.record("Imported album playlist with \(tracks.count) tracks")
        }
    }

    func setNextURI(_ uri: String, metadata: String) throws {
        let track = uri.isEmpty ? nil : try Track(uri: uri, metadata: metadata)
        try queue.sync {
            if playlist != nil {
                if track == nil { return }
                throw PlaybackError.noMedia
            }
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
            guard let track = playlist?.next ?? nextTrack else { throw PlaybackError.invalidSeekTarget }
            guard snapshot.canAdvanceToNext else { throw PlaybackError.noMedia }
            advance(to: track, targetState: snapshot.transportState)
        }
    }

    private func advance(to track: Track, targetState: TransportState) {
        playlist?.index += 1
        load(track, targetState: targetState)
    }

    func previous() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            throw PlaybackError.invalidSeekTarget
        }
    }

    private func load(_ track: Track, targetState: TransportState, keepNext: Bool = false) {
        let parsed = DIDLMetadata.parse(track.metadata)
        itemID = UUID()
        reachedEnd = false
        let autoplay = targetState == .playing
        requestedState = targetState
        if !keepNext { nextTrack = nil }
        state.update {
            $0.transportState = autoplay ? .transitioning : targetState
            $0.transportStatus = "OK"
            $0.currentURI = track.uri
            $0.currentMetadata = track.metadata
            $0.playlistURI = playlist?.uri
            $0.playlistMetadata = playlist?.metadata
            $0.playlistCount = playlist?.tracks.count ?? 0
            $0.playlistIndex = playlist?.index ?? 0
            $0.playlistDuration = playlist?.duration
            if !keepNext {
                $0.nextURI = ""
                $0.nextMetadata = ""
            }
            $0.title = parsed.title
            $0.artist = parsed.artist
            $0.album = parsed.album
            $0.artworkURL = parsed.artworkURL
            $0.itemID = itemID
            $0.audioFormat = nil
            $0.duration = track.duration ?? 0
            $0.position = 0
        }
        player.prepare(url: track.url, id: itemID)
        if playlist != nil || keepNext { player.preload(url: (playlist?.next ?? nextTrack)?.url) }
        if autoplay { player.play() }
        log.record(autoplay ? "Advanced to next track" : "Prepared media URI")
    }

    public func play() throws {
        try queue.sync {
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty else { throw PlaybackError.noMedia }
            if requestedState == .playing { return }
            if snapshot.transportStatus == "ERROR_OCCURRED" {
                let track = try Track(uri: snapshot.currentURI, metadata: snapshot.currentMetadata)
                load(track, targetState: .playing, keepNext: true)
                return
            }
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
        queue.sync {
            importRevision &+= 1
            guard !state.snapshot().currentURI.isEmpty else { return }
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
        case let .audioFormat(format):
            state.update { $0.audioFormat = format }
        case .ready, .seekCompleted:
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
            if let track = playlist?.next ?? nextTrack {
                advance(to: track, targetState: .playing)
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
        snapshot.duration = player.duration > 0 ? player.duration : snapshot.duration
        snapshot.position = player.position
    }

    public enum PlaybackError: Error { case invalidURI, noMedia, invalidSeekTarget }
}

private enum DIDLMetadata {
    static func parse(_ xml: String) -> (title: String, artist: String, album: String, artworkURL: URL?) {
        guard !xml.isEmpty else { return ("", "", "", nil) }
        let parser = LeafXMLParser(data: Data(xml.utf8))
        let candidate = parser.values["albumArtURI"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let artworkURL = candidate.flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.host != nil else { return nil }
            return url
        }
        return (parser.values["title"] ?? "", parser.values["artist"] ?? "", parser.values["album"] ?? "", artworkURL)
    }
}
