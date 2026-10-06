import Darwin
import Foundation

enum PortProbe {
    static func busy(among ports: [Int]) -> Set<Int> {
        Set(ports.filter { !canBind($0) })
    }

    static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    static func isOpen(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    static func primaryGroupName() -> String {
        let gid = getgid()
        guard let group = getgrgid(gid), let name = group.pointee.gr_name else { return "staff" }
        return String(cString: name)
    }
}

struct StackDependencies: Sendable {
    var runner: any ProcessRunning
    var keychain: any KeychainStoring
    var portIsOpen: @Sendable (String, Int) async -> Bool
    var busyPorts: @Sendable ([Int]) -> Set<Int>
    var availableBytes: @Sendable (URL) -> Int64
    var userName: String
    var groupName: String
    var uid: uid_t

    static func live() -> StackDependencies {
        StackDependencies(
            runner: LiveProcessRunner(),
            keychain: KeychainStore(),
            portIsOpen: { host, port in PortProbe.isOpen(host: host, port: port) },
            busyPorts: { PortProbe.busy(among: $0) },
            availableBytes: { url in
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage ?? 0
            },
            userName: NSUserName(),
            groupName: PortProbe.primaryGroupName(),
            uid: getuid()
        )
    }
}
