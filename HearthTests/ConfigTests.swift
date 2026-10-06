import Foundation
import Testing
@testable import Hearth

private func sampleHTTP() -> HTTPConfig {
    HTTPConfig(
        serverRoot: "/Users/jerodprice/Library/Application Support/Hearth/homebrew/opt/httpd",
        bindAddress: "127.0.0.1",
        httpPort: 8888,
        fpmPort: 9000,
        documentRoot: "/Users/jerodprice/Sites",
        pidFile: "/Users/jerodprice/Library/Application Support/Hearth/var/run/httpd.pid",
        errorLog: "/Users/jerodprice/Library/Application Support/Hearth/logs/httpd-error.log",
        accessLog: "/Users/jerodprice/Library/Application Support/Hearth/logs/httpd-access.log",
        mimeTypes: "/Users/jerodprice/Library/Application Support/Hearth/homebrew/etc/httpd/mime.types",
        adminerPHP: "/Users/jerodprice/Library/Application Support/Hearth/adminer/adminer.php",
        adminerDirectory: "/Users/jerodprice/Library/Application Support/Hearth/adminer",
        user: "jerodprice",
        group: "staff",
        moduleFiles: ConfigRenderer.moduleFiles
    )
}

@Test func httpdConfigQuotesPathsAndLoadsOnlyTheEventMPM() throws {
    let config = ConfigRenderer.httpd(sampleHTTP())
    #expect(config.contains("Listen 127.0.0.1:8888"))
    #expect(config.contains("DocumentRoot \"/Users/jerodprice/Sites\""))
    #expect(config.contains("\"/Users/jerodprice/Library/Application Support/Hearth/var/run/httpd.pid\""))
    #expect(config.contains("Alias /adminer.php \"/Users/jerodprice/Library/Application Support/Hearth/adminer/adminer.php\""))
    #expect(config.contains("proxy:fcgi://127.0.0.1:9000"))
    let loads = config.split(separator: "\n").filter { $0.hasPrefix("LoadModule") }
    #expect(loads.count == 12)
    #expect(loads.first?.contains("mpm_event_module") == true)
    #expect(!config.contains("prefork"))
    #expect(!config.contains("worker"))
    let proxy = try #require(config.range(of: "LoadModule proxy_module"))
    let fcgi = try #require(config.range(of: "LoadModule proxy_fcgi_module"))
    #expect(proxy.lowerBound < fcgi.lowerBound)
}

@Test func phpFPMConfigListensOnLocalhost() {
    let config = ConfigRenderer.phpFPM(PHPFPMConfig(
        errorLog: "/Users/jerodprice/Library/Application Support/Hearth/logs/php-fpm.log",
        pidFile: "/Users/jerodprice/Library/Application Support/Hearth/var/run/php-fpm.pid",
        user: "jerodprice",
        group: "staff",
        bindAddress: "127.0.0.1",
        port: 9000
    ))
    #expect(config.contains("listen = 127.0.0.1:9000"))
    #expect(config.contains("daemonize = no"))
    #expect(config.contains("pm.max_children = 5"))
    #expect(config.contains("\"/Users/jerodprice/Library/Application Support/Hearth/logs/php-fpm.log\""))
}

@Test func mariaConfigBindsLocallyAndDisablesMySQLX() {
    let config = ConfigRenderer.myCnf(MariaConfig(
        dataDirectory: "/Users/jerodprice/Library/Application Support/Hearth/var/mysql",
        port: 8889,
        socketPath: "/Users/jerodprice/Library/Application Support/Hearth/var/run/mysql.sock",
        pidFile: "/Users/jerodprice/Library/Application Support/Hearth/var/run/mariadb.pid",
        errorLog: "/Users/jerodprice/Library/Application Support/Hearth/logs/mariadb-error.log"
    ))
    #expect(config.contains("port = 8889"))
    #expect(config.contains("bind-address = 127.0.0.1"))
    #expect(config.contains("datadir = \"/Users/jerodprice/Library/Application Support/Hearth/var/mysql\""))
    #expect(config.contains("mysqlx = 0"))
}

@Test func welcomePageShowsThePHPVersionAndAdminer() {
    let page = ConfigRenderer.welcomePage
    #expect(page.contains("phpversion()"))
    #expect(page.contains("/adminer.php"))
    #expect(!page.contains("phpinfo"))
}

@Test func serverRootIsTheHttpdPrefix() {
    let modules = URL(fileURLWithPath: "/prefix/opt/httpd/lib/httpd/modules")
    #expect(BinaryResolver.serverRoot(modulesDirectory: modules).path == "/prefix/opt/httpd")
}

