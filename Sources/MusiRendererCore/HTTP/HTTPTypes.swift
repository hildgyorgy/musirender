import Foundation

struct HTTPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data

    var path: String {
        guard let components = URLComponents(string: target) else { return target }
        return components.path.isEmpty ? "/" : components.path
    }

    enum Framing {
        case waitingForHeaders
        case waitingForBody(sendContinue: Bool)
        case complete(HTTPRequest)
        case rejected(HTTPResponse)
    }

    static let maximumBytes = 1_048_576
    private static let maximumHeaderBytes = 32_768

    static func frame(_ data: Data) -> Framing {
        let badRequest = Framing.rejected(.init(status: 400, reason: "Bad Request"))
        let largeHeader = Framing.rejected(.init(status: 431, reason: "Request Header Fields Too Large"))
        let largeBody = Framing.rejected(.init(status: 413, reason: "Payload Too Large"))
        guard data.count <= maximumBytes else { return largeBody }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? largeHeader : .waitingForHeaders
        }
        guard headerRange.upperBound <= maximumHeaderBytes else { return largeHeader }
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return badRequest }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return badRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isToken(parts[0]), parts[1].hasPrefix("/"),
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 != 127 }),
              ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else { return badRequest }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), isToken(String(line[..<colon])) else { return badRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return badRequest }
            if let existing = headers[name] {
                guard name != "content-length", name != "transfer-encoding" else { return badRequest }
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        if headers["transfer-encoding"] != nil {
            guard headers["content-length"] == nil else { return badRequest }
            return .rejected(.init(status: 501, reason: "Transfer Encoding Not Implemented"))
        }
        let bodyStart = headerRange.upperBound
        let length: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }) else { return badRequest }
            guard let parsed = Int(rawLength), parsed <= maximumBytes - bodyStart else { return largeBody }
            length = parsed
        } else {
            length = 0
        }
        if let expect = headers["expect"], expect.lowercased() != "100-continue" || parts[2] != "HTTP/1.1" {
            return .rejected(.init(status: 417, reason: "Expectation Failed"))
        }
        guard data.count - bodyStart >= length else {
            return .waitingForBody(sendContinue: headers["expect"] != nil)
        }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: parts[0], target: parts[1], version: parts[2], headers: headers, body: body))
    }

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                "!#$%&'*+-.^`_|~".utf8.contains($0)
        }
    }
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    init(status: Int, reason: String, contentType: String = "text/plain; charset=utf-8", body: String = "",
         extraHeaders: [String: String] = [:]) {
        self.status = status
        self.reason = reason
        self.headers = extraHeaders.merging(["Content-Type": contentType]) { supplied, _ in supplied }
        self.body = Data(body.utf8)
    }

    func serialized(includeBody: Bool = true) -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Server"] = RendererConfiguration.serverProduct
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var result = Data(text.utf8)
        if includeBody { result.append(body) }
        return result
    }
}
