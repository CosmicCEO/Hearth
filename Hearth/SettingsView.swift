import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(StackModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Document root") {
                Text(model.documentRoot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { model.pickingFolder = true }
                    .disabled(model.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .fileImporter(isPresented: $model.pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.changeDocumentRoot(url)
            }
        }
    }
}
