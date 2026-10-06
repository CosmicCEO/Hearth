# Hearth v1

Date: 2026-10-06
Status: Approved

Hearth is a macOS app that installs and runs a private Apache, MariaDB, and PHP stack for local development. You start the stack, open a site from a document root, connect a MySQL client, and open a database admin page.

This spec is the design brief. Implementation waits until this file is reviewed and an implementation plan exists.

## Outcome

On a Mac that has no PHP and no MariaDB, Jerod opens Hearth, confirms setup, and waits. Hearth installs a private Homebrew prefix, installs `httpd`, `php`, and `mariadb` into that prefix, and starts three user launch agents. The browser at `http://127.0.0.1:8888/` shows a PHP page from `~/Sites`. Adminer is at `http://127.0.0.1:8888/adminer.php`. The MariaDB root password is in the Keychain and can be copied from the window. Quitting Hearth leaves the stack running. Stop stack shuts it down. The system Apache and the Homebrew at `/opt/homebrew` stay as they were.

## Decisions

1. **Private prefix.** The stack lives under `~/Library/Application Support/Hearth/`. Hearth uses that prefix's `brew`, never `/opt/homebrew/bin/brew`.
2. **MariaDB.** The database is MariaDB, speaking the MySQL protocol. The window calls the card Database and shows the version string from `mariadbd`.
3. **Ports.** Preferred ports are HTTP `8888`, MariaDB `8889`, and PHP-FPM `9000`. All three bind to `127.0.0.1` only.
4. **PHP-FPM.** Apache proxies `.php` to PHP-FPM with `proxy:fcgi`. Hearth does not load `mod_php`.
5. **Launch agents.** Three agents in `~/Library/LaunchAgents` keep the stack up across quitting Hearth and across login, while the saved desired state is running.
6. **Adminer 6.1.1.** English MySQL/MariaDB build, downloaded at setup and checked against a pinned SHA-256. Apache License 2.0.
7. **Document root.** Default is `~/Sites`. Hearth creates it when it is missing. An existing `index.php` or `index.html` is left in place.
8. **One PHP.** The `php` formula's current stable version. A version switcher is later work.
9. **Separate processes.** Hearth launches `httpd`, `php-fpm`, and `mariadbd` as their own processes. It does not link their libraries. MariaDB is GPL; this keeps Hearth on the process boundary Homebrew already uses.
10. **Developer tool signing.** The app is a local Xcode build. App Sandbox is off and Hardened Runtime is off, so Hearth can write its prefix, write LaunchAgents, and serve a folder the user picks.

## Later

These are out of scope for v1. The implementation plan should not add them.

- Switching PHP versions
- Extra virtual hosts
- TLS
- Binding on anything other than `127.0.0.1`
- A menu bar item
- A stack update button (`brew upgrade`)
- Using `/opt/homebrew` as the prefix

## Machine facts this design assumes

Checked 2026-10-06 on this Mac:

- Apple silicon, macOS 27, Xcode 27
- Homebrew is installed at `/opt/homebrew`
- `/usr/sbin/httpd` exists and was not listening
- `php` and MariaDB were not installed
- Nothing was listening on 80, 3306, 8080, or 8888

Hearth still probes ports at setup time. It does not assume those ports stay free.

## Layout on disk

```
~/Library/Application Support/Hearth/
  homebrew/                 private Homebrew prefix
  config/httpd.conf
  config/php-fpm.conf
  config/my.cnf
  var/mysql/                MariaDB data directory
  var/run/httpd.pid
  var/run/php-fpm.pid
  var/run/mysql.sock
  var/run/mariadb.pid
  logs/httpd-error.log
  logs/httpd-access.log
  logs/httpd-stdout.log
  logs/httpd-stderr.log
  logs/php-fpm.log
  logs/php-fpm-stdout.log
  logs/php-fpm-stderr.log
  logs/mariadb-error.log
  logs/mariadb-stdout.log
  logs/mariadb-stderr.log
  adminer/adminer.php
  adminer/NOTICE
  stack.json

~/Library/LaunchAgents/
  com.jerodprice.hearth.httpd.plist
  com.jerodprice.hearth.php-fpm.plist
  com.jerodprice.hearth.mariadb.plist

~/Sites/                     default document root
```

