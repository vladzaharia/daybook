import DaybookDesign
import SwiftUI

// Rows both apps' Settings use: a symbol on a tile, a title, one line of what it's set to or doing;
// an action in the rows' column; a device page's header; a section's footer. On the iPhone they make the
// grouped list; on the Mac the tile column lines up its form's rows the same way.

/// The measurements every Settings row shares, so titles line up whatever the symbol.
public enum SettingsMetrics {
    /// The symbol tile at the default text size; it grows with Dynamic Type, up to `tileLimit`.
    public static let tile: CGFloat = DaybookTileSize.row.base
    public static let tileLimit: CGFloat = DaybookTileSize.row.limit
    /// Between the tile column and the text.
    public static let gap: CGFloat = DaybookSpacing.s3
    /// Between a page and the open Duo's crease. Lists inset their cards a further 16–20 pt, so cards end
    /// about `ReadingGeometry.creaseClearance` from the fold.
    public static let creaseGap: CGFloat = DaybookSpacing.s2
}

/// The tile column's width at the person's text size.
public struct SettingsTileWidth: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.daybookDensity) private var density

    public init() {}

    public var value: CGFloat { density == .touch ? DaybookTileSize.row.side(scale: scale) : DaybookTileSize.row.base }
}

/// A row's symbol on a neutral tile, like the status sheet's: teal only while the device it stands for
/// is connected, orange while something needs you.
public struct SettingsTile: View {
    public typealias Tone = DaybookTile.Tone

    private let systemImage: String
    private let tone: Tone
    private let size: CGFloat?

    /// - Parameter size: A larger tile (a device page's header, 56 pt); nil for the row column.
    public init(systemImage: String, tone: Tone = .neutral, size: CGFloat? = nil) {
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        DaybookTile(symbol: systemImage, tone: tone, size: size == nil ? .row : .header)
    }
}

/// A Settings row: its symbol on a tile, the title, and one line of what it's set to or doing. Explicit
/// inks, so a row inside a button keeps them.
public struct SettingsRow: View {
    private let title: String
    private let detail: String?
    private let systemImage: String
    private let tone: SettingsTile.Tone
    private let detailNeedsAttention: Bool
    @Environment(\.daybookDensity) private var density

    /// - Parameter detailNeedsAttention: The detail in orange: it needs you.
    public init(title: String, detail: String?, systemImage: String, tone: SettingsTile.Tone = .neutral, detailNeedsAttention: Bool = false) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.detailNeedsAttention = detailNeedsAttention
    }

    public var body: some View {
        HStack(spacing: SettingsMetrics.gap) {
            SettingsTile(systemImage: systemImage, tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.wrappingAsName)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.keepingSeparators)
                        .font(density == .touch ? .footnote : .system(size: 11))
                        .foregroundStyle(detailNeedsAttention ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// An action in a list of rows ("Pair with Your Mac…", "Sync Now"): its symbol in the tile column, then
/// its title, both in the link's ink, so it lines up with the rows around it.
public struct SettingsActionLabel: View {
    private let title: String
    private let systemImage: String
    private let column = SettingsTileWidth()

    public init(title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: SettingsMetrics.gap) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: column.value)
                .accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DaybookPalette.Ink.link)
        .accessibilityElement(children: .combine)
    }
}

/// The top of a device's page (a recorder, a Mac): its tile, its name in New York, and its status. The
/// bar stays quiet, so the name is shown once.
public struct DevicePageHeader: View {
    private let systemImage: String
    private let isActive: Bool
    private let title: String
    private let status: String
    private let statusNeedsAttention: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.daybookDensity) private var density

    public init(systemImage: String, isActive: Bool, title: String, status: String, statusNeedsAttention: Bool = false) {
        self.systemImage = systemImage
        self.isActive = isActive
        self.title = title
        self.status = status
        self.statusNeedsAttention = statusNeedsAttention
    }

    public var body: some View {
        // At the accessibility sizes the tile sits above the name, which then has the page's width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DaybookSpacing.s3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            SettingsTile(systemImage: systemImage, tone: isActive ? .active : .neutral, size: DaybookTileSize.header.base)
            VStack(alignment: .leading, spacing: 4) {
                // On one line when it fits; else a size smaller, wrapping at spaces (a page of the open Duo).
                ViewThatFits(in: .horizontal) {
                    Text(title).font(DaybookFont.docTitle.font(density)).lineLimit(1)
                    Text(title.wrappingAsName)
                        .font(density == .touch ? .system(.title2, design: .serif, weight: .semibold) : DaybookFont.sheetTitle.font(density))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DaybookPalette.Ink.title)
                .accessibilityAddTraits(.isHeader)
                Text(status.keepingSeparators)
                    .font(density == .touch ? .subheadline : .system(size: 13))
                    .foregroundStyle(statusNeedsAttention ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A device page's header as a list row: on the list's background, not in a cell.
    public func devicePageHeaderRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

/// A section footer: one or two sentences in secondary, aligned with the rows above. Status, a next
/// step, or a consequence; never how something works (docs/interface.md, principle 7).
public struct SettingsFooter: View {
    private let text: String
    @Environment(\.daybookDensity) private var density

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(density == .touch ? .footnote : .subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The Mac's grouped form insets its rows' text; the iPhone's section footer is already inset.
            .padding(.horizontal, density == .touch ? 0 : 10)
    }
}

extension String {
    /// "Connected · 80%" with the dot kept on the end of a line when it wraps, never starting one.
    public var keepingSeparators: String { replacingOccurrences(of: " · ", with: "\u{00A0}· ") }

    /// A device's name, wrapping without leaving a short last word alone on a line: "Vlad’s MacBook /
    /// Pro (755)", not "Vlad’s MacBook Pro / (755)". Names wrap only at spaces.
    public var wrappingAsName: String {
        let words = split(separator: " ", omittingEmptySubsequences: false)
        guard words.count >= 3, let last = words.last, last.count <= 5 else { return self }
        return words.dropLast().joined(separator: " ") + "\u{00A0}" + last
    }
}
