import BackgroundTasks
import Combine
import DaybookKit
import Foundation
import Observation
import UIKit

/// Sync on iPhone: DaybookKit's `LibrarySyncController` with the phone replica configuration
/// (`.phone(displayName:)`: on-demand audio, presence, the audio cache budget) through Daybook's
/// iCloud container, run on a phone's cadence (docs/icloud-sync.md, "Phone cadence"):
///
/// - a pass on launch, on returning to the foreground, right after a recording or import is filed
///   (so its upload starts at once), and two seconds after an edit (the controller's debounce);
/// - while the app runs, the controller's 30-second check, which only lists the journal
///   (`hasRemoteChanges`) unless something changed here;
/// - in the background, `BGAppRefreshTask` passes with `.background` limits;
/// - passes are bounded (`.interactive` / `.background`); one that stops at its limits continues a
///   second later in the foreground.
///
/// A pull applies through `LibraryController.synchronize`, so the library (and every view of it)
/// updates live. The status line says what is true now: "Up to date", "Syncing 3 changes",
/// "iCloud isn't available because …".
@MainActor
@Observable
final class PhoneSync {
    enum Trigger: String, Sendable {
        case launch, foreground, edit, filed, remote, timer, backgroundRefresh, manual, linkFinished
        /// Triggers that may skip the pass when nothing changed on either side.
        var mayBeCheap: Bool { self == .timer || self == .remote }
    }

    enum Connection: Equatable {
        case checking
        /// Connected to the library's folder in the iCloud container (or, in tests and debug runs, a folder standing in for it).
        case connected(URL)
        case unavailable(String)
    }

    private(set) var connection: Connection = .checking
    private(set) var isSyncing = false
    /// Changes made here since the last completed pass (conversations, settings, Trash).
    private(set) var localChanges = 0
    /// Changes being sent in the pass running now.
    private(set) var changesInFlight = 0
    private(set) var lastSynced: Date?
    /// Why the last pass couldn't finish, in the controller's words.
    private(set) var lastError: String?
    private(set) var pendingUploads = 0
    private(set) var pendingDownloads = 0
    private(set) var hasMoreWork = false
    /// Every device known to the library (presence), most recently seen first. Empty until listed.
    private(set) var devices: [KnownSyncDevice] = []
    private(set) var devicesListed = false
    /// Conversations the last pass brought or changed here.
    private(set) var lastReceived: Set<UUID> = []
    /// Completed passes in this run (tests and diagnostics).
    private(set) var passes = 0
    /// The courier sending this iPhone's files to the Mac ahead of iCloud Drive, when there is one.
    private(set) var courier = CourierStatus()

    /// Nil for a library without sync (unit tests of other parts).
    let controller: LibrarySyncController?
    @ObservationIgnored private let library: LibraryController
    /// The conversation this phone is recording into, which a remote deletion must not touch.
    @ObservationIgnored var protectedConversation: () -> UUID? = { nil }
    /// After a pass that applied changes (the app model refreshes widgets and devices).
    @ObservationIgnored var onApplied: ((SyncApplied) -> Void)?
    /// Whether the scene is in the foreground; bounded passes continue right away only then.
    @ObservationIgnored var isForeground = true
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var rerun: Trigger?
    @ObservationIgnored private var continuation: Task<Void, Never>?
    @ObservationIgnored private var exchanged: Fingerprint?
    @ObservationIgnored private var lastPassAt: Date?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    @ObservationIgnored private var recount: Task<Void, Never>?

    static let refreshIdentifier = "local.daybook.phone.sync"
    /// Background refresh no more often than this (the system decides when, within it).
    static let refreshInterval: TimeInterval = 20 * 60
    /// A pass at least this often while running, so presence stays fresh even when nothing changes.
    static let presenceInterval: TimeInterval = 10 * 60

    init(library: LibraryController) {
        self.library = library
        controller = library.sync
        if controller == nil { connection = .unavailable("Sync isn't set up for this library.") }
        controller?.onSyncRequested = { [weak self] in await self?.synchronize(.remote) }
        controller?.$courierStatus.sink { [weak self] status in self?.courier = status }.store(in: &subscriptions)
        // Count local changes as they happen, shortly after, so a burst of typing counts once.
        library.objectWillChange.sink { [weak self] _ in self?.scheduleRecount() }.store(in: &subscriptions)
    }

