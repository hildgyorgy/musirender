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

    public var hasLANInterface: Bool { ssdpService.hasNetworkInterface }

    public func refreshAfterWake() { ssdpService.refreshAfterWake() }

    public func mediaSourceName(for stream: URL) async -> String? {
        if let location = await ssdpService.mediaServerLocation(for: stream),
           let name = await readMediaServerName(at: location) { return name }
        guard !Task.isCancelled,
              let destination = await mediaRedirectTarget(for: stream),
              let location = await ssdpService.mediaServerLocation(for: destination),
              !Task.isCancelled else { return nil }
        return await readMediaServerName(at: location)
    }

    private func mediaRedirectTarget(for stream: URL) async -> URL? {
        guard stream.scheme?.lowercased() == "http", let host = stream.host,
              stream.user == nil, stream.password == nil, ssdpService.isLocalMediaHost(host) else { return nil }
        let session = Self.makeDiscoverySession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: stream)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        guard let (_, rawResponse) = try? await session.data(for: request),
              let response = rawResponse as? HTTPURLResponse else { return nil }
        return Self.mediaRedirectOrigin(from: response, stream: stream)
    }

    static func mediaRedirectOrigin(from response: HTTPURLResponse, stream: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let destination = URL(string: location, relativeTo: stream)?.absoluteURL,
              destination.scheme?.lowercased() == "http", let host = destination.host,
              destination.user == nil, destination.password == nil,
              host != stream.host || (destination.port ?? 80) != (stream.port ?? 80) else { return nil }
        var origin = URLComponents()
        origin.scheme = "http"
        origin.host = host
        origin.port = destination.port
        return origin.url
    }

    private static func makeDiscoverySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: RejectRedirect(), delegateQueue: nil)
    }

    private func readMediaServerName(at location: URL) async -> String? {
        let session = Self.makeDiscoverySession()
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: location)
            let limit = 65_536
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= limit else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { return nil }
                data.append(byte)
            }
            return Self.mediaServerName(from: data)
        } catch {
            return nil
        }
    }

    static func mediaServerName(from data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8), !xml.contains("<!DOCTYPE"),
              let root = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]).rootElement(),
              let device = root.elements(forLocalName: "device", uri: "urn:schemas-upnp-org:device-1-0").first,
              device.elements(forName: "deviceType").first?.stringValue?
                .lowercased().hasPrefix("urn:schemas-upnp-org:device:mediaserver:") == true,
              let name = device.elements(forName: "friendlyName").first?.stringValue else { return nil }
        let compact = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? nil : String(compact.prefix(120))
    }

    private final class RejectRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
