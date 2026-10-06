import Foundation

struct InstallSnapshot: Equatable, Sendable {
    var brewBinaryExists: Bool
    var installedFormulae: Set<String>
    var adminerChecksumMatches: Bool
    var dataDirectoryInitialized: Bool
    var keychainHasPassword: Bool
    var passwordApplied: Bool
}

struct InstallPlan: Equatable, Sendable {
    var installHomebrew: Bool
    var formulaeToInstall: [String]
    var downloadAdminer: Bool
    var generatePassword: Bool
    var initializeDatabase: Bool
    var applyPassword: Bool
    var rewriteConfigs: Bool
    var blockedReason: String?
}

enum InstallPlanner {
    static let formulae = ["httpd", "php", "mariadb"]
    static let blockedMessage = "Database files exist and Hearth has no saved root password."

    static func plan(_ snapshot: InstallSnapshot) -> InstallPlan {
        let blocked = snapshot.dataDirectoryInitialized
            && !snapshot.keychainHasPassword
            && !snapshot.passwordApplied
        return InstallPlan(
            installHomebrew: !snapshot.brewBinaryExists,
            formulaeToInstall: formulae.filter { !snapshot.installedFormulae.contains($0) },
            downloadAdminer: !snapshot.adminerChecksumMatches,
            generatePassword: !snapshot.dataDirectoryInitialized && !snapshot.keychainHasPassword && !blocked,
            initializeDatabase: !snapshot.dataDirectoryInitialized && !blocked,
            applyPassword: !snapshot.passwordApplied && !blocked,
            rewriteConfigs: !blocked,
            blockedReason: blocked ? blockedMessage : nil
        )
    }
}

enum DiskRule {
    static let minimumBytes: Int64 = 2_000_000_000

    static func allowsInstall(available: Int64, installAnyway: Bool) -> Bool {
        available >= minimumBytes || installAnyway
    }
}
