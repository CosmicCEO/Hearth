import Foundation
import Testing
@testable import Hearth

@Test func preferredPortsWhenFree() throws {
    let ports = try PortPlanner.claim(busy: [])
    #expect(ports == ClaimedPorts(http: 8888, maria: 8889, fpm: 9000))
}

@Test func httpPortBusyMovesMariaPastTheClaim() throws {
    let ports = try PortPlanner.claim(busy: [8888])
    #expect(ports == ClaimedPorts(http: 8889, maria: 8890, fpm: 9000))
}

@Test func bothPreferredPortsBusy() throws {
    let ports = try PortPlanner.claim(busy: [8888, 8889])
    #expect(ports == ClaimedPorts(http: 8890, maria: 8891, fpm: 9000))
}

@Test func twentyBusyHTTPPortsFail() {
    let busy = Set(8888..<(8888 + 20))
    #expect(throws: HearthError.noFreePort) {
        try PortPlanner.claim(busy: busy)
    }
}

@Test func ownedRunningPortIsNotAConflict() {
    #expect(PortOwnership.isConflict(port: 8888, busy: [8888], agentIsRunning: true) == false)
    #expect(PortOwnership.isConflict(port: 8888, busy: [8888], agentIsRunning: false) == true)
    #expect(PortOwnership.isConflict(port: 8888, busy: [], agentIsRunning: false) == false)
}

@Test func passwordApplyDecisions() {
    #expect(PasswordApply.decide(unauthenticatedSucceeded: true, authenticatedSucceeded: false) == .runSQL)
    #expect(PasswordApply.decide(unauthenticatedSucceeded: false, authenticatedSucceeded: true) == .alreadyApplied)
    #expect(PasswordApply.decide(unauthenticatedSucceeded: false, authenticatedSucceeded: false) == .failed)
}

@Test func passwordBytesMapOntoTheAlphabet() {
    let password = PasswordGenerator.generate(bytes: Array(repeating: 0, count: 24))
    #expect(password.count == 24)
    #expect(password.allSatisfy { PasswordGenerator.alphabet.contains($0) })
    #expect(password == String(repeating: "A", count: 24))
}

@Test func passwordSQLNamesBothRootAccounts() {
    let sql = PasswordSQL.sql(password: "secret")
    #expect(sql.contains("ALTER USER 'root'@'localhost' IDENTIFIED BY 'secret';"))
    #expect(sql.contains("CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY 'secret';"))
    #expect(sql.contains("ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY 'secret';"))
    #expect(sql.contains("FLUSH PRIVILEGES;"))
}

@Test func freshInstallPlansEveryStep() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: false,
        installedFormulae: [],
        adminerChecksumMatches: false,
        dataDirectoryInitialized: false,
        keychainHasPassword: false,
        passwordApplied: false
    ))
    #expect(plan.installHomebrew)
    #expect(plan.formulaeToInstall == ["httpd", "php", "mariadb"])
    #expect(plan.downloadAdminer)
    #expect(plan.generatePassword)
    #expect(plan.initializeDatabase)
    #expect(plan.applyPassword)
    #expect(plan.rewriteConfigs)
    #expect(plan.blockedReason == nil)
}

@Test func retiredMasterHomebrewIsReinstalled() {
    let stub = "Error: Homebrew's master branch is no longer supported.\n"
    #expect(InstallPlanner.isMasterStub(stub))
    #expect(!InstallPlanner.isMasterStub("Homebrew 5.0.0\n"))
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: [],
        adminerChecksumMatches: false,
        dataDirectoryInitialized: false,
        keychainHasPassword: false,
        passwordApplied: false,
        brewIsMasterStub: true
    ))
    #expect(plan.installHomebrew)
    #expect(StackLayout.homebrewTarballURL == "https://github.com/Homebrew/brew/tarball/main")
}

@Test func brewAlreadyPresentSkipsHomebrew() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: [],
        adminerChecksumMatches: false,
        dataDirectoryInitialized: false,
        keychainHasPassword: false,
        passwordApplied: false
    ))
    #expect(!plan.installHomebrew)
    #expect(plan.formulaeToInstall == ["httpd", "php", "mariadb"])
}

@Test func partialFormulaeInstallOnlyTheMissingOnes() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: ["httpd"],
        adminerChecksumMatches: true,
        dataDirectoryInitialized: false,
        keychainHasPassword: false,
        passwordApplied: false
    ))
    #expect(plan.formulaeToInstall == ["php", "mariadb"])
    #expect(!plan.downloadAdminer)
}

