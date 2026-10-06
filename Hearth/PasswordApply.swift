import Foundation
import Security

enum PasswordApplyDecision: Equatable, Sendable {
    case runSQL
    case alreadyApplied
    case failed
}

enum PasswordApply {
    static func decide(unauthenticatedSucceeded: Bool, authenticatedSucceeded: Bool) -> PasswordApplyDecision {
        if unauthenticatedSucceeded { return .runSQL }
        if authenticatedSucceeded { return .alreadyApplied }
        return .failed
    }
}

enum PasswordGenerator {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    static func generate(bytes: [UInt8]) -> String {
        String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HearthError.keychain("random bytes failed")
        }
        return generate(bytes: bytes)
    }
}

enum MariaClient {
    static func unauthenticatedArguments(socket: String) -> [String] {
        ["--no-defaults", "--socket=\(socket)", "-u", "root", "--protocol=socket", "-e", "SELECT 1"]
    }

    static func authenticatedArguments(defaultsFile: String) -> [String] {
        ["--defaults-extra-file=\(defaultsFile)", "--protocol=socket", "-e", "SELECT 1"]
    }

    static func sqlArguments(socket: String) -> [String] {
        ["--no-defaults", "--socket=\(socket)", "-u", "root", "--protocol=socket"]
    }

    static func defaultsText(password: String, socket: String) -> String {
        """
        [client]
        socket=\(socket)
        user=root
        password=\(password)
        protocol=socket
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellCommand(binary: String, host: String, port: Int) -> String {
        "\(shellQuote(binary)) --host=\(host) --port=\(port) -u root -p"
    }
}

enum PasswordSQL {
    static func sql(password: String) -> String {
        """
        ALTER USER 'root'@'localhost' IDENTIFIED BY '\(password)';
        CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '\(password)';
        ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '\(password)';
        FLUSH PRIVILEGES;
        """
    }
}
