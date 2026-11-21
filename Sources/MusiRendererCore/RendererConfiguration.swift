import Foundation

public struct RendererConfiguration: Sendable, Equatable {
    public static let defaultHTTPPort: UInt16 = 49_494
    public static let productName = "MusiRender"
    static let serverProduct = "macOS UPnP/1.1 MusiRender/0.2.0"

    public var friendlyName: String
    public var uuid: UUID
    public var httpPort: UInt16

    public init(
        friendlyName: String = Self.productName,
        uuid: UUID,
        httpPort: UInt16 = Self.defaultHTTPPort
    ) {
        self.friendlyName = friendlyName
        self.uuid = uuid
        self.httpPort = httpPort
    }
}
