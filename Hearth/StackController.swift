import Foundation

struct CardSnapshot: Equatable, Identifiable, Sendable {
    var service: HearthService
    var title: String
    var version: String
    var endpoint: String
    var state: CardState
    var id: String { title }
}

struct AppSnapshot: Equatable, Sendable {
    var versionMessage: String?
    var setupComplete: Bool
    var hasSavedStack: Bool
    var blockedReason: String?
    var lowDisk: Bool
    var portsLine: String
    var documentRoot: String
    var statusWord: String
    var cards: [CardSnapshot]
    var httpURL: URL
    var clientCommand: String
    var passwordAvailable: Bool
    var phase: String
    var log: String

    static func empty(message: String? = nil) -> AppSnapshot {
        AppSnapshot(
            versionMessage: message,
            setupComplete: false,
            hasSavedStack: false,
            blockedReason: nil,
            lowDisk: false,
            portsLine: "",
            documentRoot: "",
            statusWord: "Stopped",
            cards: [],
            httpURL: URL(string: "http://127.0.0.1:8888/") ?? URL(fileURLWithPath: "/"),
            clientCommand: "",
            passwordAvailable: false,
            phase: "",
            log: ""
        )
    }
}

actor StackController {
    private var paths: StackPaths
    private let dependencies: StackDependencies
    private nonisolated let runner: any ProcessRunning
    private let logStore: LogStore

    init(paths: StackPaths, dependencies: StackDependencies, logStore: LogStore) {
        self.paths = paths
        self.dependencies = dependencies
        self.runner = dependencies.runner
        self.logStore = logStore
    }

    func install(allowLowDisk: Bool) async throws {
        try await withTaskCancellationHandler {
            try await performInstall(allowLowDisk: allowLowDisk)
        } onCancel: {
            dependencies.runner.cancel()
        }
    }

    nonisolated func cancelRunningWork() {
        runner.cancel()
        runner.waitForExit()
    }

    func resetDatabase() async throws {
        if let layout = try loadLayout() {
            adopt(layout)
            await bootout(.mariadb)
            guard await waitUntilPortClosed(layout.mariaPort, bind: layout.bindAddress) else {
                throw HearthError.phase("Reset database", detail: "MariaDB did not stop")
            }
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: paths.mysqlData.path) {
            let stamp = ResetStamp.string(from: Date(), calendar: .current)
            let destination = paths.support.appending(path: "var").appending(path: "mysql-reset-\(stamp)")
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: paths.mysqlData, to: destination)
        }
        if var layout = try loadLayout() {
            layout.passwordApplied = false
            try save(layout)
        }
    }

    func startStack() async throws {
        guard var layout = try loadLayout() else { throw HearthError.missing("stack.json") }
        adopt(layout)
        layout.desired = .running
        try save(layout)
        var failures: [String] = []
        for service in HearthService.startOrder {
            await setServiceEnabled(service, enabled: true)
            if let detail = await ensureRunning(service) {
                failures.append(detail)
            }
        }
        if let detail = failures.first {
            throw HearthError.phase("Start services", detail: detail)
        }
    }

    func stopStack() async {
        if var layout = try? loadLayout() {
            layout.desired = .stopped
            try? save(layout)
        }
        for service in HearthService.stopOrder {
            await setServiceEnabled(service, enabled: false)
            await bootout(service)
        }
    }

    func restart(_ service: HearthService) async throws {
        let result = await run(
            Launchctl.executable,
            Launchctl.kickstartArguments(uid: dependencies.uid, label: service.label),
            environment: [:],
            standardInput: nil,
            logged: true
        )
        if result.exitCode != 0 {
            throw HearthError.phase(service.title, detail: TextTail.lastNonEmptyLine(result.output))
        }
    }

    func reconcile() async {
        guard let layout = try? loadLayout(), layout.setupComplete else { return }
        adopt(layout)
        if layout.desired == .running {
            for service in HearthService.startOrder where await launchdState(service) == .notLoaded {
                await setServiceEnabled(service, enabled: true)
                _ = await run(
                    Launchctl.executable,
                    Launchctl.bootstrapArguments(uid: dependencies.uid, plist: paths.plist(for: service).path),
                    environment: [:],
                    standardInput: nil,
                    logged: true
                )
            }
            return
        }
        for service in HearthService.stopOrder where await launchdState(service) != .notLoaded {
            await setServiceEnabled(service, enabled: false)
            await bootout(service)
        }
    }

    func changeDocumentRoot(to path: String) async throws {
        guard var layout = try loadLayout() else { throw HearthError.missing("stack.json") }
        layout.documentRoot = path
        adopt(layout)
        try save(layout)
        try rewriteHTTP(layout)
        if await launchdState(.httpd) != .notLoaded {
            try await restart(.httpd)
        }
    }

    func serviceLog(_ service: HearthService) -> String {
        let manager = FileManager.default
        let errorURL = paths.errorLog(for: service)
        let stderrURL = paths.stderrLog(for: service)
        let raw: String
        if manager.fileExists(atPath: errorURL.path),
           let text = try? String(contentsOf: errorURL, encoding: .utf8),
           !text.isEmpty {
            raw = text
        } else {
            raw = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        }
        return LogTail.last(raw, count: 200)
    }

    func copyPassword() throws -> String {
        guard let password = try dependencies.keychain.readPassword() else {
            throw HearthError.keychain("Hearth has no saved root password")
        }
        return password
    }

    func snapshot(operationInProgress: Bool = false) async -> AppSnapshot {
        let bytes = dependencies.availableBytes(FileManager.default.homeDirectoryForCurrentUser)
        let lowDisk = bytes < DiskRule.minimumBytes
        let stored = logStore.snapshot()
        do {
            guard let layout = try loadLayout() else {
                let ports = try? PortPlanner.claim(busy: dependencies.busyPorts(PortPlanner.scanPorts))
                let http = ports?.http ?? PortPlanner.httpStart
                let maria = ports?.maria ?? PortPlanner.mariaStart
                var empty = AppSnapshot.empty()
                empty.lowDisk = lowDisk
                empty.portsLine = "Web 127.0.0.1:\(http). Database 127.0.0.1:\(maria)."
                empty.documentRoot = paths.documentRoot.path
                empty.httpURL = httpURL(http)
                empty.phase = stored.phase
                empty.log = stored.log
                empty.statusWord = ServiceStatus.window(cards: [], operationInProgress: operationInProgress)
                return empty
            }
            adopt(layout)
            let blocked = try isBlocked(layout) ? InstallPlanner.blockedMessage : nil
            let cards = layout.setupComplete ? await cards(for: layout) : []
            let password = try? dependencies.keychain.readPassword()
            return AppSnapshot(
                versionMessage: nil,
                setupComplete: layout.setupComplete,
                hasSavedStack: true,
                blockedReason: blocked,
                lowDisk: lowDisk,
                portsLine: "Web \(layout.bindAddress):\(layout.httpPort). Database \(layout.bindAddress):\(layout.mariaPort).",
                documentRoot: layout.documentRoot,
                statusWord: ServiceStatus.window(cards: cards.map(\.state), operationInProgress: operationInProgress),
                cards: cards,
                httpURL: httpURL(layout.httpPort),
                clientCommand: clientCommand(layout),
                passwordAvailable: password != nil,
                phase: stored.phase,
                log: stored.log
            )
        } catch HearthError.newerVersion {
            var empty = AppSnapshot.empty(message: HearthError.newerVersion.errorDescription)
            empty.lowDisk = lowDisk
            empty.phase = stored.phase
            empty.log = stored.log
            return empty
        } catch {
            var empty = AppSnapshot.empty(message: error.localizedDescription)
            empty.lowDisk = lowDisk
            return empty
        }
    }

    private func performInstall(allowLowDisk: Bool) async throws {
        beginPhase("Check disk and ports")
        let bytes = dependencies.availableBytes(FileManager.default.homeDirectoryForCurrentUser)
        guard DiskRule.allowsInstall(available: bytes, installAnyway: allowLowDisk) else {
            throw HearthError.lowDisk
        }
        try Task.checkCancellation()
        try ensureSetupDirectories()

        var layout: StackLayout
        if FileManager.default.fileExists(atPath: paths.stackJSON.path) {
            guard let loaded = try loadLayout() else { throw HearthError.missing("stack.json") }
            layout = loaded
            adopt(layout)
            try await assertSavedPortsFree(layout)
        } else {
            let ports = try PortPlanner.claim(busy: dependencies.busyPorts(PortPlanner.scanPorts))
            layout = StackLayout.initial(support: paths.support, documentRoot: paths.documentRoot, ports: ports)
            try save(layout)
        }
        if try isBlocked(layout) { throw HearthError.blocked }

        var plan = try await installSnapshotPlan(layout)
        try Task.checkCancellation()

        beginPhase("Install Homebrew")
        if plan.installHomebrew {
            try await runOrThrow(
                "Install Homebrew",
                "/usr/bin/curl",
                ["-fL", "--retry", "3", "-o", paths.homebrewTarball.path, StackLayout.homebrewTarballURL]
            )
            try await runOrThrow(
                "Install Homebrew",
                "/usr/bin/tar",
                ["-xz", "--strip-components", "1", "-C", paths.prefix.path, "-f", paths.homebrewTarball.path]
            )
        }
        if FileManager.default.fileExists(atPath: paths.brewBinary.path) {
            let version = await run(paths.brewBinary.path, ["--version"], environment: brewEnvironment(), standardInput: nil, logged: true)
            layout.brewVersion = firstLine(version.output)
            try save(layout)
        }

        beginPhase("Install Apache, PHP, and MariaDB")
        plan = try await installSnapshotPlan(layout)
        if !plan.formulaeToInstall.isEmpty {
            try await runOrThrow(
                "Install Apache, PHP, and MariaDB",
                paths.brewBinary.path,
                ["install"] + plan.formulaeToInstall,
                environment: brewEnvironment()
            )
        }

        beginPhase("Download Adminer")
        plan = try await installSnapshotPlan(layout)
        if plan.downloadAdminer {
            try await runOrThrow(
                "Download Adminer",
                "/usr/bin/curl",
                ["-fL", "--retry", "3", "-o", paths.adminerPHP.path, StackLayout.adminerURL]
            )
            let data = try Data(contentsOf: paths.adminerPHP)
            guard SHA256Hash.hex(data) == StackLayout.adminerSHA256Pin else {
                try? FileManager.default.removeItem(at: paths.adminerPHP)
                throw HearthError.phase("Download Adminer", detail: "checksum mismatch")
            }
        }
        if FileManager.default.fileExists(atPath: paths.adminerPHP.path) {
            try write(paths.adminerNotice, ConfigRenderer.adminerNotice)
        }

        beginPhase("Save the root password and create the database files")
        plan = try await installSnapshotPlan(layout)
        if plan.generatePassword {
            let password = try PasswordGenerator.generate()
            try dependencies.keychain.save(password: password)
        }
        if plan.initializeDatabase {
            let binaries = try resolve()
            try await runOrThrow(
                "Save the root password and create the database files",
                binaries.installDB.path,
                [
                    "--datadir=\(paths.mysqlData.path)",
                    "--auth-root-authentication-method=normal",
                    "--skip-test-db",
                ],
                environment: brewEnvironment()
            )
        }

        beginPhase("Write configuration, the welcome page, and the launch agents")
        plan = try await installSnapshotPlan(layout)
        if plan.rewriteConfigs {
            let binaries = try resolve()
            try writeWelcomeIfNeeded()
            try write(paths.httpdConf, httpdConfig(layout, binaries: binaries))
            try write(paths.phpFpmConf, phpConfig(layout))
            try write(paths.myCnf, mariaConfig(layout))
            try writeAgents(binaries)
        }

        beginPhase("Start MariaDB, apply the root password, then start PHP-FPM and Apache")
        plan = try await installSnapshotPlan(layout)
        layout.desired = .running
        try save(layout)
        if plan.applyPassword {
            await setServiceEnabled(.mariadb, enabled: true)
            if await ensureRunning(.mariadb) != nil {
                try await stopAfterFailedSetup(&layout)
                throw HearthError.servicesDidNotStart
            }
            guard await waitForPort(layout.mariaPort, bind: layout.bindAddress) else {
                try await stopAfterFailedSetup(&layout)
                throw HearthError.servicesDidNotStart
            }
            do {
                try await applyPassword(layout)
            } catch {
                try await stopAfterFailedSetup(&layout)
                throw error
            }
            layout.passwordApplied = true
            try save(layout)
        }
        for service in HearthService.startOrder {
            await setServiceEnabled(service, enabled: true)
            _ = await ensureRunning(service)
        }
        for service in HearthService.startOrder {
            guard await waitForPort(layout.port(for: service), bind: layout.bindAddress) else {
                throw HearthError.servicesDidNotStart
            }
        }
        if let binaries = try? resolve() {
            layout.formulae.httpd = firstLine((await run(binaries.httpd.path, ["-v"], environment: brewEnvironment(), standardInput: nil, logged: true)).output)
            layout.formulae.php = firstLine((await run(binaries.php.path, ["-v"], environment: brewEnvironment(), standardInput: nil, logged: true)).output)
            layout.formulae.mariadb = firstLine((await run(binaries.mariadbd.path, ["--version"], environment: brewEnvironment(), standardInput: nil, logged: true)).output)
        }
        layout.setupComplete = true
        layout.desired = .running
        try save(layout)
    }

    private func applyPassword(_ layout: StackLayout) async throws {
        guard let password = try dependencies.keychain.readPassword() else {
            throw HearthError.keychain("Hearth has no saved root password")
        }
        guard let binaries = try? resolve() else { throw HearthError.missing("mariadb") }
        let socket = paths.mysqlSocket.path
        let unauthenticated = await run(
            binaries.mariadb.path,
            MariaClient.unauthenticatedArguments(socket: socket),
            environment: brewEnvironment(),
            standardInput: nil,
            logged: true
        )
        let authenticatedSucceeded: Bool
        if unauthenticated.exitCode == 0 {
            authenticatedSucceeded = false
        } else {
            try write(paths.clientDefaults, MariaClient.defaultsText(password: password, socket: socket), permissions: 0o600)
            let authenticated = await run(
                binaries.mariadb.path,
                MariaClient.authenticatedArguments(defaultsFile: paths.clientDefaults.path),
                environment: brewEnvironment(),
                standardInput: nil,
                logged: false
            )
            try? FileManager.default.removeItem(at: paths.clientDefaults)
            authenticatedSucceeded = authenticated.exitCode == 0
        }
        switch PasswordApply.decide(
            unauthenticatedSucceeded: unauthenticated.exitCode == 0,
            authenticatedSucceeded: authenticatedSucceeded
        ) {
        case .runSQL:
            let sql = Data(PasswordSQL.sql(password: password).utf8)
            try write(paths.sqlFile, PasswordSQL.sql(password: password), permissions: 0o600)
            let applied = await run(
                binaries.mariadb.path,
                MariaClient.sqlArguments(socket: socket),
                environment: brewEnvironment(),
                standardInput: sql,
                logged: false
            )
            try? FileManager.default.removeItem(at: paths.sqlFile)
            if applied.exitCode != 0 {
                await bootout(.mariadb)
                throw HearthError.passwordApplyFailed
            }
        case .alreadyApplied:
            try? FileManager.default.removeItem(at: paths.sqlFile)
        case .failed:
            await bootout(.mariadb)
            throw HearthError.passwordApplyFailed
        }
    }

    private func stopAfterFailedSetup(_ layout: inout StackLayout) async throws {
        layout.desired = .stopped
        try save(layout)
        for service in HearthService.stopOrder {
            await setServiceEnabled(service, enabled: false)
            await bootout(service)
        }
    }

    /// Returns a failure line when the service could not be brought up. The caller keeps walking.
    private func ensureRunning(_ service: HearthService) async -> String? {
        switch await launchdState(service) {
        case .running:
            return nil
        case .notLoaded:
            let result = await run(
                Launchctl.executable,
                Launchctl.bootstrapArguments(uid: dependencies.uid, plist: paths.plist(for: service).path),
                environment: [:],
                standardInput: nil,
                logged: true
            )
            guard result.exitCode == 0 else {
                let detail = TextTail.lastNonEmptyLine(result.output)
                noteFailure(service, detail)
                return detail.isEmpty ? "\(service.title) did not start" : detail
            }
            return nil
        case .stopped:
            let result = await run(
                Launchctl.executable,
                Launchctl.kickstartArguments(uid: dependencies.uid, label: service.label),
                environment: [:],
                standardInput: nil,
                logged: true
            )
            guard result.exitCode == 0 else {
                let detail = TextTail.lastNonEmptyLine(result.output)
                noteFailure(service, detail)
                return detail.isEmpty ? "\(service.title) did not start" : detail
            }
            return nil
        }
    }

    private func setServiceEnabled(_ service: HearthService, enabled: Bool) async {
        let arguments = enabled
            ? Launchctl.enableArguments(uid: dependencies.uid, label: service.label)
            : Launchctl.disableArguments(uid: dependencies.uid, label: service.label)
        _ = await run(
            Launchctl.executable,
            arguments,
            environment: [:],
            standardInput: nil,
            logged: true
        )
    }

    private func noteFailure(_ service: HearthService, _ detail: String) {
        let line = (detail.isEmpty ? "\(service.title) did not start" : detail) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = paths.stderrLog(for: service)
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func bootout(_ service: HearthService) async {
        _ = await run(
            Launchctl.executable,
            Launchctl.bootoutArguments(uid: dependencies.uid, label: service.label),
            environment: [:],
            standardInput: nil,
            logged: true
        )
    }

    private func launchdState(_ service: HearthService) async -> LaunchdState {
        let result = await run(
            Launchctl.executable,
            Launchctl.printArguments(uid: dependencies.uid, label: service.label),
            environment: [:],
            standardInput: nil,
            logged: false
        )
        return LaunchctlParser.parse(exitCode: result.exitCode, output: result.output)
    }

    private func assertSavedPortsFree(_ layout: StackLayout) async throws {
        let busy = dependencies.busyPorts([layout.httpPort, layout.mariaPort, layout.fpmPort])
        for service in HearthService.allCases {
            let port = layout.port(for: service)
            let running = await launchdState(service) == .running
            if PortOwnership.isConflict(port: port, busy: busy, agentIsRunning: running) {
                throw HearthError.portInUse(port)
            }
        }
    }

    private func cards(for layout: StackLayout) async -> [CardSnapshot] {
        var cards: [CardSnapshot] = []
        for service in HearthService.displayOrder {
            let state = ServiceStatus.card(
                launchd: await launchdState(service),
                portOpen: await dependencies.portIsOpen(layout.bindAddress, layout.port(for: service)),
                errorLine: TextTail.lastNonEmptyLine(serviceLog(service))
            )
            let version: String
            switch service {
            case .httpd: version = layout.formulae.httpd
            case .phpFPM: version = layout.formulae.php
            case .mariadb: version = layout.formulae.mariadb
            }
            cards.append(CardSnapshot(
                service: service,
                title: service.title,
                version: version,
                endpoint: "\(layout.bindAddress):\(layout.port(for: service))",
                state: state
            ))
        }
        return cards
    }

    private func installSnapshotPlan(_ layout: StackLayout) async throws -> InstallPlan {
        var formulae = Set<String>()
        if FileManager.default.fileExists(atPath: paths.brewBinary.path) {
            let listed = await run(
                paths.brewBinary.path,
                ["list", "--formula"],
                environment: brewEnvironment(),
                standardInput: nil,
                logged: true
            )
            formulae = Set(listed.output.split(whereSeparator: \.isNewline).map(String.init))
        }
        let digest = (try? Data(contentsOf: paths.adminerPHP)).map(SHA256Hash.hex)
        let snapshot = InstallSnapshot(
            brewBinaryExists: FileManager.default.fileExists(atPath: paths.brewBinary.path),
            installedFormulae: formulae,
            adminerChecksumMatches: digest == StackLayout.adminerSHA256Pin,
            dataDirectoryInitialized: FileManager.default.fileExists(atPath: paths.mysqlSystem.path),
            keychainHasPassword: (try dependencies.keychain.readPassword()) != nil,
            passwordApplied: layout.passwordApplied
        )
        return InstallPlanner.plan(snapshot)
    }

    private func isBlocked(_ layout: StackLayout) throws -> Bool {
        let ready = FileManager.default.fileExists(atPath: paths.mysqlSystem.path)
        let hasPassword = (try dependencies.keychain.readPassword()) != nil
        return ready && !hasPassword && !layout.passwordApplied
    }

    private func resolve() throws -> ResolvedBinaries {
        try BinaryResolver.resolve(prefix: paths.prefix) { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func httpdConfig(_ layout: StackLayout, binaries: ResolvedBinaries) -> String {
        ConfigRenderer.httpd(HTTPConfig(
            serverRoot: binaries.serverRoot.path,
            bindAddress: layout.bindAddress,
            httpPort: layout.httpPort,
            fpmPort: layout.fpmPort,
            documentRoot: layout.documentRoot,
            pidFile: paths.httpdPid.path,
            errorLog: paths.errorLog(for: .httpd).path,
            accessLog: paths.logs.appending(path: "httpd-access.log").path,
            mimeTypes: binaries.mimeTypes.path,
            adminerPHP: paths.adminerPHP.path,
            adminerDirectory: paths.adminerDirectory.path,
            user: dependencies.userName,
            group: dependencies.groupName,
            moduleFiles: ConfigRenderer.moduleFiles
        ))
    }

    private func phpConfig(_ layout: StackLayout) -> String {
        ConfigRenderer.phpFPM(PHPFPMConfig(
            errorLog: paths.errorLog(for: .phpFPM).path,
            pidFile: paths.phpFpmPid.path,
            user: dependencies.userName,
            group: dependencies.groupName,
            bindAddress: layout.bindAddress,
            port: layout.fpmPort
        ))
    }

    private func mariaConfig(_ layout: StackLayout) -> String {
        ConfigRenderer.myCnf(MariaConfig(
            dataDirectory: paths.mysqlData.path,
            port: layout.mariaPort,
            socketPath: paths.mysqlSocket.path,
            pidFile: paths.mariadbPid.path,
            errorLog: paths.errorLog(for: .mariadb).path
        ))
    }

    private func rewriteHTTP(_ layout: StackLayout) throws {
        let binaries = try resolve()
        try write(paths.httpdConf, httpdConfig(layout, binaries: binaries))
    }

    private func writeWelcomeIfNeeded() throws {
        let root = URL(fileURLWithPath: paths.documentRoot.path)
        let php = root.appending(path: "index.php")
        let html = root.appending(path: "index.html")
        let manager = FileManager.default
        if manager.fileExists(atPath: php.path) || manager.fileExists(atPath: html.path) { return }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try write(php, ConfigRenderer.welcomePage)
    }

    private func writeAgents(_ binaries: ResolvedBinaries) throws {
        let path = "\(paths.prefix.appending(path: "bin").path):\(paths.prefix.appending(path: "sbin").path):/usr/bin:/bin"
        for service in HearthService.allCases {
            let body = LaunchAgentWriter.plist(
                label: service.label,
                arguments: LaunchAgentWriter.arguments(service: service, binaries: binaries, paths: paths),
                stdout: paths.stdoutLog(for: service).path,
                stderr: paths.stderrLog(for: service).path,
                path: path
            )
            try write(paths.plist(for: service), body)
        }
    }

    private func clientCommand(_ layout: StackLayout) -> String {
        let binary = (try? resolve().mariadb.path) ?? paths.prefix.appending(path: "bin/mariadb").path
        return MariaClient.shellCommand(binary: binary, host: layout.bindAddress, port: layout.mariaPort)
    }

    private func waitForPort(_ port: Int, bind: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if await dependencies.portIsOpen(bind, port) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await dependencies.portIsOpen(bind, port)
    }

    private func waitUntilPortClosed(_ port: Int, bind: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if await dependencies.portIsOpen(bind, port) == false { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await dependencies.portIsOpen(bind, port) == false
    }

    private func brewEnvironment() -> [String: String] {
        let prefix = paths.prefix.path
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_CACHE": paths.brewCache.path,
            "PATH": "\(prefix)/bin:\(prefix)/sbin:\(base)",
        ]
    }

    private func ensureSetupDirectories() throws {
        let manager = FileManager.default
        let urls = [
            paths.support, paths.prefix, paths.configDirectory, paths.runDirectory, paths.logs,
            paths.adminerDirectory, paths.launchAgents, paths.documentRoot, paths.brewCache,
            paths.mysqlData.deletingLastPathComponent(),
        ]
        for url in urls {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func beginPhase(_ name: String) {
        logStore.setPhase(name)
        logStore.append(name + "\n")
    }

    @discardableResult
    private func runOrThrow(
        _ phase: String,
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil
    ) async throws -> ProcessResult {
        let result = await run(executable, arguments, environment: environment, standardInput: standardInput, logged: true)
        if result.exitCode != 0 {
            let detail = TextTail.lastNonEmptyLine(result.output)
            throw HearthError.phase(phase, detail: detail.isEmpty ? "exit \(result.exitCode)" : detail)
        }
        return result
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        logged: Bool
    ) async -> ProcessResult {
        await dependencies.runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput
        ) { [logStore] chunk in
            if logged { logStore.append(chunk) }
        }
    }

    private func loadLayout() throws -> StackLayout? {
        guard FileManager.default.fileExists(atPath: paths.stackJSON.path) else { return nil }
        let layout = try JSONDecoder().decode(StackLayout.self, from: Data(contentsOf: paths.stackJSON))
        try layout.validate()
        return layout
    }

    private func save(_ layout: StackLayout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(layout)
        try FileManager.default.createDirectory(at: paths.stackJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: paths.stackJSON, options: .atomic)
    }

    private func write(_ url: URL, _ contents: String, permissions: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func adopt(_ layout: StackLayout) {
        paths.documentRoot = URL(fileURLWithPath: layout.documentRoot)
    }

    private func httpURL(_ port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/") ?? URL(fileURLWithPath: "/")
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

extension HearthService {
    static let displayOrder: [HearthService] = [.httpd, .phpFPM, .mariadb]
}
