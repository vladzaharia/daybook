import DaybookKit
import Foundation
import SwiftUI

/// Where Daybook opens to when something outside it asks: a notification's tap, Open Conversation and
/// New Note from Siri, Shortcuts, or Spotlight.
enum AppDestination: Equatable, Sendable {
    /// A conversation's page.
    case conversation(UUID)
    /// The library's list.
    case library
    /// A recorder's page, by its device ID (its notifications: imported, almost full).
    case device(String)
    /// The recording under way (it's on screen whenever Daybook records).
    case recording
    /// A new conversation that's only notes, open with the keyboard on them.
    case newNote
    /// A recording named after a meeting, started once Daybook is in front: a meeting's notification, tapped or
    /// its Record (`PhoneCalendar.swift`).
    case recordMeeting(String)

    // A notification carries its destination in `userInfo`, in the keys DaybookDevices' device
    // notifications use (`DeviceNotificationDestination`), so one delegate reads them all.
    static let placeKey = "daybook.place"
    static let deviceKey = "daybook.deviceID"
    static let conversationKey = "daybook.conversationID"
    static let meetingKey = "daybook.meetingTitle"

    /// What a notification carries.
    var userInfo: [String: String] {
        switch self {
        case .conversation(let id): return [Self.placeKey: "conversation", Self.conversationKey: id.uuidString]
        case .library: return [Self.placeKey: "library"]
        case .device(let id): return [Self.placeKey: "device", Self.deviceKey: id]
        case .recording: return [Self.placeKey: "recording"]
        case .newNote: return [Self.placeKey: "new-note"]
        case .recordMeeting(let title): return [Self.placeKey: "record-meeting", Self.meetingKey: title]
        }
    }

    /// Read back from a notification's `userInfo`; nil for one that says nowhere (it just opens Daybook).
    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.placeKey] as? String {
        case "conversation":
            guard let id = (userInfo[Self.conversationKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            self = .conversation(id)
        case "device":
            guard let id = userInfo[Self.deviceKey] as? String, !id.isEmpty else { return nil }
            self = .device(id)
        case "library": self = .library
        case "recording": self = .recording
        case "new-note": self = .newNote
        case "record-meeting":
            guard let title = userInfo[Self.meetingKey] as? String, !title.isEmpty else { return nil }
            self = .recordMeeting(title)
        default: return nil
        }
    }

    /// Read a widget link; other URLs don't request a destination.
    init?(widgetURL: URL) {
        guard let link = WidgetLink(url: widgetURL) else { return nil }
        switch link {
        case .library: self = .library
        case .conversation(let id): self = .conversation(id)
        case .newNote: self = .newNote
        }
    }
}

/// A destination the interface hasn't gone to yet (`PhoneAppModel.destination`): each request is its
/// own, so asking for the same place twice goes there twice.
struct DestinationRequest: Equatable, Sendable {
    var destination: AppDestination
    var id = UUID()
}

/// How the reading interface goes to a destination. Pure, so tests drive it with a `ReadingSession`.
@MainActor
enum DestinationRouter {
    /// Goes to `destination` in `session`, closing what covers it. False when it can't yet (the library
    /// is still loading), or when it's another view's to go to (a recorder's page, in the status sheet).
    @discardableResult
    static func go(to destination: AppDestination, in session: ReadingSession, library: LibraryController) -> Bool {
        switch destination {
        case .conversation(let id):
            guard library.isLoaded else { return false }
            guard library.meeting(id) != nil else {
                // Gone since (moved to the Trash, or not synced here yet): the library, rather than nothing.
                showLibrary(in: session)
                return true
            }
            uncover(session)
            session.open(id)
            return true
        case .library:
            showLibrary(in: session)
            return true
        case .newNote:
            guard library.isLoaded else { return false }
            uncover(session)
            session.newNote(in: library)
            return true
        case .recording, .recordMeeting:
            // The recorder replaces the library while anything records; nothing to open.
            uncover(session)
            return true
        case .device:
            // The status sheet opens a recorder's page (`StatusSheetView`); the conversation steps aside
            // so the sheet is there.
            uncover(session)
            session.closeConversation()
            return false
        }
    }

    private static func showLibrary(in session: ReadingSession) {
        uncover(session)
        session.closeConversation()
        session.place = .library(.section(.all))
    }

    /// Sheets, the camera, and an alert give way.
    private static func uncover(_ session: ReadingSession) {
        session.sheet = nil
        session.cameraFor = nil
        session.alert = nil
        session.isSelecting = false
    }
}

/// Follows `PhoneAppModel.destination` in the reading interface: `RootView` applies it with the
/// `ReadingSession` it owns (`.opensDestinations(reading)`).
struct OpensDestinations: ViewModifier {
    let session: ReadingSession
    @Environment(PhoneAppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.destination, initial: true) { _, _ in go() }
            .onChange(of: model.library.controller.isLoaded) { _, _ in go() }
    }

    private func go() {
        guard let request = model.destination else { return }
        if DestinationRouter.go(to: request.destination, in: session, library: model.library.controller) {
            model.reached(request)
        }
    }
}

extension View {
    /// Goes where Daybook was asked to open (`PhoneAppModel.open(_:)`) in `session`.
    func opensDestinations(_ session: ReadingSession) -> some View {
        modifier(OpensDestinations(session: session))
    }
}
