import Darwin
import Foundation

public final class SSDPService: @unchecked Sendable {
    private static let multicastAddress = "239.255.255.250"
    private static let port: UInt16 = 1900
    private static let configurationID: UInt32 = 5

    private let configuration: RendererConfiguration
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "com.musirenderer.ssdp")
    private let bootID = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(UInt32.max)))
    private var socketDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var advertisementTimer: DispatchSourceTimer?
    private var interfaces: [IPv4Interface] = []
    private var lastAdvertisement = DispatchTime(uptimeNanoseconds: 0)
    private var mediaServers: [URL: Date] = [:]
    private static let mediaServerTarget = "urn:schemas-upnp-org:device:MediaServer:1"

    public init(configuration: RendererConfiguration, log: DiagnosticLog) {
        self.configuration = configuration
        self.log = log
    }

    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    private func startOnQueue() throws {
        guard socketDescriptor < 0 else { return }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw SSDPError.posix(errno) }
        do {
            try configure(descriptor)
            socketDescriptor = descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveAvailableDatagrams() }
        source.setCancelHandler { Darwin.close(descriptor) }
        readSource = source
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refreshInterfaces() }
        advertisementTimer = timer
        timer.resume()

        log.record("SSDP listening on UDP port 1900")
        refreshInterfaces()
    }

    public func stop() {
        queue.sync {
            guard socketDescriptor >= 0 else { return }
            sendNotifications(subtype: "ssdp:byebye")
            advertisementTimer?.cancel()
            advertisementTimer = nil
            readSource?.cancel()
            readSource = nil
            socketDescriptor = -1
            interfaces = []
            mediaServers.removeAll()
        }
    }

    func mediaServerLocation(for source: URL) async -> URL? {
        guard let host = source.host, let address = IPv4Interface.parse(host),
              source.scheme?.lowercased() == "http" else { return nil }
        let port = source.port ?? 80
        if let location = cachedMediaServer(host: host, port: port) { return location }

        let sent = queue.sync {
            guard socketDescriptor >= 0,
                  let interface = interfaces.first(where: { $0.contains(address: address) }),
                  let multicast = IPv4Interface.parse(Self.multicastAddress) else { return false }
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = Self.port.bigEndian
            destination.sin_addr = multicast
            let query = [
                "M-SEARCH * HTTP/1.1", "HOST: \(Self.multicastAddress):\(Self.port)",
                "MAN: \"ssdp:discover\"", "MX: 1", "ST: \(Self.mediaServerTarget)", "", ""
            ].joined(separator: "\r\n")
            return sendPacket(Data(query.utf8), descriptor: socketDescriptor, to: destination, multicastVia: interface)
        }
        guard sent else { return nil }
        do { try await Task.sleep(for: .milliseconds(1300)) } catch { return nil }
        return cachedMediaServer(host: host, port: port)
    }

    func isLocalMediaHost(_ host: String) -> Bool {
        guard let address = IPv4Interface.parse(host) else { return false }
        return queue.sync { interfaces.contains { $0.contains(address: address) } }
    }

    private func cachedMediaServer(host: String, port: Int) -> URL? {
        queue.sync {
            mediaServers.filter { $0.key.host == host && ($0.key.port ?? 80) == port && $0.value > Date() }
                .max(by: { $0.value < $1.value })?.key
        }
    }

    var hasNetworkInterface: Bool { queue.sync { !interfaces.isEmpty } }

    func refreshAfterWake() {
        queue.async { [weak self] in self?.refreshInterfaces(rejoin: true) }
    }

    private func refreshInterfaces(rejoin: Bool = false) {
        guard socketDescriptor >= 0, let multicast = IPv4Interface.parse(Self.multicastAddress) else { return }
        let previous = interfaces
        let available = IPv4Interface.available()
        for interface in previous where rejoin || !available.contains(interface) {
            var request = ip_mreq(imr_multiaddr: multicast, imr_interface: interface.address)
            _ = setsockopt(socketDescriptor, IPPROTO_IP, IP_DROP_MEMBERSHIP, &request,
                           socklen_t(MemoryLayout<ip_mreq>.size))
        }
        interfaces = available.filter { interface in
            if !rejoin && previous.contains(interface) { return true }
            var request = ip_mreq(imr_multiaddr: multicast, imr_interface: interface.address)
            let result = setsockopt(socketDescriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request,
                                    socklen_t(MemoryLayout<ip_mreq>.size))
            return result == 0 || errno == EADDRINUSE
        }
        if previous != interfaces {
            let addresses = interfaces.map { "\($0.name)=\($0.addressString)" }.joined(separator: ", ")
            log.record(addresses.isEmpty ? "SSDP is waiting for a LAN interface" : "SSDP interfaces: \(addresses)")
        }
        if !interfaces.isEmpty && (rejoin || previous != interfaces || .now() >= lastAdvertisement + .seconds(600)) {
            lastAdvertisement = .now()
            sendAliveNotifications()
        }
    }

    private func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw SSDPError.posix(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SSDPError.posix(errno) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func receiveAvailableDatagrams() {
        while socketDescriptor >= 0 {
            var buffer = [UInt8](repeating: 0, count: 65_535)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawSender in
                    recvfrom(socketDescriptor, &buffer, buffer.count, 0, rawSender, &senderLength)
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    log.record("SSDP receive error: \(String(cString: strerror(errno)))", level: .warning)
                }
                return
            }
            handle(Data(buffer.prefix(count)), sender: sender)
        }
    }

    private func handle(_ data: Data, sender: sockaddr_in) {
        guard let message = SSDPMessage.parse(data) else { return }
        if message.startLine.hasPrefix("HTTP/1.1 200") ||
           (message.startLine == "NOTIFY * HTTP/1.1" && message.headers["nts"] == "ssdp:alive") {
            rememberMediaServer(message, sender: sender.sin_addr)
            return
        }
        guard message.startLine.uppercased() == "M-SEARCH * HTTP/1.1",
              message.headers["man"]?.lowercased().contains("ssdp:discover") == true,
              let searchTarget = message.headers["st"]
        else { return }

        let senderAddress = IPv4Interface.string(from: sender.sin_addr)
        log.record("SSDP M-SEARCH from \(senderAddress), ST=\(searchTarget)")
        let matchingTargets = targets(matching: searchTarget)
        guard !matchingTargets.isEmpty else { return }
        guard let selectedInterface = interfaces.first(where: { $0.contains(address: sender.sin_addr) })
                ?? interfaces.first else { return }
        let requestedDelay = Int(message.headers["mx"] ?? "1") ?? 1
        let maximumDelay = max(0, min(requestedDelay, 5))
        let delay = Double.random(in: 0...Double(maximumDelay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.interfaces.contains(selectedInterface) else { return }
            for target in matchingTargets {
                self.sendSearchResponse(target: target, to: sender, via: selectedInterface)
            }
        }
    }

    private func rememberMediaServer(_ message: SSDPMessage, sender: in_addr) {
        let target = message.headers["st"] ?? message.headers["nt"] ?? ""
        guard target.lowercased().hasPrefix("urn:schemas-upnp-org:device:mediaserver:"),
              let location = message.headers["location"], let url = URL(string: location),
              url.scheme?.lowercased() == "http", url.host == IPv4Interface.string(from: sender),
              url.user == nil, url.password == nil, url.fragment == nil else { return }
        let now = Date()
        mediaServers = mediaServers.filter { $0.value > now }
        guard mediaServers[url] != nil || mediaServers.count < 64 else { return }
        mediaServers[url] = now.addingTimeInterval(300)
    }

    private func sendSearchResponse(target: Target, to destination: sockaddr_in, via interface: IPv4Interface) {
        let location = "http://\(interface.addressString):\(configuration.httpPort)/device.xml"
        let message = """
        HTTP/1.1 200 OK\r
        CACHE-CONTROL: max-age=1800\r
        DATE: \(Self.httpDate())\r
        EXT:\r
        LOCATION: \(location)\r
        SERVER: macOS UPnP/1.1 MusiRenderer/0.1\r
        ST: \(target.notificationType)\r
        USN: \(target.usn)\r
        BOOTID.UPNP.ORG: \(bootID)\r
        CONFIGID.UPNP.ORG: \(Self.configurationID)\r
        \r

        """
        send(Data(message.utf8), to: destination, via: interface, multicast: false)
        log.record("SSDP response via \(interface.name), ST=\(target.notificationType)")
    }

    private func sendAliveNotifications() {
        sendNotifications(subtype: "ssdp:alive")
    }

    private func sendNotifications(subtype: String) {
        guard let multicast = IPv4Interface.parse(Self.multicastAddress) else { return }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = Self.port.bigEndian
        destination.sin_addr = multicast

        for interface in interfaces {
            for target in allTargets {
                var lines = [
                    "NOTIFY * HTTP/1.1",
                    "HOST: \(Self.multicastAddress):\(Self.port)",
                    "NT: \(target.notificationType)",
                    "NTS: \(subtype)",
                    "USN: \(target.usn)",
                    "BOOTID.UPNP.ORG: \(bootID)",
                    "CONFIGID.UPNP.ORG: \(Self.configurationID)"
                ]
                if subtype == "ssdp:alive" {
                    lines.append("CACHE-CONTROL: max-age=1800")
                    lines.append("LOCATION: http://\(interface.addressString):\(configuration.httpPort)/device.xml")
                    lines.append("SERVER: macOS UPnP/1.1 MusiRenderer/0.1")
                }
                let message = lines.joined(separator: "\r\n") + "\r\n\r\n"
                send(Data(message.utf8), to: destination, via: interface, multicast: true)
            }
        }
        if subtype == "ssdp:alive" { log.record("SSDP alive advertisements sent") }
    }

    private func send(_ data: Data, to destination: sockaddr_in, via interface: IPv4Interface, multicast: Bool) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        if multicast {
            _ = sendPacket(data, descriptor: descriptor, to: destination, multicastVia: interface)
            return
        } else {
            var source = sockaddr_in()
            source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            source.sin_family = sa_family_t(AF_INET)
            source.sin_addr = interface.address
            _ = withUnsafePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        _ = sendPacket(data, descriptor: descriptor, to: destination)
    }

    private func sendPacket(_ data: Data, descriptor: Int32, to destination: sockaddr_in,
                            multicastVia interface: IPv4Interface? = nil) -> Bool {
        if let interface {
            var address = interface.address
            guard setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &address, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                return false
            }
            var ttl: UInt8 = 2
            _ = setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        }
        var mutableDestination = destination
        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &mutableDestination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawDestination in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, rawDestination,
                           socklen_t(MemoryLayout<sockaddr_in>.size)) == bytes.count
                }
            }
        }
    }

    private var uuidString: String { "uuid:\(configuration.uuid.uuidString.lowercased())" }

    private var allTargets: [Target] {
        [
            Target(notificationType: "upnp:rootdevice", usn: "\(uuidString)::upnp:rootdevice"),
            Target(notificationType: uuidString, usn: uuidString),
            Target(notificationType: UPnPDescriptions.deviceType, usn: "\(uuidString)::\(UPnPDescriptions.deviceType)"),
            Target(notificationType: UPnPDescriptions.avTransportType, usn: "\(uuidString)::\(UPnPDescriptions.avTransportType)"),
            Target(notificationType: UPnPDescriptions.renderingControlType, usn: "\(uuidString)::\(UPnPDescriptions.renderingControlType)"),
            Target(notificationType: UPnPDescriptions.connectionManagerType, usn: "\(uuidString)::\(UPnPDescriptions.connectionManagerType)")
        ]
    }

    private func targets(matching searchTarget: String) -> [Target] {
        if searchTarget.caseInsensitiveCompare("ssdp:all") == .orderedSame { return allTargets }
        return allTargets.filter { $0.notificationType.caseInsensitiveCompare(searchTarget) == .orderedSame }
    }

    private static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    private struct Target {
        let notificationType: String
        let usn: String
    }

    private enum SSDPError: LocalizedError {
        case posix(Int32)

        var errorDescription: String? {
            switch self {
            case let .posix(code): return String(cString: strerror(code))
            }
        }
    }
}
