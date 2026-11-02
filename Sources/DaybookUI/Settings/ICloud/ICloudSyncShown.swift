import DaybookKit
import Foundation

// Settings' iCloud Sync, the same on the Mac (Settings › Library) and the iPhone (Settings › iCloud): one row saying
// where sync stands with its one action, a problem in place with its fix, the library's devices, and encryption. Each
// app fills `ICloudSyncShown` from its sync controller; the words are worked out here once, and tested
// (`ICloudSyncShownTests`).

/// What iCloud Sync shows, as plain values.
public struct ICloudSyncShown: Equatable {
    /// A device that can send the library's key while this one waits for it.
    public struct KeyPeer: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public var iCloud: ICloudSyncState
    /// Syncing through a chosen folder instead of iCloud (development builds).
    public var isFolderTransport = false
    /// The folder sync reads and writes, while connected.
    public var folder: URL?
    public var isSyncing = false
    /// Changes being sent in the pass running now (the iPhone counts them).
    public var changesInFlight = 0
    /// Changes made here since the last pass finished (the iPhone counts them).
    public var localChanges = 0
    public var pendingUploads = 0
    public var pendingDownloads = 0
    /// A bounded pass left work for the next one.
    public var hasMoreWork = false
    /// Sends to a Mac by courier that have waited a while (`CourierStatus.isStuck`); nil while nothing is stuck.
    public var courierWaiting: Int?
    public var lastSync: Date?
    /// What needs the person, from the controller's status.
    public var problem: SyncProblem?
    /// What a pass carried on past (`SyncWarningWords`), each said in place.
    public var warnings: [String] = []
    /// The older app is still installed beside this one and syncs as it (`SyncWarning.otherInstallation`).
    public var otherInstallation = false
    public var migration: SyncMigrationRecord?
    public var encryption: LibraryEncryptionShown = .unavailable
    public var mayStartOverEncryption = false
    public var hasRetiredFolderJournal = false
    /// Devices that can send the library's key, by name.
    public var keyPeers: [KeyPeer] = []
    /// Every device known to the library (presence), for the Devices row.
    public var devices: [KnownSyncDevice] = []

    public init(iCloud: ICloudSyncState) { self.iCloud = iCloud }

    /// "Mac" or "iPhone": this device, as its words name it.
    public static var device: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    // MARK: States

    /// Syncing through iCloud or a folder: Turn Off Sync… and Erase apply.
    public var isConnected: Bool { folder != nil && (isFolderTransport || iCloud == .connected) }

    /// Connected to the library, whether or not this device holds its key: the library's devices and encryption apply.
    public var isAttached: Bool { folder != nil && (isFolderTransport || iCloud == .connected || iCloud == .waitingForKey) }

    /// The library in iCloud was removed: its problem line offers Start a New Library in iCloud where the app can
    /// start one (`ICloudSyncActions.startNewLibrary`).
    public func offersNewLibrary(canStart: Bool) -> Bool { isLibraryRemoved && canStart }

    /// The library this device synced with is gone from iCloud: nothing to encrypt or erase there.
    public var isLibraryRemoved: Bool { problem == .libraryRemoved }

    /// Whether iCloud can't be used here now: signed out, iCloud Drive off, the container unreachable, a build
    /// without iCloud. Its glyph is the crossed-out cloud.
    public var isUnavailable: Bool {
        switch iCloud {
        case .signedOut, .iCloudDriveOff, .containerUnavailable, .unavailableInThisBuild: return !isFolderTransport || folder == nil
        default: return false
        }
    }

    /// Something needs the person: the status row's tile and the Settings row turn orange.
    public var needsAttention: Bool {
        switch iCloud {
        case .signedOut, .iCloudDriveOff, .containerUnavailable, .accountChanged, .previousFolderMissing, .previousFolderAccessLost:
            return true
        case .unavailableInThisBuild, .turnedOff, .checking:
            return false
        case .migrating:
            return problem != nil
        case .waitingForKey:
            return true
        case .connected:
            return problem != nil || encryption == .waitingForKey || otherInstallation
        }
    }

    /// The status row's glyph.
    public var symbol: String {
        if isUnavailable { return "icloud.slash" }
        return needsAttention ? "exclamationmark.icloud" : "icloud"
    }

    /// The spinner, for work without a bar of its own: a move that has counted its files shows its progress instead.
    public var isBusy: Bool {
        switch iCloud {
        case .checking: return true
        case .migrating(let progress): return progress.total == 0 && problem == nil
        case .connected: return isSyncing
        default: return isFolderTransport && folder != nil && isSyncing
        }
    }

    // MARK: Words

