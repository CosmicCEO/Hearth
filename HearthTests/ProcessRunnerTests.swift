import Foundation
import Testing
@testable import Hearth

@Test func liveCommandRuns() async {
    let runner = LiveProcessRunner()
    let result = await runner.run(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [:],
        standardInput: Data(),
        onOutput: { _ in }
    )
    #expect(result.exitCode == 0, "exit \(result.exitCode) output [\(result.output)]")
}

@Test func liveCommandCanWriteStandardInput() async {
    let runner = LiveProcessRunner()
    let result = await runner.run(
        executable: "/usr/bin/true",
        arguments: [],
        environment: [:],
        standardInput: Data("select 1;\n".utf8),
        onOutput: { _ in }
    )
    #expect(result.exitCode == 0)
}

@Test func liveCancelStopsTheProcessGroup() async throws {
    let runner = LiveProcessRunner()
    let output = LockedText()
    let task = Task {
        await runner.run(
            executable: "/bin/bash",
            arguments: ["-c", "sleep 30 & echo $!; exec >/dev/null; wait"],
            environment: [:],
            standardInput: nil,
            onOutput: { output.append($0) }
        )
    }
    var grandchild: pid_t = 0
    for _ in 0..<40 {
        if let pid = Int32(output.text().trimmingCharacters(in: .whitespacesAndNewlines)) {
            grandchild = pid
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(grandchild > 0)
    runner.cancel()
    _ = await task.value
    runner.waitForExit()
    #expect(kill(grandchild, 0) != 0)
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value += text
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
