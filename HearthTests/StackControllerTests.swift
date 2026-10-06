import Foundation
import Testing
@testable import Hearth

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var executable: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    var handler: @Sendable (Call) -> ProcessResult = { _ in
        ProcessResult(exitCode: 0, output: "")
    }

    func recorded() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments)
        record(call)
        let result = handler(call)
        if !result.output.isEmpty { onOutput(result.output) }
        return result
    }

    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func wasCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func waitForExit() {}
}

final class MemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    func save(password: String) throws {
        lock.lock()
        self.password = password
        lock.unlock()
    }

    func readPassword() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return password
    }
}

func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hearth-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testDependencies(
    runner: FakeProcessRunner,
    keychain: MemoryKeychain = MemoryKeychain(),
    bytes: Int64 = 20_000_000_000,
    busy: Set<Int> = [],
    gid: gid_t = 20,
    prefixNeedsAdministrator: @escaping @Sendable () -> Bool = { false }
) -> StackDependencies {
    StackDependencies(
        runner: runner,
        keychain: keychain,
        portIsOpen: { _, _ in true },
        busyPorts: { _ in busy },
        availableBytes: { _ in bytes },
        userName: "jerodprice",
        groupName: "staff",
        uid: 501,
        gid: gid,
        prefixNeedsAdministrator: prefixNeedsAdministrator
    )
}

func writeLayout(_ layout: StackLayout, to paths: StackPaths) throws {
    let data = try JSONEncoder().encode(layout)
    try FileManager.default.createDirectory(at: paths.stackJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: paths.stackJSON)
}

@Test func blockedSetupDoesNotRunBrew() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    try FileManager.default.createDirectory(at: paths.mysqlSystem, withIntermediateDirectories: true)
    let runner = FakeProcessRunner()
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    do {
        try await controller.install(allowLowDisk: true)
        Issue.record("expected the blocked error")
    } catch let error as HearthError {
        #expect(error == .blocked)
    }
    #expect(runner.recorded().isEmpty)
}

@Test func blockedSetupDoesNotAskForAdministrator() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    try FileManager.default.createDirectory(at: paths.mysqlSystem, withIntermediateDirectories: true)
    let runner = FakeProcessRunner()
    runner.handler = { _ in ProcessResult(exitCode: 1, output: "User canceled.\n") }
    let controller = StackController(
        paths: paths,
        dependencies: testDependencies(runner: runner, prefixNeedsAdministrator: { true }),
        logStore: LogStore()
    )
    do {
        try await controller.install(allowLowDisk: true)
        Issue.record("expected the blocked error")
    } catch let error as HearthError {
        #expect(error == .blocked)
    }
    #expect(runner.recorded().isEmpty)
}

@Test func deniedPrefixAuthorizationDoesNotInstallBrew() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    var layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    layout.prefix = "/Users/jerodprice/Library/Application Support/Hearth/homebrew"
    try writeLayout(layout, to: paths)
    let runner = FakeProcessRunner()
    runner.handler = { call in
        if call.executable == "/usr/bin/osascript" {
            return ProcessResult(exitCode: 1, output: "User canceled.\n")
        }
        return ProcessResult(exitCode: 0, output: "")
    }
    let controller = StackController(
        paths: paths,
        dependencies: testDependencies(runner: runner, prefixNeedsAdministrator: { true }),
        logStore: LogStore()
    )
    do {
        try await controller.install(allowLowDisk: true)
        Issue.record("expected the authorization error")
    } catch let error as HearthError {
        #expect(error == .phase("Check disk and ports", detail: "User canceled."))
    }
    let commands = runner.recorded()
    #expect(commands.last?.executable == "/usr/bin/osascript")
    #expect(commands.last?.arguments == ["-e", PrefixAuthorization.appleScript(uid: 501, gid: 20)])
    #expect(!commands.contains { $0.executable == "/usr/bin/curl" || $0.executable == "/usr/bin/tar" || $0.executable.contains("brew") })
    let saved = try JSONDecoder().decode(StackLayout.self, from: Data(contentsOf: paths.stackJSON))
    #expect(saved.prefix == HearthPrefix.path)
}

@Test func startStackBootstrapsInOrder() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    var layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    layout.setupComplete = true
    try writeLayout(layout, to: paths)
    let runner = FakeProcessRunner()
    runner.handler = { call in
        if call.arguments.first == "print" {
            return ProcessResult(exitCode: 1, output: "")
        }
        return ProcessResult(exitCode: 0, output: "")
    }
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    try await controller.startStack()
    let bootstraps = runner.recorded().filter { $0.arguments.first == "bootstrap" }.map { $0.arguments.last ?? "" }
    #expect(bootstraps == [
        paths.plist(for: .mariadb).path,
        paths.plist(for: .phpFPM).path,
        paths.plist(for: .httpd).path,
    ])
}

@Test func stopStackBootsOutInReverseOrder() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    let layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    try writeLayout(layout, to: paths)
    let runner = FakeProcessRunner()
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    await controller.stopStack()
    let labels = runner.recorded().filter { $0.arguments.first == "bootout" }.map { $0.arguments.last ?? "" }
    #expect(labels == [
        "gui/501/com.jerodprice.hearth.httpd",
        "gui/501/com.jerodprice.hearth.php-fpm",
        "gui/501/com.jerodprice.hearth.mariadb",
    ])
}

@Test func runningAgentIsNotBootstrappedAgain() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
    var layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    layout.setupComplete = true
    try writeLayout(layout, to: paths)
    let runner = FakeProcessRunner()
    runner.handler = { call in
        if call.arguments.first == "print" {
            return ProcessResult(exitCode: 0, output: "state = running\n")
        }
        return ProcessResult(exitCode: 0, output: "")
    }
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    try await controller.startStack()
    #expect(runner.recorded().filter { $0.arguments.first == "bootstrap" }.isEmpty)
}
