import Foundation

public struct OutputSampleRateControl: Sendable {
    let read: @Sendable () -> Double?
    let request: @Sendable (Double) -> Bool

    public init(read: @escaping @Sendable () -> Double?, request: @escaping @Sendable (Double) -> Bool) {
        self.read = read
        self.request = request
    }
}

public final class PlaybackCoordinator: @unchecked Sendable {
    private struct Track: Equatable {
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
    private var staged: (track: Track, id: UUID)?
    private var playlist: Playlist?
    private var importRevision: UInt64 = 0
    private var reachedEnd = false
    private var delayedEnd: DispatchWorkItem?
    private var outputDeviceUID: String?
    private var outputAvailable = true
    private var variableRendering: (volume: UInt16, muted: Bool)?
    private let readSourceRate: @Sendable (URL) async -> Double?
    private var sampleRateControl: OutputSampleRateControl?
    private var sourceFormatLoaded = false
    private var confirmedRate: Double?
    private var waitingForSourceRate = false
    private var rateRequestID: UUID?
    private var followingProbe: (id: UUID, track: Track, rate: Double?)?
    private var followingTask: Task<Void, Never>?

    init(state: RendererState, player: AudioPlayer = AVPlayerAudioPlayer(), log: DiagnosticLog,
         readSourceRate: @escaping @Sendable (URL) async -> Double? = { await StreamAudioFormat.sampleRate(at: $0) }) {
        self.state = state
        self.player = player
        self.log = log
        self.readSourceRate = readSourceRate
        player.setVolume(Float(state.snapshot().volume) / 100)
        player.onEvent = { [weak self] id, event in
            self?.queue.async { [weak self] in self?.handle(event, id: id) }
        }
    }

