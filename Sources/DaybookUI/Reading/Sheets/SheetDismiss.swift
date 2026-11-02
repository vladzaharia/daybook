import SwiftUI

// How a reading sheet closes, wherever it shows: presented as a sheet (the Mac, the iPhone in the hand), or as a card
// on the open iPhone Duo's right page, where it isn't presented at all and the page that shows it closes it.

/// Closes a sheet shown on the Duo's right page. What it does stays the same for as long as the page that sets it
/// (it clears that page's sheet), so every copy is equal: a view reading it never redraws because the page made the
/// closure again, as it would for a bare closure, which can't be compared.
public struct ClosePageSheetAction: Equatable {
    private let run: @MainActor () -> Void

    public init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    @MainActor public func callAsFunction() { run() }

    public static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Set while a reading sheet shows on the notebook's right page rather than presented: closes it.
    @Entry public var closePageSheet: ClosePageSheetAction? = nil
}

extension View {
    /// The page that shows a sheet on itself says how to close it: `.environment(\.closePageSheet) { … }`.
    public func environment(_ keyPath: WritableKeyPath<EnvironmentValues, ClosePageSheetAction?>,
                            _ close: @escaping @MainActor () -> Void) -> some View {
        environment(keyPath, ClosePageSheetAction(close))
    }

    /// Esc closes it, as Cancel does: a sheet whose only button is Done (or that has none) still answers Escape.
    public func dismissesOnEscape(_ dismiss: @escaping () -> Void) -> some View {
        background {
            Button("Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// Closes a reading sheet however it shows: presented (dismiss), or on the notebook's right page.
public struct SheetDismiss: DynamicProperty {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.closePageSheet) private var closePageSheet

    public init() {}

    @MainActor public func callAsFunction() {
        if !isPresented, let closePageSheet { closePageSheet() } else { dismiss() }
    }
}
