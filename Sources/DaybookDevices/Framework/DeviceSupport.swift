#if os(macOS)
import AppKit
#endif
import Foundation
@preconcurrency import UserNotifications

/// Keeps the Mac from idle-sleeping while a transfer or live capture runs, so an hour-long import
/// doesn't stop halfway. The display may still sleep.
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

/// Device notifications (§5.12): a finished batch and a nearly full recorder. They're posted only
/// while Daybook is in the background (in the foreground the result is visible in place), and only
/// from a bundled app: UNUserNotificationCenter crashes in an unbundled binary.
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

    /// Asks once, when the person first imports. Later calls do nothing.
    public static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    /// "Soundcore Work" and "3 recordings imported."
    public static func batchText(count: Int, device: String) -> (title: String, body: String) {
        (device, count == 1 ? "1 recording imported." : "\(count) recordings imported.")
    }

    public static func postBatchImported(count: Int, device: String, id: String) {
        guard count > 0 else { return }
        let text = batchText(count: count, device: device)
        post(id: "device-batch-\(id)", title: text.title, body: text.body)
    }

    /// "Soundcore Work is almost full." Returns whether it was posted.
    @discardableResult
    public static func postLowStorage(_ storage: DeviceStatus.Storage, device: String, id: String) -> Bool {
        let hours = storage.hoursLeft
        let rounded = StorageFormat.roundedHours(hours)
        let left = hours < 1 ? "Less than an hour" : "About \(rounded) hour\(rounded == 1 ? "" : "s")"
        return post(id: "device-storage-\(id)", title: "\(device) is almost full.", body: "\(left) of space left.")
    }

    @discardableResult
    private static func post(id: String, title: String, body: String) -> Bool {
        guard isAvailable, !isInForeground() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return true
    }
}
