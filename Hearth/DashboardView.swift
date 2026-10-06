import SwiftUI

struct DashboardView: View {
    @Environment(StackModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.statusWord)
                    .font(.title2)
                Spacer()
                Button(ServiceStatus.primaryIsStop(cards: model.cards.map(\.state)) ? "Stop stack" : "Start stack") {
                    model.toggleStack()
                }
                .disabled(model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
            HStack {
                Button("Open site") { model.openSite() }
                Button("Reveal folder") { model.revealFolder() }
            }
            if let error = model.errorText {
                Text(error).foregroundStyle(.red)
            }
            ForEach(model.cards) { card in
                ServiceCardView(card: card)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.showingLog) {
            LogSheet()
        }
    }
}

struct ServiceCardView: View {
    @Environment(StackModel.self) private var model
    var card: CardSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.title).font(.headline)
                    Spacer()
                    Text(card.state.label)
                        .foregroundStyle(color)
                }
                if !card.version.isEmpty {
                    Text(card.version).font(.callout).foregroundStyle(.secondary)
                }
                Text(card.endpoint).font(.system(.callout, design: .monospaced))
                if case .failed(let line) = card.state, !line.isEmpty {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restart") { model.restart(card.service) }
                        .disabled(model.isBusy)
                    Button("Log") { Task { await model.showLog(card.service) } }
                    if card.service == .mariadb {
                        if model.passwordAvailable {
                            Button("Copy password") { model.copyPassword() }
                            Button("Copy client command") { model.copyClientCommand() }
                        } else {
                            Text("Hearth has no saved root password")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("root").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch card.state {
        case .running: .green
        case .starting: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

struct LogSheet: View {
    @Environment(StackModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.logTitle).font(.headline)
            ScrollView {
                Text(model.logBody.isEmpty ? "No log yet." : model.logBody)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Refresh") {
                    Task { await model.refreshLog(service(for: model.logTitle)) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func service(for title: String) -> HearthService {
        HearthService.displayOrder.first { $0.title == title } ?? .httpd
    }
}
