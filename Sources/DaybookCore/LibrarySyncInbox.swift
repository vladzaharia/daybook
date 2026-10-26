import Foundation

/// A journal file by its place in the sync folder, as a courier carries it from the device that wrote it
/// to the others, ahead of iCloud Drive (docs/icloud-sync.md, "Courier (CloudKit)").
public struct SyncJournalFile: Codable, Hashable, Sendable {
    /// Relative to the sync folder: `Events/<SHA-256>.json`, `Metadata/<SHA-256>.json`, or `Blobs/<SHA-256>`.
    public var path: String
    /// The SHA-256 of the file's bytes, which is also its name.
    public var sha256: String
    public var size: Int64

    public init(path: String, sha256: String, size: Int64) {
        self.path = path; self.sha256 = sha256; self.size = size
    }

    /// The folders a courier may carry. The manifest and presence records never travel by courier.
    public static let directories = ["Events", "Metadata", "Blobs"]

    /// The folder, when the path is in one a courier may carry and names `sha256` (its content address).
    public var directory: String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, SyncFiles.isHash(sha256), size >= 0 else { return nil }
        switch parts[0] {
        case "Events", "Metadata": return parts[1] == "\(sha256).json" ? parts[0] : nil
        case "Blobs": return parts[1] == sha256 ? parts[0] : nil
        default: return nil
        }
    }

    public var isContentAddressed: Bool { directory != nil }

    /// The content address a file in `directory` is named by.
    static func address(of name: String, in directory: String) -> String {
        directory == "Blobs" || !name.hasSuffix(".json") ? name : String(name.dropLast(5))
    }
}

/// What became of a file a courier brought.
public enum CourierDelivery: Equatable, Sendable {
    /// Verified and kept in the inbox until iCloud Drive brings the sync folder's copy.
    case stored
    /// The sync folder's copy is downloaded already, or the inbox holds these bytes.
    case alreadyHave
    /// This replica hasn't read the library's manifest yet. Offer the file again after a pass.
    case waitingForLibrary
    /// A path a courier may not carry, another library, or bytes that don't match their SHA-256. Discarded.
    case rejected(String)

    /// Whether the courier can delete its copy: everything but `waitingForLibrary`.
    public var isSettled: Bool { self != .waitingForLibrary }
}

/// The courier inbox, `Sync/Inbox/<library ID>/` in the local library, laid out like the sync folder (`Events/`,
/// `Metadata/`, `Blobs/`). It holds verified files another device sent by courier until iCloud Drive brings the same
/// files into the sync folder. The engine lists the journal as the union of the two and reads the inbox's copy only
/// while the sync folder's isn't downloaded. Nothing from the inbox is written into the sync folder while the sender
/// may still upload it (a second device writing the same file there is how iCloud Drive makes conflict copies); only a
/// delivery that has waited `courierPromotionDelay` with no copy there at all is.
extension LibrarySyncEngine {
    nonisolated var inboxBase: URL { localRoot.appendingPathComponent("Sync/Inbox", isDirectory: true) }

    /// The inbox of the library this replica syncs, once its manifest has been read.
    func inboxRoot() -> URL? { libraryID.map { inboxBase.appendingPathComponent($0.uuidString, isDirectory: true) } }

    /// The courier's copy of a journal file or blob, when one is waiting in the inbox.
    func inboxCopy(_ relativePath: String) -> URL? {
        guard let root = inboxRoot() else { return nil }
        let url = root.appendingPathComponent(relativePath)
        guard (try? SyncFiles.noSymlinks(url, below: inboxBase)) != nil,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
    }

