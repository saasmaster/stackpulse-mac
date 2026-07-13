import Foundation

/// The Mac's primary LAN IPv4 address (e.g. `192.168.1.42`). A dev server started
/// with `--host` also serves on this address, so it's the "temporary IP domain"
/// you can open from your phone or another machine on the same Wi-Fi — the
/// shareable URL for showing a demo. Read-only; no network calls.
enum LocalNetwork {
    /// The first active, non-loopback IPv4 on an `en*` interface (Wi-Fi/Ethernet),
    /// preferring `en0`. `nil` when offline or none found.
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }     // prefer the primary interface
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
