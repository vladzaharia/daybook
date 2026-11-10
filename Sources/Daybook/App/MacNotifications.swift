import AppKit
import DaybookDevices
import DaybookKit
import Foundation
@preconcurrency import UserNotifications

/// One notification about this Mac's recording, as it's posted.
struct RecordingNotification: Equatable {
    enum Kind: String, Equatable {
        /// A recording ended without Stop: its title, why, and Record Again.
        case stopped = "recording-stopped"
        /// A call started recording on its own while Floating Notes wasn't showing.
        case recording = "recording-started"
    }

    var kind: Kind
    var conversationID: UUID
    var title: String
    /// The conversation's title; never a Personal one's.
    var subtitle: String?
    var body: String

    var identifier: String { Self.identifier(kind, conversationID) }

    static func identifier(_ kind: Kind, _ id: UUID) -> String { "\(kind.rawValue).\(id.uuidString)" }
}

/// What a click on a notification asks for.
enum RecordingNotificationResponse: Equatable {
    /// The notification itself: open what it's about.
    case open(RecordingNotification.Kind, UUID)
    /// "Recording stopped"'s Record Again: into the conversation that stopped.
    case recordAgain(UUID)
}

/// Posts and removes notifications. The system's center in the app; tests keep a list.
@MainActor
protocol RecordingNotificationPosting: AnyObject {
    /// Asks the person, the first time only (the system remembers the answer).
    func requestAuthorization()
    func post(_ notification: RecordingNotification)
    func remove(_ identifiers: [String])
}

/// The Mac's notifications about its own recording, for when Daybook isn't in front (HIG: Notifications), the same
/// background-only rule as a recorder's (`DeviceNotifications`):
///
/// - "Recording stopped" when a recording ends without Stop (a microphone that went, sleep, a disk that couldn't keep
///   up: `AppState.unexpectedStops`), naming the conversation unless it's Personal, saying why, with Record Again.
/// - "Recording" when a call starts recording on its own while Floating Notes isn't showing, naming the call.
///
/// Each goes once it's no longer true: the stop's when it's been seen in the app or the next recording starts, the
/// start's when that recording ends. Permission is asked the first time someone records or turns on Record calls
/// automatically.
@MainActor
final class RecordingNotifications {
    /// What it follows in the app's state, read in one place.
    struct Snapshot: Equatable {
        var recordingID: UUID?
        var automatic = false
        /// The call an automatic recording records ("Zoom call").
        var callName: String?
        var automaticRecording = false
        var stops: [UUID: String] = [:]
    }

    static let recordAgainAction = "record-again"
    static let recordAgainTitle = "Record Again"
    static let stoppedTitle = "Recording stopped"
    static let recordingTitle = "Recording"

    private weak var state: AppState?
    private let center: any RecordingNotificationPosting
    private let isInForeground: @MainActor () -> Bool
    private let isFloatingNotesShowing: @MainActor () -> Bool
    /// Opens the library window and brings Daybook forward (a click on a stop).
    var openLibrary: () -> Void = { NSApp.activate() }
    private var watch: ObservationWatch?
    private var last = Snapshot()
    private var asked = false
    /// Posted and not yet taken back.
    private(set) var posted: Set<String> = []

    init(state: AppState, center: any RecordingNotificationPosting,
         isInForeground: @escaping @MainActor () -> Bool = { DeviceNotifications.isInForeground() },
         isFloatingNotesShowing: @escaping @MainActor () -> Bool = { FloatingNotesWindow.shared.isVisible }) {
        self.state = state
        self.center = center
        self.isInForeground = isInForeground
        self.isFloatingNotesShowing = isFloatingNotesShowing
    }

    /// Follows the state for as long as this lives.
    func start() {
        watch = ObservationWatch.distinctValues(of: { [weak self] in self?.snapshot() ?? Snapshot() }) { [weak self] next in
            self?.update(to: next)
        }
    }

    func stop() {
        watch?.cancel()
        watch = nil
    }

    private func snapshot() -> Snapshot {
        guard let state else { return Snapshot() }
        let automatic = state.recordingID != nil && state.recordingWasStartedAutomatically
        return Snapshot(recordingID: state.recordingID, automatic: automatic,
                        callName: automatic ? state.monitor.activeCandidate?.callName : nil,
                        automaticRecording: state.automaticRecording, stops: state.unexpectedStops)
    }

