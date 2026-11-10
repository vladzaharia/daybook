import AppKit
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// Acknowledgements, from Settings › Models: DaybookUI's `AcknowledgementsScreen`, the iPhone's screen, in a sheet.
/// The models this Mac can use (every model in its catalog, by the rule both apps follow,
/// `ModelAcknowledgements.entries`), then the software it ships with its notices and licenses. Esc closes it, as
/// Done does.
struct ModelAcknowledgementsView: View {
    let catalog: ModelCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AboutWords.acknowledgements)
                .font(.headline)
                .padding(.horizontal, DaybookSpacing.s5)
                .padding(.top, DaybookSpacing.s5)
            AcknowledgementsScreen(entries: ModelAcknowledgements.entries(from: catalog, usable: nil, meetings: []))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DaybookSpacing.s5)
            .padding(.vertical, DaybookSpacing.s4)
        }
        .background {
            // A sheet with only a Return button ignores Esc; this one takes it.
            Button("Close", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 720, maxHeight: 760)
    }
}

/// The About Daybook panel, with the acknowledgements as its credits: the standard place on the Mac for the
/// credits an app's parts require. The same models as Acknowledgements, then the software it ships.
enum AboutPanel {
    @MainActor static func show(catalog: ModelCatalog) {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(catalog)])
        NSApp.activate()
    }

    static func credits(_ catalog: ModelCatalog, software: SoftwareNotices = .bundled) -> NSAttributedString {
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
        result.append(text(AboutWords.models + "\n", font: bold))
        for entry in ModelAcknowledgements.entries(from: catalog, usable: nil, meetings: []) {
            // A blank line before each entry, so the heading stands apart from the first one too.
            result.append(text("\n"))
            result.append(text("\(entry.title)\(entry.maker.map { " · \($0)" } ?? "")\n", font: bold))
            if let models = entry.otherModels { result.append(text(models.joined(separator: ", ") + "\n", color: .secondaryLabelColor)) }
            result.append(text(entry.licenseName, link: entry.licenseURL.isEmpty ? nil : entry.licenseURL))
            result.append(text(entry.label.map { " · \($0)\n" } ?? "\n", color: .secondaryLabelColor))
            if let attribution = entry.attribution { result.append(text(attribution + "\n", color: .secondaryLabelColor)) }
        }
        let libraries = software.libraries
        if !libraries.isEmpty {
            result.append(text("\n\(AboutWords.software)\n", font: bold))
            for library in libraries {
                result.append(text("\n"))
                result.append(text(library.name + "\n", font: bold))
                result.append(text(library.license + "\n", color: .secondaryLabelColor))
            }
        }
        return result
    }
}
