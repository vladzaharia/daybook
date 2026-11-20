import Foundation
@testable import DaybookCore

/// Synthetic pages for the notebook tests: no strokes, no files; a drawing is a record with a digest of a tag.
enum NotebookFixtures {
    static let start = Date(timeIntervalSince1970: 1_780_000_000)

    static func drawing(_ page: UUID, _ tag: String, at date: Date = start, strokes: Int = 3) -> PageDrawing {
        let digest = AudioDigest.sha256(data: Data(tag.utf8))
        return PageDrawing(relativePath: PageDrawing.relativePath(page: page, sha256: digest), sha256: digest, byteCount: 900,
                           strokeCount: strokes, editedAt: date, contentVersion: 1, device: "Test iPhone")
    }

    static func passage(_ page: UUID, key: String = "1-3-10-10", words: String? = "hello wrld", at offset: TimeInterval = 0,
                        kind: PassageKind = .writing, trackID: UUID? = nil, time: TimeInterval? = nil) -> NotebookPassage {
        NotebookPassage(id: NotebookPassage.id(page: page, firstStroke: key), kind: kind, x: 10, y: 10, width: 200, height: 30, strokeCount: 3,
                        strokeDigest: PassageGrouping.digest(of: [key]), start: start.addingTimeInterval(offset),
                        end: start.addingTimeInterval(offset + 4), trackID: trackID, time: time, words: words)
    }

    static func reading(of drawing: PageDrawing, _ passages: [NotebookPassage], at offset: TimeInterval = 100,
                        grouping: Int = PassageGrouping.version) -> PageReading {
        PageReading(drawingSHA256: drawing.sha256, passages: passages, readAt: start.addingTimeInterval(offset),
                    settings: ProcessingSettings(modelID: "pencilkit/stroke-recognizer", parameters: ["grouping": String(grouping)],
                                                 createdAt: start.addingTimeInterval(offset)))
    }

    /// A page with a drawing (committed at `offset`) and, when given, a current reading of it.
    static func page(_ id: UUID = UUID(), order: Double = 1, tag: String = "ink", offset: TimeInterval = 10,
                     passages: [NotebookPassage]? = nil) -> NotebookPage {
        var page = NotebookPage(id: id, order: order, now: start)
        page.drawing = drawing(id, tag, at: start.addingTimeInterval(offset))
        if let passages { page.reading = reading(of: page.drawing!, passages) }
        return page
    }

    static func meeting(_ id: UUID = UUID(), pages: [NotebookPage]? = nil) -> Meeting {
        var meeting = Meeting(id: id, title: "Notebook", date: start, updatedAt: start)
        meeting.pages = pages
        return meeting
    }
}
