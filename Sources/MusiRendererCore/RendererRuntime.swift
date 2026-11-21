import Foundation

public final class RendererRuntime: @unchecked Sendable {
    public let configuration: RendererConfiguration
    public let log: DiagnosticLog
    public let state: RendererState
    public let playback: PlaybackCoordinator

    private let httpServer: UPnPDeviceServer
    private let ssdpService: SSDPService
    private let lock = NSLock()
    private var running = false

    public init(configuration: RendererConfiguration, log: DiagnosticLog = DiagnosticLog()) {
        self.configuration = configuration
        self.log = log
        let state = RendererState()
        self.state = state
        let playback = PlaybackCoordinator(state: state, log: log)
        self.playback = playback
        self.httpServer = UPnPDeviceServer(configuration: configuration, playback: playback, log: log)
        self.ssdpService = SSDPService(configuration: configuration, log: log)
    }

    public func start() throws {
        try lock.withLock {
            guard !running else { return }
            do {
                try httpServer.start()
                try ssdpService.start()
                running = true
                log.record("Renderer online as \(configuration.friendlyName), UDN=uuid:\(configuration.uuid.uuidString.lowercased())")
            } catch {
                httpServer.stop()
                ssdpService.stop()
                log.record("Renderer failed to start: \(error.localizedDescription)", level: .error)
                throw error
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard running else { return }
            ssdpService.stop()
            httpServer.stop()
            running = false
            log.record("Renderer offline")
        }
    }
}
