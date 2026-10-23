import AppKit
import Combine
import DaybookCore
import Foundation

@MainActor
final class LibrarySyncController: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var isICloudLocation = false
    @Published private(set) var status = "iCloud sync is off"
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var pendingDownloads = 0
    @Published private(set) var pendingUploads = 0
    var onSyncRequested: (() async -> Void)?
    private let localRoot: URL
    private let defaults: UserDefaults
    private let deviceID: String
    private var engine: LibrarySyncEngine?
    private var activeTask: Task<SyncResult, Error>?
    private var pendingReceipt: UUID?
    private var polling: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var scopedURL: URL?
    private var configurationID = UUID()

    init(localRoot: URL, defaults: UserDefaults) {
        self.localRoot = localRoot; self.defaults = defaults
        deviceID = defaults.string(forKey: "syncDeviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "syncDeviceID")
        lastSync = defaults.object(forKey: "syncLastCompleted") as? Date
    }

    func restore() {
        guard let data = defaults.data(forKey: "syncFolderBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            try connect(to: url)
            if stale { try saveBookmark(url) }
        } catch { status = "Reconnect your iCloud folder: \(error.localizedDescription)" }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect your Daybook sync folder"
        panel.message = "Choose or create a private Daybook folder in iCloud Drive. Choose the same folder on your other Macs. All conversations, original recordings, notes, and library settings will sync there."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Connect library"
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: drive.path) { panel.directoryURL = drive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try connect(to: url); try saveBookmark(url) }
        catch { status = "Couldn’t connect: \(error.localizedDescription)" }
    }

    /// Distribution builds can supply their provisioned iCloud container in Info.plist.
    /// The current Developer ID preview also supports a user-selected iCloud Drive folder.
    func connectNativeContainer(identifier: String) async {
        let url = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)?.appendingPathComponent("Documents/Daybook", isDirectory: true)
        }.value
        guard let url else { status = "The iCloud container is unavailable. Check the Apple Account and this build’s provisioning."; return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try connect(to: url); try saveBookmark(url)
        } catch { status = "Couldn’t connect iCloud: \(error.localizedDescription)" }
    }

    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: "syncFolderBookmark")
    }

    func connect(to url: URL, monitorChanges: Bool = true) throws {
        guard !isSyncing else { throw SyncControllerError.busy }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root != local, !root.path.hasPrefix(local.path + "/"), !local.path.hasPrefix(root.path + "/") else { throw SyncControllerError.overlappingLibrary }
        stopMonitoring()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        do { engine = try LibrarySyncEngine(localRoot: localRoot, remoteRoot: url, deviceID: deviceID) }
        catch { scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil; throw error }
        folder = url; status = "Connected · preparing sync"; configurationID = UUID()
        isICloudLocation = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true || root.path.contains("/Library/Mobile Documents/")
        if monitorChanges { startMonitoring(url); requestSync() }
    }

    func disconnect() {
        guard !isSyncing else { return }
        configurationID = UUID(); stopMonitoring(); engine = nil; folder = nil
        defaults.removeObject(forKey: "syncFolderBookmark")
        status = "Sync is off. Local and iCloud copies are retained."; warnings = []; pendingDownloads = 0
    }

    func requestSync() {
        guard folder != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); guard !Task.isCancelled else { return }; await self?.onSyncRequested?() }
            catch { }
        }
    }

    func deferUntilIdle() { if folder != nil && !isSyncing { status = "Waiting for recording or local processing to finish" } }

    func synchronize(meetings: [Meeting], deletedMeetingIDs: Set<UUID>, metadata: Data) async throws -> SyncResult? {
        guard let engine, !isSyncing else { return nil }
        let generation = configurationID
        isSyncing = true; status = "Syncing recordings and conversations…"
        do {
            let task = Task { try await engine.synchronize(meetings: meetings, deletedMeetingIDs: deletedMeetingIDs, libraryMetadata: metadata) }
            activeTask = task
            let result = try await task.value
            activeTask = nil
            guard generation == configurationID else { isSyncing = false; return nil }
            pendingReceipt = result.checkpointID
            pendingDownloads = result.pendingDownloads; pendingUploads = result.pendingUploads; warnings = result.warnings
            status = "Applying library changes…"
            return result
        } catch {
            activeTask = nil; isSyncing = false; pendingReceipt = nil
            status = "Sync paused: \(error.localizedDescription)"; throw error
        }
    }

    func canApply(_ result: SyncResult) -> Bool { pendingReceipt == result.checkpointID && folder != nil }

    func acknowledge(_ result: SyncResult) async throws {
        guard let engine, canApply(result) else { throw SyncControllerError.busy }
        defer { isSyncing = false; pendingReceipt = nil }
        try await engine.acknowledge(result.checkpointID)
        guard canApply(result) else { throw SyncControllerError.busy }
        status = result.hasPendingTransfers ? "Waiting for iCloud: \(result.pendingUploads) upload(s), \(result.pendingDownloads) download(s)" : "Library changes exchanged"
        lastSync = Date(); defaults.set(lastSync, forKey: "syncLastCompleted")
    }

    func reportFailure(_ message: String) { isSyncing = false; pendingReceipt = nil; status = "Sync paused: " + message }

    private func startMonitoring(_ root: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
        query.notificationBatchingInterval = 2
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestSync() }
            })
        }
        self.query = query; query.start()
        // Reconcile after missed metadata events, sleep/wake, or a temporary offline period.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.onSyncRequested?()
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.activeTask == nil { self.isSyncing = false }
                self.activeTask?.cancel(); self.configurationID = UUID(); self.pendingReceipt = nil; self.stopMonitoring(); self.engine = nil; self.folder = nil
                self.defaults.removeObject(forKey: "syncFolderBookmark")
                self.status = "Apple Account changed · reconnect the intended iCloud folder"
            }
        })
    }

    private func stopMonitoring() {
        polling?.cancel(); polling = nil; debounce?.cancel(); debounce = nil
        query?.stop(); query = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }
}

private enum SyncControllerError: LocalizedError {
    case busy, overlappingLibrary
    var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current sync to finish before changing folders."
        case .overlappingLibrary: return "Choose a separate iCloud Drive folder, outside the local working library."
        }
    }
}