`Application Support` contains a space. Every path written into `httpd.conf`, `php-fpm.conf`, and `my.cnf` is double-quoted. LaunchAgent arguments are separate plist strings, so the space is already safe there. A unit test renders each config with a prefix that contains a space and asserts the quotes.

`stack.json` is pretty-printed UTF-8, version 1:

```json
{
  "version": 1,
  "prefix": "/Users/jerodprice/Library/Application Support/Hearth/homebrew",
  "documentRoot": "/Users/jerodprice/Sites",
  "httpPort": 8888,
  "mariaPort": 8889,
  "fpmPort": 9000,
  "bindAddress": "127.0.0.1",
  "desired": "stopped",
  "setupComplete": false,
  "passwordApplied": false,
  "adminerSHA256": "cd5d65d3e85c9e1233126625232150e2de405f3d56c76fdc171f4133a401e8d2",
  "formulae": {
    "httpd": "",
    "php": "",
    "mariadb": ""
  },
  "brewVersion": ""
}
```

This is the file written at the end of the port check, before any download. A finished setup sets `desired` to `running`, `setupComplete` to true, and `passwordApplied` to true, and replaces the three formula strings and `brewVersion` with the first line of `httpd -v`, `php -v`, `mariadbd --version`, and `brew --version`.

`desired` is `running` or `stopped`. A `version` other than 1 makes Hearth show "This Hearth data was written by a newer version" and skip start, stop, and install. When `stack.json` already exists, setup reuses its ports. If one of those ports does not bind, setup stops with "127.0.0.1:N is in use" and keeps the saved ports.

## Ports

`PortPlanner` is a pure function. It claims three ports in order: HTTP from 8888, MariaDB from 8889, PHP-FPM from 9000. A claim checks the start port and the next 19 ports. It skips ports already claimed and ports in the busy set. If any claim fails, setup stops with "Hearth could not find a free port" and does not download anything.

The busy set is measured by binding `127.0.0.1` on that port. A failed bind means busy. The probe socket is closed before install continues.

The setup screen runs the probe when it appears and shows the three chosen ports before the install button does work. When the preferred ports are free, the screen shows `127.0.0.1:8888` and `127.0.0.1:8889`.

## Setup

The setup screen is the whole window until `setupComplete` is true. A saved file with `setupComplete` false shows Continue setup. Quitting during setup terminates the installer. Quitting from the dashboard leaves a running stack running.

Copy on the screen:

- Title: Hearth
- Body: Hearth installs a private Apache, MariaDB, and PHP for this Mac. The servers live in Application Support and listen on localhost.
- A fact line for disk, the probed ports, and the document root `~/Sites`

Disk rule: if the volume holding Application Support has under 2 GB free, the Install button is disabled until the user clicks Install anyway. The UI estimate of the download is about 1 GB. Hearth does not fail the install for going over that estimate.

Phases, in order, shown as the current phase plus a monospaced log of command output (last 4,000 lines kept):

1. Check disk and ports, then write `stack.json` if it is missing
2. Install Homebrew
3. Install Apache, PHP, and MariaDB
4. Download Adminer
5. Save the root password and create the database files
6. Write configuration, the welcome page, and the launch agents
7. Start MariaDB, apply the root password, then start PHP-FPM and Apache

Buttons are disabled while a phase is running. Closing the app during setup terminates the child process group, including `brew`. The next launch runs the resume rules and the button reads Continue setup.

### Resume

`InstallPlanner` is pure. Input:

| Field | Meaning |
| --- | --- |
| `brewBinaryExists` | `prefix/bin/brew` exists |
| `installedFormulae` | subset of `httpd`, `php`, `mariadb` reported by that brew |
| `adminerChecksumMatches` | `adminer.php` SHA-256 matches the pin |
| `dataDirectoryInitialized` | `var/mysql/mysql` exists |
| `keychainHasPassword` | Keychain has the root password item |
| `passwordApplied` | `stack.json` has `passwordApplied` true |

