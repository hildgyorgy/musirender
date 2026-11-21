import AVFoundation
import Foundation

enum AudioPlaybackEvent {
    case ready
    case playing
    case seekCompleted
    case waiting
    case paused
    case ended
    case failed(String)
    case audioFormat(StreamAudioFormat)
}

protocol AudioPlayer: AnyObject {
    var onEvent: (@Sendable (UUID, AudioPlaybackEvent) -> Void)? { get set }
    var duration: TimeInterval { get }
    var position: TimeInterval { get }
    func prepare(url: URL, id: UUID)
    func preload(url: URL?)
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    func setVolume(_ value: Float)
    func setMuted(_ value: Bool)
}

final class AVPlayerAudioPlayer: AudioPlayer, @unchecked Sendable {
    var onEvent: (@Sendable (UUID, AudioPlaybackEvent) -> Void)?
    private let player = AVPlayer()
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var preloadTask: Task<Void, Never>?
    private var preloadedAsset: AVURLAsset?
    private var currentItemID: UUID?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none
    }

    deinit {
        preloadTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    var duration: TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    func preload(url: URL?) {
        preloadTask?.cancel()
        preloadTask = nil
        let asset = url.map { makeAsset($0) }
        preloadedAsset = asset
        if let asset {
            preloadTask = Task { _ = try? await asset.load(.isPlayable) }
        }
    }

    private func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    func prepare(url: URL, id: UUID) {
        currentItemID = id
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        itemObservation = nil
        playerObservation = nil
        player.pause()
        let asset: AVURLAsset
        if let preloadedAsset, preloadedAsset.url == url {
            asset = preloadedAsset
            // The in-flight asset load now belongs to the current item.
            preloadTask = nil
        } else {
            preloadTask?.cancel()
            preloadTask = nil
            asset = makeAsset(url)
        }
        preloadedAsset = nil
        let item = AVPlayerItem(asset: asset)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.onEvent?(id, .ready)
                if let track = item.tracks.lazy.filter(\.isEnabled).compactMap(\.assetTrack)
                    .first(where: { $0.mediaType == .audio }) {
                    Task { [weak self] in
                        if let format = await StreamAudioFormat.read(from: track) {
                            self?.onEvent?(id, .audioFormat(format))
                        }
                    }
                }
            case .failed:
                let error = item.error as NSError?
                self.onEvent?(id, .failed(error.map { "AVPlayer error \($0.domain) (\($0.code))" } ?? "Unknown playback error"))
            case .unknown: break
            @unknown default: break
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
        ) { [weak self] _ in self?.onEvent?(id, .ended) }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            self?.onEvent?(id, .failed(error.map { "AVPlayer error \($0.domain) (\($0.code))" } ?? "Playback interrupted"))
        }
        player.replaceCurrentItem(with: item)
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] player, _ in
            guard let item, player.currentItem === item else { return }
            switch player.timeControlStatus {
            case .playing: self?.onEvent?(id, .playing)
            case .waitingToPlayAtSpecifiedRate: self?.onEvent?(id, .waiting)
            case .paused: self?.onEvent?(id, .paused)
            @unknown default: self?.onEvent?(id, .waiting)
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() {
        player.pause()
        seek(to: 0)
    }
    func seek(to position: TimeInterval) {
        guard let id = currentItemID else { return }
        let target = CMTime(seconds: position, preferredTimescale: 1_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished { self?.onEvent?(id, .seekCompleted) }
        }
    }
    func setVolume(_ value: Float) { player.volume = min(1, max(0, value)) }
    func setMuted(_ value: Bool) { player.isMuted = value }
}