    /// The phone replica: on-demand audio within `budget`, presence as this iPhone.
    static func replica(displayName: String, budget: UInt64, cloud: SyncCloudFiles = .system) -> SyncReplicaConfiguration {
        var replica = SyncReplicaConfiguration.phone(displayName: displayName, audioCache: AudioCachePolicy(budgetBytes: budget))
        replica.cloud = cloud
        return replica
    }

    // MARK: Connecting

    /// Connects to the library in Daybook's iCloud container, or says why it can't. Safe to call again
    /// (after an account change, or from Settings).
    func connect() async {
        guard let controller else { return }
        let availability = await CloudAvailability.check()
        switch availability {
        case .checking:
            connection = .checking
        case .unavailable(let reason):
            connection = .unavailable(reason)
        case .available:
            // The controller attaches the container itself: main's `restore()` is container-first on
            // iOS (account check, `<container>/Documents/Daybook`), using the replica set at launch. The
            // lookup runs in the background, so wait for it before deciding; on first launch it takes a
            // moment, and reading `folder` straight away reported iCloud as unavailable.
            if controller.folder == nil {
                connection = .checking
                controller.restore()
                await controller.waitForContainer()
            }
            if let folder = controller.folder {
                connection = .connected(folder)
            } else if case .containerUnavailable(let reason) = controller.iCloud {
                connection = .unavailable(reason)
            } else {
                connection = .unavailable("iCloud isn't available for Daybook right now. Try again in a moment.")
            }
        }
        watchAccount()
    }

    /// Connects to a folder standing in for the container: tests, and `--sync-folder` in debug runs.
    /// `monitor` turns on the controller's metadata query and 30-second check.
    func connect(toFolder folder: URL, monitor: Bool) throws {
        guard let controller else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try controller.connect(to: folder, monitorChanges: monitor)
        connection = .connected(controller.folder ?? folder)
    }

