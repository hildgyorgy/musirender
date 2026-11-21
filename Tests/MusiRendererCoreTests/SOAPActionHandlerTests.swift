import Foundation
@testable import MusiRendererCore
import XCTest

final class SOAPActionHandlerTests: XCTestCase {
    func testSeekAndLocalChangesAreReflectedInPolling() throws {
        let player = FakeAudioPlayer()
        let log = DiagnosticLog()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: log)
        let handler = SOAPActionHandler(playback: playback, log: log)
        let path = "/upnp/avtransport/control"
        func send(_ action: String, _ arguments: String = "") -> HTTPResponse {
            handler.handle(path: path, headers: ["soapaction": "\(UPnPDescriptions.avTransportType)#\(action)"],
                           body: soap(action: action, arguments: "<InstanceID>0</InstanceID>" + arguments))
        }

        try playback.setURI("http://example.test/stream", metadata: "")
        try playback.play()
        XCTAssertEqual(send("Seek", "<Unit>REL_TIME</Unit><Target>00:01:02.500</Target>").status, 200)
        XCTAssertEqual(player.seekTarget, 62.5)
        XCTAssertEqual(playback.currentSnapshot().transportState, .playing)
        XCTAssertTrue(String(decoding: send("GetPositionInfo").body, as: UTF8.self).contains("<RelTime>00:00:12</RelTime>"))

