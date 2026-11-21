import Foundation
import Network

final class EventSubscriptionManager: @unchecked Sendable {
    private enum Service: String {
        case avTransport = "/upnp/avtransport/event"
        case renderingControl = "/upnp/renderingcontrol/event"
        case connectionManager = "/upnp/connectionmanager/event"

        func payload(_ state: RendererSnapshot) -> String {
            let escape = UPnPDescriptions.xmlEscape
            let properties: [(String, String)]
            switch self {
            case .avTransport:
                let duration = UPnPTime.format(state.duration)
                let values = [
                    ("TransportState", state.transportState.rawValue), ("TransportStatus", state.transportStatus),
                    ("TransportPlaySpeed", "1"), ("CurrentPlayMode", "NORMAL"),
                    ("CurrentTrack", String(state.trackNumber)), ("NumberOfTracks", String(state.trackCount)),
                    ("AVTransportURI", state.mediaURI), ("AVTransportURIMetaData", state.mediaMetadata),
                    ("CurrentTrackURI", state.currentURI), ("CurrentTrackMetaData", state.currentMetadata),
                    ("NextAVTransportURI", state.nextURI), ("NextAVTransportURIMetaData", state.nextMetadata),
                    ("CurrentTrackDuration", duration), ("CurrentMediaDuration", UPnPTime.format(state.mediaDuration)),
                    ("CurrentTransportActions", state.transportActions),
                    ("PlaybackStorageMedium", state.currentURI.isEmpty ? "NONE" : "NETWORK"),
                    ("RecordStorageMedium", "NOT_IMPLEMENTED"), ("RecordMediumWriteStatus", "NOT_IMPLEMENTED")
                ]
                let elements = values.map { "<\($0.0) val=\"\(escape($0.1))\"/>" }.joined()
                properties = [("LastChange", lastChange(namespace: "AVT", elements: elements))]
            case .renderingControl:
                let elements = "<Volume channel=\"Master\" val=\"\(state.volume)\"/><Mute channel=\"Master\" val=\"\(state.isMuted ? 1 : 0)\"/>"
                properties = [("LastChange", lastChange(namespace: "RCS", elements: elements))]
            case .connectionManager:
                properties = [("SourceProtocolInfo", ""), ("SinkProtocolInfo", UPnPDescriptions.sinkProtocolInfo),
                              ("CurrentConnectionIDs", "0")]
            }
            let elements = properties.map { "<e:property><\($0.0)>\(escape($0.1))</\($0.0)></e:property>" }.joined()
            return "<?xml version=\"1.0\" encoding=\"utf-8\"?><e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\">\(elements)</e:propertyset>"
        }

        private func lastChange(namespace: String, elements: String) -> String {
            "<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/\(namespace)/\"><InstanceID val=\"0\">\(elements)</InstanceID></Event>"
        }
    }

    private struct Callback {
        let host: IPv4Address
        let port: NWEndpoint.Port
        let target: String

        init?(header: String, peer: NWEndpoint) {
            guard case let .hostPort(peerHost, _) = peer else { return nil }
            let peerString = String(describing: peerHost)
            let ipv4 = peerString.hasPrefix("::ffff:") ? String(peerString.dropFirst(7)) : peerString
            guard let peerAddress = IPv4Address(ipv4),
                  header.first == "<", let end = header.firstIndex(of: ">"),
                  let url = URLComponents(string: String(header[header.index(after: header.startIndex)..<end])),
                  url.scheme?.lowercased() == "http", let host = url.host, IPv4Address(host) == peerAddress,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  let portNumber = UInt16(exactly: url.port ?? 80), portNumber > 0,
                  let port = NWEndpoint.Port(rawValue: portNumber) else { return nil }
            self.host = peerAddress
            self.port = port
            let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            self.target = path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
            guard target.utf8.count <= 4096,
                  !target.utf8.contains(where: { $0 <= 32 || $0 == 127 }) else { return nil }
        }
    }