    /// What changed since the last snapshot, posted and taken back. Internal so tests drive it with snapshots.
    func update(to next: Snapshot) {
        defer { last = next }
        if !asked, next.recordingID != nil || next.automaticRecording {
            asked = true
            center.requestAuthorization()
        }
        // A recording that ended: its "Recording" goes.
        if let ended = last.recordingID, ended != next.recordingID {
            take(RecordingNotification.identifier(.recording, ended))
        }
        // A new recording: "Recording stopped" and its Record Again are out of date.
        if let started = next.recordingID, started != last.recordingID {
            for id in posted.filter({ $0.hasPrefix(RecordingNotification.Kind.stopped.rawValue) }) { take(id) }
            if next.automatic, !isInForeground(), !isFloatingNotesShowing() {
                put(RecordingNotification(kind: .recording, conversationID: started, title: Self.recordingTitle, subtitle: nil,
                                          body: Self.callLine(next.callName)))
            }
        }
        // Stops seen in the app go; new ones are said.
        for id in last.stops.keys where next.stops[id] == nil { take(RecordingNotification.identifier(.stopped, id)) }
        for (id, reason) in next.stops where last.stops[id] == nil {
            guard !isInForeground(), next.recordingID == nil || next.recordingID == id else { continue }
            put(RecordingNotification(kind: .stopped, conversationID: id, title: Self.stoppedTitle, subtitle: shownTitle(id),
                                      body: reason))
        }
    }

    /// "Zoom call", capitalized: the call's own name, or "Call" when it's not known.
    static func callLine(_ name: String?) -> String {
        guard let name, let first = name.first else { return "Call" }
        return first.uppercased() + name.dropFirst()
    }

    /// The conversation's title where Daybook may say it outside its windows: never a Personal one's (as the menu bar
    /// extra), and nothing for one that's gone.
    private func shownTitle(_ id: UUID) -> String? {
        guard let meeting = state?.meetings.first(where: { $0.id == id }), meeting.effectivePlacement != .personal else { return nil }
        return meeting.title
    }

    private func put(_ notification: RecordingNotification) {
        posted.insert(notification.identifier)
        center.post(notification)
    }

    private func take(_ identifier: String) {
        guard posted.remove(identifier) != nil else { return }
        center.remove([identifier])
    }

    /// A click: Record Again records into the conversation that stopped, after what was saved, once the library is open,
    /// as Floating Notes' Record Again does, so a call cut short isn't split in two; the notification itself opens what
    /// it's about.
    func respond(_ response: RecordingNotificationResponse) {
        guard let state else { return }
        switch response {
        case .recordAgain(let id):
            Task { @MainActor in
                guard await LibraryOpening.opens(state) else { return }
                await state.recordAgain(into: id)
            }
        case .open(.stopped, let id):
            if state.meetings.contains(where: { $0.id == id }) { state.showConversation(id) }
            openLibrary()
        case .open(.recording, _):
            state.showFloatingNotes(focus: state.recordingID)
        }
    }
}

/// The system's notification center, from a bundled app only (it crashes in an unbundled binary): posting, taking
/// back, and the clicks, which it hands to `respond`.
@MainActor
final class SystemRecordingNotifications: NSObject, RecordingNotificationPosting, UNUserNotificationCenterDelegate {
    var respond: ((RecordingNotificationResponse) -> Void)?

    /// Becomes the center's delegate and says what Record Again is.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let recordAgain = UNNotificationAction(identifier: RecordingNotifications.recordAgainAction,
                                               title: RecordingNotifications.recordAgainTitle, options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: RecordingNotification.Kind.stopped.rawValue, actions: [recordAgain], intentIdentifiers: []),
            UNNotificationCategory(identifier: RecordingNotification.Kind.recording.rawValue, actions: [], intentIdentifiers: [])
        ])
    }

    /// The same request a recorder's import makes, so whichever comes first, "Recording stopped" can be heard.
    func requestAuthorization() {
        DeviceNotifications.requestAuthorizationIfNeeded()
    }

    func post(_ notification: RecordingNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle { content.subtitle = subtitle }
        content.body = notification.body
        content.categoryIdentifier = notification.kind.rawValue
        content.userInfo = ["conversation": notification.conversationID.uuidString, "kind": notification.kind.rawValue]
        // A recording that stopped is worth a sound; one that started isn't.
        if notification.kind == .stopped { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }

    func remove(_ identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String).flatMap(RecordingNotification.Kind.init(rawValue:))
        let id = (info["conversation"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == RecordingNotifications.recordAgainAction, let id {
                self.respond?(.recordAgain(id))
            } else if let kind, let id {
                self.respond?(.open(kind, id))
            } else {
                // A recorder's notification: Daybook comes forward, as it would without a delegate.
                NSApp.activate()
            }
            completionHandler()
        }
    }

    /// In front, what a notification says is already on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