    /// Where sync stands, in a phrase: the iPhone's Settings row and status sheet, and the row in iCloud Sync before
    /// its time (`headline`). A state both apps show is said in the same words (`SyncStatus.shortText`).
    public var line: String {
        if isFolderTransport, folder != nil { return connectedLine }
        switch iCloud {
        case .checking: return SyncStatus.connecting.shortText
        case .connected: return connectedLine
        case .waitingForKey: return SyncStatus.waitingForKey.shortText
        case .iCloudDriveOff: return SyncStatus.iCloudDriveOff.shortText
        case .signedOut: return SyncStatus.signedOut.shortText
        case .migrating(let progress): return SyncStatus.migrating(progress).shortText
        case .accountChanged: return SyncStatus.accountChanged.shortText
        case .previousFolderMissing: return SyncStatus.previousFolderMissing.shortText
        case .previousFolderAccessLost: return SyncStatus.previousFolderAccessLost.shortText
        case .containerUnavailable(let reason): return SyncStatus.iCloudUnavailable(details: reason).shortText
        case .turnedOff: return SyncStatus.off.shortText
        case .unavailableInThisBuild: return SyncStatus.unavailableInThisBuild.shortText
        }
    }

    /// The status row in iCloud Sync: the line, with when sync last finished once it's up to date ("Up to date ·
    /// 11:42 AM"). With a problem, the line under the row says what's wrong, so the row says only when sync last
    /// finished.
    public func headline(now: Date = Date()) -> String {
        let attached = iCloud == .connected || (isFolderTransport && folder != nil)
        guard attached, !isSyncing, encryption != .waitingForKey else { return line }
        if problem != nil {
            guard let lastSync else { return "Not synced yet" }
            return "Last synced \(Self.time(lastSync, now: now))"
        }
        if line == SyncStatus.upToDate(at: now).shortText, let lastSync {
            return "\(line) · \(Self.time(lastSync, now: now))"
        }
        return line
    }

    /// Connected: what's moving, what waits, or that it's all exchanged.
    private var connectedLine: String {
        if encryption == .waitingForKey { return SyncStatus.waitingForKey.shortText }
        if isSyncing { return changesInFlight > 0 ? "Syncing \(Self.changes(changesInFlight))" : SyncStatus.syncing.shortText }
        if let problem { return Self.short(problem) }
        if pendingUploads > 0 { return SyncStatus.exchanged(uploads: pendingUploads, downloads: 0).shortText }
        if let courierWaiting, courierWaiting > 0 {
            return "Waiting to send \(courierWaiting) \(courierWaiting == 1 ? "item" : "items") to your Mac"
        }
        if hasMoreWork { return "Syncing… more to come" }
        if localChanges > 0 { return "\(Self.changes(localChanges).prefix(1).uppercased())\(Self.changes(localChanges).dropFirst()) waiting to sync" }
        if pendingDownloads > 0 { return SyncStatus.exchanged(uploads: 0, downloads: pendingDownloads).shortText }
        guard lastSync != nil else { return SyncStatus.preparing.shortText }
        return SyncStatus.upToDate(at: Date()).shortText
    }

    /// A problem's phrase for the status line: "iCloud storage is full", else "Sync paused".
    static func short(_ problem: SyncProblem) -> String {
        switch problem {
        case .storageFull: return SyncStatus.storageFull.shortText
        case .iCloudUnavailable(let details): return SyncStatus.iCloudUnavailable(details: details).shortText
        default: return SyncStatus.failure(details: "").shortText
        }
    }

    /// Everything exchanged and nothing waiting.
    public var isUpToDate: Bool { (iCloud == .connected || isFolderTransport) && folder != nil && line == SyncStatus.upToDate(at: Date()).shortText }

    /// What a pass's unfinished move from the previous sync folder still has to copy.
    public var remainingMigration: String? {
        guard let record = migration, record.switchedAt != nil, record.completedAt == nil,
              !record.abandoned, record.remainingFiles > 0 else { return nil }
        return "Copying \(record.remainingFiles) more \(record.remainingFiles == 1 ? "file" : "files") from the previous sync folder"
    }

    /// A problem's sentence, with its fix in words where no button gives it: iCloud storage is full, and nothing here
    /// opens iCloud's storage (the iPhone), so it says where to free some.
    public static func problemText(_ problem: SyncProblem, managesStorage: Bool) -> String {
        guard problem == .storageFull, !managesStorage else { return problem.text }
        return "\(problem.text) \(freeUpStorage)"
    }

    /// Where iCloud storage is freed up, in this device's settings.
    public static var freeUpStorage: String {
        #if os(macOS)
        "Free up space in System Settings › Apple Account › iCloud."
        #else
        "Free up space in Settings › Apple Account › iCloud."
        #endif
    }

