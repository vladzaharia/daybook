import DaybookDesign
import DaybookKit
import SwiftUI

/// How the page was made, at its foot, the same on both apps: a short rule, where it ran with the model and the date
/// (`SummaryColophon`), whose glyph bounces once when a new summary lands (still under Reduce Motion), then the
/// template, which is a menu, and Summarize Again while it can be asked for. The template and Summarize Again are
/// quiet links: secondary ink until the pointer is over them in a window, link ink under touch.
public struct Colophon<TemplateMenu: View>: View {
    private let colophon: SummaryColophon
    private let arrived: Date
    private let template: String
    private let summarizeAgain: (() -> Void)?
    private let templateMenu: TemplateMenu
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - arrived: When the summary was made: its glyph bounces when this changes.
    ///   - template: The template's name, or "Automatic (Meeting)".
    ///   - summarizeAgain: Asks for a new summary; nil while one is asked for, running, or the conversation records.
    ///   - templateMenu: The template menu's items.
    public init(_ colophon: SummaryColophon, arrived: Date, template: String, summarizeAgain: (() -> Void)?,
                @ViewBuilder templateMenu: () -> TemplateMenu) {
        self.colophon = colophon
        self.arrived = arrived
        self.template = template
        self.summarizeAgain = summarizeAgain
        self.templateMenu = templateMenu()
    }

    public var body: some View {
        MarginRow {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                Rectangle().fill(DaybookPalette.Ink.faint).frame(width: 24, height: 1).padding(.bottom, DaybookSpacing.s1)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: colophon.symbol)
                        .daybookBounce(value: arrived)
                        .accessibilityHidden(true)
                    Text(colophon.line).fixedSize(horizontal: false, vertical: true)
                }
                // The template and Summarize Again, beside each other when they fit.
                FlowLayout(spacing: density == .touch ? DaybookSpacing.s3 : 4, lineSpacing: DaybookSpacing.s1) {
                    HStack(spacing: 4) {
                        Text("Template:")
                        Menu { templateMenu } label: {
                            QuietLink {
                                HStack(spacing: 3) {
                                    Text(template).fontWeight(.medium)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: density == .touch ? 9 : 7, weight: .semibold))
                                }
                            }
                            .daybookHitTarget()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .menuIndicator(.hidden)
                        #endif
                        .fixedSize()
                        .accessibilityLabel("Template, \(template)")
                    }
                    if let summarizeAgain {
                        HStack(spacing: 4) {
                            Text("·").accessibilityHidden(true)
                            Button(action: summarizeAgain) {
                                QuietLink { Text("Summarize Again").fontWeight(.medium) }.daybookHitTarget()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .daybookFont(.colophon)
            .foregroundStyle(DaybookPalette.Ink.meta)
        }
        .padding(.top, DaybookSpacing.s7)
    }
}
