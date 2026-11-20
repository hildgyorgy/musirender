import Foundation

public final class RendererRuntime: @unchecked Sendable {
    public let configuration: RendererConfiguration
    public let log: DiagnosticLog

    private let httpServer: UPnPDeviceServer
    private let ssdpService: SSDPService
    private let lock = NSLock()
    private var running = false

    public init(configuration: RendererConfiguration, log: DiagnosticLog = DiagnosticLog()) {
        self.configuration = configuration
        self.log = log
        self.httpServer = UPnPDeviceServer(configuration: configuration, log: log)
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
