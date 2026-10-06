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
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(StackModel.self) private var model

    var body: some View {
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
        .task { await model.onAppear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.cancelForQuit()
        }
    }
}
