import SwiftUI

/// Type: New York for titles only, SF for everything else, monospaced digits for every time.
public enum DaybookType {
    public static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
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
    /// A heading on the page: body size at semibold.
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

    /// The fixed size in the window or the panel, before `readingScale`.
    public func size(_ density: DaybookDensity) -> CGFloat {
        switch (self, density) {
        case (.docTitle, .panel): return 17
        case (.docTitle, _): return 28
        case (.sheetTitle, .panel): return 15
        case (.sheetTitle, _): return 22
        case (.rowTitle, _): return 13
        case (.rowDetail, _): return 12
        case (.byline, _): return 13
        case (.lede, _): return 16
        case (.heading, _): return 15
        case (.body, .panel): return 13
        case (.body, _): return 14
        case (.speaker, _): return 12
        case (.marginTime, _), (.time, _): return 11
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

    /// The extra leading that brings body text to its line: 22 pt for 14 pt body on the Mac.
    public static func bodyLineSpacing(_ density: DaybookDensity, scale: CGFloat = 1) -> CGFloat {
        density == .touch ? 4 : 5 * scale
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
