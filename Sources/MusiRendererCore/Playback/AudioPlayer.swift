import AVFoundation
import Foundation

enum AudioPlaybackEvent {
    case ready
    case playing
    case seekCompleted
    case waiting
    case paused
    case ended
    case queueAdvanced
    case failed(String)
    case audioFormat(StreamAudioFormat?)
}

protocol AudioPlayer: AnyObject {
    var onEvent: (@Sendable (UUID, AudioPlaybackEvent) -> Void)? { get set }
    var currentItemID: UUID? { get }
    var duration: TimeInterval { get }
    var position: TimeInterval { get }
    func prepare(url: URL, id: UUID)
    func stageNext(url: URL?, id: UUID?) -> Bool
    func activateNext(id: UUID, manually: Bool, playing: Bool) -> Bool
    func play()
    func pause()
    func stop()
    func seek(to position: TimeInterval)
    func setVolume(_ value: Float)
    func setMuted(_ value: Bool)
    func setOutputDevice(uid: String?)
}

final class AVPlayerAudioPlayer: AudioPlayer, @unchecked Sendable {
    private struct QueueItem {
        let id: UUID
        let item: AVPlayerItem
    }

    var onEvent: (@Sendable (UUID, AudioPlaybackEvent) -> Void)?
    private let player = AVQueuePlayer()
    private var active: QueueItem?
    private var next: QueueItem?
    private var currentItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
    }

    deinit { clearActiveObservers() }

    var currentItemID: UUID? {
        guard let item = player.currentItem else { return nil }
        if item === active?.item { return active?.id }
        if item === next?.item { return next?.id }
        return nil
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

    func stageNext(url: URL?, id: UUID?) -> Bool {
        // If the player advanced between the coordinator check and this call,
        // keep the new current item so the coordinator can adopt it first.
        if let next, player.currentItem === next.item { return false }
        currentItemObservation = nil
        player.actionAtItemEnd = .pause
        if let next { player.remove(next.item) }
        next = nil

        guard let url, let id, let current = player.currentItem else { return false }
        let item = makeItem(url)
        guard player.canInsert(item, after: current) else { return false }
        next = QueueItem(id: id, item: item)
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self, weak item] player, _ in
            guard let item, player.currentItem === item else { return }
            self?.onEvent?(id, .queueAdvanced)
        }
        player.insert(item, after: current)
        player.actionAtItemEnd = .advance
        return true
    }

    func activateNext(id: UUID, manually: Bool, playing: Bool) -> Bool {
        guard let next, next.id == id else { return false }
        if player.currentItem !== next.item {
            guard manually, player.items().dropFirst().first === next.item else { return false }
            if !playing { player.pause() }
            player.advanceToNextItem()
        }
        guard player.currentItem === next.item else { return false }

        if !playing { player.pause() }
        currentItemObservation = nil
        self.next = nil
        player.actionAtItemEnd = .pause
        activate(next)
        if manually && playing { player.play() }
        return true
    }

    func prepare(url: URL, id: UUID) {
        clearActiveObservers()
        currentItemObservation = nil
        player.pause()
        player.actionAtItemEnd = .pause
        player.removeAllItems()
        next = nil
        let slot = QueueItem(id: id, item: makeItem(url))
        player.insert(slot.item, after: nil)
        activate(slot)
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
    }

    private func clearActiveObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        itemObservation = nil
        timeControlObservation = nil
    }

    private func activate(_ slot: QueueItem) {
        clearActiveObservers()
        active = slot
        let (id, item) = (slot.id, slot.item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.onEvent?(id, .ready)
                let track = item.tracks.lazy.filter(\.isEnabled).compactMap(\.assetTrack)
                    .first(where: { $0.mediaType == .audio })
                Task { [weak self] in
                    let format = if let track { await StreamAudioFormat.read(from: track) } else { nil as StreamAudioFormat? }
                    self?.onEvent?(id, .audioFormat(format))
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
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak item] player, _ in
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

    func setOutputDevice(uid: String?) { player.audioOutputDeviceUniqueID = uid }
}
