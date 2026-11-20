import DaybookKit
import Foundation
import Observation
import os
import UIKit

/// Audio for playback on the phone, which is an on-demand replica: conversations arrive without
/// their audio, and a recording downloads from iCloud the first time it's played
/// (`LibrarySyncEngine.fetchAudio`: progress, cancellation, integrity check, then an atomic install).
/// Downloads are kept within the cache budget, least recently played going back to iCloud first;
/// recordings made here are kept until iCloud has them.
///
/// Injected at the app root as `\.audioProvider`. Without sync (no iCloud) it serves the files
/// already on this iPhone and says plainly when a recording isn't here.
///
/// It also says how much audio is on this iPhone (`usage`, Settings › Storage and the status sheet): measured from
/// the library's files, so it's right with sync off, when every recording lives only here. It's measured again at
/// launch, when a recording is filed or imported or a conversation goes, after a download, and after eviction.
///
/// Audio goes back to iCloud (within the budget, by the same proof as ever: `LibrarySyncEngine.evictAudio`) at launch,
/// after a download, when the budget changes, when a sync pass finds iCloud has just confirmed an upload, when a
/// conversation's processing here ends, and as the app goes to the background (`evictLeavingForeground`). Audio of a
/// conversation this iPhone still has work on (`needsAudio`) is never taken back until that work is done or given up.
@MainActor
@Observable
final class SyncAudioProvider: AudioProviding {
    /// Downloads in flight, by track, for "Downloading… 40%".
    private(set) var downloads: [UUID: Double] = [:]
    /// The audio on this iPhone and the budget, after the last check.
    private(set) var usage = CacheUsage()
    /// What the library takes on this iPhone, after the last check (Settings › Storage adds the models). Nil until
    /// it's first measured.
    private(set) var report: LibraryStorageReport?

