import Foundation
import Network

public final class UPnPDeviceServer: @unchecked Sendable {
    private let configuration: RendererConfiguration
    private let log: DiagnosticLog
    private let soapHandler: SOAPActionHandler
    private let subscriptions: EventSubscriptionManager
    private let queue = DispatchQueue(label: "com.musirenderer.http")
    private var listener: NWListener?

    public init(configuration: RendererConfiguration, playback: PlaybackCoordinator, log: DiagnosticLog) {
        self.configuration = configuration
        self.log = log
        self.soapHandler = SOAPActionHandler(playback: playback, log: log)
        self.subscriptions = EventSubscriptionManager(state: playback.state)
    }

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.httpPort) else {
            throw ServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.record("HTTP server listening on port \(self.configuration.httpPort)")
            case let .failed(error):
                self.log.record("HTTP server failed: \(error)", level: .error)
            case .cancelled:
                self.log.record("HTTP server stopped")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        subscriptions.stop()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if buffer.count > 1_048_576 {
                self.send(.init(status: 413, reason: "Payload Too Large"), on: connection)
                return
            }

            if self.isCompleteRequest(buffer), let request = HTTPRequest.parse(buffer) {
                self.handle(request, on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return false }
        guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return true }
        let lengthLine = header.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("content-length:")
        }
        let length = lengthLine.flatMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        } ?? 0
        return length >= 0 && length <= data.count - range.upperBound
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let method = request.method.uppercased()
        log.record("HTTP \(method) \(request.target)")
        let response: HTTPResponse

        if method == "GET" || method == "HEAD" {
            response = descriptionResponse(for: request.path)
        } else if method == "POST", request.path.hasSuffix("/control") {
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

    private enum ServerError: Error {
        case invalidPort
    }
}