@Test func resolverFindsHomebrewLayoutAndNamesAMissingModule() throws {
    let prefix = URL(fileURLWithPath: "/prefix")
    var paths = Set([
        "/prefix/opt/httpd/bin/httpd",
        "/prefix/opt/httpd/lib/httpd/modules",
        "/prefix/etc/httpd/mime.types",
        "/prefix/opt/php/sbin/php-fpm",
        "/prefix/opt/php/bin/php",
        "/prefix/opt/mariadb/bin/mariadbd",
        "/prefix/opt/mariadb/bin/mariadb",
        "/prefix/opt/mariadb/bin/mariadb-install-db",
    ])
    for file in ConfigRenderer.moduleFiles {
        paths.insert("/prefix/opt/httpd/lib/httpd/modules/\(file)")
    }
    let resolved = try BinaryResolver.resolve(prefix: prefix) { paths.contains($0.path) }
    #expect(resolved.serverRoot.path == "/prefix/opt/httpd")
    #expect(resolved.httpd.path == "/prefix/opt/httpd/bin/httpd")

    paths.remove("/prefix/opt/httpd/lib/httpd/modules/mod_proxy.so")
    #expect(throws: HearthError.missing("mod_proxy.so")) {
        try BinaryResolver.resolve(prefix: prefix) { paths.contains($0.path) }
    }
}

@Test func resolverFallsBackToPrefixBinaries() throws {
    let prefix = URL(fileURLWithPath: "/prefix")
    var paths: Set<String> = [
        "/prefix/bin/httpd",
        "/prefix/lib/httpd/modules",
        "/prefix/etc/httpd/mime.types",
        "/prefix/sbin/php-fpm",
        "/prefix/bin/php",
        "/prefix/bin/mariadbd",
        "/prefix/bin/mariadb",
        "/prefix/bin/mariadb-install-db",
    ]
    for file in ConfigRenderer.moduleFiles {
        paths.insert("/prefix/lib/httpd/modules/\(file)")
    }
    let resolved = try BinaryResolver.resolve(prefix: prefix) { paths.contains($0.path) }
    #expect(resolved.httpd.path == "/prefix/bin/httpd")
    #expect(resolved.phpFpm.path == "/prefix/sbin/php-fpm")
}

@Test func stackLayoutRoundTripsAndRejectsANewerVersion() throws {
    let layout = StackLayout.initial(
        support: URL(fileURLWithPath: "/Users/jerodprice/Library/Application Support/Hearth"),
        documentRoot: URL(fileURLWithPath: "/Users/jerodprice/Sites"),
        ports: ClaimedPorts(http: 8888, maria: 8889, fpm: 9000)
    )
    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(StackLayout.self, from: data)
    #expect(decoded == layout)
    #expect(layout.desired == .stopped)
    #expect(!layout.setupComplete)
    #expect(layout.prefix == "/Users/jerodprice/Library/Application Support/Hearth/homebrew")
    var newer = layout
    newer.version = 2
    #expect(throws: HearthError.newerVersion) {
        try newer.validate()
    }
}

@Test func launchAgentPlistKeepsArgumentsSeparate() {
    let plist = LaunchAgentWriter.plist(
        label: "com.jerodprice.hearth.httpd",
        arguments: ["/opt/httpd", "-D", "FOREGROUND", "-f", "/Users/jerodprice/Library/Application Support/Hearth/config/httpd.conf"],
        stdout: "/logs/out",
        stderr: "/logs/err",
        path: "/opt/bin:/usr/bin:/bin"
    )
    #expect(plist.contains("<string>com.jerodprice.hearth.httpd</string>"))
    #expect(plist.contains("<string>-D</string>"))
    #expect(plist.contains("<string>FOREGROUND</string>"))
    #expect(plist.contains("<string>/Users/jerodprice/Library/Application Support/Hearth/config/httpd.conf</string>"))
    #expect(plist.contains("<key>RunAtLoad</key>\n  <true/>"))
    #expect(plist.contains("<key>KeepAlive</key>\n  <true/>"))
    #expect(plist.contains("<string>/opt/bin:/usr/bin:/bin</string>"))
}

@Test func mariadbLaunchArgumentsPutTheDefaultsFileFirst() {
    let binaries = ResolvedBinaries(
        httpd: URL(fileURLWithPath: "/httpd"),
        modulesDirectory: URL(fileURLWithPath: "/modules"),
        mimeTypes: URL(fileURLWithPath: "/mime"),
        phpFpm: URL(fileURLWithPath: "/php-fpm"),
        php: URL(fileURLWithPath: "/php"),
        mariadbd: URL(fileURLWithPath: "/mariadbd"),
        mariadb: URL(fileURLWithPath: "/mariadb"),
        installDB: URL(fileURLWithPath: "/install"),
        serverRoot: URL(fileURLWithPath: "/opt/httpd")
    )
    let paths = StackPaths(
        support: URL(fileURLWithPath: "/support"),
        documentRoot: URL(fileURLWithPath: "/Sites"),
        launchAgents: URL(fileURLWithPath: "/agents")
    )
    let arguments = LaunchAgentWriter.arguments(service: .mariadb, binaries: binaries, paths: paths)
    #expect(arguments == ["/mariadbd", "--defaults-file=/support/config/my.cnf"])
}