    private struct Subscription {
        let service: Service
        let callback: Callback
        var expires: DispatchTime
        var active = false
        var sequence: UInt32 = 0
        var lastSent: String?
        var pending: String?
        var inFlight: String?
        var retries = 0
        var delivery: NWConnection?
        var timer: DispatchWorkItem?
    }

    private let queue = DispatchQueue(label: "com.musirenderer.gena")
    private let state: RendererState
    private let log: DiagnosticLog
    private var observer: UUID?
    private var subscriptions: [String: Subscription] = [:]
    private var latest = RendererSnapshot()

    init(state: RendererState, log: DiagnosticLog) {
        self.state = state
        self.log = log
        observer = state.observe { [weak self] snapshot in
            self?.queue.async { [weak self] in self?.publish(snapshot) }
        }
    }

    deinit { if let observer { state.removeObserver(observer) } }

    func stop() {
        queue.sync { for sid in Array(subscriptions.keys) { remove(sid) } }
    }

    func handle(_ request: HTTPRequest, peer: NWEndpoint) -> (HTTPResponse, initialSID: String?) {
        queue.sync {
            removeExpired()
            guard let service = Service(rawValue: request.path) else {
                return (.init(status: 404, reason: "Not Found"), nil)
            }
            let headers = request.headers
            let sid = headers["sid"]
            let hasNewHeaders = headers["nt"] != nil || headers["callback"] != nil
            if request.method.uppercased() == "UNSUBSCRIBE" {
                guard !hasNewHeaders else { return (.init(status: 400, reason: "Bad Request"), nil) }
                guard let sid, subscriptions[sid]?.service == service else { return (preconditionFailed, nil) }
                remove(sid)
                return (.init(status: 200, reason: "OK"), nil)
            }

            let seconds = timeout(headers["timeout"])
            let expires = DispatchTime.now() + .seconds(seconds)
            if let sid {
                guard !hasNewHeaders else { return (.init(status: 400, reason: "Bad Request"), nil) }
                guard subscriptions[sid]?.service == service else { return (preconditionFailed, nil) }
                subscriptions[sid]?.expires = expires
                return (accepted(sid, seconds: seconds), nil)
            }
            guard headers["nt"]?.lowercased() == "upnp:event",
                  let header = headers["callback"], let callback = Callback(header: header, peer: peer) else {
                log.record("GENA subscription rejected for \(service.rawValue)", level: .warning)
                return (preconditionFailed, nil)
            }
            guard subscriptions.count < 64 else { return (.init(status: 503, reason: "Service Unavailable"), nil) }
            let newSID = "uuid:\(UUID().uuidString.lowercased())"
            subscriptions[newSID] = Subscription(service: service, callback: callback, expires: expires)
            return (accepted(newSID, seconds: seconds), newSID)
        }
    }

    func finishSubscription(_ sid: String, accepted: Bool) {
        queue.async {
            self.removeExpired()
            guard var subscription = self.subscriptions[sid] else { return }
            guard accepted else { self.remove(sid); return }
            subscription.active = true
            self.log.record("GENA subscribed to \(subscription.service.rawValue)")
            subscription.pending = subscription.service.payload(self.latest)
            self.subscriptions[sid] = subscription
            self.deliver(sid)
        }
    }

    private var preconditionFailed: HTTPResponse { .init(status: 412, reason: "Precondition Failed") }

    private func accepted(_ sid: String, seconds: Int) -> HTTPResponse {
        .init(status: 200, reason: "OK", extraHeaders: ["SID": sid, "TIMEOUT": "Second-\(seconds)"])
    }

    private func timeout(_ value: String?) -> Int {
        let prefix = "second-"
        guard let value = value?.lowercased(), value.hasPrefix(prefix),
              let requested = Int(value.dropFirst(prefix.count)), requested > 0 else { return 1800 }
        return min(requested, 1800)
    }

    private func removeExpired() {
        let now = DispatchTime.now()
        for sid in subscriptions.filter({ $0.value.expires <= now }).keys { remove(sid) }
    }

