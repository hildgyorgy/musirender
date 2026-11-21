import Darwin
import Foundation

struct IPv4Interface: Sendable, Equatable {
    let name: String
    let address: in_addr
    let netmask: in_addr
    let index: UInt32

    var addressString: String { Self.string(from: address) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.address.s_addr == rhs.address.s_addr && lhs.netmask.s_addr == rhs.netmask.s_addr
    }

    func contains(address candidate: in_addr) -> Bool {
        (address.s_addr & netmask.s_addr) == (candidate.s_addr & netmask.s_addr)
    }

    static func available() -> [IPv4Interface] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [IPv4Interface] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current?.pointee {
            defer { current = item.ifa_next }
            guard let rawAddress = item.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET),
                  let rawMask = item.ifa_netmask
            else { continue }

            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_MULTICAST != 0
            else { continue }

            let address = rawAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            let netmask = rawMask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            let name = String(cString: item.ifa_name)
            result.append(.init(
                name: name,
                address: address,
                netmask: netmask,
                index: if_nametoindex(item.ifa_name)
            ))
        }
        return result
    }

    static func parse(_ string: String) -> in_addr? {
        var address = in_addr()
        return inet_pton(AF_INET, string, &address) == 1 ? address : nil
    }

    static func string(from address: in_addr) -> String {
        var mutableAddress = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &mutableAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "0.0.0.0"
        }
        return String(cString: buffer)
    }
}
