import SwiftUI

/// Type: New York for titles only, SF for everything else, monospaced digits for every time.
public enum DaybookType {
    public static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    /// New York at a text style, so it follows Dynamic Type: the iPhone's titles that aren't a role of
    /// `DaybookFont`, as the notebook's "Choose a Conversation" (`.title2`) and the widgets' (`.headline`).
    public static func title(_ style: Font.TextStyle) -> Font { .system(style, design: .serif, weight: .semibold) }
    public static func clock(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    /// Times in a margin lane on the Mac: a fixed size, so "1:02:03" always fits. Under touch, the
    /// margin time follows Dynamic Type (`DaybookFont.marginTime`).
    public static let marginTime = Font.system(size: 11).monospacedDigit()
}

/// How dense a surface is, which sets its type and its targets. Each scene sets it once at its root;
/// components read it rather than taking per-platform metrics.
public enum DaybookDensity: Hashable, Sendable, CaseIterable {
    /// Floating Notes: a small panel over someone else's call. Fixed sizes, a size down.
    case panel
    /// The Mac's main window and Settings: fixed sizes, the reading surface scaling with View › Make
    /// Text Bigger.
    case window
    /// The iPhone: Dynamic Type, and 44 pt targets.
    case touch

    /// The platform's own: touch on iPhone, the window on the Mac.
    public static var platformDefault: DaybookDensity {
        #if os(iOS)
        .touch
        #else
        .window
        #endif
    }
}

extension EnvironmentValues {
    /// The surface's density (`DaybookDensity`). Floating Notes sets `.panel` at its root.
    @Entry public var daybookDensity: DaybookDensity = .platformDefault
}

/// The reading surface (page, transcript, floating notes) scales with View › Make Text Bigger on the Mac.
/// Chrome text never scales; under touch, Dynamic Type does the scaling instead.
public struct ReadingScaleKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    public var readingScale: CGFloat {
        get { self[ReadingScaleKey.self] }
        set { self[ReadingScaleKey.self] = newValue }
    }
}

/// A role in the type scale: one name, one font, at every density. Under touch each role is a Dynamic
/// Type text style; in the window and the panel it's a fixed size, and the reading roles scale with
/// `readingScale`.
public enum DaybookFont: String, CaseIterable, Sendable {
    /// A conversation's title at the top of its page (New York).
    case docTitle
    /// A sheet's or a device page's title, a smaller New York.
    case sheetTitle
    /// A list row's title (SF).
    case rowTitle
    /// A list row's second line.
    case rowDetail
    /// The page's byline: date, length, people.
    case byline
    /// The summary's first paragraph.
    case lede
    /// A heading on the page, semibold and a size above the body.
    case heading
    /// Everything read on the page.
    case body
    /// A speaker's name above their passage.
    case speaker
    /// A time in the margin or lane.
    case marginTime
    /// A time a person taps to play from.
    case time
    /// A status line's words.
    case status
    /// A status box's first line.
    case statusLead
    /// How the page was made, at its foot.
    case colophon
    /// Live captions: the newest line.
    case captionNewest
    /// Live captions: the lines above it.
    case captionOlder

    /// Whether the role is on the reading surface, and so scales with `readingScale` on the Mac.
    public var isReading: Bool {
        switch self {
        case .docTitle, .byline, .lede, .heading, .body, .speaker, .marginTime, .time: return true
        default: return false
        }
    }

    /// The text style the role follows under touch.
    public var textStyle: Font.TextStyle {
        switch self {
        case .docTitle: return .title
        case .sheetTitle, .rowTitle, .heading: return .headline
        case .rowDetail, .byline, .speaker, .status, .statusLead, .captionOlder: return .subheadline
        case .lede, .captionNewest: return .title3
        case .body: return .body
        case .marginTime: return .caption2
        case .time, .colophon: return .footnote
        }
    }

    /// The fixed size in the window or the panel, before `readingScale`. The window's page is typeset as a document:
    /// a 15 pt body (about 80 characters to the 560 pt measure), a 19 pt lede, and 17 pt headings, so a heading
    /// outranks the paragraph above it.
    public func size(_ density: DaybookDensity) -> CGFloat {
        switch (self, density) {
        case (.docTitle, .panel): return 17
        case (.docTitle, _): return 30
        case (.sheetTitle, .panel): return 15
        case (.sheetTitle, _): return 22
        case (.rowTitle, _): return 13
        case (.rowDetail, _): return 12
        case (.byline, _): return 13
        case (.lede, .panel): return 16
        case (.lede, _): return 19
        case (.heading, .panel): return 15
        case (.heading, _): return 17
        case (.body, .panel): return 13
        case (.body, _): return 15
        case (.speaker, _): return 12
        case (.marginTime, .panel), (.time, .panel): return 11
        case (.marginTime, _), (.time, _): return 12
        case (.status, _), (.statusLead, _): return 12
        case (.colophon, _): return 11
        case (.captionNewest, _): return 14
        case (.captionOlder, _): return 12.5
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .docTitle, .sheetTitle, .rowTitle, .heading, .speaker: return .semibold
        case .statusLead, .captionNewest: return .medium
        default: return .regular
        }
    }

    /// New York for titles only.
    public var design: Font.Design { self == .docTitle || self == .sheetTitle ? .serif : .default }

    /// Times and the byline use monospaced digits.
    public var monospacedDigits: Bool { self == .byline || self == .marginTime || self == .time }

    /// The role's font at a density; `scale` is the Mac's reading scale, which only the reading roles
    /// follow (Dynamic Type scales them under touch).
    public func font(_ density: DaybookDensity, scale: CGFloat = 1) -> Font {
        let font: Font
        switch density {
        case .touch:
            font = .system(textStyle, design: design, weight: weight)
        case .window, .panel:
            font = .system(size: size(density) * (isReading ? scale : 1), weight: weight, design: design)
        }
        return monospacedDigits ? font.monospacedDigit() : font
    }

    /// The extra leading that brings body text to its line: a 24 pt line for the window's 15 pt body, 21 for the
    /// panel's 13.
    public static func bodyLineSpacing(_ density: DaybookDensity, scale: CGFloat = 1) -> CGFloat {
        switch density {
        case .touch: return 4
        case .window: return 6 * scale
        case .panel: return 5 * scale
        }
    }

    /// The lede's: a 26 pt line for the window's 19 pt lede; under touch and in the panel, the body's.
    public static func ledeLineSpacing(_ density: DaybookDensity, scale: CGFloat = 1) -> CGFloat {
        density == .window ? 4 * scale : bodyLineSpacing(density, scale: scale)
    }
}

extension View {
    /// Sets the text in a type role, at the surface's density and (on the Mac) reading scale.
    public func daybookFont(_ role: DaybookFont) -> some View {
        modifier(DaybookFontModifier(role: role))
    }
}

private struct DaybookFontModifier: ViewModifier {
    let role: DaybookFont
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var scale
    func body(content: Content) -> some View {
        content.font(role.font(density, scale: scale))
    }
}
