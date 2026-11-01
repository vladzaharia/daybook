import DaybookKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Marks what changed between two versions word by word (`WordChanges`): removed words struck through
/// in magenta, inserted words washed in mint, over the text's own styling. The Mac's Version History
/// draws the same marks.
enum WordDiff {
    static func tokens(_ text: String) -> [Substring] { WordChanges.tokens(text) }
    static func changes(old: [Substring], new: [Substring]) -> (removed: IndexSet, inserted: IndexSet) { WordChanges.changes(old: old, new: new) }

    static func marked(old: String, new: String, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        marked(old: AttributedString(old), new: AttributedString(new), dark: dark)
    }

    /// In dark mode the washes are stronger and an inserted word is itself neon mint.
    static func marked(old: AttributedString, new: AttributedString, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        var removed = AttributeContainer(), inserted = AttributeContainer()
        removed.strikethroughStyle = Text.LineStyle(pattern: .solid, color: PhoneStyle.neonMagenta)
        removed.backgroundColor = PhoneStyle.neonMagenta.opacity(dark ? 0.20 : 0.16)
        inserted.backgroundColor = PhoneStyle.neonMint.opacity(dark ? 0.22 : 0.16)
        if dark { inserted.foregroundColor = PhoneStyle.neonMint }
        return WordChanges.marked(old: old, new: new, removed: removed, inserted: inserted)
    }
}

/// Words for a recording in Info › Audio, as the Mac's inspector says them from its side
/// (`RecordingWords`): its name, where it was made when the name doesn't say ("Your Mac"), and,
/// only when the conversation has several recordings, how it lines up.
@MainActor
enum SourceDescription {
    static func name(_ track: RecordingTrack, in meeting: Meeting) -> String {
        RecordingWords.name(track, in: meeting)
    }

    static func symbol(_ track: RecordingTrack) -> String {
        if track.deviceKind == PhoneDevice.kind { return "iphone" }
        switch track.source {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "recordingtape"
        case .imported: return "doc"
        }
    }

    /// "Your Mac · The main recording", "Lined up by sound · starts 0:12"; nil when there's nothing to say.
    static func line(_ track: RecordingTrack, in meeting: Meeting) -> String? {
        RecordingWords.line(track, in: meeting, mac: "Your Mac", pending: "Lines up when your Mac processes it")
    }

    static func isUnaligned(_ track: RecordingTrack, in meeting: Meeting) -> Bool {
        RecordingWords.isUnaligned(track, in: meeting)
    }
}

/// Conversations in the library's Trash folder. The store keeps their audio and notes; the
/// controller lists only their IDs, so their saved metadata is read here, for the Trash list.
enum TrashedConversations {
    static func load(rootURL: URL, ids: [UUID]) -> [Meeting] {
        let decoder = JSONDecoder()
        return ids.compactMap { id in
            let directory = rootURL.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
            for name in ["meeting.json", "meeting.recovery.json"] {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                   let meeting = try? decoder.decode(Meeting.self, from: data), meeting.id == id {
                    return meeting
                }
            }
            return nil
        }
        .sorted { $0.date > $1.date }
    }
}

/// Files handed to the share sheet: the conversation as Markdown, named after its title. They wait in
/// `tmp/Daybook Export/` and are removed once the share sheet is done with them, and at launch.
enum ExportFiles {
    static func root(in directory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory.appendingPathComponent("Daybook Export", isDirectory: true)
    }

    /// Removes the export folders holding `urls`, or every export when nil. A URL outside the export
    /// folder (a library original) is never touched.
    static func clear(_ urls: [URL]? = nil, in directory: URL = FileManager.default.temporaryDirectory) {
        let root = root(in: directory)
        guard let urls else { try? FileManager.default.removeItem(at: root); return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for url in urls where url.isFileURL {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard path.count > rootPath.count, Array(path.prefix(rootPath.count)) == rootPath else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path[rootPath.count], isDirectory: true))
        }
    }

    /// A photo-bearing export is one ZIP, so sharing keeps the Markdown's relative links intact.
    static func markdownWithPhotos(_ meeting: Meeting, originals: [UUID: URL],
                                   in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !meeting.visiblePhotos.isEmpty else { return try markdown(meeting, in: directory) }
        let name = fileName(meeting.title)
        let folder = root(in: directory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = folder.appendingPathComponent(name, isDirectory: true)
        try MeetingExport.write(meeting, to: package, name: name) { originals[$0.id] }
        let archive = folder.appendingPathComponent(name + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .forUploading, error: &coordinationError) { uploaded in
            do { try FileManager.default.copyItem(at: uploaded, to: archive) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError as NSError? { throw error }
        return archive
    }

    static func markdown(_ meeting: Meeting, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root(in: directory).appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(meeting.title) + ".md")
        try MeetingExport.markdown(meeting).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One photo for the share sheet, named after its caption and re-encoded with only its orientation
    /// and capture time (`ExportPhoto`): no location or camera details. The library's original stays.
    static func photo(_ original: URL, caption: String?, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root(in: directory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let file = ExportPhoto.write(original, to: folder, name: fileName(caption.map { String($0.prefix(60)) } ?? "Photo")) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileReadCorruptFile)
        }
        return folder.appendingPathComponent(file)
    }

    /// The recording, under the conversation's name, so the share sheet doesn't offer "iPhone recording.m4a".
    @MainActor
    static func audio(_ source: URL, meeting: Meeting, track: RecordingTrack, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root(in: directory).appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = meeting.tracks.count > 1 ? " (\(SourceDescription.name(track, in: meeting)))" : ""
        let url = folder.appendingPathComponent(fileName(meeting.title) + fileName(suffix))
            .appendingPathExtension(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// A file name without path separators or characters Files and Mail refuse.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(120))
    }
}

/// Copy for conversation content: it stays on this iPhone (`.localOnly`) rather than going to
/// Universal Clipboard on nearby devices signed in to the same Apple Account.
enum LocalPasteboard {
    static func copy(_ text: String, to pasteboard: some LocalPasteboardWriting = UIPasteboard.general) {
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}

/// What copying needs of a pasteboard, so tests can watch it.
protocol LocalPasteboardWriting {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: LocalPasteboardWriting {}

/// Marks every match of the library search on the page and in the transcript.
enum FindHighlight {
    static func mark(_ text: AttributedString, query: String) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        var text = text
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = Color(uiColor: .systemYellow).opacity(0.45)
            cursor = range.upperBound
        }
        return text
    }
}