    deinit { followingTask?.cancel() }

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
            reconcileQueue()
            if playlist != nil {
                if track == nil { return }
                throw PlaybackError.noMedia
            }
            nextTrack = track
            stageFollowingTrack()
            // A native transition can race a replacement of the staged URL.
            if reconcileQueue() {
                nextTrack = track
                stageFollowingTrack()
            }
            state.update {
                $0.nextURI = track?.uri ?? ""
                $0.nextMetadata = track?.metadata ?? ""
            }
        }
    }

    func next() throws {
        try queue.sync {
            reconcileQueue()
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty else { throw PlaybackError.noMedia }
            guard let track = playlist?.next ?? nextTrack else { throw PlaybackError.invalidSeekTarget }
            guard snapshot.canAdvanceToNext else { throw PlaybackError.noMedia }
            advance(to: track, targetState: snapshot.transportState)
        }
    }

    private func advance(to track: Track, targetState: TransportState) {
        let queuedID = staged.flatMap { $0.track == track ? $0.id : nil }
        let activeID = queuedID.flatMap { id in
            player.activateNext(id: id, manually: true, playing: targetState == .playing) ? id : nil
        }
        playlist?.index += 1
        load(track, targetState: targetState, activeID: activeID)
    }

    @discardableResult
    private func reconcileQueue() -> Bool {
        guard let staged, player.currentItemID == staged.id,
              player.activateNext(id: staged.id, manually: false, playing: requestedState == .playing) else { return false }
        playlist?.index += 1
        load(staged.track, targetState: requestedState, activeID: staged.id)
        return true
    }

    private func stageFollowingTrack() {
        let following = playlist?.next ?? nextTrack
        if sampleRateControl != nil {
            if followingProbe?.track != following {
                followingTask?.cancel()
                followingProbe = nil
                if staged != nil { unstageFollowingTrack() }
            }
            guard let following, let confirmedRate else { return }
            if followingProbe == nil {
                probeFollowingTrack(following)
                return
            }
            // Changing the hardware clock requires a stop between tracks.
            guard followingProbe?.rate == confirmedRate else { return }
        }
        if staged?.track == following { return }
        let candidate = following.map { ($0, UUID()) }
        if let candidate, player.stageNext(url: candidate.0.url, id: candidate.1) {
            staged = (track: candidate.0, id: candidate.1)
        } else if following == nil {
            unstageFollowingTrack()
        } else if player.currentItemID != staged?.id {
            staged = nil
        }
    }

    private func unstageFollowingTrack() {
        _ = player.stageNext(url: nil, id: nil)
        if player.currentItemID != staged?.id { staged = nil }
    }

    private func probeFollowingTrack(_ track: Track) {
        let id = UUID()
        followingProbe = (id, track, nil)
        followingTask = Task { [weak self, readSourceRate] in
            let rate = await readSourceRate(track.url)
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                guard self.followingProbe?.id == id else { return }
                self.followingProbe?.rate = rate
                self.stageFollowingTrack()
            }
        }
    }

    func previous() throws {
        try queue.sync {
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            throw PlaybackError.invalidSeekTarget
        }
    }

    private func load(_ track: Track, targetState: TransportState, keepNext: Bool = false, activeID: UUID? = nil) {
        delayedEnd?.cancel()
        delayedEnd = nil
        cancelRatePreparation()
        followingTask?.cancel()
        followingProbe = nil
        sourceFormatLoaded = false
        if activeID == nil { confirmedRate = nil }
        let parsed = DIDLMetadata.parse(track.metadata)
        itemID = activeID ?? UUID()
        staged = nil
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
            $0.sampleRateError = nil
            $0.duration = track.duration ?? 0
            $0.position = 0
        }
        if activeID == nil { player.prepare(url: track.url, id: itemID) }
        stageFollowingTrack()
        if autoplay && activeID == nil { startPlayback() }
        if activeID != nil { log.record("Advanced to queued audio item") }
        else { log.record(autoplay ? "Advanced to next track" : "Prepared media URI") }
    }

    public func play() throws {
        try queue.sync {
            reconcileQueue()
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty else { throw PlaybackError.noMedia }
            guard outputAvailable else { throw PlaybackError.outputUnavailable }
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
            startPlayback()
        }
    }

    private func startPlayback() {
        guard sampleRateControl != nil else {
            player.play()
            return
        }
        waitingForSourceRate = true
        if sourceFormatLoaded { prepareSampleRate(state.snapshot().audioFormat?.sampleRateHz) }
    }

    private func prepareSampleRate(_ rate: Double?) {
        guard waitingForSourceRate, let control = sampleRateControl else { return }
        waitingForSourceRate = false
        guard let rate else {
            stopForSampleRateError("Could not determine the source sample rate.")
            return
        }
        if control.read() == rate {
            beginWithConfirmedRate(rate)
            return
        }
        guard control.request(rate) else {
            stopForSampleRateError("The selected output could not switch to \(rate) Hz.")
            return
        }
        let requestID = UUID()
        rateRequestID = requestID
        confirmSampleRate(rate, requestID: requestID, attempts: 20)
    }

    private func confirmSampleRate(_ rate: Double, requestID: UUID, attempts: Int) {
        guard rateRequestID == requestID, let control = sampleRateControl else { return }
        if control.read() == rate {
            beginWithConfirmedRate(rate)
        } else if attempts == 0 {
            stopForSampleRateError("The selected output did not confirm \(rate) Hz.")
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.confirmSampleRate(rate, requestID: requestID, attempts: attempts - 1)
            }
        }
    }

    private func beginWithConfirmedRate(_ rate: Double) {
        rateRequestID = nil
        confirmedRate = rate
        stageFollowingTrack()
        player.play()
    }

    private func cancelRatePreparation() {
        waitingForSourceRate = false
        rateRequestID = nil
    }

    private func stopForSampleRateError(_ message: String) {
        cancelRatePreparation()
        requestedState = .stopped
        player.pause()
        state.update {
            $0.transportState = .stopped
            $0.transportStatus = "ERROR_OCCURRED"
            $0.sampleRateError = message
        }
        log.record(message, level: .error)
    }

    public func pause() throws {
        try queue.sync {
            reconcileQueue()
            guard !state.snapshot().currentURI.isEmpty else { throw PlaybackError.noMedia }
            cancelRatePreparation()
            requestedState = .pausedPlayback
            player.pause()
            state.update { $0.transportState = .pausedPlayback; refreshTimes(&$0) }
        }
    }

    public func stop() throws {
        queue.sync {
            importRevision &+= 1
            reconcileQueue()
            guard !state.snapshot().currentURI.isEmpty else { return }
            cancelRatePreparation()
            requestedState = .stopped
            reachedEnd = false
            player.stop()
            state.update { $0.transportState = .stopped; $0.position = 0; $0.duration = player.duration }
        }
    }

    public func seek(to position: TimeInterval, expectedURI: String? = nil) throws {
        try queue.sync {
            reconcileQueue()
            let snapshot = state.snapshot()
            guard !snapshot.currentURI.isEmpty, snapshot.transportStatus == "OK",
                  expectedURI == nil || snapshot.currentURI == expectedURI,
                  player.duration > 0 else { throw PlaybackError.noMedia }
            guard position.isFinite, position >= 0, position <= player.duration else {
                throw PlaybackError.invalidSeekTarget
            }
            delayedEnd?.cancel()
            delayedEnd = nil
            reachedEnd = false
            player.seek(to: position)
        }
    }

    public func setVolume(_ value: UInt16) {
        queue.sync {
            guard variableRendering == nil else { return }
            let clamped = min(100, value)
            player.setVolume(Float(clamped) / 100)
            state.update { $0.volume = clamped }
        }
    }

    public func setMuted(_ muted: Bool) {
        queue.sync {
            guard variableRendering == nil else { return }
            player.setMuted(muted)
            state.update { $0.isMuted = muted }
        }
    }

    func resetRenderingDefaults() {
        queue.sync {
            guard variableRendering == nil else { return }
            let defaults = RendererSnapshot()
            applyRendering(volume: defaults.volume, muted: defaults.isMuted)
        }
    }

    public func selectOutput(uid: String?, available: Bool) throws {
        try queue.sync {
            try requireStopped()
            if outputDeviceUID != uid {
                changeSampleRateControl(nil)
                restoreVariableRendering()
                player.setOutputDevice(uid: uid)
                outputDeviceUID = uid
            }
            outputAvailable = uid == nil || available
        }
    }

    public func updateOutputAvailability(uid: String, available: Bool) {
        queue.sync {
            guard uid == outputDeviceUID, available != outputAvailable else { return }
            outputAvailable = available
            if available { player.setOutputDevice(uid: uid) }
            guard !available, requestedState == .playing || requestedState == .pausedPlayback else { return }
            cancelRatePreparation()
            player.pause()
            requestedState = .stopped
            state.update { $0.transportState = .stopped; refreshTimes(&$0) }
            log.record("Playback stopped because the selected output disconnected", level: .warning)
        }
    }

    public func setOutputSampleRateControl(_ control: OutputSampleRateControl?) throws {
        try queue.sync {
            try requireStopped()
            if control != nil, outputDeviceUID == nil { throw PlaybackError.outputUnavailable }
            changeSampleRateControl(control)
        }
    }

    private func changeSampleRateControl(_ control: OutputSampleRateControl?) {
        guard sampleRateControl != nil || control != nil else { return }
        sampleRateControl = control
        cancelRatePreparation()
        confirmedRate = nil
        followingTask?.cancel()
        followingProbe = nil
        unstageFollowingTrack()
        stageFollowingTrack()
    }

    public func setFixedVolume(_ enabled: Bool) throws {
        try queue.sync {
            try requireStopped()
            if enabled {
                guard outputDeviceUID != nil else { throw PlaybackError.outputUnavailable }
                guard variableRendering == nil else { return }
                let snapshot = state.snapshot()
                variableRendering = (snapshot.volume, snapshot.isMuted)
                applyRendering(volume: 100, muted: false)
            } else {
                restoreVariableRendering()
            }
        }
    }

    private func requireStopped() throws {
        reconcileQueue()
        guard requestedState == .stopped || requestedState == .noMediaPresent else {
            throw PlaybackError.outputChangeWhilePlaying
        }
    }

    private func restoreVariableRendering() {
        guard let variableRendering else { return }
        self.variableRendering = nil
        applyRendering(volume: variableRendering.volume, muted: variableRendering.muted)
    }

    private func applyRendering(volume: UInt16, muted: Bool) {
        player.setVolume(Float(volume) / 100)
        player.setMuted(muted)
        state.update {
            $0.volume = volume
            $0.isMuted = muted
        }
    }

    public func currentSnapshot() -> RendererSnapshot {
        queue.sync {
            reconcileQueue()
            var snapshot = state.snapshot()
            refreshTimes(&snapshot)
            return snapshot
        }
    }

    private func handle(_ event: AudioPlaybackEvent, id: UUID) {
        reconcileQueue()
        guard id == itemID else { return }
        switch event {
        case .queueAdvanced:
            break // The current-item identity was reconciled above.
        case let .audioFormat(format):
            sourceFormatLoaded = true
            state.update { $0.audioFormat = format }
            prepareSampleRate(format?.sampleRateHz)
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
            if staged != nil {
                // AVQueuePlayer may report the end before changing currentItem.
                delayedEnd?.cancel()
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.delayedEnd = nil
                    self.reconcileQueue()
                    guard self.itemID == id, self.requestedState == .playing else { return }
                    self.finishCurrentItem()
                }
                delayedEnd = fallback
                queue.asyncAfter(deadline: .now() + .milliseconds(350), execute: fallback)
            } else {
                finishCurrentItem()
            }
        case let .failed(message):
            cancelRatePreparation()
            requestedState = .stopped
            player.pause()
            state.update { $0.transportState = .stopped; $0.transportStatus = "ERROR_OCCURRED" }
            log.record("Playback failed: \(message)", level: .error)
        }
    }

    private func finishCurrentItem() {
        if let track = playlist?.next ?? nextTrack {
            advance(to: track, targetState: .playing)
        } else {
            requestedState = .stopped
            reachedEnd = true
            player.pause()
            state.update { $0.transportState = .stopped; refreshTimes(&$0) }
            log.record("Playback reached end of queue")
        }
    }

    private func refreshTimes(_ snapshot: inout RendererSnapshot) {
        snapshot.duration = player.duration > 0 ? player.duration : snapshot.duration
        snapshot.position = player.position
    }

    public enum PlaybackError: Error {
        case invalidURI, noMedia, invalidSeekTarget, outputUnavailable, outputChangeWhilePlaying
    }
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
