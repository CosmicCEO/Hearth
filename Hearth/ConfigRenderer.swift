import Foundation

struct HTTPConfig: Equatable, Sendable {
    var serverRoot: String
    var bindAddress: String
    var httpPort: Int
    var fpmPort: Int
    var documentRoot: String
    var pidFile: String
    var errorLog: String
    var accessLog: String
    var mimeTypes: String
    var adminerPHP: String
    var adminerDirectory: String
    var user: String
    var group: String
    var moduleFiles: [String]
}

struct PHPFPMConfig: Equatable, Sendable {
    var errorLog: String
    var pidFile: String
    var user: String
    var group: String
    var bindAddress: String
    var port: Int
}

struct MariaConfig: Equatable, Sendable {
    var dataDirectory: String
    var port: Int
    var socketPath: String
    var pidFile: String
    var errorLog: String
}

enum ConfigRenderer {
    static let moduleFiles = [
        "mod_mpm_event.so",
        "mod_authz_core.so",
        "mod_authz_host.so",
        "mod_unixd.so",
        "mod_dir.so",
        "mod_mime.so",
        "mod_log_config.so",
        "mod_alias.so",
        "mod_headers.so",
        "mod_rewrite.so",
        "mod_proxy.so",
        "mod_proxy_fcgi.so",
    ]

    static func quote(_ path: String) -> String {
        "\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    static func loadModuleLine(file: String) -> String {
        let base = file.replacingOccurrences(of: ".so", with: "")
        let short = base.hasPrefix("mod_") ? String(base.dropFirst(4)) : base
        return "LoadModule \(short)_module lib/httpd/modules/\(file)"
    }

    static func httpd(_ input: HTTPConfig) -> String {
        let handler = "proxy:fcgi://\(input.bindAddress):\(input.fpmPort)"
        let modules = input.moduleFiles.map(loadModuleLine).joined(separator: "\n")
        return """
        ServerRoot \(quote(input.serverRoot))
        Listen \(input.bindAddress):\(input.httpPort)
        ServerName localhost
        PidFile \(quote(input.pidFile))
        ErrorLog \(quote(input.errorLog))
        CustomLog \(quote(input.accessLog)) common

        \(modules)

        User \(input.user)
        Group \(input.group)

        <IfModule mime_module>
            TypesConfig \(quote(input.mimeTypes))
        </IfModule>

        DocumentRoot \(quote(input.documentRoot))
        <Directory \(quote(input.documentRoot))>
            Options Indexes FollowSymLinks
            AllowOverride All
            Require all granted
            DirectoryIndex index.php index.html
            <FilesMatch \\.php$>
                SetHandler "\(handler)"
            </FilesMatch>
        </Directory>

        Alias /adminer.php \(quote(input.adminerPHP))
        <Directory \(quote(input.adminerDirectory))>
            Require all granted
            <Files "adminer.php">
                SetHandler "\(handler)"
            </Files>
        </Directory>
        """
    }

    static func phpFPM(_ input: PHPFPMConfig) -> String {
        """
        [global]
        error_log = \(quote(input.errorLog))
        daemonize = no
        pid = \(quote(input.pidFile))

        [www]
        user = \(input.user)
        group = \(input.group)
        listen = \(input.bindAddress):\(input.port)
        pm = dynamic
        pm.max_children = 5
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        clear_env = no
        security.limit_extensions = .php
        """
    }

    static func myCnf(_ input: MariaConfig) -> String {
        """
        [mysqld]
        datadir = \(quote(input.dataDirectory))
        port = \(input.port)
        bind-address = 127.0.0.1
        socket = \(quote(input.socketPath))
        pid-file = \(quote(input.pidFile))
        log_error = \(quote(input.errorLog))
        mysqlx = 0
        skip-name-resolve

        [client]
        port = \(input.port)
        socket = \(quote(input.socketPath))
        """
    }

    static let welcomePage = """
    <?php
    declare(strict_types=1);
    $version = phpversion();
    ?>
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Hearth</title>
    </head>
    <body>
      <h1>Hearth</h1>
      <p>This folder is being served by Hearth.</p>
      <p>PHP <?php echo htmlspecialchars($version, ENT_QUOTES, 'UTF-8'); ?></p>
      <p><a href="/adminer.php">Open Adminer</a></p>
    </body>
    </html>
    """

    static let adminerNotice = """
    \(StackLayout.adminerURL)
    6.1.1
    License: Apache-2.0
    """
}
