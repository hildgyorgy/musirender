import Foundation
import Network
@testable import MusiRendererCore
import XCTest

final class HTTPAndEventTests: XCTestCase {
    func testRequestFramingHandlesContinueAndRejectsAmbiguousLengths() {
        let line = "POST /upnp/avtransport/control HTTP/1.1\r\n"
        let header = line + "Content-Length: 4\r\nExpect: 100-continue\r\n\r\n"
        guard case .waitingForBody(sendContinue: true) = HTTPRequest.frame(Data(header.utf8)) else {
            return XCTFail("Expected an interim continue response")
        }
        guard case .complete(let request) = HTTPRequest.frame(Data((header + "bodytrailing bytes").utf8)) else {
            return XCTFail("Expected complete framed request")
        }
        XCTAssertEqual(request.body, Data("body".utf8))
        let invalid = [
            ("Content-Length: 2\r\nContent-Length: 4", 400),
            ("Transfer-Encoding: chunked\r\nContent-Length: 4", 400),
            ("Transfer-Encoding: chunked", 501),
            ("Content-Length: -1", 400),
            ("Content-Length: 999999999999999999999999999", 413),
            ("Expect: custom", 417)
        ]
        for (fields, status) in invalid {
            guard case .rejected(let response) = HTTPRequest.frame(Data((line + fields + "\r\n\r\n").utf8)) else {
                XCTFail("Expected HTTP \(status) for \(fields)")
                continue
            }
            XCTAssertEqual(response.status, status)
        }
    }

    func testRuntimeDoesNotAdvertiseWhenHTTPPortIsOccupied() throws {
        let occupied = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Port bound")
        occupied.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        occupied.newConnectionHandler = { $0.cancel() }
        occupied.start(queue: DispatchQueue(label: "test.occupied-port"))
        defer { occupied.cancel() }
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(occupied.port)
        let runtime = RendererRuntime(configuration: .init(uuid: UUID(), httpPort: port.rawValue))
        defer { runtime.stop() }
        XCTAssertThrowsError(try runtime.start())
        XCTAssertFalse(runtime.hasLANInterface)
        XCTAssertFalse(runtime.log.snapshot().contains { $0.message.hasPrefix("Renderer online") })
    }

    func testGENAStatusParsing() {
        XCTAssertEqual(EventSubscriptionManager.httpStatus(Data("HTTP/1.1 204 No Content\r\n".utf8)), 204)
        XCTAssertEqual(EventSubscriptionManager.httpStatus(Data("HTTP/1.0 202 Accepted\r\n".utf8)), 202)
        XCTAssertNil(EventSubscriptionManager.httpStatus(Data("HTTP/1.1 2000 Invalid\r\n".utf8)))
    }
}
