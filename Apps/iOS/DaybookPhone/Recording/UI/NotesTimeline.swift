import DaybookCore
import DaybookKit
import DaybookUI
import Foundation

/// The recording's notes, bookmarks, and photos in reading order, with their times: where the notes editor draws
/// each mark (`NoteParagraphs.placement`, which the Mac's notes use too), and the paragraph a bookmark follows.
enum NotesTimeline {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case paragraph(index: Int, text: String)
            case bookmark(UUID)
            case photo(String)
        }
        var kind: Kind
        var time: TimeInterval?
        var id: String {
            switch kind {
            case .paragraph(let index, _): return "p\(index)"
            case .bookmark(let id): return "b\(id.uuidString)"
            case .photo(let fileName): return "f\(fileName)"
            }
        }
        var isBookmark: Bool { if case .bookmark = kind { return true } else { return false } }
        var isParagraph: Bool { if case .paragraph = kind { return true } else { return false } }
    }

    /// Nonempty paragraphs, split the way `NoteTimeline` splits them.
    static func paragraphs(_ text: String) -> [String] {
        let source = text as NSString
        return NoteParagraphs.ranges(in: source).map { source.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// This recording's bookmarks and photos, as the notes editor marks them.
    static func marks(bookmarks: [Highlight], photos: [CapturePhoto] = []) -> [NoteMark] {
        bookmarks.map { NoteMark(id: "b\($0.id.uuidString)", kind: .bookmark, time: $0.time) }
            + photos.map { NoteMark(id: "f\($0.fileName)", kind: .photo, time: $0.time) }
    }

    /// Paragraphs stay in text order; each bookmark and photo goes before the first paragraph written after it.
    static func items(notes: String, anchors: [TimedNote], bookmarks: [Highlight], photos: [CapturePhoto] = []) -> [Item] {
        let paragraphs = paragraphs(notes)
        let times = NoteTimeline.paragraphTimes(anchors: anchors, text: notes)
        let timed = Array(times.prefix(paragraphs.count))
        let placed = NoteParagraphs.placement(of: marks(bookmarks: bookmarks, photos: photos), times: timed)
        var items: [Item] = []
        for (index, text) in paragraphs.enumerated() {
            items += placed.filter { $0.before == index }.map(item)
            items.append(Item(kind: .paragraph(index: index, text: text), time: index < timed.count ? timed[index] : nil))
        }
        items += placed.filter { $0.before >= paragraphs.count }.map(item)
        return items
    }

    /// The paragraph written last before `time`: what a bookmark there was about.
    static func paragraph(before time: TimeInterval, notes: String, anchors: [TimedNote]) -> String? {
        let paragraphs = paragraphs(notes)
        let times = NoteTimeline.paragraphTimes(anchors: anchors, text: notes)
        var best: (time: TimeInterval, text: String)?
        for (index, text) in paragraphs.enumerated() {
            guard index < times.count, let written = times[index], written <= time else { continue }
            if best == nil || written >= best!.time { best = (written, text) }
        }
        return best?.text
    }

    private static func item(_ placed: (mark: NoteMark, before: Int)) -> Item {
        let id = String(placed.mark.id.dropFirst())
        switch placed.mark.kind {
        case .bookmark: return Item(kind: .bookmark(UUID(uuidString: id) ?? UUID()), time: placed.mark.time)
        case .photo: return Item(kind: .photo(id), time: placed.mark.time)
        }
    }
}
