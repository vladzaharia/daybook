import DaybookCore
import Foundation

/// Where library sync stands on this device, as `LibrarySyncController.status` publishes it. Both apps read the case,
/// never its words: `text` is the controller's sentence (logs, tests, and leftover readers), `shortText` the phrase both
/// apps' status lines say for it, and `problem` what needs the person, if anything.
public enum SyncStatus: Equatable, Sendable {
    /// Sync is off on this device: turned off, or never connected.
    case off
    /// This build can't use iCloud (unsigned and ad hoc development builds, tests).
    case unavailableInThisBuild
    /// No iCloud account is signed in.
    case signedOut
    /// iCloud Drive is off in System Settings.
    case iCloudDriveOff
    /// Looking for the library in iCloud.
    case connecting
    /// Connected; the first pass hasn't run yet.
    case preparing
    /// Passes wait for this device's recording or processing to finish.
    case deferred
    /// A pass is exchanging changes.
    case syncing
    /// A pass's changes are being applied to the library.
    case applying
    /// iCloud hasn't listed the library's folder yet; the pass runs again once it has.
    case waitingForICloud
    /// The library in iCloud is encrypted and this device doesn't hold its key yet.
    case waitingForKey
    /// This device's keychain can't be read right now (locked, or still starting up). It passes on its own.
    case keyStoreUnreadable
    /// The last pass finished with files still moving through iCloud.
    case exchanged(uploads: Int, downloads: Int)
    /// The last pass finished, with nothing left to move.
    case upToDate(at: Date)
    /// Copying the folder this Mac synced through before into iCloud.
    case migrating(SyncMigrationProgress)
    /// The copy into iCloud stopped on an error and tries again on its own.
    case migrationPaused(details: String)
    /// iCloud has no room for what this device sends.
    case storageFull
    /// Signed in to a different iCloud account from the one this library synced with.
    case accountChanged
    /// The Apple Account changed while syncing through a chosen folder (development builds).
    case folderAccountChanged
    /// The encrypted library this device synced with is gone from iCloud (someone deleted Daybook's data there). Sync
    /// waits for the person: `LibrarySyncController.startNewLibrary()` starts a new one.
    case libraryRemoved
    /// iCloud holds a library that isn't encrypted where this device synced an encrypted one. This device publishes
    /// nothing there, and syncs again once the library in iCloud is encrypted.
    case libraryNotEncrypted
    /// The folder this Mac synced through before can't be found.
    case previousFolderMissing
    /// The folder this Mac synced through before is there, but this build can't open it.
    case previousFolderAccessLost
    /// iCloud couldn't be reached. `details` is the system's reason; nil when iCloud isn't on for Daybook.
    case iCloudUnavailable(details: String?)
    /// The chosen sync folder couldn't be opened again (development builds).
    case reconnectFolder(details: String)
    /// A folder the person chose couldn't be used (development builds).
    case couldNotUseFolder(details: String)
    /// A pass failed. `details` is the system's reason.
    case failure(details: String)

    /// The controller's sentence for it.
    public var text: String {
        switch self {
        case .off: return "iCloud sync is off"
        case .unavailableInThisBuild: return "iCloud sync isn’t available in this build"
        case .signedOut: return "Signed out of iCloud"
        case .iCloudDriveOff: return "iCloud is off in System Settings"
        case .connecting: return "Connecting to iCloud…"
        case .preparing: return "Connected · preparing sync"
        case .deferred: return "Waiting for recording or local processing to finish"
        case .syncing: return "Syncing recordings and conversations…"
        case .applying: return "Applying library changes…"
        case .waitingForICloud: return LibrarySyncError.waitingForICloud.localizedDescription
        case .waitingForKey: return LibrarySyncError.keyUnavailable("").localizedDescription
        case .keyStoreUnreadable: return "Waiting to read this library’s key."
        case .exchanged(let uploads, let downloads): return "Waiting for iCloud: \(uploads) upload(s), \(downloads) download(s)"
        case .upToDate: return "Library changes exchanged"
        case .migrating(let progress):
            guard progress.total > 0 else { return "Preparing to move sync to iCloud…" }
            let waiting = progress.waitingForDownload > 0 ? " Waiting for iCloud to download \(progress.waitingForDownload)." : ""
            return "Migrating \(progress.completed) of \(progress.total) files…" + waiting
        case .migrationPaused(let details): return "Moving sync to iCloud paused: \(details)"
        case .storageFull: return "Sync paused: iCloud storage is full"
        case .accountChanged: return "Sync paused: the iCloud account changed"
        case .folderAccountChanged: return "Apple Account changed · reconnect the intended iCloud folder"
        case .libraryRemoved: return "Sync paused: the library in iCloud was removed"
        case .libraryNotEncrypted: return "Sync paused: the library in iCloud isn’t encrypted"
        case .previousFolderMissing: return "Sync paused: the folder this Mac synced through can’t be found"
        case .previousFolderAccessLost: return "Sync paused: choose the folder this Mac synced through again"
        case .iCloudUnavailable(let details?): return "Couldn’t connect to iCloud: \(details)"
        case .iCloudUnavailable(nil): return "iCloud isn’t available for Daybook. Check that iCloud Drive is on for Daybook in System Settings."
        case .reconnectFolder(let details): return "Reconnect your iCloud folder: \(details)"
        case .couldNotUseFolder(let details): return "Couldn’t use that folder: \(details)"
        case .failure(let details): return "Sync paused: \(details)"
        }
    }

