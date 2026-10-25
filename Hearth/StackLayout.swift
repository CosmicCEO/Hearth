import CryptoKit
import Darwin
import Foundation

enum HearthPrefix {
    // Current arm64 bottles pour only when the install prefix is at most 13 characters.
    static let path = "/opt/hearth"
    static let maximumLength = 13

    static var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

enum PrefixAuthorization {
    static func needsAdministrator(fileExists: Bool, isWritable: Bool) -> Bool {
        !(fileExists && isWritable)
    }

    static func shellCommand(uid: uid_t, gid: gid_t) -> String {
        "mkdir -p \(HearthPrefix.path) && chown \(uid):\(gid) \(HearthPrefix.path) && chmod 755 \(HearthPrefix.path)"
    }

    static var removeAppleScript: String {
        "do shell script \"rmdir \(HearthPrefix.path)\" with administrator privileges"
    }

    static func appleScript(uid: uid_t, gid: gid_t) -> String {
        let command = shellCommand(uid: uid, gid: gid)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(command)\" with administrator privileges"
    }
}

enum DesiredState: String, Codable, Equatable, Sendable {
    case running
    case stopped
}

struct FormulaVersions: Codable, Equatable, Sendable {
    var httpd: String
    var php: String
    var mariadb: String
}

struct StackLayout: Codable, Equatable, Sendable {
    var version: Int
    var prefix: String
    var documentRoot: String
    var httpPort: Int
    var mariaPort: Int
    var fpmPort: Int
    var bindAddress: String
    var desired: DesiredState
    var setupComplete: Bool
    var passwordApplied: Bool
    var adminerSHA256: String
    var formulae: FormulaVersions
    var brewVersion: String

    static let supportedVersion = 1
    static let adminerSHA256Pin = "cd5d65d3e85c9e1233126625232150e2de405f3d56c76fdc171f4133a401e8d2"
    static let adminerURL = "https://github.com/vrana/adminer/releases/download/v6.1.1/adminer-6.1.1-mysql-en.php"
    static let homebrewTarballURL = "https://github.com/Homebrew/brew/tarball/main"

    static func initial(support: URL, documentRoot: URL, ports: ClaimedPorts) -> StackLayout {
        StackLayout(
            version: supportedVersion,
            prefix: HearthPrefix.path,
            documentRoot: documentRoot.path,
            httpPort: ports.http,
            mariaPort: ports.maria,
            fpmPort: ports.fpm,
            bindAddress: "127.0.0.1",
            desired: .stopped,
            setupComplete: false,
            passwordApplied: false,
            adminerSHA256: adminerSHA256Pin,
            formulae: FormulaVersions(httpd: "", php: "", mariadb: ""),
            brewVersion: ""
        )
    }

    func validate() throws {
        guard version == Self.supportedVersion else { throw HearthError.newerVersion }
    }

    func port(for service: HearthService) -> Int {
        switch service {
        case .httpd: httpPort
        case .phpFPM: fpmPort
        case .mariadb: mariaPort
        }
    }
}

struct StackPaths: Equatable, Sendable {
    var support: URL
    var documentRoot: URL
    var launchAgents: URL
    var prefix: URL = HearthPrefix.url

    var configDirectory: URL { support.appending(path: "config") }
    var httpdConf: URL { configDirectory.appending(path: "httpd.conf") }
    var phpFpmConf: URL { configDirectory.appending(path: "php-fpm.conf") }
    var myCnf: URL { configDirectory.appending(path: "my.cnf") }
    var mysqlData: URL { support.appending(path: "var/mysql") }
    var mysqlSystem: URL { mysqlData.appending(path: "mysql") }
    var runDirectory: URL { support.appending(path: "var/run") }
    var httpdPid: URL { runDirectory.appending(path: "httpd.pid") }
    var phpFpmPid: URL { runDirectory.appending(path: "php-fpm.pid") }
    var mysqlSocket: URL { runDirectory.appending(path: "mysql.sock") }
    var mariadbPid: URL { runDirectory.appending(path: "mariadb.pid") }
    var logs: URL { support.appending(path: "logs") }
    var adminerDirectory: URL { support.appending(path: "adminer") }
    var adminerPHP: URL { adminerDirectory.appending(path: "adminer.php") }
    var adminerNotice: URL { adminerDirectory.appending(path: "NOTICE") }
    var stackJSON: URL { support.appending(path: "stack.json") }
    var sqlFile: URL { support.appending(path: "root-init.sql") }
    var clientDefaults: URL { configDirectory.appending(path: "client.cnf") }
    var brewCache: URL { support.appending(path: "cache") }
    var homebrewTarball: URL { support.appending(path: "homebrew.tar.gz") }
    var brewBinary: URL { prefix.appending(path: "bin/brew") }

    func plist(for service: HearthService) -> URL {
        launchAgents.appending(path: service.label + ".plist")
    }

    func stdoutLog(for service: HearthService) -> URL {
        switch service {
        case .httpd: logs.appending(path: "httpd-stdout.log")
        case .phpFPM: logs.appending(path: "php-fpm-stdout.log")
        case .mariadb: logs.appending(path: "mariadb-stdout.log")
        }
    }

    func stderrLog(for service: HearthService) -> URL {
        switch service {
        case .httpd: logs.appending(path: "httpd-stderr.log")
        case .phpFPM: logs.appending(path: "php-fpm-stderr.log")
        case .mariadb: logs.appending(path: "mariadb-stderr.log")
        }
    }

    func errorLog(for service: HearthService) -> URL {
        switch service {
        case .httpd: logs.appending(path: "httpd-error.log")
        case .phpFPM: logs.appending(path: "php-fpm.log")
        case .mariadb: logs.appending(path: "mariadb-error.log")
        }
    }

    func with(documentRoot: URL) -> StackPaths {
        StackPaths(support: support, documentRoot: documentRoot, launchAgents: launchAgents, prefix: prefix)
    }
}

enum ResetStamp {
    static func string(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}

enum Checksum {
    static func sha256Hex(data: Data) -> String {
        SHA256Hash.hex(data)
    }
}

enum SHA256Hash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
