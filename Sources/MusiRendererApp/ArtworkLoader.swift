import AppKit
import Foundation
import ImageIO

enum ArtworkLoader {
    private static let maximumBytes = 8 * 1_024 * 1_024

    static func image(from url: URL) async -> NSImage? {
        guard validURL(url) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        } catch {
            return nil
        }
    }

    private static func validURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.host != nil && url.user == nil && url.password == nil
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        // A session serves one artwork request. URLSession serializes delegate calls.
        private var redirects = 0

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            redirects += 1
            guard redirects <= 3, let from = response.url, let to = request.url, ArtworkLoader.validURL(to) else {
                completionHandler(nil)
                return
            }
            let bothLocalIPv4 = [from.host, to.host].allSatisfy { host in
                guard let host, let address = IPv4Interface.parse(host) else { return false }
                return IPv4Interface.available().contains { $0.contains(address: address) }
            }
            let sameHTTPOrigin = from.host == to.host && (from.port ?? 80) == (to.port ?? 80)
            let allowed = to.scheme == "https" ||
                (from.scheme == "http" && (sameHTTPOrigin || bothLocalIPv4))
            completionHandler(allowed ? request : nil)
        }
    }
}
