import SwiftUI

// Where the two platforms differ by a single modifier, one helper that does nothing on the other, so a shared
// view reads the same on both instead of wrapping the modifier in `#if os(…)`.

/// How a text field capitalizes under touch (`touchKeyboard(capitalization:submit:)`). The Mac's keyboard doesn't.
public enum TouchCapitalization: Sendable {
    case never
    case words
    case sentences
    case characters
}

extension View {
    /// The navigation title inline in its bar under touch, where it would otherwise be large. The Mac's
    /// titles are never large.
    public func touchInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The keyboard a text field brings up under touch: how it capitalizes, and what its return key says. Either
    /// left out keeps the system's. The Mac's fields have neither.
    public func touchKeyboard(capitalization: TouchCapitalization? = nil, submit: SubmitLabel? = nil) -> some View {
        #if os(iOS)
        modifier(TouchKeyboard(capitalization: capitalization, submit: submit))
        #else
        self
        #endif
    }

    /// A tooltip on the Mac, where a pointer rests on things; nothing under touch.
    public func macHelp(_ text: LocalizedStringKey) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }

    /// A tooltip on the Mac from a string that's already words; nothing under touch.
    @_disfavoredOverload
    public func macHelp<S: StringProtocol>(_ text: S) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }

    /// A control's size on the Mac; under touch, the system's.
    public func macControlSize(_ size: ControlSize) -> some View {
        #if os(macOS)
        controlSize(size)
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct TouchKeyboard: ViewModifier {
    let capitalization: TouchCapitalization?
    let submit: SubmitLabel?

    @ViewBuilder func body(content: Content) -> some View {
        switch (capitalization.map(Self.autocapitalization), submit) {
        case let (capitalization?, submit?): content.textInputAutocapitalization(capitalization).submitLabel(submit)
        case let (capitalization?, nil): content.textInputAutocapitalization(capitalization)
        case let (nil, submit?): content.submitLabel(submit)
        case (nil, nil): content
        }
    }

    private static func autocapitalization(_ capitalization: TouchCapitalization) -> TextInputAutocapitalization {
        switch capitalization {
        case .never: return .never
        case .words: return .words
        case .sentences: return .sentences
        case .characters: return .characters
        }
    }
}
#endif
