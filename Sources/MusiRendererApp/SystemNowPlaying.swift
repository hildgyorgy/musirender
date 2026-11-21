import AppKit
import Foundation
import MediaPlayer

/// Publishes renderer state for macOS media controls independently of any window.
@MainActor
final class SystemNowPlaying {
    private struct Presentation: Equatable {
        let itemID: UUID?
        let title: String
        let artist: String
        let album: String
        let artworkURL: URL?
        let state: TransportState
        let position: TimeInterval
        let duration: TimeInterval
        let actions: String
        let queueCount: Int
        let queueIndex: Int

        init(_ snapshot: RendererSnapshot) {
            itemID = snapshot.itemID
            title = snapshot.title
            artist = snapshot.artist
            album = snapshot.album
            artworkURL = snapshot.artworkURL
            state = snapshot.transportState
            position = snapshot.position
            duration = snapshot.duration
            actions = snapshot.transportActions
            queueCount = snapshot.playlistCount > 0 ? snapshot.playlistCount : (snapshot.nextURI.isEmpty ? 1 : 2)
            queueIndex = snapshot.playlistIndex
        }
    }

    private let playback: PlaybackCoordinator
    private var observer: UUID?
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var lastPresentation: Presentation?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(playback: PlaybackCoordinator) {
        self.playback = playback
        registerCommands()
        observer = playback.state.observe { [weak self] snapshot in
            DispatchQueue.main.async { self?.update(snapshot) }
        }
    }

    deinit {
        for (command, target) in registrations { command.removeTarget(target) }
        if let observer { playback.state.removeObserver(observer) }
    }

    private func update(_ snapshot: RendererSnapshot) {
        let presentation = Presentation(snapshot)
        guard presentation != lastPresentation else { return }
        lastPresentation = presentation
        publish()
    }

    private func publish() {
        let snapshot = playback.currentSnapshot()
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        let hasItem = snapshot.itemID != nil
        let active = snapshot.transportState == .playing || snapshot.transportState == .transitioning
        let actions = snapshot.transportActions.split(separator: ",")
        commands.playCommand.isEnabled = hasItem && !active
        commands.pauseCommand.isEnabled = hasItem && active
        commands.togglePlayPauseCommand.isEnabled = hasItem
        commands.stopCommand.isEnabled = hasItem && snapshot.transportState != .stopped
        commands.nextTrackCommand.isEnabled = snapshot.canAdvanceToNext
        commands.changePlaybackPositionCommand.isEnabled = actions.contains("Seek")

        guard hasItem else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title.isEmpty ? "Current track" : snapshot.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.playlistIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.playlistCount > 0 ? snapshot.playlistCount : (snapshot.nextURI.isEmpty ? 1 : 2),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.transportState == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        metadata[MPNowPlayingInfoPropertyExcludeFromSuggestions] = true
        if !snapshot.artist.isEmpty { metadata[MPMediaItemPropertyArtist] = snapshot.artist }
        if !snapshot.album.isEmpty { metadata[MPMediaItemPropertyAlbumTitle] = snapshot.album }
        if snapshot.duration > 0 { metadata[MPMediaItemPropertyPlaybackDuration] = snapshot.duration }
        if snapshot.artworkURL == artworkURL, let artwork { metadata[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = metadata
        switch snapshot.transportState {
        case .playing: center.playbackState = .playing
        case .pausedPlayback, .transitioning: center.playbackState = .paused
        case .noMediaPresent, .stopped: center.playbackState = .stopped
        }
    }

    func setArtwork(_ image: NSImage?, for url: URL?) {
        artworkURL = url
        artwork = image.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        publish()
    }

    private func registerCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        register(commands.playCommand) { player, _ in try player.play() }
        register(commands.pauseCommand) { player, _ in try player.pause() }
        register(commands.togglePlayPauseCommand) { player, _ in
            switch player.currentSnapshot().transportState {
            case .playing, .transitioning: try player.pause()
            case .pausedPlayback, .stopped, .noMediaPresent: try player.play()
            }
        }
        register(commands.stopCommand) { player, _ in try player.stop() }
        register(commands.nextTrackCommand) { player, _ in try player.next() }
        register(commands.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                throw PlaybackCoordinator.PlaybackError.invalidSeekTarget
            }
            try player.seek(to: event.positionTime)
        }
    }

    private func register(_ command: MPRemoteCommand,
                          action: @escaping (PlaybackCoordinator, MPRemoteCommandEvent) throws -> Void) {
        command.isEnabled = false
        let target = command.addTarget { [weak playback] event in
            guard let playback, playback.currentSnapshot().itemID != nil else { return .noSuchContent }
            do {
                try action(playback, event)
                return .success
            } catch {
                return .commandFailed
            }
        }
        registrations.append((command, target))
    }
}
