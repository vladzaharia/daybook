import DaybookDesign
import DaybookKit
import SwiftUI

/// Acknowledgements on both apps: the models this device can use and those behind the library's results, each
/// family with its license and the credit it requires (`ModelAcknowledgements.entries`), then the software the
/// app ships with the notices and licenses its bundle carries. The Mac shows it in a sheet from Settings › Models
/// (and its About panel's credits list the same); the iPhone from Settings › About.
public struct AcknowledgementsScreen: View {
    private let entries: [ModelAcknowledgement]
    private let software: SoftwareNotices
    @Environment(\.daybookDensity) private var density

    public init(entries: [ModelAcknowledgement], software: SoftwareNotices = .bundled) {
        self.entries = entries
        self.software = software
    }

    private var touch: Bool { density == .touch }

    public var body: some View {
        Form {
            ForEach(entries) { entry in
                Section {
                    if let models = entry.otherModels {
                        LabeledContent(AboutWords.models.asSettingsLabel) {
                            Text(models.joined(separator: "\n")).multilineTextAlignment(.trailing)
                        }
                    }
                    license(entry)
                    if entry.label != nil || entry.addedByYou {
                        HStack(spacing: DaybookSpacing.s2) {
                            if let label = entry.label { DaybookChip(label, kind: .fact) }
                            if entry.addedByYou, let added = ModelOrigin.addedByYou.label { DaybookChip(added, kind: .fact) }
                        }
                    }
                    if let attribution = entry.attribution {
                        Text(attribution)
                            .font(touch ? .footnote : .subheadline)
                            .foregroundStyle(touch ? AnyShapeStyle(DaybookPalette.Ink.secondary) : AnyShapeStyle(.secondary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(entry.maker.map { "\(entry.title) · \($0)" } ?? entry.title)
                }
            }
            if !software.isEmpty {
                Section(AboutWords.software) {
                    if let notices = software.notices, !notices.isEmpty {
                        DisclosureGroup(AboutWords.thirdPartyNotices.asSettingsLabel) {
                            NoticesText(markdown: notices)
                        }
                    }
                    ForEach(software.packages) { package in
                        DisclosureGroup(package.name) {
                            VStack(alignment: .leading, spacing: DaybookSpacing.s4) {
                                ForEach(Array(package.files.enumerated()), id: \.offset) { _, file in
                                    LicenseText(text: file.text)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AboutWords.acknowledgements)
        .touchInlineTitle()
    }

    @ViewBuilder private func license(_ entry: ModelAcknowledgement) -> some View {
        let title = AboutWords.license.asSettingsLabel
        if let url = URL(string: entry.licenseURL), !entry.licenseURL.isEmpty {
            if touch {
                Link(destination: url) {
                    // Explicit inks: a link tints its label, so "License" would be teal too.
                    LabeledContent {
                        Text(entry.licenseName).foregroundStyle(DaybookPalette.Ink.link)
                    } label: {
                        Text(title).foregroundStyle(DaybookPalette.Ink.title)
                    }
                }
            } else {
                LabeledContent(title) {
                    Link(entry.licenseName, destination: url).buttonStyle(.daybookLink)
                }
            }
        } else {
            LabeledContent(title, value: entry.licenseName)
        }
    }
}

/// A license's text as it ships: monospaced, selectable.
private struct LicenseText: View {
    let text: String
    @Environment(\.daybookDensity) private var density

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(density == .touch ? .caption.monospaced() : .system(size: 11, design: .monospaced))
            .foregroundStyle(density == .touch ? AnyShapeStyle(DaybookPalette.Ink.body) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// THIRD_PARTY_NOTICES.md drawn as a page: its headings, paragraphs (with their bold and links), each library of
/// its table on a line of its own, and the license texts it includes.
private struct NoticesText: View {
    let markdown: String
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let touch = density == .touch
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            ForEach(Array(NoticesDocument.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text).font(touch ? .subheadline.weight(.semibold) : .system(size: 12, weight: .semibold))
                case .paragraph(let text):
                    Text(Self.inline(text))
                        .font(touch ? .footnote : .system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let header, let rows):
                    VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.first ?? "").font(touch ? .footnote.weight(.semibold) : .system(size: 11, weight: .semibold))
                                ForEach(Array(row.dropFirst().enumerated()), id: \.offset) { index, cell in
                                    let label = header.indices.contains(index + 1) ? header[index + 1] : ""
                                    Text(label.isEmpty ? cell : "\(label): \(cell)")
                                        .font(touch ? .caption : .system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                case .code(let text):
                    LicenseText(text: text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A paragraph's bold and links, as Markdown's inline syntax writes them.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
