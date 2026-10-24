import AppKit
import DaybookKit
import SwiftUI

/// Acknowledgements for the models Daybook can use, generated from their manifests
/// (`ModelAcknowledgements`): the models each license covers, the license and its link, the credit
/// it requires, and "Non-commercial" where its terms say so. Shown from Settings › Models and in
/// the About Daybook panel's credits.
struct ModelAcknowledgementsView: View {
    let catalog: ModelCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Acknowledgements")
                .font(.headline)
                .padding(.horizontal, Space.s5)
                .padding(.top, Space.s5)
            Form {
                ForEach(ModelAcknowledgements.list(from: catalog)) { entry in
                    Section {
                        LabeledContent("Models") {
                            Text(entry.models.joined(separator: "\n")).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("License") {
                            if let url = URL(string: entry.licenseURL), !entry.licenseURL.isEmpty {
                                Link(entry.licenseName, destination: url).buttonStyle(.daybookLink)
                            } else {
                                Text(entry.licenseName)
                            }
                        }
                        if let attribution = entry.attribution {
                            Text(attribution)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(entry.title)
                            if let maker = entry.maker { Text(maker).fontWeight(.regular).foregroundStyle(.secondary) }
                            Spacer()
                            if let label = entry.label { ModelLabelChip(label) }
                            if entry.addedByYou { ModelLabelChip(ModelOrigin.addedByYou.label ?? "") }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s4)
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 720, maxHeight: 760)
    }
}

/// The About Daybook panel, with the model acknowledgements as its credits: the standard place on
/// the Mac for the credits an app's parts require.
enum AboutPanel {
    @MainActor static func show(catalog: ModelCatalog) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(catalog)])
        NSApp.activate()
    }

    static func credits(_ catalog: ModelCatalog) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 2
        func text(_ string: String, font: NSFont = body, color: NSColor = .labelColor, link: String? = nil) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let link, let url = URL(string: link) { attributes[.link] = url }
            return NSAttributedString(string: string, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        result.append(text("Models\n", font: bold))
        for (index, entry) in ModelAcknowledgements.list(from: catalog).enumerated() {
            if index > 0 { result.append(text("\n")) }
            result.append(text("\(entry.title)\(entry.maker.map { " · \($0)" } ?? "")\n", font: bold))
            result.append(text(entry.models.joined(separator: ", ") + "\n", color: .secondaryLabelColor))
            result.append(text(entry.licenseName, link: entry.licenseURL.isEmpty ? nil : entry.licenseURL))
            result.append(text(entry.label.map { " · \($0)\n" } ?? "\n", color: .secondaryLabelColor))
            if let attribution = entry.attribution { result.append(text(attribution + "\n", color: .secondaryLabelColor)) }
        }
        return result
    }
}
