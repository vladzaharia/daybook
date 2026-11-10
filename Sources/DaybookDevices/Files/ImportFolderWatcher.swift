import AVFoundation
import DaybookCore
import Foundation
import Observation

/// The files method, shared by every device kind: a watched folder of exported recordings.
///
/// It watches only a folder the person chose. A file counts once it's finished (`Stability`): unchanged
/// across two scans, last written at least 30 seconds ago, and its container readable, so AirDrop,
/// network copies, and slow writers aren't read half-written. Files are only read: Daybook
/// copies them into the library and never moves, renames, or deletes them. A file's ID is its
/// content digest, so different exports cannot collide merely by sharing a name and size.
@MainActor
@Observable
public final class ImportFolderWatcher: DeviceConnection {
    public nonisolated static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "ogg", "opus"]

    public let method = ConnectionMethodKind.files
    public let capabilities: DeviceCapabilities = []
    public private(set) var folder: URL?
    public private(set) var recordings: [DeviceRecording] = []
    public private(set) var inventoryUpdatedAt: Date?
    public private(set) var isRefreshing = false
    public private(set) var problem: DeviceProblem?
    public private(set) var lastImportDate: Date?
    /// Files in iCloud Drive that haven’t downloaded to this device yet.
    public private(set) var waitingForICloud = 0
    public private(set) var isWatching = false
    /// Where the folder was, when it's no longer watched because this build can't open it: in the App Sandbox a
    /// bookmark made before can stop working. Names the folder and starts Choose Folder… there (`suggestedFolder`).
    public private(set) var lastKnownFolder: URL?
    @ObservationIgnored public var onChange: (() -> Void)?

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
    @ObservationIgnored private var task: Task<Void, Never>?
    private var scanning = false
    private var securityScope = false
    /// Files seen on the previous scan, by path.
    @ObservationIgnored private var observations: [String: FileFingerprint] = [:]
    @ObservationIgnored private var digests: [String: (fingerprint: FileFingerprint, value: String)] = [:]
    @ObservationIgnored private var scanGeneration = UUID()
    /// Recording IDs imported before (kept even if the conversation is later deleted, so a file
    /// isn't imported again on its own).
    private var completed: Set<String> = []
    @ObservationIgnored private var urls: [String: URL] = [:]
    private var isDemo = false

    public enum Keys {
        public static let bookmark = "bookmark"
        /// A plain (not security-scoped) bookmark of the same folder: it still says where the folder is when the scoped
        /// one can't be opened.
        public static let location = "location"
        public static let completed = "completed"
        public static let lastImport = "lastImport"
    }

    /// When a file counts as finished, beyond being unchanged across two scans: last written at least `quiet` ago (a
    /// slow writer pausing between scans isn't done), and its container readable (an M4A or MP4 still being written has
    /// no index yet). One that can't be read once it has been unchanged for `unreadable` is listed anyway, so its
    /// import says why rather than it never appearing.
    public struct Stability: Equatable, Sendable {
        public var quiet: TimeInterval
        public var unreadable: TimeInterval

        public init(quiet: TimeInterval = 30, unreadable: TimeInterval = 300) {
            self.quiet = quiet
            self.unreadable = unreadable
        }
    }

    private let stability: Stability
    /// Whether each file's container could be read, as of its fingerprint.
    @ObservationIgnored private var readability: [String: (fingerprint: FileFingerprint, value: Bool)] = [:]

    public init(storage: DeviceStorage, interval: Duration = .seconds(5), stability: Stability = Stability()) {
        self.storage = storage
        self.interval = interval
        self.stability = stability
    }

    /// "Watching iCloud Drive › Daybook Import · Last import 2 hours ago", as the page's line and Settings say it.
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
        return "Watching \(name) · Last import \(DeviceDateFormat.relative(lastImportDate))"
    }

    /// "iCloud Drive › Daybook Import".
    public var folderDisplayName: String? { (folder ?? lastKnownFolder).map { Self.displayPath($0) } }

    /// Where Choose Folder… starts: the watched folder, or where it was.
    public var suggestedFolder: URL? { folder ?? lastKnownFolder }

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
            lastKnownFolder = storedLocation()
            problem = Self.accessLost
            publish()
        }
    }

    /// Where the folder was, from the plain bookmark.
    private func storedLocation() -> URL? {
        guard let data = storage.data(Keys.location) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
    }

    /// Starts watching a folder the person chose, and remembers it.
    public func watch(_ url: URL) throws {
        stopWatching()
        securityScope = url.startAccessingSecurityScopedResource()
        let bookmark = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
        storage.set(bookmark, Keys.bookmark)
        #if os(macOS)
        storage.set(try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), Keys.location)
        #endif
        completed = Set(storage.strings(Keys.completed))
        folder = url
        lastKnownFolder = nil
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
        lastKnownFolder = nil
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
        scanGeneration = UUID()
        digests = [:]
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

    /// Looks at the folder once. Listing it, reading each file's details (in iCloud Drive, a file provider that
    /// can be slow or offline), asking iCloud to download what isn't here, and hashing are done off the main
    /// actor; only what they found is applied here.
    public func scan() async {
        guard let folder, !scanning else { return }
        let generation = scanGeneration
        scanning = true
        defer { scanning = false }
        let surveyed = await Task.detached(priority: .utility) { Self.survey(folder) }.value
        guard generation == scanGeneration, !Task.isCancelled else { return }
        let survey: FolderSurvey
        switch surveyed {
        case .success(let found):
            survey = found
            if problem != nil { problem = nil; publish() }
        case .failure(let failure):
            let next = failure == .missing ? Self.missing : Self.accessLost
            if problem != next { problem = next; publish() }
            return
        }
        var stable: [DeviceRecording] = []
        var found: [String: URL] = [:]
        var seen: [String: FileFingerprint] = [:]
        var migratedCompletion = false
        for file in survey.files {
            let path = file.fingerprint.path
            seen[path] = file.fingerprint
            // Unchanged since the last scan, and last written a while ago: finished copying.
            guard observations[path] == file.fingerprint else { continue }
            let age = Date().timeIntervalSince1970 - file.fingerprint.modified
            guard age >= stability.quiet else { continue }
            // Its container can be read (once unchanged a long while, it counts anyway, and its import says why).
            let readable: Bool
            if let cached = readability[path], cached.fingerprint == file.fingerprint {
                readable = cached.value
            } else {
                readable = await Task.detached(priority: .utility) { Self.isReadableAudio(file.url) }.value
                guard generation == scanGeneration, !Task.isCancelled else { return }
                readability[path] = (file.fingerprint, readable)
            }
            guard readable || age >= stability.unreadable else { continue }
            let digest: String
            if let cached = digests[path], cached.fingerprint == file.fingerprint {
                digest = cached.value
            } else {
                let hashed = await Task.detached(priority: .utility) { Self.digest(of: file.url, unchangedFrom: file.fingerprint) }.value
                guard generation == scanGeneration, !Task.isCancelled else { return }
                guard let hashed else { continue }
                digest = hashed
                digests[path] = (file.fingerprint, digest)
            }
            let id = Self.recordingID(sha256: digest)
            // Old completion records have no digest. Adopt the first stable file they identify
            // once, preserving the person's previous import/deletion decision; future versions
            // and other folders are distinguished by their bytes.
            if completed.remove(Self.recordingID(name: file.name, size: file.fingerprint.size)) != nil {
                completed.insert(id)
                migratedCompletion = true
            }
            guard found[id] == nil else { continue }
            found[id] = file.url
            stable.append(DeviceRecording(id: id, startedAt: nil, length: nil, byteCount: UInt64(file.fingerprint.size), fileName: file.name,
                                          addedAt: file.addedAt))
        }
        observations = seen
        digests = digests.filter { seen[$0.key] != nil }
        readability = readability.filter { seen[$0.key] != nil }
        if migratedCompletion { storage.set(Array(completed).sorted(), Keys.completed) }
        urls = found
        stable.sort { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        let pending = survey.waitingForICloud
        let changed = stable != recordings || pending != waitingForICloud
        recordings = stable
        waitingForICloud = pending
        inventoryUpdatedAt = Date()
        if changed { publish() }
    }

    private nonisolated static let surveyKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                                                   .fileResourceIdentifierKey, .isUbiquitousItemKey,
                                                                   .ubiquitousItemDownloadingStatusKey]

    /// The folder's audio files with their details, in path order, and how many are still in iCloud (asked to
    /// download). Off the main actor: it reads the disk.
    nonisolated static func survey(_ folder: URL) -> Result<FolderSurvey, FolderSurvey.Failure> {
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: surveyKeys, options: [])
        } catch {
            return .failure(fileManager.fileExists(atPath: folder.path) ? .unreadable : .missing)
        }
        var survey = FolderSurvey()
        for url in contents.sorted(by: { $0.path < $1.path }) {
            let name = url.lastPathComponent
            // Older iCloud placeholders are hidden ".name.m4a.icloud" files.
            if name.hasPrefix(".") {
                if let original = placeholderOriginalName(name), isAudio(original) {
                    survey.waitingForICloud += 1
                    try? fileManager.startDownloadingUbiquitousItem(at: url)
                }
                continue
            }
            guard isAudio(name), let values = try? url.resourceValues(forKeys: Set(surveyKeys)) else { continue }
            if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
                survey.waitingForICloud += 1
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate else { continue }
            let fingerprint = FileFingerprint(path: url.path, size: size, modified: modified.timeIntervalSince1970,
                                              resourceID: values.fileResourceIdentifier.map { String(describing: $0) })
            survey.files.append(FolderSurvey.File(url: url, name: name, fingerprint: fingerprint, addedAt: values.creationDate ?? modified))
        }
        return .success(survey)
    }

    /// Whether the system can open the file as audio with something in it: a container still being written (an M4A
    /// whose index comes last) can't be. Off the main actor.
    nonisolated static func isReadableAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// The file's SHA-256, if it's still as `fingerprint` says once hashed (not mid-copy). Off the main actor.
    nonisolated static func digest(of url: URL, unchangedFrom fingerprint: FileFingerprint) -> String? {
        // The listing's URL keeps the details it was read with: read them afresh, or a file that changed while it
        // was hashed would look unchanged.
        var current = url
        current.removeAllCachedResourceValues()
        guard let hashed = try? AudioDigest.sha256(fileURL: url),
              let after = try? current.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
              after.fileSize == fingerprint.size, after.contentModificationDate?.timeIntervalSince1970 == fingerprint.modified,
              after.fileResourceIdentifier.map({ String(describing: $0) }) == fingerprint.resourceID else { return nil }
        return hashed
    }

    private func publish() { onChange?() }

    // MARK: Helpers

    /// "file:notes.m4a|20480".
    public nonisolated static func recordingID(name: String, size: Int) -> String { "file:\(name)|\(size)" }

    public nonisolated static func recordingID(sha256: String) -> String { "file:sha256:\(sha256)" }

    public nonisolated static func isAudio(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// ".notes.m4a.icloud" → "notes.m4a".
    public nonisolated static func placeholderOriginalName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
    }

    /// One plain sentence for a file that didn't import.
    public static func failureMessage(_ error: Error) -> String {
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

    /// "iCloud Drive › Daybook Import", "Documents › Recorder", or the folder's name. `home` is the person's own home
    /// folder (`UserHome`), not the sandbox container's.
    public nonisolated static func displayPath(_ url: URL, home: URL = UserHome.url) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " › ")
        }
        let home = home.standardizedFileURL.pathComponents
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

/// What one look at a watched folder found: plain values, read off the main actor.
struct FolderSurvey: Sendable {
    struct File: Sendable {
        let url: URL
        let name: String
        let fingerprint: FileFingerprint
        let addedAt: Date
    }

    enum Failure: Error, Equatable {
        /// The folder isn't there any more.
        case missing
        /// It's there, but this build can't read it.
        case unreadable
    }

    var files: [File] = []
    /// Audio files in iCloud Drive that aren't on this device yet, asked to download.
    var waitingForICloud = 0
}

public struct FileFingerprint: Equatable, Sendable {
    public let path: String
    public let size: Int
    public let modified: TimeInterval
    public let resourceID: String?

    public init(path: String, size: Int, modified: TimeInterval, resourceID: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.resourceID = resourceID
    }
}
