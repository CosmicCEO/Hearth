# Hearth

Hearth is a macOS app that installs and runs a private Apache, MariaDB, and PHP stack for local development. The servers live in Application Support and listen on localhost. Hearth does not use the system Apache or the Homebrew install at `/opt/homebrew`.

## Requirements

- macOS 15 or later
- About 1 GB for the first install, and at least 2 GB free on the volume that holds Application Support (Install stays disabled below that until you choose Install anyway)
- A network connection for the first install

## Install the app

Download `Hearth-0.1.1.zip` from the [release](https://github.com/CosmicCEO/Hearth/releases/tag/v0.1.1), unzip it, and move `Hearth.app` where you want it. The app is ad-hoc signed. The first time you open it, right-click the icon and choose Open.

## First run

Hearth shows a setup screen until the stack is actually up. Install downloads a private Homebrew prefix, then Apache, PHP, and MariaDB, saves a MariaDB root password in the Keychain, and starts the three servers.

Default locations:

| | |
|---|---|
| Prefix, config, and data | `~/Library/Application Support/Hearth` |
| Document root | `~/Sites` |
| Web | `http://127.0.0.1:8888/` |
| Database admin | `http://127.0.0.1:8888/adminer.php` |
| MariaDB | `127.0.0.1:8889` |
| PHP-FPM | `127.0.0.1:9000` |

If a preferred port is already taken, Hearth scans upward, up to 20 ports, and shows the ports it chose before it downloads anything. An existing `index.php` or `index.html` in the document root is left in place.

The root password is 24 characters. Copy it from the Database card. The Keychain item is service `com.jerodprice.hearth`, account `mariadb-root`, available when the Mac is unlocked.

## Daily use

The window shows Web server, PHP, and Database. Start stack and Stop stack follow that order: MariaDB, then PHP-FPM, then Apache; stop is the reverse.

Quit leaves the stack running. The three servers are user launch agents, so they come back at login while Hearth's desired state is running. Stop stack disables those agents, so login does not bring them back.

Settings changes the document root and rewrites the Apache config. Apache restarts only when that agent is already loaded.

## Build

```sh
xcodebuild -project Hearth.xcodeproj -scheme Hearth -configuration Release -destination 'platform=macOS' build
```

Tests:

```sh
xcodebuild -project Hearth.xcodeproj -scheme Hearth -destination 'platform=macOS' test
```

The app target is `com.jerodprice.hearth`. App Sandbox and Hardened Runtime are off. This is a local developer tool, not an App Store build.

## Third-party software

Hearth runs these programs. It does not link them.

| Software | Role | License |
|---|---|---|
| Homebrew | Private prefix and formulae | BSD 2-Clause |
| Apache `httpd` | Web server | Apache License 2.0 |
| PHP | php-fpm | PHP License |
| MariaDB | Database server | GPL-2.0 |
| Adminer 6.1.1, English MySQL build | Database admin page at `/adminer.php` | Apache License 2.0 |
