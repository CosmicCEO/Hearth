import Foundation

final class LogStore: @unchecked Sendable {
    static let maxLines = 4000
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    private var phase = ""

    func setPhase(_ phase: String) {
        lock.lock()
        self.phase = phase
        lock.unlock()
    }

    func append(_ chunk: String) {
        lock.lock()
        partial.append(chunk)
        while let newline = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<newline]))
            partial = String(partial[partial.index(after: newline)...])
        }
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
        lock.unlock()
    }

    func snapshot() -> (phase: String, log: String) {
        lock.lock()
        defer { lock.unlock() }
        var shown = lines
        if !partial.isEmpty { shown.append(partial) }
        return (phase, shown.joined(separator: "\n"))
    }
}