Output:

| Step | Runs when |
| --- | --- |
| Install Homebrew | `brewBinaryExists` is false |
| `brew install` missing formulae | any of the three formulae is absent; install only the absent ones |
| Download Adminer | checksum does not match |
| Generate password | the data directory is not initialized and the Keychain item is absent and the planner is not blocked |
| `mariadb-install-db` | the data directory is not initialized and the planner is not blocked |
| Apply password | `passwordApplied` is false and the planner is not blocked |
| Rewrite configs and plists | the planner is not blocked |

Blocked state: the data directory is initialized, the Keychain item is absent, and `passwordApplied` is false. Reason shown: "Database files exist and Hearth has no saved root password." Hearth does not initialize, does not apply a password, and does not start services. The screen offers Reset database.

Reset database moves `var/mysql` to `var/mysql-reset-YYYYMMDDHHMMSS` in the same parent folder. It does not delete the old directory. It sets `passwordApplied` to false. The planner then treats the data directory as uninitialized and continues setup.

The controller runs the planner once at the start of Continue setup and again after the database files exist, so Apply password is still taken in a fresh run where the directory was created in the same session.

Password lifecycle:

- Generate 24 characters from `SecRandomCopyBytes`, alphabet `A-Za-z0-9`.
- Write the Keychain item before `mariadb-install-db`, so a crash keeps the same password for the retry.
- When the Keychain already has a password, reuse it.
- To apply the password, write the SQL to a file mode `0600` inside the Hearth folder, start MariaDB, and wait up to 30 seconds for its port to accept a connection.

Password apply has three outcomes, decided by a pure function of the two client results:

| Unauthenticated socket | `SELECT 1` with the Keychain password | Result |
| --- | --- | --- |
| Success | not tried | Run the SQL, then set `passwordApplied` true |
| Failure | Success | The password is already set. Set `passwordApplied` true |
| Failure | Failure | Boot MariaDB out and fail the phase |

The SQL file is deleted after the client exits. On success the controller starts PHP-FPM and Apache, waits up to 30 seconds for all three cards to be Running, writes the version lines, and sets `setupComplete` true and `desired` to `running`. A failure in that wait leaves `setupComplete` false. Agents that are already running stay running. Continue setup bootstraps labels that are `notLoaded` and leaves a `running` label alone.

SQL applied as root over the socket:

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '<password>';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '<password>';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '<password>';
FLUSH PRIVILEGES;
```

### Homebrew install

When `prefix/bin/brew` is missing, create the prefix directory and unpack the current Homebrew master tarball:

```bash
curl -L https://github.com/Homebrew/brew/tarball/master | tar xz --strip-components 1 -C <prefix>
```

Record `brew --version` in `stack.json`.

Every brew invocation uses the private `prefix/bin/brew` and this environment:

- `HOMEBREW_NO_AUTO_UPDATE=1`
- `HOMEBREW_NO_ANALYTICS=1`
- `HOMEBREW_NO_ENV_HINTS=1`
- `PATH` starting with `prefix/bin` and `prefix/sbin`

Install command: `brew install httpd php mariadb`, limited to formulae the planner marked missing.

### Adminer

Download:

`https://github.com/vrana/adminer/releases/download/v6.1.1/adminer-6.1.1-mysql-en.php`

SHA-256: `cd5d65d3e85c9e1233126625232150e2de405f3d56c76fdc171f4133a401e8d2`

Save the bytes as `adminer/adminer.php`. Write `adminer/NOTICE` with the URL, the version `6.1.1`, and the line `License: Apache-2.0`. A checksum mismatch deletes the file and fails the phase with a retryable error.

### Binaries and files Hearth resolves

After install, resolve each item by the first path that exists. If a required item is missing, setup fails and names it.

