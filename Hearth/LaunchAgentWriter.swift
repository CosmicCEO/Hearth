import Foundation

enum LaunchAgentWriter {
    static func plist(label: String, arguments: [String], stdout: String, stderr: String, path: String) -> String {
        let argumentXML = arguments.map { "    <string>\(xml($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xml(label))</string>
          <key>ProgramArguments</key>
          <array>
        \(argumentXML)
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(xml(stdout))</string>
          <key>StandardErrorPath</key>
          <string>\(xml(stderr))</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>\(xml(path))</string>
          </dict>
        </dict>
        </plist>
        """
    }

    static func arguments(service: HearthService, binaries: ResolvedBinaries, paths: StackPaths) -> [String] {
        switch service {
        case .httpd:
            [binaries.httpd.path, "-D", "FOREGROUND", "-f", paths.httpdConf.path]
        case .phpFPM:
            [binaries.phpFpm.path, "--nodaemonize", "--fpm-config", paths.phpFpmConf.path]
        case .mariadb:
            [binaries.mariadbd.path, "--defaults-file=\(paths.myCnf.path)"]
        }
    }

    private static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
