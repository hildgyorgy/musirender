import Foundation
@testable import MusiRendererCore
import XCTest

final class UPnPDescriptionsTests: XCTestCase {
    func testMediaRedirectUsesOnlyDestinationOrigin() throws {
        let stream = try XCTUnwrap(URL(string: "http://192.168.1.20:17502/mconnect/stream"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: stream, statusCode: 301, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://192.168.1.33:49494/media/track?token=fixture#fragment"]
        ))
        XCTAssertEqual(RendererRuntime.mediaRedirectOrigin(from: response, stream: stream)?.absoluteString,
                       "http://192.168.1.33:49494")

        let sameHost = try XCTUnwrap(HTTPURLResponse(
            url: stream, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "/other-track"]
        ))
        XCTAssertNil(RendererRuntime.mediaRedirectOrigin(from: sameHost, stream: stream))
    }

    func testMediaSourceUsesTheServersAdvertisedName() {
        let server = """
            <root xmlns="urn:schemas-upnp-org:device-1-0">
              <device>
                <deviceType>urn:schemas-upnp-org:device:MediaServer:2</deviceType>
                <friendlyName> Gerbera &amp; Music </friendlyName>
              </device>
            </root>
            """
        XCTAssertEqual(RendererRuntime.mediaServerName(from: Data(server.utf8)), "Gerbera & Music")
        let renderer = UPnPDescriptions.device(configuration: .init(uuid: UUID()))
        XCTAssertNil(RendererRuntime.mediaServerName(from: Data(renderer.utf8)))
    }

    func testEveryDescriptionIsWellFormedXML() throws {
        let configuration = RendererConfiguration(
            friendlyName: "Living Room & Hi-Fi",
            uuid: UUID(uuidString: "67F8B2A1-9742-4579-98F7-4C1461C07E11")!
        )
        let documents = [
            UPnPDescriptions.device(configuration: configuration),
            UPnPDescriptions.avTransport,
            UPnPDescriptions.renderingControl,
            UPnPDescriptions.connectionManager,
            UPnPDescriptions.invalidActionSOAP()
        ]

        for document in documents {
            XCTAssertNoThrow(try XMLDocument(xmlString: document))
        }
    }

    func testDeviceDescriptionContainsStableIdentityAndServices() {
        let uuid = UUID(uuidString: "67F8B2A1-9742-4579-98F7-4C1461C07E11")!
        let document = UPnPDescriptions.device(configuration: .init(friendlyName: "Test", uuid: uuid))

        XCTAssertTrue(document.contains("uuid:67f8b2a1-9742-4579-98f7-4c1461c07e11"))
        XCTAssertTrue(document.contains(UPnPDescriptions.deviceType))
        XCTAssertTrue(document.contains(UPnPDescriptions.avTransportType))
        XCTAssertTrue(document.contains(UPnPDescriptions.renderingControlType))
        XCTAssertTrue(document.contains(UPnPDescriptions.connectionManagerType))
    }
}
