import AVFoundation
import DaybookCore
import Foundation

/// The files method, shared by every device kind: a watched folder of exported recordings.
///
/// It watches only a folder the person chose. A file must be unchanged across two scans before it
/// counts, so AirDrop and network copies aren't read half-written. Files are only read: Daybook
/// copies them into the library and never moves, renames, or deletes them. A file's ID is its name
/// and size, so a file already in the library is recognised on another Mac too.
@MainActor
public final class ImportFolderWatcher: ObservableObject, DeviceConnection {
    public static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "ogg", "opus"]

    public let method = ConnectionMethodKind.files
    public let capabilities: DeviceCapabilities = []
    @Published public private(set) var folder: URL?
    @Published public private(set) var recordings: [DeviceRecording] = []
    @Published public private(set) var inventoryUpdatedAt: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var problem: DeviceProblem?
    @Published public private(set) var lastImportDate: Date?
    /// Files in iCloud Drive that haven't downloaded to this Mac yet.
    @Published public private(set) var waitingForICloud = 0
    @Published public private(set) var isWatching = false
    public var onChange: (() -> Void)?

    public var status: DeviceStatus? { nil }
    public var lastConnectedAt: Date? { nil }
    public var isSetUp: Bool { folder != nil || storage.data(Keys.bookmark) != nil }

    public var state: ConnectionState {
        if problem != nil { return .unavailable }
        if folder == nil { return .notSetUp }
        return isWatching ? .connected : .notConnected
    }

    private let storage: DeviceStorage
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var scanning = false
    private var securityScope = false
    /// Files seen on the previous scan, by path.
    private var observations: [String: FileFingerprint] = [:]
    /// Recording IDs imported before (kept even if the conversation is later deleted, so a file
    /// isn't imported again on its own).
    private var completed: Set<String> = []
    private var urls: [String: URL] = [:]
    private var isDemo = false

    public enum Keys {
        public static let bookmark = "bookmark"
        public static let completed = "completed"
        public static let lastImport = "lastImport"
    }

    public init(storage: DeviceStorage, interval: Duration = .seconds(5)) {
        self.storage = storage
        self.interval = interval
    }

    /// "Watching · last import 2 hours ago" for the page and Settings.
    public var summary: String {
        if let problem {
            guard let name = folderDisplayName else { return problem.message }
            return problem == Self.missing ? "Can’t find \(name)." : "Choose \(name) again to keep importing."
        }
        guard let name = folderDisplayName else { return "No folder chosen" }
        if waitingForICloud > 0 {
            return waitingForICloud == 1 ? "Waiting for iCloud to download 1 file…" : "Waiting for iCloud to download \(waitingForICloud) files…"
        }
        guard isWatching else { return "Not watching \(name)." }
        guard let lastImportDate else { return "Watching \(name)" }
        return "Watching \(name) · last import \(DeviceDateFormat.relative(lastImportDate))"
    }

    /// "iCloud Drive › Daybook Import".
    public var folderDisplayName: String? { folder.map(Self.displayPath) }

    // A sandboxed Mac keeps access with a security-scoped bookmark; on iPhone a folder picked in
    // Files is security-scoped already and keeps a minimal bookmark. Both are polled, not observed.
    #if os(macOS)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.minimalBookmark]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    public func activate() {
        guard !isDemo else { return }
        completed = Set(storage.strings(Keys.completed))
        lastImportDate = storage.date(Keys.lastImport)
        guard let data = storage.data(Keys.bookmark) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, bookmarkDataIsStale: &stale)
            try watch(url)
            if stale, let refreshed = try? url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) {
                storage.set(refreshed, Keys.bookmark)
            }
        } catch {
            problem = Self.accessLost
            publish()
        }
    }

    /// Starts watching a folder the person chose, and remembers it.
    public func watch(_ url: URL) throws {
        stopWatching()
        securityScope = url.startAccessingSecurityScopedResource()
        let bookmark = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        storage.set(bookmark, Keys.bookmark)
        completed = Set(storage.strings(Keys.completed))
        folder = url
        problem = nil
        observations = [:]
        startPolling()
        publish()
    }

    public func connect() {
        if folder != nil { startPolling(); publish() } else { activate() }
    }

    /// Stops watching for now. The folder is remembered and its files are untouched.
    public func disconnect() {
        task?.cancel(); task = nil
        isWatching = false
        publish()
    }

    public func refresh() { scanSoon() }

    public func refreshIfStale() { scanSoon() }

    public func dismissProblem() { problem = nil; publish() }

    /// Stops watching and forgets the folder. Files in it are not touched.
    public func forget() {
        stopWatching()
        storage.removeAll()
        completed = []
        lastImportDate = nil
        recordings = []
        problem = nil
        publish()
    }

    public func shutDown() { stopWatching() }

    public func transfer(_ recording: DeviceRecording,
                  progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        guard let url = urls[recording.id], FileManager.default.fileExists(atPath: url.path) else {
            throw DeviceTransferError.unreadable("The file is no longer in the folder.")
        }
        progress(.finishing, recording.byteCount ?? 0)
        return TransferredAudio(url: url, isStaged: false)
    }

    /// Everything stable in the folder that hasn't been imported before.
    public func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] {
        guard isWatching else { return [] }
        return recordings.filter { !completed.contains($0.id) && links.imported[$0.id] == nil && !excluding.contains($0.id) }
    }

    public func didImport(_ recording: DeviceRecording) {
        completed.insert(recording.id)
        storage.set(Array(completed).sorted(), Keys.completed)
        lastImportDate = Date()
        storage.set(lastImportDate, Keys.lastImport)
        publish()
    }

    /// Whether a file was imported before, even if its conversation was later deleted.
    public func wasImported(_ id: String) -> Bool { completed.contains(id) }

    // MARK: Scanning

    private func startPolling() {
        guard !isDemo, folder != nil else { return }
        task?.cancel()
        isWatching = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopWatching() {
        task?.cancel(); task = nil
        if securityScope { folder?.stopAccessingSecurityScopedResource() }
        securityScope = false
        folder = nil
        isWatching = false
        waitingForICloud = 0
        urls = [:]
    }

    private func scanSoon() {
        guard folder != nil, isWatching, !isDemo else { return }
        Task { [weak self] in await self?.scan() }
    }

    public func scan() async {
        guard let folder, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
            if problem != nil { problem = nil; publish() }
        } catch {
            let next = FileManager.default.fileExists(atPath: folder.path) ? Self.accessLost : Self.missing
            if problem != next { problem = next; publish() }
            return
        }
        var pending = 0
        var stable: [DeviceRecording] = []
        var found: [String: URL] = [:]
        var seen: [String: FileFingerprint] = [:]
        for url in contents {
            let name = url.lastPathComponent
            // Older iCloud placeholders are hidden ".name.m4a.icloud" files.
            if name.hasPrefix(".") {
                if let original = Self.placeholderOriginalName(name), Self.isAudio(original) {
                    pending += 1
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
                continue
            }
            guard Self.isAudio(name), let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
                pending += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate else { continue }
            let fingerprint = FileFingerprint(path: url.path, size: size, modified: modified.timeIntervalSince1970)
            seen[url.path] = fingerprint
            // Unchanged since the last scan: finished copying.
            guard observations[url.path] == fingerprint else { continue }
            let id = Self.recordingID(name: name, size: size)
            found[id] = url
            stable.append(DeviceRecording(id: id, startedAt: nil, length: nil, byteCount: UInt64(size), fileName: name,
                                          addedAt: values.creationDate ?? modified))
        }
        observations = seen
        urls = found
        stable.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        let changed = stable != recordings || pending != waitingForICloud
        recordings = stable
        waitingForICloud = pending
        inventoryUpdatedAt = Date()
        if changed { publish() }
    }

    private func publish() { onChange?() }

    // MARK: Helpers

    /// "file:notes.m4a|20480".
    public static func recordingID(name: String, size: Int) -> String { "file:\(name)|\(size)" }

    public static func isAudio(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// ".notes.m4a.icloud" → "notes.m4a".
    public static func placeholderOriginalName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    /// One plain sentence for a file that didn't import.
    public static func failureMessage(_ error: Error) -> String {
        if case DaybookError.invalidAudio? = error as? DaybookError { return "Couldn’t read this file." }
        if case DaybookError.invalidAudio? = error as? DaybookError { return "Couldn’t read this file." }
        if (error as NSError).domain == AVFoundationErrorDomain { return "Couldn’t read this file." }
        if case DeviceTransferError.unreadable(let message)? = error as? DeviceTransferError { return message }
        return "Couldn’t import this file."
    }

    public static let missing = DeviceProblem(id: "folderMissing", title: "The import folder is missing",
                                       message: "Choose it again if it was moved or renamed.",
                                       actions: [.chooseFolder])
    public static let accessLost = DeviceProblem(id: "folderAccessLost", title: "Daybook can’t read the import folder",
                                          message: "Choose your import folder again to keep importing.", actions: [.chooseFolder])

    /// "iCloud Drive › Daybook Import", "Documents › Recorder", or the folder's name.
    public nonisolated static func displayPath(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " › ")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.pathComponents
        if components.count > home.count, Array(components.prefix(home.count)) == home {
            return components[home.count...].joined(separator: " › ")
        }
        return components.suffix(2).filter { $0 != "/" }.joined(separator: " › ")
    }

    #if DEBUG
    /// A representative state for screenshots. Never reads the disk.
    public func applyDemo(folder: URL?, recordings: [DeviceRecording], completed: Set<String>, lastImport: Date?,
                   waitingForICloud: Int = 0, problem: DeviceProblem? = nil) {
        isDemo = true
        self.folder = folder
        self.recordings = recordings
        self.completed = completed
        self.lastImportDate = lastImport
        self.waitingForICloud = waitingForICloud
        self.problem = problem
        self.isWatching = folder != nil
        self.inventoryUpdatedAt = Date()
    }
    #endif
}

public struct FileFingerprint: Equatable {
    public let path: String
    public let size: Int
    public let modified: TimeInterval

    public init(path: String, size: Int, modified: TimeInterval) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}