    /// The fix the status row's action can't give on its own: where iCloud Drive is turned on, or where to sign in.
    public var footer: String? {
        switch iCloud {
        case .iCloudDriveOff:
            #if os(macOS)
            return "Turn it on in System Settings › Apple Account › iCloud."
            #else
            return "Turn it on in Settings › Apple Account › iCloud."
            #endif
        case .signedOut:
            #if os(macOS)
            return nil
            #else
            return "Sign in to your Apple Account in Settings."
            #endif
        default:
            return nil
        }
    }

    /// The Devices row's value: "Only this Mac", "1 other", "3 others".
    public func devicesSummary(now: Date = Date()) -> String {
        let others = devices.inUse(at: now).filter { !$0.isCurrentDevice }
        return others.isEmpty ? "Only this \(Self.device)" : others.count == 1 ? "1 other" : "\(others.count) others"
    }

    /// The older app still installed beside this one, in a sentence with what to do.
    public static let otherInstallationLine = "Daybook is also installed as an older app on this \(device). Delete the older app."

    /// The fix for a library that was removed from iCloud.
    public static let startNewLibraryTitle = LibraryWords.startNewLibrary

    /// Get Key from a device that couldn't be reached.
    public static func couldntReach(_ name: String) -> String {
        "Couldn’t reach \(name). Make sure both are on the same Wi‑Fi, then try again."
    }

    /// While waiting for the library's key: how to get it.
    public static let waitingForKeyLine = "Turn on iCloud Keychain, or get the key from another device."

    static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func changes(_ count: Int) -> String { count == 1 ? "1 change" : "\(count) changes" }
}

/// Whether the library in iCloud is encrypted, as Settings shows it.
public enum LibraryEncryptionShown: Equatable, Sendable {
    /// This build can't keep library keys: nothing to show.
    case unavailable
    case off
    case waitingForKey
    /// "On", or how much is left to encrypt; whether a recovery key was saved; and whether this device is the one
    /// encrypting the history now (the iPhone then offers cellular data for it).
    case on(status: String, hasRecoveryKey: Bool, encryptsHere: Bool)

    public init(_ state: LibraryEncryptionState) {
        switch state {
        case .unavailable: self = .unavailable
        case .off: self = .off
        case .waitingForKey: self = .waitingForKey
        case .on(let summary):
            self = .on(status: LibraryWords.encryptionStatus(summary), hasRecoveryKey: summary.hasRecoveryKey,
                       encryptsHere: LibraryWords.encryptsHere(summary))
        }
    }

    public var isOn: Bool { if case .on = self { return true } else { return false } }
}

/// Something the person asked for in Settings that couldn't be done: one plain sentence, with the system's own words
/// behind Details.
public struct SyncSettingsProblem: Equatable, Identifiable {
    public var message: String
    public var details: String?
    public var id: String { message + "\u{1F}" + (details ?? "") }

    public init(message: String, details: String? = nil) {
        self.message = message
        self.details = details.flatMap { $0.isEmpty || $0 == message ? nil : $0 }
    }

    /// Sync's own errors that are already a sentence are the message; anything else gets `fallback`, with its words
    /// behind Details.
    public init(error: Error, fallback: String) {
        if let error = error as? LibrarySyncError, error.isPlainSentence {
            self.init(message: error.localizedDescription)
        } else {
            self.init(message: fallback, details: error.localizedDescription)
        }
    }
}

// MARK: - The library's devices

/// How Settings names the library's devices and what each is doing, on both apps.
public enum LibraryDeviceWords {
    /// A device's name; one known only from the journal hasn't written a presence record: an earlier Daybook, or one
    /// that hasn't finished its first sync, so it can't be told which, or what kind of device it is.
    public static func name(_ device: KnownSyncDevice) -> String {
        device.displayName ?? (device.deviceClass == nil ? "A device that hasn’t checked in" : "Unnamed device")
    }

    /// "This Mac · Synced today, 11:42 AM", "Recording now · Transcribes and summarizes · Last seen today, 9:02 AM";
    /// nil when there's nothing to say.
    public static func detail(_ device: KnownSyncDevice, now: Date = Date()) -> String? {
        var parts: [String] = device.isCurrentDevice ? ["This \(ICloudSyncShown.device)"] : []
        if device.deviceClass == .mac, device.isRecording(at: now) { parts.append("Recording now") }
        if device.canProcess == true { parts.append("Transcribes and summarizes") }
        if let seen = device.lastSeen {
            parts.append(device.isCurrentDevice ? "Synced \(DeviceDateFormat.lastSeen(seen, now: now))" : RecorderStatusWords.lastSeen(seen, now: now))
        } else if device.isCurrentDevice {
            parts.append("Not synced yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
