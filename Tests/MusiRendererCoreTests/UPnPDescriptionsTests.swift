import Foundation
@testable import MusiRendererCore
import XCTest

final class UPnPDescriptionsTests: XCTestCase {
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
