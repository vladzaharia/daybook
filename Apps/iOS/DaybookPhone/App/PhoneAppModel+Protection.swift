import DaybookCaptions
import DaybookKit
import Foundation

/// "Protect while iPhone is locked" (Settings › Storage; docs/iphone.md, "File protection"): the library's files can't
/// be read while the iPhone is locked (`LibraryProtection`), so what runs in the background waits for the unlock instead
/// of failing or reading a conversation that's there as one that isn't: loading the library, sync (its sealing and the
/// courier's sends), processing, Spotlight, the widgets' snapshots, and backups' rules. A recording still starts, records,
/// and stops while locked: it's kept in `Staging/`, as before.
extension PhoneAppModel {
    /// The library is kept locked while the iPhone is: the switch is on, or was just turned off and the library's files
    /// aren't all back to their usual classes yet.
    var libraryKeptLocked: Bool { settings.protectsWhileLocked || !protector.isSettled(protects: false) }

    /// The library's files can be read now.
    var libraryReadable: Bool { !libraryKeptLocked || environment.protectedData.isAvailable() }

    /// Returns once the library's files can be read.
    func waitUntilLibraryReadable() async {
        while !libraryReadable { await waitUntilUnlocked() }
    }

    /// Ties what reads the library in the background to whether it can be read, once, as the model is made.
    func wireProtection() {
        library.isReadable = { [weak self] in self?.libraryReadable ?? true }
        library.untilReadable = { [weak self] in await self?.waitUntilLibraryReadable() }
        sync.libraryReadable = { [weak self] in self?.libraryReadable ?? true }
        processor.services.protectedDataAvailable = { [weak self] in self?.environment.protectedData.isAvailable() ?? true }
        protector.isAvailable = { [weak self] in self?.environment.protectedData.isAvailable() ?? true }
        protector.untilAvailable = { [weak self] in await self?.waitUntilUnlocked() }
        protector.exemptions = { [weak self] in self?.protectionExemptions() ?? LibraryProtection.Exemptions() }
        // Switched off and every file back: what waited for the unlock needn't any more.
        protector.settled = { [weak self] in self?.protectionApplied() }
        conversationIndex?.untilWritable = { [weak self] in await self?.waitUntilLibraryReadable() }
        environment.protectedData.whenUnavailable { [weak self] in self?.libraryLocking() }
        protectionApplied()
        processor.conditions.protectedDataAvailable = environment.protectedData.isAvailable()
        // A run Daybook didn't finish goes on, and one the switch asks for and never began begins.
        protector.protect(settings.protectsWhileLocked)
    }

    /// The switch changed (Settings › Storage): the library's files (the widgets' snapshots with them) are re-protected
    /// in the background, and saved captions and Spotlight follow at once.
    func protectionChanged() {
        protector.protect(settings.protectsWhileLocked)
        protectionApplied()
        if let index = conversationIndex { index.use(spotlightIndexer) }
    }

    /// What follows the switch and the record of its last run: the class saved captions are filed with, and whether work
    /// under way stops at the lock.
    func protectionApplied() {
        captions.store.filedProtection = settings.protectsWhileLocked ? .complete : captions.store.protection
        processor.conditions.keepsLibraryLocked = libraryKeptLocked
    }

    /// Where Spotlight lists the library now.
    var spotlightIndexer: ConversationIndex.Indexer {
        settings.protectsWhileLocked ? environment.spotlightWhileLocked ?? environment.spotlight : environment.spotlight
    }

    /// The iPhone is locking: no processing starts, and, while the library is kept locked, work under way stops (a sync
    /// pass cleanly, to run again on the unlock) and files a save made with another class get theirs while they still can.
    func libraryLocking() {
        processor.conditions.protectedDataAvailable = false
        guard libraryKeptLocked else { return }
        sync.lockedOut()
        protector.keep(now: true)
    }

    /// The iPhone is unlocked (`protectedDataMayBeAvailable`): what waited for it goes on.
    func libraryUnlocked() {
        processor.conditions.protectedDataAvailable = true
        protector.resume()
        protector.keep()
        let waiting = publishesAfterUnlock
        publishesAfterUnlock = [:]
        for publish in waiting.values { publish() }
        if backupExclusionWaits { applyBackupExclusion() }
        sync.unlocked()
    }

    /// Runs `work` now if the library can be read, else once it can, the latest under `key` only.
    func whenLibraryReadable(_ key: String, _ work: @escaping @MainActor () -> Void) {
        guard libraryReadable else {
            publishesAfterUnlock[key] = work
            return
        }
        publishesAfterUnlock[key] = nil
        work()
    }

    /// What a pass over the library leaves as it is, and what's this iPhone's own: the captions of a recording in
    /// progress or waiting for an unlock (a locked iPhone writes them), and the audio and photos recorded here (class B
    /// when it's off, as filed).
    func protectionExemptions() -> LibraryProtection.Exemptions {
        var exemptions = LibraryProtection.Exemptions()
        let recording = [recorder.captureID, captions.activeMeetingID].compactMap { $0 } + afterUnlock.values.map(\.conversationID)
        exemptions.skipped = Set(recording).map { "LiveCaptions/\($0.uuidString)" }
        let installation = library.installationID
        for meeting in library.controller.meetings {
            let folder = "Meetings/\(meeting.id.uuidString)/"
            for track in meeting.tracks where track.deviceKind == PhoneDevice.kind && track.deviceSerial == installation {
                exemptions.madeHere.insert(folder + track.relativePath)
            }
            for photo in meeting.photos ?? [] where photo.origin?.kind == PhoneDevice.kind && photo.origin?.serial == installation {
                exemptions.madeHere.insert(folder + photo.relativePath)
            }
        }
        return exemptions
    }
}
