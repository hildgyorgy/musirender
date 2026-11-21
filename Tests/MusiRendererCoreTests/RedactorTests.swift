@testable import MusiRendererCore
import XCTest

final class RedactorTests: XCTestCase {
    func testRedactsValuesInAllURLs() {
        let value = "http://one.test/a?id=1&t=first http://two.test/b?%75=second&amp;token=third"
        XCTAssertEqual(Redactor.redact(value),
                       "http://one.test/a?id=1&t=<redacted> http://two.test/b?%75=<redacted>&amp;token=<redacted>")
    }
    func testRedactsAuthenticationQueryParameters() {
        let input = "GET /stream?id=42&u=alice&t=secret&s=salt&format=raw HTTP/1.1"
        let result = Redactor.redact(input)

        XCTAssertEqual(
            result,
            "GET /stream?id=42&u=<redacted>&t=<redacted>&s=<redacted>&format=raw HTTP/1.1"
        )
        XCTAssertFalse(result.contains("alice"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testLeavesDescriptionPathUntouched() {
        XCTAssertEqual(Redactor.redact("HTTP GET /device.xml"), "HTTP GET /device.xml")
    }
}
