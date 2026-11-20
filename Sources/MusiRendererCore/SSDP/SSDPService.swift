import Darwin
import Foundation

public final class SSDPService: @unchecked Sendable {
    private static let multicastAddress = "239.255.255.250"
    private static let port: UInt16 = 1900

    private let configuration: RendererConfiguration
    private let log: DiagnosticLog
    private let queue = DispatchQueue(label: "com.musirenderer.ssdp")
    private let bootID = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(UInt32.max)))
    private var socketDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var advertisementTimer: DispatchSourceTimer?
    private var interfaces: [IPv4Interface] = []

    public init(configuration: RendererConfiguration, log: DiagnosticLog) {
        self.configuration = configuration
        self.log = log
    }

    public func start() throws {
        guard socketDescriptor < 0 else { return }
        interfaces = IPv4Interface.available()
        guard !interfaces.isEmpty else { throw SSDPError.noMulticastInterface }

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
        timer.schedule(deadline: .now() + .seconds(600), repeating: .seconds(600), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.sendAliveNotifications() }
        advertisementTimer = timer
        timer.resume()

        log.record("SSDP listening on 239.255.255.250:1900 via \(interfaces.map { "\($0.name)=\($0.addressString)" }.joined(separator: ", "))")
        queue.async { [weak self] in self?.sendAliveNotifications() }
    }

    public func stop() {
        guard socketDescriptor >= 0 else { return }
        queue.sync {
            sendNotifications(subtype: "ssdp:byebye")
            advertisementTimer?.cancel()
            advertisementTimer = nil
            readSource?.cancel()
            readSource = nil
            socketDescriptor = -1
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

        guard let multicast = IPv4Interface.parse(Self.multicastAddress) else { throw SSDPError.invalidMulticastAddress }
        for interface in interfaces {
            var request = ip_mreq(imr_multiaddr: multicast, imr_interface: interface.address)
            if setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout.size(ofValue: request))) != 0 {
                log.record("Could not join SSDP on \(interface.name): \(String(cString: strerror(errno)))", level: .warning)
            }
        }

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
        guard let message = SSDPMessage.parse(data),
              message.startLine.uppercased() == "M-SEARCH * HTTP/1.1",
              message.headers["man"]?.lowercased().contains("ssdp:discover") == true,
              let searchTarget = message.headers["st"]
        else { return }

        let senderAddress = IPv4Interface.string(from: sender.sin_addr)
        log.record("SSDP M-SEARCH from \(senderAddress), ST=\(searchTarget)")
        let matchingTargets = targets(matching: searchTarget)
        guard !matchingTargets.isEmpty else { return }
        let selectedInterface = interfaces.first { $0.contains(address: sender.sin_addr) } ?? interfaces.first!
        let requestedDelay = Int(message.headers["mx"] ?? "1") ?? 1
        let maximumDelay = max(0, min(requestedDelay, 5))
        let delay = Double.random(in: 0...Double(maximumDelay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            for target in matchingTargets {
                self.sendSearchResponse(target: target, to: sender, via: selectedInterface)
            }
        }
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
        CONFIGID.UPNP.ORG: 1\r
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
                    "CONFIGID.UPNP.ORG: 1"
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

        var sourceAddress = interface.address
        if multicast {
            _ = setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &sourceAddress, socklen_t(MemoryLayout.size(ofValue: sourceAddress)))
            var ttl: UInt8 = 2
            _ = setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
        } else {
            var source = sockaddr_in()
            source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            source.sin_family = sa_family_t(AF_INET)
            source.sin_addr = sourceAddress
            _ = withUnsafePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var mutableDestination = destination
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &mutableDestination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawDestination in
                    _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, rawDestination, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        case noMulticastInterface
        case invalidMulticastAddress
        case posix(Int32)

        var errorDescription: String? {
            switch self {
            case .noMulticastInterface: return "No active IPv4 multicast interface is available."
            case .invalidMulticastAddress: return "The SSDP multicast address is invalid."
            case let .posix(code): return String(cString: strerror(code))
            }
        }
    }
}