| Item | Candidates |
| --- | --- |
| `httpd` | `prefix/opt/httpd/bin/httpd`, `prefix/bin/httpd` |
| modules directory | `prefix/opt/httpd/lib/httpd/modules`, `prefix/lib/httpd/modules` |
| `mime.types` | `prefix/etc/httpd/mime.types`, `prefix/opt/httpd/share/httpd/conf/mime.types` |
| `php-fpm` | `prefix/opt/php/sbin/php-fpm`, `prefix/sbin/php-fpm` |
| `php` | `prefix/opt/php/bin/php`, `prefix/bin/php` |
| `mariadbd` | `prefix/opt/mariadb/bin/mariadbd`, `prefix/bin/mariadbd` |
| `mariadb` client | `prefix/opt/mariadb/bin/mariadb`, `prefix/bin/mariadb` |
| `mariadb-install-db` | `prefix/opt/mariadb/bin/mariadb-install-db`, `prefix/bin/mariadb-install-db` |

Required module files inside the modules directory:

`mod_mpm_event.so`, `mod_authz_core.so`, `mod_authz_host.so`, `mod_dir.so`, `mod_mime.so`, `mod_rewrite.so`, `mod_proxy.so`, `mod_proxy_fcgi.so`, `mod_log_config.so`, `mod_unixd.so`, `mod_alias.so`, `mod_headers.so`

Load `mod_mpm_event.so` only. Do not load a second MPM.

### httpd.conf

`ServerRoot` is the directory that contains `lib/httpd/modules` two levels up from the modules directory (`…/opt/httpd` in the Homebrew layout). `LoadModule` paths are `lib/httpd/modules/<name>.so` relative to that `ServerRoot`.

The file sets:

- `Listen 127.0.0.1:<httpPort>`
- `ServerName localhost`
- `PidFile` at `var/run/httpd.pid`
- `ErrorLog` and `CustomLog` at the httpd log paths
- `TypesConfig` as the absolute `mime.types` path
- `DocumentRoot` and a matching `<Directory>` for the document root
- `Options Indexes FollowSymLinks`
- `AllowOverride All`
- `Require all granted`
- `DirectoryIndex index.php index.html`
- `<FilesMatch \.php$>` with `SetHandler "proxy:fcgi://127.0.0.1:<fpmPort>"`
- `Alias /adminer.php` to the absolute `adminer.php` path, plus a `<Directory>` for the adminer folder that grants access and sets the same PHP handler on `adminer.php`

The `User` and `Group` directives name the current user and that user's primary group. Apache ignores a user change when it is already running as that user. The config stays explicit so the file documents who serves files.

### php-fpm.conf

A complete file. It does not include Homebrew's default pool, so PHP-FPM cannot also bind the prefix's default socket.

```
[global]
error_log = "<logs>/php-fpm.log"
daemonize = no
pid = "<var>/run/php-fpm.pid"

[www]
user = <current user>
group = <primary group>
listen = 127.0.0.1:<fpmPort>
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
clear_env = no
security.limit_extensions = .php
```

Launch arguments: `php-fpm --nodaemonize --fpm-config <config>/php-fpm.conf`.

A log line that says the `user` directive is ignored because PHP-FPM is not root is a successful start.

### my.cnf

```
[mysqld]
datadir = "<var>/mysql"
port = <mariaPort>
bind-address = 127.0.0.1
socket = "<var>/run/mysql.sock"
pid-file = "<var>/run/mariadb.pid"
log_error = "<logs>/mariadb-error.log"
mysqlx = 0
skip-name-resolve

[client]
port = <mariaPort>
socket = "<var>/run/mysql.sock"
```

`mariadb-install-db` arguments: `--datadir=<var>/mysql`, `--auth-root-authentication-method=normal`, `--skip-test-db`.

Launch arguments, with the defaults file first: `mariadbd --defaults-file=<config>/my.cnf`.

### Launch agents

Each plist is a `launchd` user agent, label equal to the file name without `.plist`.

| Label | Program arguments |
| --- | --- |
| `com.jerodprice.hearth.httpd` | `httpd -D FOREGROUND -f <config>/httpd.conf` |
| `com.jerodprice.hearth.php-fpm` | `php-fpm --nodaemonize --fpm-config <config>/php-fpm.conf` |
| `com.jerodprice.hearth.mariadb` | `mariadbd --defaults-file=<config>/my.cnf` |

