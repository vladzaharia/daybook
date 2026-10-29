import DaybookKit
import SwiftUI

/// Settings › About › Acknowledgements: the models behind this library's transcripts, speakers,
/// and summaries (made on a Mac), with their licenses and the credits those require. Generated from
/// the catalog's manifests (`ModelAcknowledgements`), so a new model's credit arrives with its entry.
struct AcknowledgementsScreen: View {
    @Environment(PhoneAppModel.self) private var model

    /// The models behind this library's results. About links here only when there are some.
    @MainActor
    static func entries(for model: PhoneAppModel) -> [ModelAcknowledgement] {
        let catalog = ModelCatalog.builtIn
        return ModelAcknowledgements.list(from: catalog, only: catalog.resultModelKeys(in: model.library.controller.meetings))
    }

    var body: some View {
        let entries = Self.entries(for: model)
        Form {
            ForEach(entries) { entry in
                Section {
                    LabeledContent("Models") {
                        Text(entry.models.joined(separator: "\n")).multilineTextAlignment(.trailing)
                    }
                    if let url = URL(string: entry.licenseURL), !entry.licenseURL.isEmpty {
                        Link(destination: url) {
                            // Explicit inks: a link tints its label, so "License" would be teal too.
                            LabeledContent {
                                Text(entry.licenseName).foregroundStyle(PhoneStyle.Ink.link)
                            } label: {
                                Text("License").foregroundStyle(PhoneStyle.Ink.title)
                            }
                        }
                    } else {
                        LabeledContent("License", value: entry.licenseName)
                    }
                    if let label = entry.label { LabeledContent("Use", value: label) }
                    if let attribution = entry.attribution {
                        Text(attribution)
                            .font(.footnote)
                            .foregroundStyle(PhoneStyle.Ink.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(entry.maker.map { "\(entry.title) · \($0)" } ?? entry.title)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
