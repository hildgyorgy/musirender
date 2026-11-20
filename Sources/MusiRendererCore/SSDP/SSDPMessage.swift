import Foundation

struct SSDPMessage {
    let startLine: String
    let headers: [String: String]

    static func parse(_ data: Data) -> SSDPMessage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return SSDPMessage(startLine: String(first), headers: headers)
    }
}