    /// The phrase for a status line: the Mac's iCloud row in Settings › Library (`SyncShown.headline`) and the iPhone's
    /// sync line (`PhoneSync.statusLine`) say it for the same state, so the two apps word it alike.
    public var shortText: String {
        switch self {
        case .off: return "Off"
        case .unavailableInThisBuild: return "Not available in this build"
        case .signedOut: return "Signed out"
        case .iCloudDriveOff: return "iCloud Drive is off"
        case .connecting: return "Checking…"
        case .preparing, .deferred: return "Waiting to sync"
        case .syncing, .applying: return "Syncing…"
        case .waitingForICloud: return "Waiting for iCloud…"
        case .waitingForKey, .keyStoreUnreadable: return "Waiting for this library’s key"
        case .exchanged(let uploads, let downloads):
            if uploads > 0 { return "Uploading \(uploads) \(uploads == 1 ? "item" : "items") to iCloud" }
            if downloads > 0 { return "Waiting for iCloud to download \(downloads) \(downloads == 1 ? "item" : "items")…" }
            return "Up to date"
        case .upToDate: return "Up to date"
        case .migrating(let progress):
            return progress.total > 0 ? "Moving to iCloud · \(progress.completed) of \(progress.total) files" : "Moving to iCloud…"
        case .storageFull: return "iCloud storage is full"
        case .iCloudUnavailable: return "Not available right now"
        case .migrationPaused, .accountChanged, .folderAccountChanged, .libraryRemoved, .libraryNotEncrypted, .previousFolderMissing,
             .previousFolderAccessLost, .reconnectFolder, .couldNotUseFolder, .failure:
            return "Sync paused"
        }
    }

    /// What needs the person; nil while sync is working, waiting, or off by choice.
    public var problem: SyncProblem? {
        switch self {
        case .off, .unavailableInThisBuild, .signedOut, .iCloudDriveOff, .connecting, .preparing, .deferred, .syncing, .applying,
             .waitingForICloud, .waitingForKey, .keyStoreUnreadable, .exchanged, .upToDate, .migrating:
            return nil
        case .migrationPaused(let details): return .migrationPaused(details: details)
        case .storageFull: return .storageFull
        case .accountChanged: return .accountChanged
        case .folderAccountChanged: return .folderAccountChanged
        case .libraryRemoved: return .libraryRemoved
        case .libraryNotEncrypted: return .libraryNotEncrypted
        case .previousFolderMissing: return .previousFolderMissing
        case .previousFolderAccessLost: return .previousFolderAccessLost
        case .iCloudUnavailable(let details): return .iCloudUnavailable(details: details)
        case .reconnectFolder(let details): return .reconnectFolder(details: details)
        case .couldNotUseFolder(let details): return .couldNotUseFolder(details: details)
        case .failure(let details): return .failure(details: details)
        }
    }

    /// A pass is running: syncing or applying what it brought.
    public var isPassRunning: Bool { self == .syncing || self == .applying }
}

/// Sync needs the person: what happened, in a sentence (`text`), with the system's own words behind Details (`details`).
public enum SyncProblem: Equatable, Sendable {
    /// A pass failed.
    case failure(details: String)
    case storageFull
    case accountChanged
    case folderAccountChanged
    case libraryRemoved
    case libraryNotEncrypted
    case migrationPaused(details: String)
    case previousFolderMissing
    case previousFolderAccessLost
    case iCloudUnavailable(details: String?)
    case reconnectFolder(details: String)
    case couldNotUseFolder(details: String)

    public var text: String {
        switch self {
        case .failure: return "Sync is paused."
        case .storageFull: return "iCloud storage is full."
        case .accountChanged: return "This library synced with a different iCloud account."
        case .folderAccountChanged: return "Apple Account changed · reconnect the intended iCloud folder"
        case .libraryRemoved: return "The library in iCloud was removed."
        case .libraryNotEncrypted: return "The library in iCloud isn’t encrypted."
        case .migrationPaused: return "Moving to iCloud is paused."
        case .previousFolderMissing: return "Can’t find the folder this Mac synced through before."
        case .previousFolderAccessLost: return "Can’t open the folder this Mac synced through before."
        case .iCloudUnavailable: return "Couldn’t connect to iCloud."
        case .reconnectFolder: return "Reconnect your iCloud folder."
        case .couldNotUseFolder: return "Couldn’t use that folder."
        }
    }

    /// The system's words for it, when there are any.
    public var details: String? {
        switch self {
        case .failure(let details), .migrationPaused(let details), .reconnectFolder(let details), .couldNotUseFolder(let details):
            return details.isEmpty ? nil : details
        case .iCloudUnavailable(let details): return details
        case .storageFull, .accountChanged, .folderAccountChanged, .libraryRemoved, .libraryNotEncrypted, .previousFolderMissing,
             .previousFolderAccessLost:
            return nil
        }
    }
}

/// Something worth knowing about sync that doesn't stop it (`LibrarySyncController.warning`). The surface that shows
/// one words it.
public enum SyncWarning: Equatable, Sendable {
    /// Another installation of Daybook on this device syncs as it too, sharing its identity through the keychain: the
    /// iPhone app kept beside the one that replaced it. Both claim the same work, so the person deletes the older one.
    /// Said while the other one synced in the last day (`LibrarySyncController.otherInstallationWindow`).
    case otherInstallation
}
