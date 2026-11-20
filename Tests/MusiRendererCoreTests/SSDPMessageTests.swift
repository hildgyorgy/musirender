@testable import MusiRendererCore
import XCTest

final class SSDPMessageTests: XCTestCase {
    func testParsesHeadersCaseInsensitively() throws {
        let data = Data("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: \"ssdp:discover\"\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        MX: 2\r
        \r

        """.utf8)

        let message = try XCTUnwrap(SSDPMessage.parse(data))
        XCTAssertEqual(message.startLine, "M-SEARCH * HTTP/1.1")
        XCTAssertEqual(message.headers["man"], "\"ssdp:discover\"")
        XCTAssertEqual(message.headers["mx"], "2")
    }
}