@Test func keychainWrittenBeforeDataDirectoryReusesThePassword() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: ["httpd", "php", "mariadb"],
        adminerChecksumMatches: true,
        dataDirectoryInitialized: false,
        keychainHasPassword: true,
        passwordApplied: false
    ))
    #expect(!plan.generatePassword)
    #expect(plan.initializeDatabase)
    #expect(plan.applyPassword)
}

@Test func passwordStillToApply() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: ["httpd", "php", "mariadb"],
        adminerChecksumMatches: true,
        dataDirectoryInitialized: true,
        keychainHasPassword: true,
        passwordApplied: false
    ))
    #expect(plan.applyPassword)
    #expect(plan.rewriteConfigs)
    #expect(!plan.generatePassword)
    #expect(!plan.initializeDatabase)
    #expect(!plan.installHomebrew)
    #expect(!plan.downloadAdminer)
}

@Test func existingDataWithoutAPasswordIsBlocked() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: ["httpd", "php", "mariadb"],
        adminerChecksumMatches: true,
        dataDirectoryInitialized: true,
        keychainHasPassword: false,
        passwordApplied: false
    ))
    #expect(plan.blockedReason == "Database files exist and Hearth has no saved root password.")
    #expect(!plan.initializeDatabase)
    #expect(!plan.applyPassword)
    #expect(!plan.rewriteConfigs)
    #expect(!plan.generatePassword)
}

@Test func finishedInstallHasNothingLeft() {
    let plan = InstallPlanner.plan(InstallSnapshot(
        brewBinaryExists: true,
        installedFormulae: ["httpd", "php", "mariadb"],
        adminerChecksumMatches: true,
        dataDirectoryInitialized: true,
        keychainHasPassword: true,
        passwordApplied: true
    ))
    #expect(!plan.installHomebrew)
    #expect(plan.formulaeToInstall.isEmpty)
    #expect(!plan.downloadAdminer)
    #expect(!plan.generatePassword)
    #expect(!plan.initializeDatabase)
    #expect(!plan.applyPassword)
    #expect(plan.rewriteConfigs)
    #expect(plan.blockedReason == nil)
}

@Test func lowDiskBlocksInstallUntilTheUserAllowsIt() {
    #expect(!DiskRule.allowsInstall(available: 1_000_000_000, installAnyway: false))
    #expect(DiskRule.allowsInstall(available: 1_000_000_000, installAnyway: true))
    #expect(DiskRule.allowsInstall(available: 2_000_000_000, installAnyway: false))
    #expect(DiskRule.limitingBytes(home: 9_000_000_000, prefixVolume: 1_500_000_000) == 1_500_000_000)
    #expect(DiskRule.limitingBytes(home: 3_000_000_000, prefixVolume: 8_000_000_000) == 3_000_000_000)
}

@Test func prefixFitsBottleRelocation() {
    #expect(HearthPrefix.path == "/opt/hearth")
    #expect(HearthPrefix.path.count <= HearthPrefix.maximumLength)
    #expect(HearthPrefix.path != "/opt/homebrew")
    let paths = StackPaths(
        support: URL(fileURLWithPath: "/Users/jerodprice/Library/Application Support/Hearth"),
        documentRoot: URL(fileURLWithPath: "/Users/jerodprice/Sites"),
        launchAgents: URL(fileURLWithPath: "/Users/jerodprice/Library/LaunchAgents")
    )
    #expect(paths.prefix.path == "/opt/hearth")
    #expect(paths.mysqlData.path == "/Users/jerodprice/Library/Application Support/Hearth/var/mysql")
    #expect(paths.brewCache.path == "/Users/jerodprice/Library/Application Support/Hearth/cache")
}

@Test func prefixAuthorizationAsksUnlessTheDirectoryIsWritable() {
    #expect(PrefixAuthorization.needsAdministrator(fileExists: false, isWritable: false))
    #expect(PrefixAuthorization.needsAdministrator(fileExists: true, isWritable: false))
    #expect(PrefixAuthorization.needsAdministrator(fileExists: false, isWritable: true))
    #expect(!PrefixAuthorization.needsAdministrator(fileExists: true, isWritable: true))
    let command = PrefixAuthorization.shellCommand(uid: 501, gid: 20)
    #expect(command == "mkdir -p /opt/hearth && chown 501:20 /opt/hearth && chmod 755 /opt/hearth")
    #expect(!command.contains("/opt/homebrew"))
    #expect(
        PrefixAuthorization.appleScript(uid: 501, gid: 20)
            == "do shell script \"mkdir -p /opt/hearth && chown 501:20 /opt/hearth && chmod 755 /opt/hearth\" with administrator privileges"
    )
}
