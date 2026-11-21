import Foundation

public enum TransportState: String, Sendable {
    case noMediaPresent = "NO_MEDIA_PRESENT"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case playing = "PLAYING"
    case pausedPlayback = "PAUSED_PLAYBACK"
}

public struct RendererSnapshot: Sendable, Equatable {
    public var transportState: TransportState = .noMediaPresent
    public var transportStatus = "OK"
    public var currentURI = ""
    public var currentMetadata = ""
    public var nextURI = ""
    public var nextMetadata = ""
    var playlistURI: String?
    var playlistMetadata: String?
    var playlistCount = 0
    var playlistIndex = 0
    var playlistDuration: TimeInterval?
    public var title = ""
    public var artist = ""
    public var album = ""
    public var artworkURL: URL?
    public var itemID: UUID?
    public var audioFormat: StreamAudioFormat?
    public var outputPlaybackError: String?
    public var exclusiveOutputActive = false
    public var duration: TimeInterval = 0
    public var position: TimeInterval = 0
    public var volume: UInt16 = 50
    public var isMuted = false

    public init() {}

    var canAdvanceToNext: Bool {
        !currentURI.isEmpty && (!nextURI.isEmpty || playlistIndex + 1 < playlistCount) && transportState != .transitioning &&
            transportState != .noMediaPresent
    }

    var trackNumber: Int { currentURI.isEmpty ? 0 : playlistIndex + 1 }
    var trackCount: Int { playlistCount > 0 ? playlistCount : (currentURI.isEmpty ? 0 : 1) }
    var mediaURI: String { playlistURI ?? currentURI }
    var mediaMetadata: String { playlistMetadata ?? currentMetadata }
    var mediaDuration: TimeInterval { playlistURI == nil ? duration : playlistDuration ?? 0 }

    var transportActions: String {
        var actions: [String]
        switch transportState {
        case .noMediaPresent: actions = []
        case .playing: actions = ["Stop", "Pause"]
        case .pausedPlayback: actions = ["Play", "Stop"]
        case .stopped: actions = ["Play"]
        case .transitioning: actions = ["Stop", "Pause"]
        }
        if !currentURI.isEmpty, duration > 0, transportStatus == "OK" { actions.append("Seek") }
        if canAdvanceToNext { actions.append("Next") }
        return actions.joined(separator: ",")
    }
}

public final class RendererState: @unchecked Sendable {
    public typealias Observer = @Sendable (RendererSnapshot) -> Void
    private let lock = NSLock()
    private var value = RendererSnapshot()
    private var observers: [UUID: Observer] = [:]

    public init() {}

    public func snapshot() -> RendererSnapshot { lock.withLock { value } }

    func update(_ mutation: (inout RendererSnapshot) -> Void) {
        let snapshot: RendererSnapshot
        let callbacks: [Observer]
        lock.lock()
        mutation(&value)
        snapshot = value
        callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0(snapshot) }
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        let snapshot: RendererSnapshot
        lock.lock()
        observers[id] = observer
        snapshot = value
        lock.unlock()
        observer(snapshot)
        return id
    }

    public func removeObserver(_ id: UUID) { lock.withLock { observers[id] = nil } }
}

enum UPnPTime {
    static func parse(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[0-5][0-9]$"#, options: .regularExpression) != nil,
              parts[2].range(of: #"^[0-5][0-9](\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else {
            return nil
        }
        let result = hours * 3_600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }

    static func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "00:00:00" }
        let total = Int(interval.rounded(.down))
        return String(format: "%02lld:%02lld:%02lld", Int64(total / 3600), Int64((total % 3600) / 60), Int64(total % 60))
    }
}