    private func remove(_ sid: String) {
        guard let subscription = subscriptions.removeValue(forKey: sid) else { return }
        subscription.timer?.cancel()
        subscription.delivery?.cancel()
    }

    private func publish(_ snapshot: RendererSnapshot) {
        latest = snapshot
        removeExpired()
        for sid in Array(subscriptions.keys) {
            guard var sub = subscriptions[sid], sub.active else { continue }
            let payload = sub.service.payload(snapshot)
            sub.pending = payload == (sub.inFlight ?? sub.lastSent) ? nil : payload
            subscriptions[sid] = sub
            deliver(sid)
        }
    }

    private func deliver(_ sid: String) {
        guard var sub = subscriptions[sid], sub.active, sub.delivery == nil, sub.timer == nil,
              let payload = sub.inFlight ?? sub.pending else { return }
        guard sub.expires > .now() else { remove(sid); return }
        let callback = sub.callback
        let headers = [
            "NOTIFY \(callback.target) HTTP/1.1", "HOST: \(callback.host):\(callback.port.rawValue)",
            "CONTENT-TYPE: text/xml; charset=\"utf-8\"", "CONTENT-LENGTH: \(payload.utf8.count)",
            "NT: upnp:event", "NTS: upnp:propchange", "SID: \(sid)", "SEQ: \(sub.sequence)",
            "CONNECTION: close"
        ].joined(separator: "\r\n")
        let message = Data((headers + "\r\n\r\n" + payload).utf8)
        let connection = NWConnection(host: .ipv4(callback.host), port: callback.port, using: .tcp)
        let timer = DispatchWorkItem { [weak self] in self?.finishDelivery(sid, status: nil) }
        sub.delivery = connection
        sub.timer = timer
        if sub.inFlight == nil {
            sub.inFlight = payload
            sub.pending = nil
        }
        subscriptions[sid] = sub

        queue.asyncAfter(deadline: .now() + .seconds(5), execute: timer)
        connection.start(queue: queue)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.subscriptions[sid]?.delivery === connection else { return }
            guard error == nil else { self.finishDelivery(sid, status: nil); return }
            connection.receive(minimumIncompleteLength: 13, maximumLength: 512) { [weak self, weak connection] data, _, _, _ in
                guard let self, let connection, self.subscriptions[sid]?.delivery === connection else { return }
                self.finishDelivery(sid, status: data.flatMap(Self.httpStatus))
            }
        })
    }

    static func httpStatus(_ data: Data) -> Int? {
        let prefix = Array(data.prefix(13))
        guard prefix.count == 13,
              ["HTTP/1.0 ", "HTTP/1.1 "].contains(String(decoding: prefix[0..<9], as: UTF8.self)),
              prefix[9..<12].allSatisfy({ (48...57).contains($0) }),
              prefix[12] == 32 || prefix[12] == 13 else { return nil }
        return Int(String(decoding: prefix[9..<12], as: UTF8.self))
    }

    private func finishDelivery(_ sid: String, status: Int?) {
        guard var sub = subscriptions[sid] else { return }
        sub.delivery?.cancel()
        sub.timer?.cancel()
        sub.delivery = nil
        sub.timer = nil
        if let status, (200..<300).contains(status) {
            sub.lastSent = sub.inFlight
            sub.inFlight = nil
            sub.sequence = sub.sequence == UInt32.max ? 1 : sub.sequence + 1
            sub.retries = 0
        } else if sub.retries == 0, status == nil || status == 408 || status == 429 || (status ?? 0) >= 500 {
            sub.retries = 1
            let retry = DispatchWorkItem { [weak self] in
                self?.subscriptions[sid]?.timer = nil
                self?.deliver(sid)
            }
            sub.timer = retry
            subscriptions[sid] = sub
            queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: retry)
            return
        } else {
            log.record("GENA delivery failed for \(sub.service.rawValue); subscription removed", level: .warning)
            remove(sid)
            return
        }
        subscriptions[sid] = sub
        deliver(sid)
    }
}
