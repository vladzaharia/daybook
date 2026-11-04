import AppKit
import SwiftUI

extension SettingsPane {
    /// The preference the Settings window restores its pane from: `@AppStorage(SettingsPane.storageKey)`, never the
    /// word itself, so a pane renamed here is renamed everywhere.
    static let storageKey = "settingsPane"

    /// Opens Settings on this pane, from a menu, a page, or the panel: the window reads its pane from `storageKey`.
    /// `activating` brings Daybook forward too (Floating Notes and the menu bar extra open it from another app).
    @MainActor func open(with openWindow: OpenWindowAction, defaults: UserDefaults = LaunchOptions.defaults, activating: Bool = true) {
        defaults.set(rawValue, forKey: Self.storageKey)
        openWindow.settings()
        if activating { NSApp.activate() }
    }
}

extension OpenWindowAction {
    /// Opens Settings, a window of its own (`WindowID.settings`), on the pane it last showed.
    @MainActor func settings() { callAsFunction(id: WindowID.settings) }
}
