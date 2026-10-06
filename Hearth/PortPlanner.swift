import Foundation

struct ClaimedPorts: Equatable, Sendable {
    var http: Int
    var maria: Int
    var fpm: Int
}

enum PortPlanner {
    static let httpStart = 8888
    static let mariaStart = 8889
    static let fpmStart = 9000
    static let window = 20

    static var scanPorts: [Int] {
        Array(httpStart..<(httpStart + window))
            + Array(mariaStart..<(mariaStart + window))
            + Array(fpmStart..<(fpmStart + window))
    }

    static func claim(busy: Set<Int>) throws -> ClaimedPorts {
        var used = busy
        guard let http = take(start: httpStart, busy: &used) else { throw HearthError.noFreePort }
        guard let maria = take(start: mariaStart, busy: &used) else { throw HearthError.noFreePort }
        guard let fpm = take(start: fpmStart, busy: &used) else { throw HearthError.noFreePort }
        return ClaimedPorts(http: http, maria: maria, fpm: fpm)
    }

    private static func take(start: Int, busy: inout Set<Int>) -> Int? {
        for offset in 0..<window {
            let candidate = start + offset
            if busy.contains(candidate) { continue }
            busy.insert(candidate)
            return candidate
        }
        return nil
    }
}

enum PortOwnership {
    static func isConflict(port: Int, busy: Set<Int>, agentIsRunning: Bool) -> Bool {
        busy.contains(port) && !agentIsRunning
    }
}