        try playback.seek(to: 75, expectedURI: "http://example.test/stream")
        player.position = 75
        XCTAssertTrue(String(decoding: send("GetPositionInfo").body, as: UTF8.self).contains("<RelTime>00:01:15</RelTime>"))
        XCTAssertTrue(String(decoding: send("Seek", "<Unit>TRACK_NR</Unit><Target>1</Target>").body, as: UTF8.self)
            .contains("<errorCode>710</errorCode>"))
        for invalidTarget in ["00:00:60", "00:04:00"] {
            XCTAssertTrue(String(decoding: send("Seek", "<Unit>ABS_TIME</Unit><Target>\(invalidTarget)</Target>").body, as: UTF8.self)
                .contains("<errorCode>711</errorCode>"))
        }
        XCTAssertThrowsError(try playback.seek(to: 50, expectedURI: "http://example.test/old"))
        XCTAssertEqual(player.seekTarget, 75)
    }

    func testSetURIAndPlayReportActualPlayingState() throws {
        let player = FakeAudioPlayer()
        let state = RendererState()
        let coordinator = PlaybackCoordinator(state: state, player: player, log: DiagnosticLog())
        let handler = SOAPActionHandler(playback: coordinator, log: DiagnosticLog())

        let setResponse = handler.handle(
            path: "/upnp/avtransport/control",
            headers: ["soapaction": "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\""],
            body: soap(action: "SetAVTransportURI", arguments: """
                <InstanceID>0</InstanceID>
                <CurrentURI>http://192.168.1.33:4533/rest/stream.view?id=42&amp;t=secret</CurrentURI>
                <CurrentURIMetaData></CurrentURIMetaData>
                """)
        )
        XCTAssertEqual(setResponse.status, 200)
        XCTAssertEqual(player.preparedURL?.absoluteString, "http://192.168.1.33:4533/rest/stream.view?id=42&t=secret")
        XCTAssertEqual(state.snapshot().transportState, .stopped)

        let playResponse = handler.handle(
            path: "/upnp/avtransport/control",
            headers: ["soapaction": "\"urn:schemas-upnp-org:service:AVTransport:1#Play\""],
            body: soap(action: "Play", arguments: "<InstanceID>0</InstanceID><Speed>1</Speed>")
        )
        XCTAssertEqual(playResponse.status, 200)
        XCTAssertEqual(coordinator.currentSnapshot().transportState, .playing)
    }

    func testAdvancePromotesMetadataAndConsumesNextOnlyOnce() throws {
        let player = FakeAudioPlayer()
        let log = DiagnosticLog()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: log)
        let handler = SOAPActionHandler(playback: playback, log: log)
        func send(_ action: String, _ arguments: String = "") -> HTTPResponse {
            handler.handle(path: "/upnp/avtransport/control",
                           headers: ["soapaction": "\(UPnPDescriptions.avTransportType)#\(action)"],
                           body: soap(action: action, arguments: "<InstanceID>0</InstanceID>" + arguments))
        }
        try playback.setURI("http://example.test/one", metadata: "")
        try playback.play()
        XCTAssertEqual(playback.currentSnapshot().transportState, .playing)
        let first = try XCTUnwrap(player.itemID)
        XCTAssertEqual(send("SetNextAVTransportURI",
                            "<NextURI>http://example.test/two?a=1&amp;b=2</NextURI><NextURIMetaData>&lt;title&gt;Two&lt;/title&gt;</NextURIMetaData>").status, 200)
        XCTAssertEqual(player.preloadedURL?.absoluteString, "http://example.test/two?a=1&b=2")
        XCTAssertTrue(String(decoding: send("GetMediaInfo").body, as: UTF8.self)
            .contains("<NextURI>http://example.test/two?a=1&amp;b=2</NextURI>"))

        player.onEvent?(first, .ended)
        let promoted = playback.currentSnapshot()
        XCTAssertEqual(promoted.currentURI, "http://example.test/two?a=1&b=2")
        XCTAssertEqual(promoted.title, "Two")
        XCTAssertEqual(promoted.nextURI, "")
        player.onEvent?(first, .ended)
        XCTAssertEqual(playback.currentSnapshot().transportState, .playing)
        for action in ["Next", "Previous"] {
            XCTAssertTrue(String(decoding: send(action).body, as: UTF8.self).contains("<errorCode>711</errorCode>"))
        }
        let second = try XCTUnwrap(player.itemID)
        player.onEvent?(second, .ended)
        XCTAssertEqual(playback.currentSnapshot().transportState, .stopped)
    }

    func testManualNextWhenStoppedAndEmptyURIClearsQueue() throws {
        let player = FakeAudioPlayer()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: DiagnosticLog())
        try playback.setURI("http://example.test/one", metadata: "")
        try playback.setNextURI("http://example.test/two", metadata: "")
        try playback.setNextURI("", metadata: "")
        XCTAssertThrowsError(try playback.next())
        try playback.setNextURI("http://example.test/three", metadata: "")
        try playback.next()
        XCTAssertEqual(playback.currentSnapshot().transportState, .stopped)
        XCTAssertEqual(playback.currentSnapshot().currentURI, "http://example.test/three")
        XCTAssertEqual(playback.currentSnapshot().nextURI, "")
    }

    func testRenderingControlMapsVolumeAndMute() {
        let player = FakeAudioPlayer()
        let coordinator = PlaybackCoordinator(state: RendererState(), player: player, log: DiagnosticLog())
        let handler = SOAPActionHandler(playback: coordinator, log: DiagnosticLog())

        let volume = handler.handle(
            path: "/upnp/renderingcontrol/control",
            headers: ["soapaction": "\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\""],
            body: soap(action: "SetVolume", arguments: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>73</DesiredVolume>")
        )
        let mute = handler.handle(
            path: "/upnp/renderingcontrol/control",
            headers: ["soapaction": "\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\""],
            body: soap(action: "SetMute", arguments: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>1</DesiredMute>")
        )

        XCTAssertEqual(volume.status, 200)
        XCTAssertEqual(mute.status, 200)
        XCTAssertEqual(player.volume, 0.73, accuracy: 0.001)
        XCTAssertTrue(player.muted)
    }

    func testRejectsUnknownInstance() {
        let coordinator = PlaybackCoordinator(state: RendererState(), player: FakeAudioPlayer(), log: DiagnosticLog())
        let response = SOAPActionHandler(playback: coordinator, log: DiagnosticLog()).handle(
            path: "/upnp/avtransport/control",
            headers: ["soapaction": "\"urn:schemas-upnp-org:service:AVTransport:1#Play\""],
            body: soap(action: "Play", arguments: "<InstanceID>4</InstanceID><Speed>1</Speed>")
        )
        XCTAssertEqual(response.status, 500)
        XCTAssertTrue(String(data: response.body, encoding: .utf8)?.contains("<errorCode>718</errorCode>") == true)
    }

    private func soap(action: String, arguments: String) -> Data {
        Data("""
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(arguments)</u:\(action)></s:Body>
        </s:Envelope>
        """.utf8)
    }
}

private final class FakeAudioPlayer: AudioPlayer {
    var onEvent: (@Sendable (UUID, AudioPlaybackEvent) -> Void)?
    var duration: TimeInterval = 180
    var position: TimeInterval = 12
    var preparedURL: URL?
    var volume: Float = 0
    var muted = false
    var seekTarget: TimeInterval?
    var itemID: UUID?
    var preloadedURL: URL?

    func prepare(url: URL, id: UUID) { preparedURL = url; itemID = id; emit(.ready) }
    func preload(url: URL?) { preloadedURL = url }
    func play() { emit(.playing) }
    func pause() { emit(.paused) }
    func stop() { position = 0; emit(.paused) }
    func seek(to position: TimeInterval) { seekTarget = position }
    func setVolume(_ value: Float) { volume = value }
    func setMuted(_ value: Bool) { muted = value }

    private func emit(_ event: AudioPlaybackEvent) {
        if let itemID { onEvent?(itemID, event) }
    }
}