    private func watchAccount() {
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The controller lets go of the old account's folder; connect to the new one, if any.
                self.connection = .checking
                self.devices = []
                self.devicesListed = false
                Task { await self.connect(); await self.synchronize(.foreground) }
            }
        }
    }

    var isConnected: Bool { if case .connected = connection { return controller?.folder != nil } else { return false } }

    /// The sync engine while connected: on-demand audio, presence, the cheap remote check.
    var engine: LibrarySyncEngine? { isConnected ? controller?.engine : nil }

    // MARK: Passes

    /// One pass, or a cheap check when `trigger` allows and nothing changed on either side. A request
    /// while a pass runs is folded into one more pass after it. Returns when the work is done.
    func synchronize(_ trigger: Trigger) async {
        guard isConnected, library.isLoaded else { return }
        if let running {
            rerun = rerun ?? trigger
            await running.value
            return
        }
        let task = Task { await self.run(trigger) }
        running = task
        await task.value
        running = nil
        if let again = rerun {
            rerun = nil
            await synchronize(again)
        }
    }

    private func run(_ trigger: Trigger) async {
        guard let controller else { return }
        if trigger.mayBeCheap, localChangeCount() == 0, !hasMoreWork,
           let last = lastPassAt, Date().timeIntervalSince(last) < Self.presenceInterval,
           let engine = controller.engine, await !engine.hasRemoteChanges() {
            return
        }
        changesInFlight = localChangeCount()
        isSyncing = true
        let limits: SyncPassLimits = trigger == .backgroundRefresh ? .background : .interactive
        let applied = await library.synchronize(protecting: protectedConversation(), limits: limits)
        isSyncing = false
        changesInFlight = 0
        lastPassAt = Date()
        pendingUploads = controller.pendingUploads
        pendingDownloads = controller.pendingDownloads
        hasMoreWork = controller.hasMoreWork
        if let applied, applied.acknowledged {
            lastSynced = controller.lastSync ?? Date()
            lastError = nil
            exchanged = fingerprint()
            lastReceived = applied.changed
            passes += 1
            onApplied?(applied)
        } else if controller.status.hasPrefix(Self.pausedPrefix) {
            lastError = String(controller.status.dropFirst(Self.pausedPrefix.count))
        }
        recountLocalChanges()
        await refreshDevices()
        scheduleContinuation()
    }

    private static let pausedPrefix = "Sync paused: "

    /// A bounded pass that left work continues a second later, while the app is in front.
    private func scheduleContinuation() {
        continuation?.cancel()
        guard hasMoreWork, isForeground else { return }
        continuation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.synchronize(.manual)
        }
    }

    /// Lists the library's devices (presence) for "Waiting for your Mac · last seen 2 h ago".
    func refreshDevices() async {
        guard isConnected, let controller else { return }
        let listed = await controller.knownDevices()
        if listed != devices { devices = listed }
        devicesListed = true
    }

    /// The shared library's ID (the link tags its Bonjour browsing with it).
    func libraryID() async -> UUID? { isConnected ? await controller?.libraryID() : nil }

    // MARK: Background

    /// Asks iOS for a background refresh. Call when the app leaves the foreground.
    func scheduleBackgroundRefresh() {
        guard isConnected else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The `BGAppRefreshTask` body: one bounded pass, then the next request. iOS cancels the task
    /// when its time is up; the pass stops cleanly and an unacknowledged pull is offered again.
    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await synchronize(.backgroundRefresh)
    }

    /// Runs a pass that must not stop when the app goes to the background (a just-filed recording's
    /// upload), under a background-task assertion of a few seconds to a few minutes. The courier sends
    /// what the pass wrote under the same assertion.
    func synchronizeFinishing(_ trigger: Trigger) {
        let application = UIApplication.shared
        var assertion = UIBackgroundTaskIdentifier.invalid
        let pass = Task {
            await self.synchronize(trigger)
            await self.controller?.finishCourierSends()
        }
        assertion = application.beginBackgroundTask(withName: "Daybook sync") { pass.cancel() }
        Task {
            await pass.value
            if assertion != .invalid { application.endBackgroundTask(assertion) }
        }
    }

    // MARK: Status

    /// One line, true right now.
    var statusLine: String {
        switch connection {
        case .checking: return "Checking iCloud…"
        case .unavailable(let reason): return reason
        case .connected:
            if isSyncing { return changesInFlight > 0 ? "Syncing \(Self.changes(changesInFlight))" : "Syncing…" }
            if let lastError { return "Sync paused: \(lastError)" }
            if pendingUploads > 0 { return "Uploading \(pendingUploads) \(pendingUploads == 1 ? "item" : "items") to iCloud" }
            if let line = courierLine() { return line }
            if hasMoreWork { return "Syncing… more to come" }
            if localChanges > 0 { return "\(Self.changes(localChanges).capitalizedFirst) waiting to sync" }
            if pendingDownloads > 0 { return "Waiting for iCloud to download \(pendingDownloads) \(pendingDownloads == 1 ? "item" : "items")" }
            return lastSynced == nil ? "Waiting to sync" : "Up to date"
        }
    }

    /// "Last synced 2 min ago", or nil.
    func detailLine(now: Date = Date()) -> String? {
        guard isConnected, let lastSynced else { return nil }
        return "Last synced \(MacPresence.age(now.timeIntervalSince(lastSynced)))"
    }

    var isUpToDate: Bool {
        isConnected && !isSyncing && lastError == nil && localChanges == 0 && pendingUploads == 0 && !hasMoreWork && lastSynced != nil
            && courierLine() == nil
    }

    /// A send to the Mac by courier that has waited a while (`CourierStatus.stuckAfter`); nil otherwise.
    func courierLine(now: Date = Date()) -> String? {
        guard courier.isStuck(now: now) else { return nil }
        if courier.storageFull { return "iCloud storage is full" }
        let count = courier.waitingToSend
        return "Waiting to send \(count) \(count == 1 ? "item" : "items") to your Mac"
    }

    private static func changes(_ count: Int) -> String { count == 1 ? "1 change" : "\(count) changes" }

    // MARK: Local changes

    /// What the library looked like when it was last exchanged, to count changes since.
    private struct Fingerprint: Equatable {
        var meetings: [UUID: Date]
        var metadata: LibraryMetadata
        var trash: Set<UUID>
    }

    private func fingerprint() -> Fingerprint {
        Fingerprint(meetings: Dictionary(library.meetings.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a }),
                    metadata: library.metadata, trash: Set(library.trashedMeetingIDs()))
    }

    private func localChangeCount() -> Int {
        guard library.isLoaded else { return 0 }
        let now = fingerprint()
        // Before the first pass of this run, what's new here isn't known; the pass finds out.
        guard let exchanged else { return 0 }
        var count = 0
        for (id, updated) in now.meetings where exchanged.meetings[id] != updated { count += 1 }
        count += now.trash.subtracting(exchanged.trash).count
        if now.metadata != exchanged.metadata { count += 1 }
        return count
    }

    private func scheduleRecount() {
        guard recount == nil else { return }
        recount = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.recount = nil
            self?.recountLocalChanges()
        }
    }

    private func recountLocalChanges() {
        let count = isConnected ? localChangeCount() : 0
        if count != localChanges { localChanges = count }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
