import Foundation
import Network

struct DIDLPlaylist {
    static let protocolInfo = "http-get:*:text/xml:DLNA.ORG_PN=DIDL_S"
    static let maximumBytes = 1_048_576
    private static let namespace = "urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"

    struct Entry {
        let uri: String
        let metadata: String
        let duration: TimeInterval?
    }

    static func identifiesPlaylist(_ metadata: String, uri: String) -> Bool {
        guard metadata.contains("DIDL_S"), let root = try? rootElement(metadata) else { return false }
        return root.elements(forLocalName: "item", uri: namespace).contains { item in
            item.elements(forLocalName: "res", uri: namespace).contains { resource in
                resource.attribute(forName: "protocolInfo")?.stringValue?
                    .caseInsensitiveCompare(protocolInfo) == .orderedSame && resource.stringValue == uri
            }
        }
    }

    static func download(uri: String, from peer: NWEndpoint) async throws -> [Entry] {
        guard case let .hostPort(peerHost, _) = peer,
              let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "http", let host = components.host,
              let address = IPv4Address(host),
              let expectedAddress = IPv4Address(String(describing: peerHost).replacingOccurrences(of: "::ffff:", with: "")),
              address == expectedAddress,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw PlaybackCoordinator.PlaybackError.invalidURI }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "text/xml" || response.mimeType == "application/xml",
              response.expectedContentLength <= maximumBytes else { throw InvalidDocument() }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw InvalidDocument() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [Entry] {
        guard data.count <= maximumBytes, let xml = String(data: data, encoding: .utf8) else { throw InvalidDocument() }
        let root = try rootElement(xml)
        let items = root.elements(forLocalName: "item", uri: namespace)
        guard (1...1_000).contains(items.count), root.children?.compactMap({ $0 as? XMLElement }).count == items.count else {
            throw InvalidDocument()
        }
        return try items.map { item in
            guard let resource = item.elements(forLocalName: "res", uri: namespace).first(where: {
                $0.attribute(forName: "protocolInfo")?.stringValue?.lowercased().hasPrefix("http-get:*:audio/") == true
            }), let uri = resource.stringValue else { throw InvalidDocument() }
            let entryRoot = XMLElement(name: "DIDL-Lite")
            for namespace in root.namespaces ?? [] { entryRoot.addNamespace(namespace.copy() as! XMLNode) }
            entryRoot.addChild(item.copy() as! XMLNode)
            let duration = resource.attribute(forName: "duration")?.stringValue.flatMap(UPnPTime.parse)
            return Entry(uri: uri, metadata: entryRoot.xmlString, duration: duration)
        }
    }

    private static func rootElement(_ xml: String) throws -> XMLElement {
        guard !xml.contains("<!DOCTYPE"),
              let root = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]).rootElement(),
              root.localName == "DIDL-Lite", root.uri == namespace else { throw InvalidDocument() }
        return root
    }

    private struct InvalidDocument: Error {}

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
