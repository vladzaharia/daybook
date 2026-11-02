import DaybookDesign
import SwiftUI

// Welcome's pages as both apps draw them: the first page (the mark, the name, what Daybook is), and a step's
// page (a title, its sentence, what the step shows, and its buttons at the foot). On the Mac a page fills a fixed
// window; on the iPhone it scrolls under its buttons, so the largest text sizes still fit.

/// Welcome's first page: the mark, the name, what Daybook is, and Continue.
public struct WelcomeIntroPage: View {
    private let device: WelcomeWords.Device
    private let next: () -> Void

    public init(device: WelcomeWords.Device, next: @escaping () -> Void) {
        self.device = device
        self.next = next
    }

    public var body: some View {
        WelcomeStepPage(title: nil, message: nil) {
            VStack(spacing: 0) {
                DaybookMark(size: WelcomeMetrics.markSize)
                Text(WelcomeWords.name)
                    .font(WelcomeMetrics.nameFont)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .padding(.top, DaybookSpacing.s4)
                Text(WelcomeWords.tagline)
                    .font(.title3)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, DaybookSpacing.s1)
                VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
                    ForEach(WelcomeWords.points(device), id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                            Image(systemName: point.symbol)
                                .font(WelcomeMetrics.pointSymbolFont)
                                .foregroundStyle(DaybookPalette.brandGradient(.mark))
                                .frame(width: WelcomeMetrics.pointSymbolWidth)
                                .accessibilityHidden(true)
                            Text(point.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .daybookFont(.body)
                .foregroundStyle(DaybookPalette.Ink.body)
                .frame(maxWidth: WelcomeMetrics.pointsWidth, alignment: .leading)
                .padding(.top, DaybookSpacing.s6)
            }
        } actions: {
            WelcomePrimaryButton(WelcomeWords.next, action: next)
        }
    }
}

/// A step's page: a title in New York and its sentence, then what the step shows, then its buttons. The first
/// button is the step's one prominent action; `WelcomeNotNowButton` follows it when the step can be skipped.
public struct WelcomeStepPage<Content: View, Actions: View>: View {
    private let title: String?
    private let message: String?
    private let showsMark: Bool
    private let content: Content
    private let actions: Actions

    public init(title: String?, message: String?, showsMark: Bool = false,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.showsMark = showsMark
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        #if os(iOS)
        // Centred in the room above the buttons, as the Mac's window centres it; scrolling once text sizes need more,
        // and never under the buttons.
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: DaybookSpacing.s5)
                        header
                        content
                        Spacer(minLength: DaybookSpacing.s5)
                    }
                    .padding(.horizontal, DaybookSpacing.s5)
                    .frame(maxWidth: WelcomeMetrics.columnWidth)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: DaybookSpacing.s2) { actions }
                .padding(.horizontal, DaybookSpacing.s5)
                .padding(.vertical, DaybookSpacing.s3)
                .frame(maxWidth: WelcomeMetrics.columnWidth)
                .frame(maxWidth: .infinity)
        }
        #else
        VStack(spacing: 0) {
            Spacer(minLength: DaybookSpacing.s7)
            header
            content
            Spacer(minLength: DaybookSpacing.s5)
            VStack(spacing: DaybookSpacing.s3) { actions }
                .padding(.bottom, DaybookSpacing.s4)
        }
        .padding(.horizontal, DaybookSpacing.s6)
        #endif
    }

    @ViewBuilder private var header: some View {
        if showsMark {
            DaybookMark(size: WelcomeMetrics.closingMarkSize)
                .padding(.bottom, DaybookSpacing.s4)
        }
        if let title {
            Text(title)
                .font(WelcomeMetrics.titleFont)
                .foregroundStyle(DaybookPalette.Ink.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        if let message {
            Text(message)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: WelcomeMetrics.messageWidth)
                .padding(.top, DaybookSpacing.s2)
        }
    }
}

/// A step's one prominent action: Continue, Download and Continue, Record.
public struct WelcomePrimaryButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            #if os(iOS)
            label.frame(maxWidth: .infinity)
            #else
            label.frame(minWidth: 120)
            #endif
        }
        #if os(iOS)
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        #else
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        #endif
        .tint(DaybookPalette.prominentFill)
        .keyboardShortcut(.defaultAction)
    }
}

extension WelcomePrimaryButton where Label == Text {
    public init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

/// Leaves a step for later: quiet, under the step's action.
public struct WelcomeNotNowButton: View {
    private let title: String
    private let action: () -> Void

