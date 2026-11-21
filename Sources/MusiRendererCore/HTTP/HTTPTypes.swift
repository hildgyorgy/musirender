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

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body = bodyStart < data.endIndex ? Data(data[bodyStart...]) : Data()
        return HTTPRequest(method: parts[0], target: parts[1], version: parts[2], headers: headers, body: body)
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
        allHeaders["Server"] = "macOS UPnP/1.1 MusiRenderer/0.1"
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
