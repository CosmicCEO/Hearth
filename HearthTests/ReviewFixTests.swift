import Foundation
import Testing
@testable import Hearth

@Test func mariaClientKeepsThePasswordOffTheCommandLine() {
    let plain = MariaClient.unauthenticatedArguments(socket: "/tmp/mysql.sock")
    #expect(plain.first == "--no-defaults")
    #expect(!plain.joined(separator: " ").contains("password"))
    let defaults = MariaClient.defaultsText(password: "s3cret", socket: "/tmp/mysql.sock")
    #expect(defaults.contains("password=s3cret"))
    #expect(defaults.contains("socket=/tmp/mysql.sock"))
    let authed = MariaClient.authenticatedArguments(defaultsFile: "/tmp/client.cnf")
    #expect(authed.first == "--defaults-extra-file=/tmp/client.cnf")
    #expect(!authed.joined(separator: " ").contains("s3cret"))
    let sql = MariaClient.sqlArguments(socket: "/tmp/mysql.sock")
    #expect(sql.first == "--no-defaults")
    #expect(!sql.joined(separator: " ").contains("password"))
}

@Test func clientCommandQuotesAPathWithSpaces() {
    let command = MariaClient.shellCommand(
        binary: "/Users/jerodprice/Library/Application Support/Hearth/bin/mariadb",
        host: "127.0.0.1",
        port: 8889
    )
    #expect(command == "'/Users/jerodprice/Library/Application Support/Hearth/bin/mariadb' --host=127.0.0.1 --port=8889 -u root -p")
}

@Test func stoppedAgentIsKickstartedAndAFailureDoesNotStopTheWalk() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = testPaths(root)
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
            return ProcessResult(exitCode: 0, output: "state = spawn scheduled\n")
        }
        if call.arguments.first == "kickstart", call.arguments.last?.contains("mariadb") == true {
            return ProcessResult(exitCode: 1, output: "mariadb failed\n")
        }
        return ProcessResult(exitCode: 0, output: "")
    }
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    do {
        try await controller.startStack()
        Issue.record("expected the start to report the MariaDB failure")
    } catch let error as HearthError {
        #expect(error == .phase("Start services", detail: "mariadb failed"))
    }
    let kicks = runner.recorded().filter { $0.arguments.first == "kickstart" }.map { $0.arguments.last ?? "" }
    #expect(kicks == [
        "gui/501/com.jerodprice.hearth.mariadb",
        "gui/501/com.jerodprice.hearth.php-fpm",
        "gui/501/com.jerodprice.hearth.httpd",
    ])
}

@Test func reconcileBootsOutWhenDesiredIsStopped() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = testPaths(root)
    var layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    layout.setupComplete = true
    layout.desired = .stopped
    try writeLayout(layout, to: paths)
    let runner = FakeProcessRunner()
    runner.handler = { call in
        if call.arguments.first == "print" {
            return ProcessResult(exitCode: 0, output: "state = running\n")
        }
        return ProcessResult(exitCode: 0, output: "")
    }
    let controller = StackController(paths: paths, dependencies: testDependencies(runner: runner), logStore: LogStore())
    await controller.reconcile()
    let labels = runner.recorded().filter { $0.arguments.first == "bootout" }.map { $0.arguments.last ?? "" }
    #expect(labels == [
        "gui/501/com.jerodprice.hearth.httpd",
        "gui/501/com.jerodprice.hearth.php-fpm",
        "gui/501/com.jerodprice.hearth.mariadb",
    ])
    let disables = runner.recorded().filter { $0.arguments.first == "disable" }
    #expect(disables.count == 3)
}

@Test func resetBootsMariaDBOutBeforeMovingTheDataDirectory() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = testPaths(root)
    let layout = StackLayout.initial(
        support: paths.support,
        documentRoot: paths.documentRoot,
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    try writeLayout(layout, to: paths)
    try FileManager.default.createDirectory(at: paths.mysqlSystem, withIntermediateDirectories: true)
    let ports = OpenPorts()
    let runner = FakeProcessRunner()
    runner.handler = { call in
        if call.arguments.first == "bootout" { ports.close() }
        return ProcessResult(exitCode: 0, output: "")
    }
    var dependencies = testDependencies(runner: runner)
    dependencies.portIsOpen = { _, _ in ports.isOpen() }
    let controller = StackController(paths: paths, dependencies: dependencies, logStore: LogStore())
    try await controller.resetDatabase()
    #expect(runner.recorded().first?.arguments.first == "bootout")
    #expect(!FileManager.default.fileExists(atPath: paths.mysqlData.path))
    let moved = try FileManager.default.contentsOfDirectory(at: paths.support.appending(path: "var"), includingPropertiesForKeys: nil)
    #expect(moved.contains { $0.lastPathComponent.hasPrefix("mysql-reset-") })
}

@Test @MainActor func quitSignalsTheRunner() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FakeProcessRunner()
    let controller = StackController(paths: testPaths(root), dependencies: testDependencies(runner: runner), logStore: LogStore())
    let model = StackModel(controller: controller, logStore: LogStore())
    model.cancelForQuit()
    #expect(runner.wasCancelled())
}

@Test func busyFlagMakesTheWindowStarting() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = StackController(paths: testPaths(root), dependencies: testDependencies(runner: FakeProcessRunner()), logStore: LogStore())
    let snap = await controller.snapshot(operationInProgress: true)
    #expect(snap.statusWord == "Starting")
}

private func testPaths(_ root: URL) -> StackPaths {
    StackPaths(
        support: root.appending(path: "Hearth"),
        documentRoot: root.appending(path: "Sites"),
        launchAgents: root.appending(path: "LaunchAgents")
    )
}

private final class OpenPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}