    public init(_ title: String = WelcomeWords.notNow, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .daybookHitTarget()
    }
}

/// Where a permission stands, as Settings › General › Permissions shows it: allowed; not asked yet (Allow asks);
/// or asked and not allowed, which only the system's settings can change.
public enum WelcomePermissionState: Equatable, Sendable {
    case allowed
    case askable
    case openSettings
}

/// One permission on the Allow page: its symbol and name, then Allowed, Allow, or Open Settings.
public struct WelcomePermissionRow: View {
    private let title: String
    private let symbol: String
    private let state: WelcomePermissionState
    private let device: WelcomeWords.Device
    private let allow: () -> Void
    private let openSettings: () -> Void

    public init(_ title: String, symbol: String, state: WelcomePermissionState, device: WelcomeWords.Device,
                allow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.state = state
        self.device = device
        self.allow = allow
        self.openSettings = openSettings
    }

    public var body: some View {
        HStack(spacing: DaybookSpacing.s3) {
            DaybookTile(symbol: symbol, size: .row)
            Text(title)
                .foregroundStyle(DaybookPalette.Ink.title)
            Spacer(minLength: DaybookSpacing.s3)
            switch state {
            case .allowed:
                Label {
                    Text(WelcomeWords.allowed).foregroundStyle(DaybookPalette.Ink.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DaybookPalette.Ink.link)
                }
                .labelStyle(.titleAndIcon)
            case .askable:
                Button(WelcomeWords.allow(device), action: allow)
                    .buttonStyle(.bordered)
            case .openSettings:
                Button(WelcomeWords.openSettings(device), action: openSettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, DaybookSpacing.s4)
        .padding(.vertical, DaybookSpacing.s3)
        .accessibilityElement(children: .contain)
    }
}

/// Rows on one card, divided, as Settings groups them. A divider starts where the rows' text does.
public struct WelcomeCard<Content: View>: View {
    private let dividerInset: CGFloat
    private let content: Content

    /// - Parameter dividerInset: Where a divider starts: after a tile (`WelcomeMetrics.tileInset`) or a radio
    ///   (`WelcomeMetrics.radioInset`).
    public init(dividerInset: CGFloat = WelcomeMetrics.tileInset, @ViewBuilder content: () -> Content) {
        self.dividerInset = dividerInset
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, dividerInset) }
                    row
                }
            }
        }
        // Clipped, so a first or last row's selection wash follows the card's corners.
        .background(WelcomeMetrics.cardFill)
        .clipShape(DaybookRadius.shape(DaybookRadius.box))
        .overlay {
            DaybookRadius.shape(DaybookRadius.box).strokeBorder(WelcomeMetrics.cardStroke)
        }
    }
}

/// A download under way: what's downloading and how far, over the brand bar.
public struct WelcomeDownloadProgress: View {
    private let title: String
    private let fraction: Double

    public init(_ title: String, fraction: Double) {
        self.title = title
        self.fraction = fraction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            HStack {
                Text(title)
                Spacer()
                Text(WorkProgress.clamped(fraction), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            WorkProgress(fraction: fraction, style: .bar)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Welcome's measurements, per device.
public enum WelcomeMetrics {
    #if os(iOS)
    public static let markSize: CGFloat = 88
    public static let closingMarkSize: CGFloat = 64
    public static let nameFont = Font.system(.largeTitle, design: .serif, weight: .semibold)
    public static let titleFont = DaybookFont.docTitle.font(.touch)
    public static let pointSymbolFont = Font.body
    public static let pointSymbolWidth: CGFloat = 24
    public static let pointsWidth: CGFloat = 420
    public static let messageWidth: CGFloat = 420
    public static let columnWidth: CGFloat = 520
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardStroke = Color.clear
    #else
    public static let markSize: CGFloat = 96
    public static let closingMarkSize: CGFloat = 64
    public static let nameFont = DaybookType.title(34)
    public static let titleFont = DaybookFont.sheetTitle.font(.window)
    public static let pointSymbolFont = Font.system(size: 17)
    public static let pointSymbolWidth: CGFloat = 22
    public static let pointsWidth: CGFloat = 360
    public static let messageWidth: CGFloat = 400
    public static let columnWidth: CGFloat = 496
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color(nsColor: .separatorColor)
    #endif
    /// Where a divider between rows starts: after a row's radio, or after its tile (the row's inset, the tile, the gap).
    public static let radioInset: CGFloat = 44
    public static let tileInset: CGFloat = DaybookSpacing.s4 + DaybookTileSize.row.base + DaybookSpacing.s3
}
