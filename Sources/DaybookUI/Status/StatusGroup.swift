import DaybookDesign
import SwiftUI

/// A group of the status overview: its heading, then its card (or a card per device).
public struct StatusGroup<Content: View>: View {
    private let title: String
    private let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            StatusHeading(text: title).padding(.horizontal, StatusCardMetrics.padding)
            content
        }
    }
}

/// A group's heading: a generic label ("Recorders", "Macs", "This iPhone"), or what's live ("Listening to Soundcore
/// Work"). In sentence case and the names' own casing, never capitals, as Settings' section headers are.
public struct StatusHeading: View {
    private let text: String
    @Environment(\.daybookDensity) private var density

    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(density == .touch ? .subheadline.weight(.semibold) : .system(size: DaybookFont.status.size(density), weight: .semibold))
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
