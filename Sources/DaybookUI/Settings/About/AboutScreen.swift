import DaybookDesign
import DaybookKit
import SwiftUI

/// About on the iPhone: Daybook, its version as the Mac's About panel says it, the privacy statement both apps
/// share, and Acknowledgements (`route`, in Settings' navigation). The Mac keeps the system's About panel, whose
/// credits list the same acknowledgements, and shows the same statement in Settings › Library.
public struct AboutScreen<Route: Hashable>: View {
    private let version: String?
    private let acknowledgements: Route

    /// - Parameter version: "Version 0.1.0 (1)" (`AboutWords.version`); nil for a build without one.
    public init(version: String? = AboutWords.version(Bundle.main.infoDictionary), acknowledgements: Route) {
        self.version = version
        self.acknowledgements = acknowledgements
    }

    public var body: some View {
        Form {
            Section {
                HStack(spacing: DaybookSpacing.s4) {
                    DaybookMark(size: 56)
                    VStack(alignment: .leading, spacing: DaybookSpacing.s1) {
                        Text(AboutWords.appName)
                            .font(DaybookFont.docTitle.font(.touch))
                            .foregroundStyle(DaybookPalette.Ink.title)
                        if let version {
                            Text(version)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(DaybookPalette.Ink.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, DaybookSpacing.s1 + 2)
                .accessibilityElement(children: .combine)
            }
            Section(AboutWords.privacy) {
                PrivacyStatement()
            }
            Section {
                NavigationLink(AboutWords.acknowledgements, value: acknowledgements)
            }
        }
        .navigationTitle(AboutWords.title)
        .touchInlineTitle()
    }
}

/// The privacy statement both apps show (`PrivacyWords.statement`), by the lock in the brand gradient.
public struct PrivacyStatement: View {
    @Environment(\.daybookDensity) private var density

    public init() {}

    public var body: some View {
        Label {
            Text(PrivacyWords.statement)
                .font(density == .touch ? .subheadline : nil)
                .foregroundStyle(density == .touch ? AnyShapeStyle(DaybookPalette.Ink.body) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill").foregroundStyle(DaybookPalette.brandGradient(.mark))
        }
    }
}
