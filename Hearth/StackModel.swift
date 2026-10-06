import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class StackModel {
    var phase = ""
    var log = ""
    var isBusy = false
    var statusWord = "Stopped"
    var cards: [CardSnapshot] = []
    var setupComplete = false
    var hasSavedStack = false
    var blockedReason: String?
    var versionMessage: String?
    var errorText: String?
    var portsLine = ""
    var documentRoot = ""
    var lowDisk = false
    var installUnlocked = false
    var httpURL = URL(string: "http://127.0.0.1:8888/") ?? URL(fileURLWithPath: "/")
    var clientCommand = ""
    var passwordAvailable = false
    var showingLog = false
    var logTitle = ""
    var logBody = ""
    var pickingFolder = false

    private let controller: StackController
    private let logStore: LogStore

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = StackPaths(
            support: home.appending(path: "Library/Application Support/Hearth"),
            documentRoot: home.appending(path: "Sites"),
            launchAgents: home.appending(path: "Library/LaunchAgents")
        )
        let store = LogStore()
        logStore = store
        controller = StackController(paths: paths, dependencies: .live(), logStore: store)
    }

    init(controller: StackController, logStore: LogStore) {
        self.controller = controller
        self.logStore = logStore
    }

    func onAppear() async {
        await reload()
        if setupComplete && blockedReason == nil && versionMessage == nil {
            await controller.reconcile()
            await reload()
        }
    }

    func install() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        let allow = installUnlocked || !lowDisk
        Task {
            let finished = FinishFlag()
            let installTask = Task {
                defer { finished.mark() }
                try await controller.install(allowLowDisk: allow)
            }
            while !finished.isSet {
                pullLog()
                try? await Task.sleep(for: .milliseconds(300))
            }
            switch await installTask.result {
            case .success:
                break
            case .failure(let error):
                if error is CancellationError {
                    errorText = nil
                } else {
                    errorText = error.localizedDescription
                }
            }
            pullLog()
            await reload()
            isBusy = false
        }
    }

    func resetDatabase() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            do {
                try await controller.resetDatabase()
                try await controller.install(allowLowDisk: true)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
            isBusy = false
        }
    }

    func toggleStack() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        let stop = ServiceStatus.primaryIsStop(cards: cards.map(\.state))
        Task {
            do {
                if stop {
                    await controller.stopStack()
                } else {
                    try await controller.startStack()
                }
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
            isBusy = false
        }
    }

    func restart(_ service: HearthService) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await controller.restart(service)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
            isBusy = false
        }
    }

    func showLog(_ service: HearthService) async {
        logTitle = service.title
        logBody = await controller.serviceLog(service)
        showingLog = true
    }

    func refreshLog(_ service: HearthService) async {
        logBody = await controller.serviceLog(service)
    }

    func copyPassword() {
        Task {
            do {
                let password = try await controller.copyPassword()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func copyClientCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clientCommand, forType: .string)
    }

    func openSite() {
        NSWorkspace.shared.open(httpURL)
    }

    func revealFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: documentRoot))
    }

    func changeDocumentRoot(_ url: URL) {
        let allowed = url.startAccessingSecurityScopedResource()
        let path = url.path
        if allowed { url.stopAccessingSecurityScopedResource() }
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await controller.changeDocumentRoot(to: path)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
            isBusy = false
        }
    }

    private func pullLog() {
        let stored = logStore.snapshot()
        phase = stored.phase
        log = stored.log
    }

    private func reload() async {
        let snap = await controller.snapshot()
        versionMessage = snap.versionMessage
        setupComplete = snap.setupComplete
        hasSavedStack = snap.hasSavedStack
        blockedReason = snap.blockedReason
        lowDisk = snap.lowDisk
        portsLine = snap.portsLine
        documentRoot = snap.documentRoot
        statusWord = snap.statusWord
        cards = snap.cards
        httpURL = snap.httpURL
        clientCommand = snap.clientCommand
        passwordAvailable = snap.passwordAvailable
        pullLog()
    }
}

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func mark() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
