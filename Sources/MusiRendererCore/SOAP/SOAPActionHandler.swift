import Foundation
import Network

final class SOAPActionHandler: @unchecked Sendable {
    private let playback: PlaybackCoordinator
    private let log: DiagnosticLog

    init(playback: PlaybackCoordinator, log: DiagnosticLog) {
        self.playback = playback
        self.log = log
    }

    func playlistRequest(path: String, headers: [String: String], body: Data) -> (uri: String, metadata: String)? {
        guard Service(path: path) == .avTransport,
              actionName(headers: headers, body: body) == "SetAVTransportURI" else { return nil }
        let arguments = LeafXMLParser(data: body).values
        guard arguments["InstanceID"] == nil || arguments["InstanceID"] == "0",
              let uri = arguments["CurrentURI"], let metadata = arguments["CurrentURIMetaData"],
              DIDLPlaylist.identifiesPlaylist(metadata, uri: uri) else { return nil }
        return (uri, metadata)
    }

    func beginPlaylistImport() -> UInt64 { playback.beginPlaylistImport() }

    func importPlaylist(uri: String, metadata: String, peer: NWEndpoint, revision: UInt64) async -> HTTPResponse {
        do {
            let entries = try await DIDLPlaylist.download(uri: uri, from: peer)
            try playback.importPlaylist(uri: uri, metadata: metadata, entries: entries, revision: revision)
            return success("SetAVTransportURI", service: .avTransport)
        } catch PlaybackCoordinator.PlaybackError.noMedia {
            return fault(code: 701, description: "Transition Not Available")
        } catch {
            log.record("Could not import album playlist", level: .warning)
            return fault(code: 716, description: "Resource Not Found")
        }
    }

    func handle(path: String, headers: [String: String], body: Data) -> HTTPResponse {
        guard let service = Service(path: path),
              let action = actionName(headers: headers, body: body)
        else { return fault(code: 401, description: "Invalid Action") }

        let arguments = LeafXMLParser(data: body).values
        if let instance = arguments["InstanceID"], instance != "0" {
            return fault(code: 718, description: "Invalid InstanceID")
        }
        log.record("SOAP \(service.label).\(action)")

        switch service {
        case .avTransport: return handleAVTransport(action, arguments: arguments)
        case .renderingControl: return handleRenderingControl(action, arguments: arguments)
        case .connectionManager: return handleConnectionManager(action)
        }
    }

    private func handleAVTransport(_ action: String, arguments: [String: String]) -> HTTPResponse {
        do {
            switch action {
            case "SetAVTransportURI":
                guard let uri = arguments["CurrentURI"], !uri.isEmpty else { return fault(code: 402, description: "Invalid Args") }
                try playback.setURI(uri, metadata: arguments["CurrentURIMetaData"] ?? "")
                return success(action, service: .avTransport)
            case "SetNextAVTransportURI":
                guard arguments["InstanceID"] == "0", let uri = arguments["NextURI"] else {
                    return fault(code: 402, description: "Invalid Args")
                }
                try playback.setNextURI(uri, metadata: arguments["NextURIMetaData"] ?? "")
                return success(action, service: .avTransport)
            case "Next", "Previous":
                guard arguments["InstanceID"] == "0" else { return fault(code: 402, description: "Invalid Args") }
                if action == "Next" { try playback.next() }
                else { try playback.previous() }
                return success(action, service: .avTransport)
            case "Play":
                guard arguments["Speed", default: "1"] == "1" else { return fault(code: 717, description: "Play Speed Not Supported") }
                try playback.play()
                return success(action, service: .avTransport)
            case "Pause":
                try playback.pause()
                return success(action, service: .avTransport)
            case "Stop":
                try playback.stop()
                return success(action, service: .avTransport)
            case "GetTransportSettings":
                return success(action, service: .avTransport, values: [("PlayMode", "NORMAL"), ("RecQualityMode", "NOT_IMPLEMENTED")])
            case "SetPlayMode":
                guard let mode = arguments["NewPlayMode"] else { return fault(code: 402, description: "Invalid Args") }
                guard mode == "NORMAL" else { return fault(code: 712, description: "Play Mode Not Supported") }
                return success(action, service: .avTransport)
            case "Seek":
                guard arguments["InstanceID"] == "0",
                      let unit = arguments["Unit"], let target = arguments["Target"] else {
                    return fault(code: 402, description: "Invalid Args")
                }
                guard unit == "REL_TIME" || (unit == "ABS_TIME" && playback.state.snapshot().playlistURI == nil) else {
                    return fault(code: 710, description: "Seek Mode Not Supported")
                }
                guard let position = UPnPTime.parse(target) else {
                    return fault(code: 711, description: "Illegal Seek Target")
                }
                try playback.seek(to: position)
                return success(action, service: .avTransport)
            case "GetTransportInfo":
                let state = playback.currentSnapshot()
                return success(action, service: .avTransport, values: [
                    ("CurrentTransportState", state.transportState.rawValue),
                    ("CurrentTransportStatus", state.transportStatus),
                    ("CurrentSpeed", "1")
                ])
            case "GetPositionInfo":
                let state = playback.currentSnapshot()
                return success(action, service: .avTransport, values: [
                    ("Track", String(state.trackNumber)),
                    ("TrackDuration", UPnPTime.format(state.duration)),
                    ("TrackMetaData", state.currentMetadata),
                    ("TrackURI", state.currentURI),
                    ("RelTime", UPnPTime.format(state.position)),
                    ("AbsTime", state.playlistURI == nil ? UPnPTime.format(state.position) : "NOT_IMPLEMENTED"),
                    ("RelCount", "2147483647"),
                    ("AbsCount", "2147483647")
                ])
            case "GetMediaInfo":
                let state = playback.currentSnapshot()
                return success(action, service: .avTransport, values: [
                    ("NrTracks", String(state.trackCount)),
                    ("MediaDuration", UPnPTime.format(state.mediaDuration)),
                    ("CurrentURI", state.mediaURI),
                    ("CurrentURIMetaData", state.mediaMetadata),
                    ("NextURI", state.nextURI), ("NextURIMetaData", state.nextMetadata),
                    ("PlayMedium", "NETWORK"), ("RecordMedium", "NOT_IMPLEMENTED"),
                    ("WriteStatus", "NOT_IMPLEMENTED")
                ])
            case "GetCurrentTransportActions":
                let state = playback.currentSnapshot()
                return success(action, service: .avTransport, values: [("Actions", state.transportActions)])
            default:
                return fault(code: 401, description: "Invalid Action")
            }
        } catch PlaybackCoordinator.PlaybackError.invalidURI {
            return fault(code: 716, description: "Resource Not Found")
        } catch PlaybackCoordinator.PlaybackError.noMedia {
            return fault(code: 701, description: "Transition Not Available")
        } catch PlaybackCoordinator.PlaybackError.invalidSeekTarget {
            return fault(code: 711, description: "Illegal Seek Target")
        } catch {
            return fault(code: 501, description: "Action Failed")
        }
    }

