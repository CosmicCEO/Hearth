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