Shared keys: `RunAtLoad` true, `KeepAlive` true, `StandardOutPath` and `StandardErrorPath` at that service's stdout and stderr logs, and `EnvironmentVariables.PATH` set to `prefix/bin:prefix/sbin:/usr/bin:/bin`.

Domain: `gui/<uid>` from `getuid()`.

| Action | Command |
| --- | --- |
| Start | `launchctl bootstrap gui/<uid> <plist>` |
| Stop | `launchctl bootout gui/<uid>/<label>` |
| Restart | `launchctl kickstart -k gui/<uid>/<label>` |
| Status | `launchctl print gui/<uid>/<label>` |

Start order: MariaDB, PHP-FPM, Apache. Stop order: Apache, PHP-FPM, MariaDB. Start stack and Stop stack walk those orders. A failure on one service is recorded on that service and the walk continues.

A Start stack request sets `desired` to `running` before it bootstraps agents. A Stop stack request sets `desired` to `stopped` before it boots agents out. On later launches, Hearth bootstraps any `notLoaded` agent while `desired` is `running`, and it leaves agents alone while `desired` is `stopped`.

Restart of one card is `kickstart -k` for that label. Changing the document root rewrites `httpd.conf`. When the Apache agent is loaded, Hearth restarts Apache. When it is `notLoaded`, the next start reads the new file.

### Status

`LaunchctlParser` reads `launchctl print` output:

- Non-zero exit → `notLoaded`
- A line matching optional whitespace, `state = running` → `running`
- Any other output → `stopped`

The card state combines that with a port connect:

| Card | Running when |
| --- | --- |
| Web server | launchd `running` and TCP connect to the HTTP port succeeds |
| PHP | launchd `running` and TCP connect to the FPM port succeeds |
| Database | launchd `running` and TCP connect to the MariaDB port succeeds |

Launchd `running` with a closed port shows Starting. Launchd `notLoaded` shows Stopped. Any other launchd state shows Failed, with the last non-empty line of that service's error log.

Versions come from the first line of `httpd -v`, `php -v`, and `mariadbd --version`.

### Welcome page

During the configuration phase, when the document root contains neither `index.php` nor `index.html`, write this `index.php`. If either file exists, write nothing.

```php
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
```

The page uses `phpversion()`. It does not call `phpinfo()`.

## Window

One SwiftUI window, title Hearth, default size 760×560, minimum 640×480. Deployment target macOS 15. Swift 6 with complete strict concurrency.

### Dashboard

Shown when `setupComplete` is true.

- Top status uses the first match: Starting if a start or restart is in progress or any card is Starting; Failed if any card is Failed; Running if all three cards are Running; otherwise Stopped.
- Primary button is Stop stack when any card is Running or Starting. Otherwise it is Start stack.
- Open site, which opens `http://127.0.0.1:<httpPort>/` in the default browser.
- Reveal folder, which shows the document root in Finder.

Three cards:

| Card | Shows | Actions |
| --- | --- | --- |
| Web server | Apache version, `127.0.0.1:<httpPort>` | Restart, Log |
| PHP | PHP version, FPM port | Restart, Log |
| Database | MariaDB version, `127.0.0.1:<mariaPort>`, user `root` | Copy password, Copy client command, Restart, Log |

Copy password reads the Keychain item and copies it. Copy client command copies:

```
<mariadb client> --host=127.0.0.1 --port=<mariaPort> -u root -p
```

The log sheet shows the service name and the last 200 lines of its error log. When that file is missing, it shows the launchd stderr log. Refresh reads the file again.

While `isBusy` is true, Start, Stop, Restart, and the document-root change are disabled.

### Settings

The macOS Settings window has one control: the document root path and a Change button. Change uses a directory picker. On confirm, Hearth updates `stack.json`, rewrites `httpd.conf`, and restarts Apache when that agent is loaded.

## Keychain

Generic password:

- Service: `com.jerodprice.hearth`
- Account: `mariadb-root`
- Accessible: when unlocked

