import DaybookKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Marks what changed between two versions word by word: removed words struck through in magenta,
/// inserted words washed in mint. Whitespace stays with the word before it, so the text reads
/// unchanged. The Mac's Version History draws the same marks.
enum WordDiff {
    /// Above this many words a diff stops being readable, so both versions show plain.
    static let limit = 4_000

    static func tokens(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex, index = text.startIndex, inSpace = false
        while index < text.endIndex {
            let space = text[index].isWhitespace
            if !space && inSpace && start < index { result.append(text[start..<index]); start = index }
            inSpace = space
            index = text.index(after: index)
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// Indices of removed tokens in `old` and inserted tokens in `new`, compared ignoring trailing whitespace.
    static func changes(old: [Substring], new: [Substring]) -> (removed: IndexSet, inserted: IndexSet) {
        let difference = new.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .difference(from: old.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return (removed, inserted)
    }

    /// In dark mode the washes are stronger and an inserted word is itself neon mint.
    static func marked(old: String, new: String, dark: Bool = false) -> (old: AttributedString, new: AttributedString) {
        let before = tokens(old), after = tokens(new)
        guard before.count + after.count <= limit, !before.isEmpty, !after.isEmpty else {
            return (AttributedString(old), AttributedString(new))
        }
        let changes = changes(old: before, new: after)
        return (build(before, marked: changes.removed) { word in
                    word.strikethroughStyle = Text.LineStyle(pattern: .solid, color: PhoneStyle.neonMagenta)
                    word.backgroundColor = PhoneStyle.neonMagenta.opacity(dark ? 0.20 : 0.16)
                },
                build(after, marked: changes.inserted) { word in
                    word.backgroundColor = PhoneStyle.neonMint.opacity(dark ? 0.22 : 0.16)
                    if dark { word.foregroundColor = PhoneStyle.neonMint }
                })
    }

    private static func build(_ tokens: [Substring], marked: IndexSet, style: (inout AttributedString) -> Void) -> AttributedString {
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            guard marked.contains(index) else { result += AttributedString(token); continue }
            let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var styled = AttributedString(word)
            style(&styled)
            result += styled
            result += AttributedString(token.dropFirst(word.count))
        }
        return result
    }
}

/// Words for a recording in Info › Audio: where it came from and how it was lined up.
@MainActor
enum SourceDescription {
    static func name(_ track: RecordingTrack, in meeting: Meeting) -> String {
        if track.deviceKind == PhoneDevice.kind { return "iPhone" }
        if track.source == .imported { return track.fileName }
        var name = recordingName(track.source)
        if let kind = track.deviceKind, let device = DeviceCatalog.kind(kind)?.name { name = device }
        if track.derivedFrom != nil { return "\(name), \(track.processing == RecordingTrack.echoCancelledProcessing ? "echo removed" : "processed")" }
        if meeting.tracks.contains(where: { $0.derivedFrom == track.id }) { return "\(name), original" }
        return name
    }

    static func recordingName(_ source: AudioSource) -> String {
        switch source {
        case .microphone: return "Microphone"
        case .systemAudio: return "Computer audio"
        case .soundcore: return "Soundcore Work"
        case .imported: return "Imported file"
        }
    }

    static func symbol(_ track: RecordingTrack) -> String {
        if track.deviceKind == PhoneDevice.kind { return "iphone" }
        switch track.source {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "waveform.badge.microphone"
        case .imported: return "doc"
        }
    }

    /// "Lined up by sound · starts 0:12 · 93% sure", as the Mac's inspector says it.
    static func timing(_ track: RecordingTrack, in meeting: Meeting) -> String {
        let report = meeting.alignmentReports.first { $0.trackID == track.id }
        let placement = meeting.timelinePlacement(of: track.id)
        let starts = placement.map { "starts \(TimeLabel.short($0.offset))" }
        let sure = track.alignment?.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }
        let drift = placement.flatMap { abs($0.rate - 1) > 0.000_001 ? String(format: "drift %+.3f%%", ($0.rate - 1) * 100) : nil }
        func line(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        switch track.alignment?.method {
        case .audio?: return line("Lined up by sound", starts, sure, drift)
        case .transcript?: return line("Lined up by shared phrases", starts, sure, drift)
        case .clock?: return line("Placed by the clocks only", starts)
        case .manual?: return line("Timing set by you", starts)
        case .pending?: return "Lines up when your Mac processes it"
        case .unaligned?: return "Couldn’t line up"
        case nil:
            switch report?.method {
            case .unaligned?: return "Couldn’t line up"
            case .anchors?: return line("Lined up by shared phrases", starts, drift)
            case .audio?: return line("Lined up by sound", starts, report?.confidence.map { "\(Int(($0 * 100).rounded()))% sure" }, drift)
            case .timestamps?: return line("Placed by the clocks only", starts)
            case .reference?: return meeting.tracks.count > 1 ? line("The main recording", starts) : "The main recording"
            case .provided?: return line("Placed when recorded", starts)
            case nil: return placement == nil ? "Not lined up yet" : line(starts)
            }
        }
    }

    static func isUnaligned(_ track: RecordingTrack, in meeting: Meeting) -> Bool {
        track.alignment?.method == .unaligned || meeting.alignmentReports.contains { $0.trackID == track.id && $0.method == .unaligned }
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