    /// Courier deliveries waiting in one folder of the inbox, by file name.
    func inboxNames(_ directory: String) -> [String] {
        guard let root = inboxRoot(),
              let names = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(directory, isDirectory: true).path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }
    }

    /// A journal folder as a pass sees it: the sync folder's entries (downloaded, evicted, or placeholders), plus
    /// courier deliveries iCloud Drive hasn't brought yet, all as sync-folder URLs.
    func journalListing(in name: String) throws -> [URL] {
        let listed = try journalFiles(in: name)
        let delivered = inboxNames(name).filter { $0.hasSuffix(".json") && SyncFiles.isHash(String($0.dropLast(5))) }
        guard !delivered.isEmpty else { return listed }
        let known = Set(listed.map(\.lastPathComponent))
        let directory = remoteRoot.appendingPathComponent(name, isDirectory: true)
        let added = delivered.filter { !known.contains($0) }.map { directory.appendingPathComponent($0) }
        return (listed + added).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads a journal entry from the sync folder when its copy is downloaded and matches its name, and otherwise from a
    /// courier delivery (asking iCloud for the sync folder's copy, so the delivery can be pruned). Without a delivery it
    /// reads exactly as before, requesting the download of an evicted entry.
    func readJournal(_ url: URL, in directory: String) throws -> Data {
        guard let delivered = inboxCopy("\(directory)/\(url.lastPathComponent)") else {
            return try SyncFiles.read(url, below: remoteRoot, cloud: cloud)
        }
        switch SyncFiles.itemState(url) {
        case .local:
            if let bytes = try? SyncFiles.read(url, below: remoteRoot, cloud: cloud),
               SyncDigest.sha256(data: bytes) == url.deletingPathExtension().lastPathComponent { return bytes }
        case .inCloud:
            try? cloud.requestDownload(url)
        case .absent:
            break
        }
        let bytes = try SyncFiles.coordinateRead(delivered, below: inboxBase) { try Data(contentsOf: $0) }
        // A delivery damaged after it was stored is discarded; iCloud Drive's copy takes over.
        guard SyncDigest.sha256(data: bytes) == url.deletingPathExtension().lastPathComponent else {
            discardDelivery(delivered)
            throw SyncPendingDownload()
        }
        return bytes
    }

    /// The courier's copy of an audio object to install from while the sync folder's copy isn't downloaded (or hasn't
    /// arrived). Asks iCloud for the sync folder's copy, so the delivery can be pruned once it's there.
    func courierBlob(_ sha256: String) -> URL? {
        guard let delivered = inboxCopy("Blobs/\(sha256)") else { return nil }
        let remote = blobURL(sha256)
        switch SyncFiles.itemState(remote) {
        case .local: return nil
        case .inCloud: try? cloud.requestDownload(remote); return delivered
        case .absent: return delivered
        }
    }

    /// Removes a delivery that no longer matches its SHA-256; iCloud Drive's copy takes over.
    func discardDelivery(_ url: URL) {
        guard (try? SyncFiles.noSymlinks(url, below: inboxBase)) != nil else { return }
        try? fm.removeItem(at: url)
    }

    /// Takes a file a courier brought from another device. It must be a journal entry or audio object named by its
    /// SHA-256, for this library, with bytes that match; it's then kept in the inbox. Nothing is written to the sync
    /// folder. A file the sync folder already holds downloaded isn't kept again.
    public func receiveCourierFile(_ file: SyncJournalFile, libraryID sender: UUID, contents: URL) throws -> CourierDelivery {
        try Task.checkCancellation()
        guard file.isContentAddressed else { return .rejected("A courier can’t deliver \(file.path).") }
        if libraryID == nil { libraryID = existingLibraryID() }
        guard let root = inboxRoot(), let libraryID else { return .waitingForLibrary }
        guard sender == libraryID else { return .rejected("\(file.path) belongs to another library.") }
        let remote = remoteRoot.appendingPathComponent(file.path)
        try SyncFiles.noSymlinks(remote, below: remoteRoot)
        if SyncFiles.itemState(remote) == .local { return .alreadyHave }
        if inboxCopy(file.path) != nil { return .alreadyHave }
        let destination = root.appendingPathComponent(file.path)
        try SyncFiles.noSymlinks(destination, below: inboxBase)
        let size = (try? contents.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap { $0.isRegularFile == true ? $0.fileSize : nil }
        guard let size, Int64(size) == file.size else { return .rejected("\(file.path) arrived incomplete.") }
        try LocalFiles.directory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: contents, to: temporary)
        guard try SyncDigest.sha256(fileURL: temporary) == file.sha256 else { return .rejected("\(file.path) arrived damaged.") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: destination)
        // When it arrived, for `courierPromotionDelay`.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return .stored
    }

    /// A delivery whose sync-folder copy hasn't appeared after this long (its sender went away before iCloud Drive
    /// uploaded it, or lost the file) is written into the sync folder from here, so every other device gets it too.
    /// Its name is its content, so a copy arriving from the sender as well is the same file.
    public static let courierPromotionDelay: TimeInterval = 24 * 60 * 60

    /// Deletes deliveries whose sync-folder copy is now downloaded and identical, and anything an interrupted delivery
    /// left behind. A delivery is never deleted before that: a pass may have applied it, and losing it would roll the
    /// conversation back. One that has waited `courierPromotionDelay` with no copy in the sync folder at all is written
    /// there. Returns how many deliveries are still waiting for iCloud Drive.
    @discardableResult
    public func pruneCourierInbox(now: Date = Date()) -> Int {
        guard let root = inboxRoot() else { return 0 }
        var waiting = 0
        for directory in SyncJournalFile.directories {
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names {
                let url = folder.appendingPathComponent(name)
                guard (try? SyncFiles.noSymlinks(url, below: inboxBase)) != nil else { continue }
                if name.hasPrefix(".") { try? fm.removeItem(at: url); continue }
                let remote = remoteRoot.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(name)
                let expected = SyncJournalFile.address(of: name, in: directory)
                let state = SyncFiles.itemState(remote)
                if state == .local,
                   (try? SyncFiles.coordinateRead(remote, below: remoteRoot) { try SyncDigest.sha256(fileURL: $0) }) == expected {
                    try? fm.removeItem(at: url)
                } else {
                    if state == .absent, let arrived = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                       now.timeIntervalSince(arrived) >= Self.courierPromotionDelay {
                        promoteDelivery(url, to: remote, expected: expected)
                    }
                    waiting += 1
                }
            }
        }
        return waiting
    }

    /// Writes a verified delivery into the sync folder where nothing holds its name. Best effort: a failure leaves it
    /// waiting in the inbox for the next pass.
    private func promoteDelivery(_ delivery: URL, to remote: URL, expected: String) {
        try? SyncFiles.coordinateWrite(remote, below: remoteRoot) { target in
            guard !self.fm.fileExists(atPath: target.path) else { return }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".promote-\(UUID().uuidString)")
            defer { try? self.fm.removeItem(at: temporary) }
            try SyncFiles.coordinateRead(delivery, below: inboxBase) { try self.fm.copyItem(at: $0, to: temporary) }
            guard try SyncDigest.sha256(fileURL: temporary) == expected else { discardDelivery(delivery); return }
            try self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try self.fm.moveItem(at: temporary, to: target)
        }
    }

    /// Deliveries in the inbox still waiting for iCloud Drive.
    public func courierInboxCount() -> Int {
        SyncJournalFile.directories.reduce(0) { $0 + inboxNames($1).count }
    }

    /// Copies a journal file this replica wrote, with a coordinated read, to `destination`, checking its SHA-256: a
    /// courier sends that copy, so iCloud evicting or replacing the sync folder's file can't change what's sent.
    public nonisolated func copyJournalFile(_ file: SyncJournalFile, to destination: URL) throws {
        guard file.isContentAddressed else { throw LibrarySyncError.invalidEvent(file.path) }
        let fm = FileManager.default
        let source = remoteRoot.appendingPathComponent(file.path)
        try SyncFiles.noSymlinks(source, below: remoteRoot)
        guard SyncFiles.itemState(source) == .local else { throw SyncPendingDownload() }
        let folder = destination.deletingLastPathComponent()
        try LocalFiles.directory(folder)
        let temporary = folder.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try SyncFiles.coordinateRead(source, below: remoteRoot) { try fm.copyItem(at: $0, to: temporary) }
        guard try SyncDigest.sha256(fileURL: temporary) == file.sha256 else { throw LibrarySyncError.invalidBlob(file.sha256) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
    }
}
