#if os(macOS)
import AppKit
#endif
import Foundation
import UserNotifications

/// Keeps this device from idle-sleeping while a transfer, a live capture, or the Mac's own recording runs, so neither an
/// hour-long import nor a long call stops halfway. The display may still sleep.
@MainActor
public final class SleepAssertion {
    private var token: NSObjectProtocol?
    private let reason: String

    public init(reason: String) { self.reason = reason }

    public var isHeld: Bool { token != nil }

    public func hold(_ active: Bool) {
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
        } else if !active, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}

/// Time to finish work the person no longer sees once the app leaves the screen: an import, from the moment its
/// audio has arrived until it's in the library. `ProcessInfo` activities don't keep an iOS app running, so the iPhone
/// app sets `hold` to a background task (`UIApplication.beginBackgroundTask`); elsewhere it holds nothing (the Mac
/// keeps `SleepAssertion`). Returns what ends it.
@MainActor
public enum DeviceBackgroundTime {
    public static var hold: (_ name: String) -> (@MainActor () -> Void) = { _ in {} }
}

/// Where opening a device notification takes the person, carried in the notification's `userInfo` for the
/// app's notification delegate: the conversation the recordings went into, when they all went into one, else
/// the recorder's page.
public enum DeviceNotificationDestination: Equatable, Sendable {
    /// The recorder's page, by its device ID.
    case device(String)
    /// A conversation, by its ID.
    case conversation(UUID)

    private static let placeKey = "daybook.place"
    private static let deviceKey = "daybook.deviceID"
    private static let conversationKey = "daybook.conversationID"

    /// What the notification carries.
    public var userInfo: [String: String] {
        switch self {
        case .device(let id): return [Self.placeKey: "device", Self.deviceKey: id]
        case .conversation(let id): return [Self.placeKey: "conversation", Self.conversationKey: id.uuidString]
        }
    }

    /// Read back from a notification's `userInfo`; nil for one that isn't a device notification's.
    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.placeKey] as? String {
        case "device":
            guard let id = userInfo[Self.deviceKey] as? String, !id.isEmpty else { return nil }
            self = .device(id)
        case "conversation":
            guard let id = (userInfo[Self.conversationKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            self = .conversation(id)
        default:
            return nil
        }
    }
}

/// Device notifications (§5.12): a finished batch and a nearly full recorder. They're posted only
/// while Daybook is in the background (in the foreground the result is visible in place), and only
/// from a bundled app: UNUserNotificationCenter crashes in an unbundled binary. Each carries where opening
/// it goes (`DeviceNotificationDestination`).
@MainActor
public enum DeviceNotifications {
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Whether Daybook is in front, where results show in place. The iPhone app sets this from its
    /// scene phase; on the Mac it's the application's own state.
    public static var isInForeground: () -> Bool = {
        #if os(macOS)
        NSApp.isActive
        #else
        false
        #endif
    }

    /// What Daybook asks to do: show notifications, and play a sound with one (the Mac's "Recording stopped"). The
    /// system asks only once, so every request asks for both, whichever comes first.
    public static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]

    /// Asks once: when the person first imports, or (on the Mac) first records. Later calls do nothing.
    public static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: authorizationOptions)
        }
    }

    /// "Soundcore Work" and "3 recordings imported."
    public static func batchText(count: Int, device: String) -> (title: String, body: String) {
        (device, count == 1 ? "1 recording imported." : "\(count) recordings imported.")
    }

    /// A batch finished: opening the notification goes to `destination` (the conversation they went into, or
    /// the recorder's page).
    public static func postBatchImported(count: Int, device: String, id: String, destination: DeviceNotificationDestination? = nil) {
        guard count > 0 else { return }
        let text = batchText(count: count, device: device)
        post(id: "device-batch-\(id)", title: text.title, body: text.body, destination: destination ?? .device(id))
    }

    /// "Soundcore Work is almost full." Returns whether it was posted. Opening it goes to the recorder's page.
    @discardableResult
    public static func postLowStorage(_ storage: DeviceStatus.Storage, device: String, id: String) -> Bool {
        let hours = storage.hoursLeft
        let rounded = StorageFormat.roundedHours(hours)
        let left = hours < 1 ? "Less than an hour" : "About \(rounded) hour\(rounded == 1 ? "" : "s")"
        return post(id: "device-storage-\(id)", title: "\(device) is almost full.", body: "\(left) of space left.", destination: .device(id))
    }

    @discardableResult
    private static func post(id: String, title: String, body: String, destination: DeviceNotificationDestination) -> Bool {
        guard isAvailable, !isInForeground() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = destination.userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return true
    }
}
