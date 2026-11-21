import Foundation
import Network

public final class UPnPDeviceServer: @unchecked Sendable {
    private let configuration: RendererConfiguration
    private let log: DiagnosticLog
    private let soapHandler: SOAPActionHandler
    private let subscriptions: EventSubscriptionManager
    private let rendererState: RendererState
    private let queue = DispatchQueue(label: "com.musirenderer.http")
    private var listener: NWListener?
    private var playlistImport: Task<Void, Never>?

    public init(configuration: RendererConfiguration, playback: PlaybackCoordinator, log: DiagnosticLog) {
        self.configuration = configuration
        self.log = log
        self.rendererState = playback.state
        self.soapHandler = SOAPActionHandler(playback: playback, log: log)
        self.subscriptions = EventSubscriptionManager(state: playback.state, log: log)
    }

    public func start(onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let startup: ListenerStartup? = try queue.sync {
            guard listener == nil else { return nil }
            guard let port = NWEndpoint.Port(rawValue: configuration.httpPort), port != .any else {
                throw ServerError.invalidPort
            }
            let listener = try NWListener(using: .tcp, on: port)
            let startup = ListenerStartup()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    startup.complete(.success(()))
                    self.log.record("HTTP server listening on port \(self.configuration.httpPort)")
                case let .failed(error), let .waiting(error):
                    if !startup.complete(.failure(error)) {
                        DispatchQueue.global().async { onFailure(error.localizedDescription) }
                    }
                case .cancelled:
                    startup.complete(.failure(ServerError.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
            return startup
        }
        guard let startup else { return }
        do {
            guard startup.signal.wait(timeout: .now() + .seconds(3)) == .success else {
                throw ServerError.startupTimeout
            }
            try queue.sync { try startup.result?.get() }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        queue.sync {
            let previous = listener
            listener = nil
            previous?.cancel()
            playlistImport?.cancel()
            playlistImport = nil
        }
        subscriptions.stop()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak connection] in connection?.cancel() }
        queue.asyncAfter(deadline: .now() + .seconds(10), execute: deadline)
        receive(on: connection, accumulated: Data(), continued: false, deadline: deadline)
    }

    private func receive(on connection: NWConnection, accumulated: Data, continued: Bool, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            let frame = HTTPRequest.frame(buffer)
            switch frame {
            case .complete(let request):
                deadline.cancel()
                self.handle(request, on: connection)
            case .rejected(let response):
                deadline.cancel()
                self.send(response, on: connection)
            case .waitingForHeaders, .waitingForBody:
                guard !complete, error == nil else { deadline.cancel(); connection.cancel(); return }
                if case .waitingForBody(sendContinue: true) = frame, !continued {
                    let interim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                    let prefix = buffer
                    connection.send(content: interim, completion: .contentProcessed { [weak self] error in
                        guard error == nil else { deadline.cancel(); connection.cancel(); return }
                        self?.receive(on: connection, accumulated: prefix, continued: true, deadline: deadline)
                    })
                } else {
                    self.receive(on: connection, accumulated: buffer, continued: continued, deadline: deadline)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let method = request.method.uppercased()
        log.record("HTTP \(method) \(request.target.split(separator: "?", maxSplits: 1).first ?? "/")")
        let response: HTTPResponse

        if method == "GET" || method == "HEAD" {
            response = descriptionResponse(for: request.path)
        } else if method == "POST", request.path.hasSuffix("/control") {
            if let playlist = soapHandler.playlistRequest(path: request.path, headers: request.headers, body: request.body) {
                playlistImport?.cancel()
                let revision = soapHandler.beginPlaylistImport()
                playlistImport = Task { [weak self] in
                    guard let self else { connection.cancel(); return }
                    let result = await self.soapHandler.importPlaylist(uri: playlist.uri, metadata: playlist.metadata,
                                                                       peer: connection.endpoint, revision: revision)
                    self.send(result, on: connection)
                }
                return
            }
            response = soapHandler.handle(path: request.path, headers: request.headers, body: request.body)
        } else if method == "SUBSCRIBE" || method == "UNSUBSCRIBE" {
            let event = subscriptions.handle(request, peer: connection.endpoint)
            send(event.0, on: connection) { [weak self] success in
                if let sid = event.initialSID { self?.subscriptions.finishSubscription(sid, accepted: success) }
            }
            return
        } else {
            response = HTTPResponse(status: 405, reason: "Method Not Allowed")
        }
        send(response, includeBody: method != "HEAD", on: connection)
    }

    private func descriptionResponse(for path: String) -> HTTPResponse {
        switch path {
        case "/api/v1/audio-format":
            struct Report: Encodable {
                let itemID: UUID?
                let transportState: String
                let transportStatus: String
                let stream: StreamAudioFormat?
            }
            let snapshot = rendererState.snapshot()
            let report = Report(itemID: snapshot.itemID, transportState: snapshot.transportState.rawValue,
                                transportStatus: snapshot.transportStatus, stream: snapshot.audioFormat)
            guard let bytes = try? JSONEncoder().encode(report) else {
                return .init(status: 500, reason: "Internal Server Error")
            }
            return .init(status: 200, reason: "OK", contentType: "application/json",
                         body: String(decoding: bytes, as: UTF8.self), extraHeaders: ["Cache-Control": "no-store"])
        case "/", "/device.xml":
            return xml(UPnPDescriptions.device(configuration: configuration))
        case "/upnp/avtransport/scpd.xml":
            return xml(UPnPDescriptions.avTransport)
        case "/upnp/renderingcontrol/scpd.xml":
            return xml(UPnPDescriptions.renderingControl)
        case "/upnp/connectionmanager/scpd.xml":
            return xml(UPnPDescriptions.connectionManager)
        default:
            return HTTPResponse(status: 404, reason: "Not Found", body: "Not found.\n")
        }
    }

    private func xml(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", contentType: "text/xml; charset=\"utf-8\"", body: body)
    }

    private func send(_ response: HTTPResponse, includeBody: Bool = true, on connection: NWConnection,
                      completion: (@Sendable (Bool) -> Void)? = nil) {
        connection.send(content: response.serialized(includeBody: includeBody), completion: .contentProcessed { error in
            completion?(error == nil)
            connection.cancel()
        })
    }

    private final class ListenerStartup {
        let signal = DispatchSemaphore(value: 0)
        private(set) var result: Result<Void, Error>?

        @discardableResult
        func complete(_ result: Result<Void, Error>) -> Bool {
            guard self.result == nil else { return false }
            self.result = result
            signal.signal()
            return true
        }
    }

    private enum ServerError: LocalizedError {
        case invalidPort
        case startupTimeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Invalid HTTP port"
            case .startupTimeout: return "HTTP server did not become ready"
            case .cancelled: return "HTTP server startup cancelled"
            }
        }
    }
}
