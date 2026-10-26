import SwiftUI

struct SetupView: View {
    @Environment(StackModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Hearth")
                .font(.largeTitle)
            Text("Hearth installs a private Apache, MariaDB, and PHP for this Mac. Programs go in /opt/hearth. The database and settings stay in Application Support, and the servers listen on localhost. macOS asks once for an administrator password to create /opt/hearth.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("About 1 GB. \(model.portsLine) Document root \(model.documentRoot).")
                .font(.callout)
            if let blocked = model.blockedReason {
                Text(blocked)
                    .foregroundStyle(.orange)
            }
            if let error = model.errorText {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.blockedReason != nil {
                    Button("Reset database") { model.resetDatabase() }
                        .disabled(model.isBusy)
                } else {
                    Button(model.hasSavedStack ? "Continue setup" : "Install stack") { model.install() }
                        .disabled(model.isBusy || (model.lowDisk && !model.installUnlocked))
                        .keyboardShortcut(.defaultAction)
                    if model.lowDisk && !model.installUnlocked {
                        Button("Install anyway") { model.installUnlocked = true }
                            .disabled(model.isBusy)
                    }
                    if model.errorText != nil {
                        Button("Try again") { model.install() }
                            .disabled(model.isBusy || (model.lowDisk && !model.installUnlocked))
                    }
                }
                if model.hasSavedStack {
                    Spacer()
                    Button("Uninstall…") { model.confirmingUninstall = true }
                        .disabled(model.isBusy)
                }
            }
            if model.isBusy || !model.log.isEmpty {
                Text(model.phase)
                    .font(.headline)
                ScrollView {
                    Text(model.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
