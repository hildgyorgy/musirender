import Foundation

public struct RendererConfiguration: Sendable, Equatable {
    public static let defaultHTTPPort: UInt16 = 49_494

    public var friendlyName: String
    public var uuid: UUID
    public var httpPort: UInt16

    public init(
        friendlyName: String = "MusiRenderer",
        uuid: UUID,
        httpPort: UInt16 = Self.defaultHTTPPort
    ) {
        self.friendlyName = friendlyName
        self.uuid = uuid
        self.httpPort = httpPort
    }
}
