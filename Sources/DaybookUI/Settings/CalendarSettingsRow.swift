import DaybookDesign
import DaybookKit
import SwiftUI

/// Use Calendar, in Settings › Recording on both apps: the toggle, and while the system refuses Daybook its calendars
/// (turned on just now and refused, or taken away in the system's settings since) the problem line with the way to
/// fix it: Open System Settings… on the Mac, Open Settings on the iPhone.
public struct CalendarSettingsRow: View {
    private let isOn: Bool
    private let access: CalendarAccess
    private let set: (Bool) async -> Bool
    private let openSettings: () -> Void
    /// Turned on just now, and the system said no.
    @State private var refused = false

    /// - Parameters:
    ///   - isOn: Whether Daybook uses the calendar.
    ///   - access: What the system allows now.
    ///   - set: Turns it on or off, asking the system for access when it's turned on; says whether it's on after.
    ///   - openSettings: Opens the system's settings where calendar access is given.
    public init(isOn: Bool, access: CalendarAccess, set: @escaping (Bool) async -> Bool, openSettings: @escaping () -> Void) {
        self.isOn = isOn
        self.access = access
        self.set = set
        self.openSettings = openSettings
    }

    private static var openSettingsTitle: String {
        #if os(macOS)
        "Open System Settings…"
        #else
        "Open Settings"
        #endif
    }

    public var body: some View {
        Toggle(SettingsWords.useCalendar, isOn: Binding(get: { isOn }, set: { on in
            Task { @MainActor in
                let nowOn = await set(on)
                refused = on && !nowOn
            }
        }))
        if SettingsWords.calendarIsRefused(justNow: refused, isOn: isOn, access: access) {
            ProblemLine(text: SettingsWords.calendarRefused) {
                Button(Self.openSettingsTitle, action: openSettings)
            }
        }
    }
}