The UI talks to a `KeychainStoring` protocol. Tests use an in-memory fake. A Keychain write failure fails the setup phase and is shown in the log. Hearth does not claim the password was saved.

When `passwordApplied` is true and the Keychain item is absent, the Database card shows "Hearth has no saved root password" and Copy password is disabled. Hearth leaves the data directory in place.

## App structure

Project path: `/Users/jerodprice/Developer/Hearth`

Xcode macOS app target `Hearth` and unit-test target `HearthTests`, created through Xcode. Bundle identifier `com.jerodprice.hearth`. `ENABLE_APP_SANDBOX = NO`. `ENABLE_HARDENED_RUNTIME = NO`. `SWIFT_STRICT_CONCURRENCY = complete`. Do not hand-edit `project.pbxproj`.

| Type | Role |
| --- | --- |
| `StackLayout` | Sendable value: paths, ports, document root, desired state. Encodes `stack.json`. |
| `PortPlanner` | Pure port claims. |
| `ConfigRenderer` | Pure `httpd.conf`, `php-fpm.conf`, `my.cnf`, and the welcome `index.php`. |
| `LaunchAgentWriter` | Pure plist bodies, plus writing them. |
| `InstallPlanner` | Pure resume decisions. |
| `ProcessRunner` | Protocol. The live one uses `Process` and merges stdout and stderr. |
| `KeychainStoring` | Protocol. The live one uses the Security framework. |
| `LaunchctlParser` | Pure parser of `launchctl print`. |
| `StackController` | Actor. One install, start, stop, or restart at a time. |
| `StackModel` | `@MainActor` observable object the views read. |
| SwiftUI views | Setup, dashboard, service card, log sheet, settings. |

`StackController` depends on the protocols, so tests can pass fakes. Unit tests do not run `brew`, do not download Adminer, and do not talk to the real Keychain.

## Errors

Each failed phase throws a `LocalizedError` whose description includes the phase name and the last non-empty line of the command log. The setup screen keeps the log and offers Try again, which runs the planner again.

Service start failure leaves that card Failed and leaves the other cards as they are. The log button shows the reason.

## Tests

| Test | Asserts |
| --- | --- |
| HTTP config | Bind address, port, quoted document root, quoted space-containing prefix, Adminer alias, FPM handler, event MPM only |
| PHP-FPM config | Listen address, `daemonize = no`, pool limits |
| MariaDB config | Port, `bind-address`, quoted datadir, `mysqlx = 0` |
| Welcome page | Contains `phpversion()` and `/adminer.php`, does not contain `phpinfo` |
| Port planner | Preferred ports when free; upward scan; skip claimed ports; failure after 20 busy ports |
| Launchctl parser | `running`, other state text, non-zero exit |
| Install planner | Fresh install; brew already present; formulae partially present; crash after the Keychain write; password still to apply; blocked existing datadir; nothing left to install |
| Password apply | SQL runs when the empty socket works; flag-only when the password already works; failure when both clients fail |

## Acceptance

Done means all of the following are true on this Mac:

1. `xcodebuild test` for `HearthTests` passes.
2. `xcodebuild build` produces `Hearth.app`.
3. Setup finishes and the dashboard shows Running.
4. `curl -fsS http://127.0.0.1:<httpPort>/` returns the welcome page, including a PHP version.
5. `curl -fsS http://127.0.0.1:<httpPort>/adminer.php` returns Adminer HTML.
6. The private `mariadb` client connects to `127.0.0.1` on the MariaDB port as `root` with the Keychain password and `SELECT 1` returns 1.
7. Stop stack makes the HTTP curl fail to connect.
8. Start stack, quit Hearth, and the HTTP curl still returns the page.
9. Point the document root at a temporary folder that contains a `.php` file, and curl returns that file's output.
10. `/opt/homebrew` still has no `httpd`, `php`, or `mariadb` formula that this setup installed, and `/usr/sbin/httpd` is not the server answering port 8888.

Acceptance steps 3 through 10 need a network install and are a manual run. The automated gate is step 1 and step 2.
