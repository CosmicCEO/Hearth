import Foundation

enum HearthError: Error, Equatable, LocalizedError {
    case noFreePort
    case portInUse(Int)
    case blocked
    case newerVersion
    case missing(String)
    case phase(String, detail: String)
    case lowDisk
    case passwordApplyFailed
    case servicesDidNotStart
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .noFreePort:
            "Hearth could not find a free port"
        case .portInUse(let port):
            "127.0.0.1:\(port) is in use"
        case .blocked:
            InstallPlanner.blockedMessage
        case .newerVersion:
            "This Hearth data was written by a newer version"
        case .missing(let name):
            "Hearth could not find \(name)"
        case .phase(let name, let detail):
            "\(name): \(detail)"
        case .lowDisk:
            "Less than 2 GB is free"
        case .passwordApplyFailed:
            "Start services: the database root password could not be set"
        case .servicesDidNotStart:
            "Start services: a service did not open its port"
        case .keychain(let detail):
            "Save the root password: \(detail)"
        }
    }
}

enum TextTail {
    static func lastNonEmptyLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}
