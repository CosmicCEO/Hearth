import AppKit
import SwiftUI

@main
struct HearthApp: App {
    @State private var model = StackModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 760, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Uninstall Stack…") { model.confirmingUninstall = true }
                    .disabled(model.isBusy || !model.hasSavedStack)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(StackModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let message = model.versionMessage {
                ContentUnavailableView(
                    "Hearth",
                    image: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else if model.setupComplete && model.blockedReason == nil {
                DashboardView()
            } else {
                SetupView()
            }
        }
        .confirmationDialog("Uninstall the Hearth stack?", isPresented: $model.confirmingUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("This stops the servers and deletes /opt/hearth, ~/Library/Application Support/Hearth (including the database and any database backups), the launch agents, and the saved root password. Your document root and Hearth.app are kept.")
        }
        .task { await model.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.cancelForQuit()
        }
    }
}
