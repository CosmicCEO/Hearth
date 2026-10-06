import Darwin
import Foundation

struct ProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var output: String
}

protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ProcessResult
    func cancel()
}

final class LiveProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?

    func cancel() {
        lock.lock()
        let process = current
        lock.unlock()
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0, getpgid(pid) == pid {
            kill(-pid, SIGTERM)
        } else {
            process.terminate()
        }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "set -m; exec \"$0\" \"$@\"", executable] + arguments
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            process.environment = env

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let inputPipe = Pipe()
            if standardInput != nil {
                process.standardInput = inputPipe
            }

            let buffer = OutputBuffer()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) {
                    onOutput(text)
                }
            }

            let resumed = ResumeOnce()
            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let rest = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    buffer.append(rest)
                    if let text = String(data: rest, encoding: .utf8) {
                        onOutput(text)
                    }
                }
                resumed.resume(continuation, ProcessResult(exitCode: process.terminationStatus, output: buffer.text()))
            }

            do {
                try process.run()
                self.lock.lock()
                self.current = process
                self.lock.unlock()
                if let standardInput {
                    inputPipe.fileHandleForWriting.write(standardInput)
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                resumed.resume(continuation, ProcessResult(exitCode: 127, output: error.localizedDescription))
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<ProcessResult, Never>, _ result: ProcessResult) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume { continuation.resume(returning: result) }
    }
}
