import Foundation

enum LaunchdState: Equatable, Sendable {
    case running
    case stopped
    case notLoaded
}

enum LaunchctlParser {
    static func parse(exitCode: Int32, output: String) -> LaunchdState {
        if exitCode != 0 { return .notLoaded }
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = running") { return .running }
        }
        return .stopped
    }
}

enum CardState: Equatable, Sendable {
    case running
    case starting
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

enum ServiceStatus {
    static func card(launchd: LaunchdState, portOpen: Bool, errorLine: String) -> CardState {
        switch launchd {
        case .running:
            portOpen ? .running : .starting
        case .notLoaded:
            .stopped
        case .stopped:
            .failed(errorLine)
        }
    }

    static func window(cards: [CardState], operationInProgress: Bool) -> String {
        if operationInProgress || cards.contains(where: isStarting) {
            return "Starting"
        }
        if cards.contains(where: isFailed) {
            return "Failed"
        }
        if !cards.isEmpty && cards.allSatisfy({ $0 == .running }) {
            return "Running"
        }
        return "Stopped"
    }

    static func primaryIsStop(cards: [CardState]) -> Bool {
        cards.contains { $0 == .running || $0 == .starting }
    }

    private static func isStarting(_ state: CardState) -> Bool {
        if case .starting = state { return true }
        return false
    }

    private static func isFailed(_ state: CardState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

enum LogTail {
    static func last(_ text: String, count: Int) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        return lines.suffix(count).joined(separator: "\n")
    }
}

enum Launchctl {
    static let executable = "/bin/launchctl"

    static func domain(_ uid: uid_t) -> String { "gui/\(uid)" }

    static func printArguments(uid: uid_t, label: String) -> [String] {
        ["print", "\(domain(uid))/\(label)"]
    }

    static func bootstrapArguments(uid: uid_t, plist: String) -> [String] {
        ["bootstrap", domain(uid), plist]
    }

    static func bootoutArguments(uid: uid_t, label: String) -> [String] {
        ["bootout", "\(domain(uid))/\(label)"]
    }

    static func kickstartArguments(uid: uid_t, label: String) -> [String] {
        ["kickstart", "-k", "\(domain(uid))/\(label)"]
    }
}

enum HearthService: CaseIterable, Equatable, Sendable {
    case mariadb
    case phpFPM
    case httpd

    static let startOrder: [HearthService] = [.mariadb, .phpFPM, .httpd]
    static let stopOrder: [HearthService] = [.httpd, .phpFPM, .mariadb]

    var label: String {
        switch self {
        case .mariadb: "com.jerodprice.hearth.mariadb"
        case .phpFPM: "com.jerodprice.hearth.php-fpm"
        case .httpd: "com.jerodprice.hearth.httpd"
        }
    }

    var title: String {
        switch self {
        case .mariadb: "Database"
        case .phpFPM: "PHP"
        case .httpd: "Web server"
        }
    }
}