    private func handleRenderingControl(_ action: String, arguments: [String: String]) -> HTTPResponse {
        if let channel = arguments["Channel"], channel != "Master" {
            return fault(code: 402, description: "Invalid Args")
        }
        switch action {
        case "GetVolume":
            return success(action, service: .renderingControl, values: [("CurrentVolume", String(playback.currentSnapshot().volume))])
        case "SetVolume":
            guard let raw = arguments["DesiredVolume"], let value = UInt16(raw), value <= 100 else {
                return fault(code: 402, description: "Invalid Args")
            }
            playback.setVolume(value)
            return success(action, service: .renderingControl)
        case "GetMute":
            return success(action, service: .renderingControl, values: [("CurrentMute", playback.currentSnapshot().isMuted ? "1" : "0")])
        case "SetMute":
            guard let raw = arguments["DesiredMute"], ["0", "1", "false", "true"].contains(raw.lowercased()) else {
                return fault(code: 402, description: "Invalid Args")
            }
            playback.setMuted(raw == "1" || raw.lowercased() == "true")
            return success(action, service: .renderingControl)
        default:
            return fault(code: 401, description: "Invalid Action")
        }
    }

    private func handleConnectionManager(_ action: String) -> HTTPResponse {
        switch action {
        case "GetProtocolInfo":
            return success(action, service: .connectionManager, values: [("Source", ""), ("Sink", UPnPDescriptions.sinkProtocolInfo)])
        case "GetCurrentConnectionIDs":
            return success(action, service: .connectionManager, values: [("ConnectionIDs", "0")])
        case "GetCurrentConnectionInfo":
            return success(action, service: .connectionManager, values: [
                ("RcsID", "0"), ("AVTransportID", "0"), ("ProtocolInfo", ""),
                ("PeerConnectionManager", ""), ("PeerConnectionID", "-1"),
                ("Direction", "Input"), ("Status", "OK")
            ])
        default:
            return fault(code: 401, description: "Invalid Action")
        }
    }

    private func actionName(headers: [String: String], body: Data) -> String? {
        if let header = headers["soapaction"] {
            return header.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).split(separator: "#").last.map(String.init)
        }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let pattern = #"<(?:[A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)\b[^>]*xmlns[^>]*urn:schemas-upnp-org:service"#
        return try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).flatMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private func success(_ action: String, service: Service, values: [(String, String)] = []) -> HTTPResponse {
        let content = values.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let body = envelope("<u:\(action)Response xmlns:u=\"\(service.type)\">\(content)</u:\(action)Response>")
        return HTTPResponse(status: 200, reason: "OK", contentType: "text/xml; charset=\"utf-8\"", body: body)
    }

    private func fault(code: Int, description: String) -> HTTPResponse {
        HTTPResponse(
            status: 500, reason: "Internal Server Error", contentType: "text/xml; charset=\"utf-8\"",
            body: UPnPDescriptions.errorSOAP(code: code, description: description)
        )
    }

    private func envelope(_ content: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\(content)</s:Body></s:Envelope>"
    }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private enum Service {
        case avTransport, renderingControl, connectionManager

        init?(path: String) {
            if path.contains("/avtransport/") { self = .avTransport }
            else if path.contains("/renderingcontrol/") { self = .renderingControl }
            else if path.contains("/connectionmanager/") { self = .connectionManager }
            else { return nil }
        }
        var type: String {
            switch self {
            case .avTransport: return UPnPDescriptions.avTransportType
            case .renderingControl: return UPnPDescriptions.renderingControlType
            case .connectionManager: return UPnPDescriptions.connectionManagerType
            }
        }
        var label: String {
            switch self {
            case .avTransport: return "AVTransport"
            case .renderingControl: return "RenderingControl"
            case .connectionManager: return "ConnectionManager"
            }
        }
    }
}
