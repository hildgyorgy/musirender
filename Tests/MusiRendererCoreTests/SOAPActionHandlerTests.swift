import Foundation
@testable import MusiRendererCore
import XCTest

final class SOAPActionHandlerTests: XCTestCase {
    func testCapabilitiesPresetsAndCDATA() throws {
        let log = DiagnosticLog()
        let player = FakeAudioPlayer()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: log)
        let handler = SOAPActionHandler(playback: playback, log: log)
        func send(_ action: String, _ arguments: String = "", rendering: Bool = false) -> HTTPResponse {
            let type = rendering ? UPnPDescriptions.renderingControlType : UPnPDescriptions.avTransportType
            let service = rendering ? "renderingcontrol" : "avtransport"
            return handler.handle(path: "/upnp/\(service)/control", headers: ["soapaction": "\(type)#\(action)"],
                                  body: soap(action: action, arguments: "<InstanceID>0</InstanceID>" + arguments))
        }
        XCTAssertTrue(String(decoding: send("GetDeviceCapabilities").body, as: UTF8.self)
            .contains("<PlayMedia>NETWORK</PlayMedia>"))
        XCTAssertTrue(String(decoding: send("ListPresets", rendering: true).body, as: UTF8.self)
            .contains("<CurrentPresetNameList>FactoryDefaults</CurrentPresetNameList>"))
        playback.setVolume(85)
        playback.setMuted(true)
        XCTAssertEqual(send("SelectPreset", "<PresetName>FactoryDefaults</PresetName>", rendering: true).status, 200)
        XCTAssertEqual(playback.currentSnapshot().volume, RendererSnapshot().volume)
        XCTAssertFalse(player.muted)
        let result = send("SetAVTransportURI",
                          "<CurrentURI>http://example.test/one</CurrentURI><CurrentURIMetaData><![CDATA[<item><title>A &amp; B</title></item>]]></CurrentURIMetaData>")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(playback.currentSnapshot().title, "A & B")
    }

    func testAlbumPlaylistSurvivesConsecutiveNextWithoutController() throws {
        let player = FakeAudioPlayer()
        let log = DiagnosticLog()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: log)
        let handler = SOAPActionHandler(playback: playback, log: log)
        let uri = "http://127.0.0.1:8000/album.xml"
        let xml = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/">
            \((1...3).map { number in
                """
                <item><dc:title>Track \(number)</dc:title><res protocolInfo="http-get:*:audio/mp4:*" duration="0:02:00">http://example.test/\(number)?id=\(number)&amp;token=test</res></item>
                """
            }.joined())
            </DIDL-Lite>
            """
        let entries = try DIDLPlaylist.parse(Data(xml.utf8))
        let requestMetadata = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
            <item><res protocolInfo="http-get:*:text/xml:DLNA.ORG_PN=DIDL_S">\(uri)</res></item>
            </DIDL-Lite>
            """
        XCTAssertTrue(DIDLPlaylist.identifiesPlaylist(requestMetadata, uri: uri))
        XCTAssertFalse(DIDLPlaylist.identifiesPlaylist(requestMetadata, uri: "http://127.0.0.1/other.xml"))
        let revision = playback.beginPlaylistImport()
        try playback.stop()
        XCTAssertThrowsError(try playback.importPlaylist(uri: uri, metadata: requestMetadata, entries: entries, revision: revision))
        try playback.importPlaylist(uri: uri, metadata: requestMetadata, entries: entries, revision: playback.beginPlaylistImport())
        func send(_ action: String) -> String {
            let response = handler.handle(path: "/upnp/avtransport/control",
                                          headers: ["soapaction": "\(UPnPDescriptions.avTransportType)#\(action)"],
                                          body: soap(action: action, arguments: "<InstanceID>0</InstanceID>"))
            return String(decoding: response.body, as: UTF8.self)
        }
        XCTAssertTrue(send("GetMediaInfo").contains("<NrTracks>3</NrTracks>"))
        XCTAssertTrue(send("GetMediaInfo").contains("<CurrentURI>\(uri)</CurrentURI>"))
        XCTAssertTrue(send("GetMediaInfo").contains("<NextURI></NextURI>"))
        try playback.play()
        XCTAssertEqual(playback.currentSnapshot().transportState, .playing)
        try playback.next()
        let second = playback.currentSnapshot()
        XCTAssertEqual(second.trackNumber, 2)
        XCTAssertEqual(second.title, "Track 2")
        XCTAssertTrue(second.canAdvanceToNext)
        XCTAssertTrue(send("GetPositionInfo").contains("<TrackURI>http://example.test/2?id=2&amp;token=test</TrackURI>"))
        player.finishNaturally()
        let third = playback.currentSnapshot()
        XCTAssertEqual(third.trackNumber, 3)
        XCTAssertEqual(third.title, "Track 3")
        XCTAssertEqual(playback.currentSnapshot().transportState, .playing)
        XCTAssertFalse(third.canAdvanceToNext)
    }

    func testManualNextWhenPausedKeepsPlaybackPaused() throws {
        let player = FakeAudioPlayer()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: DiagnosticLog())
        try playback.setURI("http://example.test/first", metadata: "")
        try playback.setNextURI("http://example.test/second", metadata: "")
        try playback.play()
        try playback.pause()
        XCTAssertTrue(playback.currentSnapshot().canAdvanceToNext)
        try playback.next()
        let snapshot = playback.currentSnapshot()
        XCTAssertEqual(snapshot.transportState, .pausedPlayback)
        XCTAssertEqual(snapshot.currentURI, "http://example.test/second")
        XCTAssertFalse(snapshot.canAdvanceToNext)
        XCTAssertThrowsError(try playback.previous())
    }

    func testFormatBelongsToCurrentItemAndRetryRetainsNext() throws {
        let player = FakeAudioPlayer()
        let playback = PlaybackCoordinator(state: RendererState(), player: player, log: DiagnosticLog())
        let first = "http://example.test/first"
        let second = "http://example.test/second"
        try playback.setURI(first, metadata: "")
        try playback.setNextURI(second, metadata: "")
        try playback.play()
        let firstID = try XCTUnwrap(playback.currentSnapshot().itemID)
        let format = StreamAudioFormat(codec: "ALAC", sampleRateHz: 96_000, bitDepth: 24,
                                       channels: 2, estimatedBitrateBps: 2_000_000)
        player.onEvent?(firstID, .audioFormat(format))
        XCTAssertEqual(playback.currentSnapshot().audioFormat, format)
        player.onEvent?(firstID, .failed("Connection lost"))
        try playback.play()
        player.onEvent?(firstID, .audioFormat(format))
        let retried = playback.currentSnapshot()
        XCTAssertNotEqual(retried.itemID, firstID)
        XCTAssertNil(retried.audioFormat)
        XCTAssertEqual(retried.currentURI, first)
        XCTAssertEqual(retried.nextURI, second)
        XCTAssertEqual(retried.transportState, .playing)
    }

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
        let nextMetadata = """
            &lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;
            &lt;item&gt;&lt;dc:title&gt;Two&lt;/dc:title&gt;&lt;upnp:albumArtURI&gt;https://example.test/cover?id=2&amp;amp;size=250&lt;/upnp:albumArtURI&gt;&lt;/item&gt;
            &lt;/DIDL-Lite&gt;
            """
        XCTAssertEqual(send("SetNextAVTransportURI",
                            "<NextURI>http://example.test/two?a=1&amp;b=2</NextURI><NextURIMetaData>\(nextMetadata)</NextURIMetaData>").status, 200)
        XCTAssertEqual(player.preloadedURL?.absoluteString, "http://example.test/two?a=1&b=2")
        XCTAssertTrue(String(decoding: send("GetMediaInfo").body, as: UTF8.self)
            .contains("<NextURI>http://example.test/two?a=1&amp;b=2</NextURI>"))

        let nextID = try XCTUnwrap(player.stagedID)
        player.finishNaturally()
        let promoted = playback.currentSnapshot()
        XCTAssertEqual(promoted.currentURI, "http://example.test/two?a=1&b=2")
        XCTAssertEqual(promoted.itemID, nextID)
        XCTAssertEqual(player.preparedURL?.absoluteString, "http://example.test/one")
        XCTAssertEqual(player.playCalls, 1)
        XCTAssertEqual(promoted.title, "Two")
        XCTAssertEqual(promoted.artworkURL?.absoluteString, "https://example.test/cover?id=2&size=250")
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
    var stagedID: UUID?
    var playCalls = 0
    var currentItemID: UUID? { itemID }

    func prepare(url: URL, id: UUID) {
        preparedURL = url
        itemID = id
        preloadedURL = nil
        stagedID = nil
        emit(.ready)
    }

    func stageNext(url: URL?, id: UUID?) -> Bool {
        preloadedURL = url
        stagedID = id
        return id != nil
    }

    func activateNext(id: UUID, manually: Bool, playing: Bool) -> Bool {
        guard stagedID == id, manually || itemID == id else { return false }
        itemID = id
        stagedID = nil
        preloadedURL = nil
        emit(.ready)
        emit(playing ? .playing : .paused)
        return true
    }

    func finishNaturally() {
        let previous = itemID
        let successor = stagedID
        if let successor { itemID = successor }
        if let previous { onEvent?(previous, .ended) }
        if let successor { onEvent?(successor, .queueAdvanced) }
    }

    func play() { playCalls += 1; emit(.playing) }
    func pause() { emit(.paused) }
    func stop() { position = 0; emit(.paused) }
    func seek(to position: TimeInterval) { seekTarget = position }
    func setVolume(_ value: Float) { volume = value }
    func setMuted(_ value: Bool) { muted = value }

    private func emit(_ event: AudioPlaybackEvent) {
        if let itemID { onEvent?(itemID, event) }
    }
}
