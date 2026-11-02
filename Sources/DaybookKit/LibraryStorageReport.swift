import DaybookCore
import Foundation
import UniformTypeIdentifiers

/// How much room Daybook takes on this device (Settings › Storage on both apps): the library's audio, everything else
/// its conversations keep, and downloaded models. It's measured from the library's own files, so it's right whether or
/// not sync is on: an iPhone without iCloud, where every recording lives only on it, says how much audio it holds.
public struct LibraryStorageReport: Equatable, Sendable {
    /// Every recording's audio on this device: recorded or brought in here, synced from another device, or downloaded
    /// for playback.
    public var audio: Int64
    /// Of `audio`, what was downloaded for playback and can go back to iCloud. Nil where nothing is downloaded on
    /// demand (the Mac keeps every recording) or this device can't tell now (an iPhone with sync off).
    public var downloadedAudio: Int64?
    /// Everything else the library keeps: transcripts, notes, photos, captions, history, and sync's own records.
    public var conversations: Int64
    /// Models downloaded to this device.
    public var models: Int64

    public init(audio: Int64 = 0, downloadedAudio: Int64? = nil, conversations: Int64 = 0, models: Int64 = 0) {
        self.audio = audio
        self.downloadedAudio = downloadedAudio
        self.conversations = conversations
        self.models = models
    }

    /// Nothing measured yet.
    public static let empty = LibraryStorageReport()

    /// Of `audio`, what wasn't downloaded: recorded or brought in on this device (or synced to a device that keeps
    /// everything). Nil when downloads aren't told apart.
    public var recordedAudio: Int64? { downloadedAudio.map { max(0, audio - min($0, audio)) } }
    /// The library on this device: its audio and the rest.
    public var library: Int64 { audio + conversations }
    /// Everything Daybook keeps here.
    public var total: Int64 { library + models }

    /// The same, with this device's downloaded models.
    public func with(models bytes: Int64) -> LibraryStorageReport {
        var report = self
        report.models = max(0, bytes)
        return report
    }

    // MARK: Measuring

    /// Where a conversation's file sits under the library folder: "Meetings/<id>/<relative path>", the key `downloaded`
    /// is given in.
    public static func key(meetingID: UUID, relativePath: String) -> String {
        "Meetings/\(meetingID.uuidString)/\(relativePath)"
    }

    /// The downloads among an on-demand replica's local audio (`LibrarySyncEngine.cachedAudio()`), as keys for
    /// `measure`.
    public static func downloadedKeys(_ cached: [CachedAudio]) -> Set<String> {
        Set(cached.filter { $0.origin == .fetched }.map { key(meetingID: $0.meetingID, relativePath: $0.relativePath) })
    }

    /// Walks the library folder and adds up what's in it, reading sizes only. Audio is any file of an audio type,
    /// wherever it is (a conversation, the Trash, a recording being filed); `downloaded` names the ones downloaded for
    /// playback, and nil leaves downloads untold. Folders in `excluding` are left out, with all they hold: what's
    /// counted on its own, like the Mac's models, which it keeps in the library folder (`models`). Reads the disk, so
    /// call it off the main actor.
    public static func measure(libraryRoot: URL, downloaded: Set<String>? = nil, models: Int64 = 0, excluding: [URL] = [],
                               fileManager: FileManager = .default) -> LibraryStorageReport {
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var report = LibraryStorageReport(downloadedAudio: downloaded == nil ? nil : 0, models: max(0, models))
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return report }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // The walk's paths are under `root`, symbolic links resolved, so the folders left out are compared the same way.
        let excluded = Set(excluding.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for case let url as URL in walker {
            if !excluded.isEmpty, excluded.contains(url.standardizedFileURL.path) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            // Its length, as Finder and the sync engine's audio index count it.
            let bytes = Int64(values.fileSize ?? 0)
            guard isAudio(url) else {
                report.conversations += bytes
                continue
            }
            report.audio += bytes
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if let downloaded, path.hasPrefix(prefix), downloaded.contains(String(path.dropFirst(prefix.count))) {
                report.downloadedAudio? += bytes
            }
        }
        return report
    }

    /// A recording's audio by its type: AAC, WAV, CAF, MP3, and the rest.
    static func isAudio(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio)
    }
}

// MARK: - Words

/// Settings › Storage's words, the same on both apps: "1.2 GB of audio" for the row, and what the audio is.
public enum StorageWords {
    /// The Storage row's status line, and the status sheet's: "1.2 GB of audio", or "No audio on this iPhone".
    /// `here` is "this Mac" or "this iPhone".
    public static func audioSummary(bytes: Int64, here: String) -> String {
        bytes <= 0 ? "No audio on \(here)" : "\(ByteSize.format(bytes)) of audio"
    }

    /// What the audio is, under its figure: both kinds with their sizes, one kind without repeating the figure, or
    /// nil when there's none or downloads aren't told apart. `here` is "this iPhone".
    public static func audioBreakdown(_ report: LibraryStorageReport, here: String) -> String? {
        guard let downloaded = report.downloadedAudio, report.audio > 0 else { return nil }
        let fetched = min(report.audio, downloaded), recorded = report.audio - fetched
        switch (fetched > 0, recorded > 0) {
        case (true, true): return "\(ByteSize.format(fetched)) downloaded · \(ByteSize.format(recorded)) recorded on \(here)"
        case (true, false): return "Downloaded for playback"
        case (false, true): return "Recorded on \(here)"
        case (false, false): return nil
        }
    }

    /// The section's title: "On This iPhone", "On This Mac".
    public static func section(device: String) -> String { "On This \(device)" }
}
