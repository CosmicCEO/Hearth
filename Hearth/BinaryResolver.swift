import Foundation

struct ResolvedBinaries: Equatable, Sendable {
    var httpd: URL
    var modulesDirectory: URL
    var mimeTypes: URL
    var phpFpm: URL
    var php: URL
    var mariadbd: URL
    var mariadb: URL
    var installDB: URL
    var serverRoot: URL
}

enum BinaryResolver {
    static func serverRoot(modulesDirectory: URL) -> URL {
        modulesDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func resolve(prefix: URL, exists: (URL) -> Bool) throws -> ResolvedBinaries {
        func pick(_ name: String, _ relatives: [String]) throws -> URL {
            for relative in relatives {
                let url = prefix.appending(path: relative)
                if exists(url) { return url }
            }
            throw HearthError.missing(name)
        }

        let httpd = try pick("httpd", ["opt/httpd/bin/httpd", "bin/httpd"])
        let modules = try pick("modules directory", ["opt/httpd/lib/httpd/modules", "lib/httpd/modules"])
        for file in ConfigRenderer.moduleFiles {
            let url = modules.appending(path: file)
            if !exists(url) { throw HearthError.missing(file) }
        }
        let mime = try pick("mime.types", ["etc/httpd/mime.types", "opt/httpd/share/httpd/conf/mime.types"])
        let phpFpm = try pick("php-fpm", ["opt/php/sbin/php-fpm", "sbin/php-fpm"])
        let php = try pick("php", ["opt/php/bin/php", "bin/php"])
        let mariadbd = try pick("mariadbd", ["opt/mariadb/bin/mariadbd", "bin/mariadbd"])
        let mariadb = try pick("mariadb", ["opt/mariadb/bin/mariadb", "bin/mariadb"])
        let installDB = try pick("mariadb-install-db", ["opt/mariadb/bin/mariadb-install-db", "bin/mariadb-install-db"])
        return ResolvedBinaries(
            httpd: httpd,
            modulesDirectory: modules,
            mimeTypes: mime,
            phpFpm: phpFpm,
            php: php,
            mariadbd: mariadbd,
            mariadb: mariadb,
            installDB: installDB,
            serverRoot: serverRoot(modulesDirectory: modules)
        )
    }
}