    @ObservationIgnored private let library: PhoneLibrary
    @ObservationIgnored private let sync: PhoneSync
    @ObservationIgnored private var budget: UInt64
    /// Tracks asked for recently (likely playing): eviction never removes them.
    @ObservationIgnored private var recent: [UUID: Date] = [:]
    /// How long a track counts as possibly playing: spared by budget eviction for `keepWindow`, and by
    /// Clear Downloaded Audio for `playingWindow`.
    @ObservationIgnored var keepWindow: TimeInterval = 30 * 60
    @ObservationIgnored var playingWindow: TimeInterval = 60
    @ObservationIgnored let options: AudioFetchOptions
    /// Conversations this iPhone still needs the audio of: processing it will run, or a recording a Mac waits for that
    /// isn't sent yet. Set by the app (`PhoneAppModel`); their recordings are spared like the ones being played.
    @ObservationIgnored var needsAudio: @MainActor () -> Set<UUID> = { [] }
    /// How long a request for eviction waits for others to join it.
    @ObservationIgnored var evictionDelay: Duration = .milliseconds(1500)
    /// Asks iOS for time to finish in the background, calling `expired` if it runs out first; returns what ends it.
    @ObservationIgnored var holdsBackgroundTime: @MainActor (_ expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { expired in
        let application = UIApplication.shared
        var assertion = UIBackgroundTaskIdentifier.invalid
        let end: @MainActor () -> Void = {
            if assertion != .invalid { application.endBackgroundTask(assertion); assertion = .invalid }
        }
        assertion = application.beginBackgroundTask(withName: "Daybook storage") { MainActor.assumeIsolated { expired(); end() } }
        return end
    }
    /// The eviction waiting for others to join it, or running; one at a time.
    @ObservationIgnored private var scheduledEviction: Task<Void, Never>?
    @ObservationIgnored private var evictionRunning = false
    @ObservationIgnored private var evictAgain = false
    @ObservationIgnored private var evictionGeneration = 0
    /// How many times eviction ran (tests).
    @ObservationIgnored private(set) var evictions = 0
    /// Measures again when the library's recordings change: one filed or imported, a conversation moved to the Trash.
    @ObservationIgnored private var recordingsWatch: ObservationWatch?
    @ObservationIgnored private var measuring: Task<Void, Never>?
    /// Walks can overlap (a play, eviction, Clear Downloaded Audio): each is numbered as it starts, and one that
    /// started before the figure shown never replaces it.
    @ObservationIgnored private var measuresStarted = 0
    @ObservationIgnored private var measureShown = 0
    /// Walks the library folder, off the main actor (tests hold it to see what waits for it).
    @ObservationIgnored var measure: @Sendable (_ libraryRoot: URL, _ downloaded: Set<String>?) -> LibraryStorageReport = {
        LibraryStorageReport.measure(libraryRoot: $0, downloaded: $1)
    }

    private static let log = Logger(subsystem: "local.daybook.phone", category: "Audio")

    struct CacheUsage: Equatable, Sendable {
        /// Audio Daybook keeps on this iPhone: recordings made or brought in here, and downloads.
        var bytes: UInt64 = 0
        /// Of that, downloads that can go back to iCloud.
        var downloadedBytes: UInt64 = 0
        var budget: UInt64 = 0
        /// The audio files sync tracks for eviction (none without sync).
        var items = 0
    }

    init(library: PhoneLibrary, sync: PhoneSync, budget: UInt64, options: AudioFetchOptions = AudioFetchOptions()) {
        self.library = library
        self.sync = sync
        self.budget = budget
        self.options = options
        let controller = library.controller
        recordingsWatch = ObservationWatch.distinctValues(of: { Set(controller.meetings.flatMap { $0.tracks.map(\.id) }) }, initial: false,
                                                          delay: .seconds(1)) { [weak self] _ in
            self?.measureSoon()
        }
    }

    private var engine: LibrarySyncEngine? { sync.engine }

    // MARK: AudioProviding

    func localAudio(for track: RecordingTrack, in meetingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await localAudio(for: track, in: meetingID) { (fetch: AudioFetchProgress) in progress(Self.fraction(fetch)) }
    }

    /// The same, with the engine's phases (waiting for the recording to upload elsewhere, downloading, copying).
    func localAudio(for track: RecordingTrack, in meetingID: UUID,
                    phases: @escaping @MainActor (AudioFetchProgress) -> Void) async throws -> URL {
        guard library.controller.meeting(meetingID) != nil else { throw AudioProvidingError.missing }
        recent[track.id] = Date()
        guard let engine else {
            let url = try await library.audioURL(for: track, in: meetingID)
            // Not on this iPhone, and without sync there's no way to fetch it now.
            guard FileManager.default.fileExists(atPath: url.path) else { throw AudioProvidingError.offline }
            phases(AudioFetchProgress(phase: .installed))
            return url
        }
        downloads[track.id] = 0
        defer { downloads[track.id] = nil }
        // Anything before "installed" means it wasn't here yet: a download, maybe making room for it.
        let fetched = OSAllocatedUnfairLock(initialState: false)
        let url = try await engine.fetchAudio(for: track, in: meetingID, options: options) { [weak self] fetch in
            if fetch.phase != .installed { fetched.withLock { $0 = true } }
            Task { @MainActor [weak self] in
                guard let self, self.downloads[track.id] != nil else { return }
                self.downloads[track.id] = Self.fraction(fetch)
                phases(fetch)
            }
        }
        await engine.noteAudioPlayed(trackID: track.id, in: meetingID)
        // Playback, sharing and processing don't wait for the library to be measured.
        if fetched.withLock({ $0 }) { measureSoon() }
        return url
    }

    func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability {
        guard let meeting = library.controller.meeting(meetingID) else { return .missing }
        if let engine {
            // The track's size isn't recorded on it, so the download size stays unknown.
            return engine.audioAvailability(for: meeting)[track.id] == .local ? .local : .downloadable(bytes: nil)
        }
        let directory = library.rootURL.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(track.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? .local : .offline
    }

    // MARK: The cache

    /// Settings › Storage › Keep Up To; at launch with the saved choice, which also measures what's here (soon after,
    /// so launch doesn't wait for the library to be walked).
    func setBudget(_ bytes: UInt64) async {
        budget = bytes
        guard let engine else { return measureSoon() }
        await engine.setAudioCachePolicy(AudioCachePolicy(budgetBytes: bytes))
        _ = await evict()
    }

    /// Brings local audio within the budget, sparing what's playing or was just asked for, and measures again soon after.
    @discardableResult
    func evict() async -> AudioEvictionReport? {
        guard let engine else { return nil }
        var report: AudioEvictionReport?
        do { report = try await engine.evictAudio(protecting: protectedTracks(within: keepWindow)) } catch is CancellationError {
            // The background time ran out: what wasn't removed stays, and the next eviction picks it up.
        } catch {
            // Nothing is lost: what wasn't removed stays, and the next eviction tries again.
            Self.log.error("Couldn’t bring audio within the budget: \(error.localizedDescription)")
        }
        measureSoon()
        return report
    }

    /// Evicts shortly, once for a burst of requests: a sync pass that found an upload confirmed, a job that ended. A
    /// request while it runs asks for one more run after it.
    func evictSoon() {
        guard engine != nil else { return }
        guard scheduledEviction == nil else {
            if evictionRunning { evictAgain = true }
            return
        }
        scheduleEviction(after: evictionDelay)
    }

    /// The app is going to the background: evicts now, under the background time iOS gives (cancelled if it runs out).
    /// Never waits: the app leaves the foreground as it would have. An eviction already under way carries on.
    func evictLeavingForeground() {
        guard engine != nil, !evictionRunning else { return }
        let end = holdsBackgroundTime { [weak self] in self?.cancelEviction() }
        scheduleEviction(after: .zero, finishing: end)
    }

    private func cancelEviction() {
        scheduledEviction?.cancel()
    }

    private func scheduleEviction(after delay: Duration, finishing end: (@MainActor () -> Void)? = nil) {
        scheduledEviction?.cancel()
        evictionGeneration += 1
        let mine = evictionGeneration
        evictAgain = false
        scheduledEviction = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { end?(); return }
            guard !Task.isCancelled, self.evictionGeneration == mine else {
                end?()
                if self.evictionGeneration == mine { self.scheduledEviction = nil }
                return
            }
            self.evictionRunning = true
            self.evictions += 1
            await self.evict()
            end?()
            guard self.evictionGeneration == mine else { return }
            self.evictionRunning = false
            self.scheduledEviction = nil
            if self.evictAgain { self.evictAgain = false; self.evictSoon() }
        }
    }

    /// Clear Downloaded Audio: every download goes back to iCloud (it plays again by downloading).
    /// Recordings made on this iPhone stay until the budget needs their space.
    @discardableResult
    func clearDownloaded() async -> UInt64 {
        guard let engine else { return 0 }
        await engine.setAudioCachePolicy(AudioCachePolicy(budgetBytes: 0, evictsUploadedOriginals: false))
        var report: AudioEvictionReport?
        do { report = try await engine.evictAudio(protecting: protectedTracks(within: playingWindow)) } catch {
            Self.log.error("Couldn’t clear downloaded audio: \(error.localizedDescription)")
        }
        await engine.setAudioCachePolicy(AudioCachePolicy(budgetBytes: budget))
        await refreshUsage()
        return report?.bytesFreed ?? 0
    }

    /// Measures the audio on this iPhone from the library's files, telling downloads apart while sync tracks them.
    /// Reads the disk off the main actor.
    func refreshUsage() async {
        measuresStarted += 1
        let started = measuresStarted
        let root = library.rootURL
        var downloaded: Set<String>?
        var items = 0
        if let engine {
            let cached = await engine.cachedAudio()
            BackupExclusion.excludeDownloads(cached, libraryRoot: root)
            downloaded = LibraryStorageReport.downloadedKeys(cached)
            items = cached.count
        }
        let measure = self.measure
        let measured = await Task.detached(priority: .utility) { measure(root, downloaded) }.value
        // A newer walk already finished: this one may count what's gone since, like downloads just cleared.
        guard started > measureShown else { return }
        measureShown = started
        report = measured
        let next = CacheUsage(bytes: UInt64(max(0, measured.audio)), downloadedBytes: UInt64(max(0, measured.downloadedAudio ?? 0)),
                              budget: budget, items: items)
        if next != usage { usage = next }
    }

    /// Measures again shortly, once for a burst of changes.
    private func measureSoon() {
        measuring?.cancel()
        measuring = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshUsage()
        }
    }

    private func protectedTracks(within window: TimeInterval, now: Date = Date()) -> Set<UUID> {
        recent = recent.filter { now.timeIntervalSince($0.value) < max(keepWindow, playingWindow) }
        let needed = needsAudio().flatMap { library.controller.meeting($0)?.tracks.map(\.id) ?? [] }
        return Set(recent.filter { now.timeIntervalSince($0.value) < window }.keys).union(downloads.keys).union(needed)
    }

    /// One figure for a progress bar: downloading fills most of it, copying and checking the rest.
    nonisolated static func fraction(_ progress: AudioFetchProgress) -> Double {
        switch progress.phase {
        case .waitingForUpload: return 0
        case .downloading: return 0.9 * (progress.downloadFraction ?? 0)
        case .copying: return 0.9 + 0.1 * (progress.fractionCompleted ?? 0)
        case .installed: return 1
        }
    }
}
