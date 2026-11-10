import DaybookDesign
import DaybookKit
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Your notes as free text, with each paragraph's recording time in a lane on its left: one editor for the
// conversation page and the recorder on both apps (docs/interface.md, "Behaviour worth knowing"). The
// platform text views (`MarginNotesEditor+AppKit.swift`, `MarginNotesEditor+UIKit.swift`) draw the lane;
// what they draw is worked out here, the same way on both.

/// Something marked while recording, drawn as a tick in the notes' lane before the first paragraph written
/// after it: a bookmark in amber, a photo in meta ink.
public struct NoteMark: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case bookmark, photo }

    public var id: String
    public var kind: Kind
    /// Its time in the recording.
    public var time: TimeInterval

    public init(id: String, kind: Kind, time: TimeInterval) {
        self.id = id
        self.kind = kind
        self.time = time
    }

    /// "Bookmark at 4 minutes 10 seconds", for VoiceOver.
    public var spoken: String { "\(kind == .bookmark ? "Bookmark" : "Photo") at \(SpokenTime.format(time))" }
}

/// The notes' paragraphs as the lane sees them: split exactly as DaybookCore's `NoteTimeline` splits them
/// (any newline, blank ones skipped), so `times[n]` always lands on the paragraph it belongs to.
public enum NoteParagraphs {
    /// Each nonblank paragraph's range in `text`, in order.
    public static func ranges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length {
            let rest = NSRange(location: location, length: text.length - location)
            let separator = text.rangeOfCharacter(from: .newlines, options: [], range: rest)
            let end = separator.location == NSNotFound ? text.length : separator.location
            let range = NSRange(location: location, length: end - location)
            if !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ranges.append(range) }
            guard separator.location != NSNotFound else { break }
            location = NSMaxRange(separator)
        }
        return ranges
    }

    /// Where each mark goes: before the first paragraph written after it (the first with a time later than
    /// the mark's), else after the last. `before` is that paragraph's index, or `times.count` for after the last.
    public static func placement(of marks: [NoteMark], times: [TimeInterval?]) -> [(mark: NoteMark, before: Int)] {
        marks.sorted { $0.time < $1.time }.map { mark in
            (mark, times.firstIndex { time in time.map { $0 > mark.time } ?? false } ?? times.count)
        }
    }

    /// A bookmark placed after the last of `paragraphs`, with nothing written after it: alone on an empty line, it says
    /// "Bookmark" there in placeholder ink (`BookmarkLabel.untitled`), as its row in the summary does. A photo shows
    /// itself, and a mark beside a paragraph has that paragraph's words.
    public static func isWordless(_ mark: NoteMark, before: Int, paragraphs: Int) -> Bool {
        mark.kind == .bookmark && before >= paragraphs
    }

    /// The paragraph holding `location` (a caret), or the last one before it: where "Play from Here" plays from.
    public static func paragraph(at location: Int, in ranges: [NSRange]) -> Int? {
        ranges.lastIndex { $0.location <= location }
    }

    /// The time "Play from Here" plays from at `location`: its paragraph's, else the nearest earlier timed one's.
    public static func playTime(at location: Int, ranges: [NSRange], times: [TimeInterval?]) -> TimeInterval? {
        guard let index = paragraph(at: location, in: ranges) else { return nil }
        for candidate in stride(from: min(index, times.count - 1), through: 0, by: -1) {
            if let time = times[candidate] { return time }
        }
        return nil
    }

    /// The attachment characters inside `range`, which Writing Tools leaves alone: on the iPhone each block of
    /// handwriting is one (`NotesInk`), and a rewrite over it would drop the block. The Mac's plain text has none.
    public static func attachments(in text: NSAttributedString, within range: NSRange) -> [NSRange] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return [] }
        var found: [NSRange] = []
        text.enumerateAttribute(.attachment, in: range, options: []) { value, run, _ in
            if value != nil { found.append(run) }
        }
        return found
    }

    /// Every match of the library search in the notes, marked as the page marks the rest (`FindHighlight`).
    public static func matches(of query: String, in text: NSString) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [NSRange] = []
        var location = 0
        while location < text.length {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            matches.append(found)
            location = NSMaxRange(found)
        }
        return matches
    }
}

/// The notes editor: free text, each paragraph's time in the lane, and while recording the bookmarks and
/// photos as ticks there. It edits a string and draws what it's given, so the page and the recorder share it.
///
/// - `times` are the nonempty paragraphs' recording times, in order: `Meeting.paragraphTimes()` on a page, or
///   `NoteTimeline.paragraphTimes(anchors:text:)` while recording. A paragraph without one shows none.
/// - Inside a page (`scrolls == false`) it sizes itself to its text, so the page scrolls as one document; with
///   `scrolls` it scrolls on its own, under a soft edge.
/// - With `playTime`, each time is a button ("Play from 4 minutes 10 seconds") and Play from Here plays from the
///   paragraph at the insertion point, from its menu and as a VoiceOver action; without, times only say.
/// - `findQuery` marks the library search's matches, as the rest of the page does.
public struct MarginNotesEditor {
    let binding: Binding<String>
    var text: String {
        get { binding.wrappedValue }
        nonmutating set { binding.wrappedValue = newValue }
    }
    var times: [TimeInterval?]
    var marks: [NoteMark]
    var placeholder: String
    var scrolls: Bool
    var isEditable: Bool
    var focusOnAppear: Bool
    /// When it scrolls: room under the last line, so it can clear a bar drawn over the bottom edge.
    var bottomInset: CGFloat
    var findQuery: String
    var playTime: ((TimeInterval) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    #if os(macOS)
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    /// The time margin: text starts here, and times are right-aligned 8 pt short of it.
    var margin: CGFloat
    /// Room between the end of every line and the trailing edge.
    var trailingInset: CGFloat
    /// A fixed size for the times. Nil scales them with the text, as the page does.
    var timeFontSize: CGFloat?
    #else
    /// Handwriting between the typed paragraphs; nil leaves it out.
    var ink: NotesInkModel?
    var textStyle: UIFont.TextStyle
    /// The lane at the default text size; it grows with Dynamic Type to 1.9 times. Zero hides the times.
    var lane: CGFloat
    #endif

    /// The placeholder both apps show.
    public static let placeholder = "Add a note…"
}

extension MarginNotesEditor {
    /// The VoiceOver label of a time in the lane: a button that plays, or the time a note was taken.
    public static func spokenTime(_ time: TimeInterval, plays: Bool) -> String {
        plays ? "Play from \(SpokenTime.format(time))" : "Note at \(SpokenTime.format(time))"
    }

    /// The menu item and VoiceOver action that plays from the paragraph at the insertion point.
    public static let playFromHere = "Play from Here"
}
