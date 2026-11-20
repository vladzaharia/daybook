import DaybookCore
import Foundation

/// Synthetic notebook pages for tests of what reads them (summaries, search, exports): no strokes, no files; a drawing is a
/// record with a digest of a tag, and a reading is whatever passages the test gives.
enum NotebookTestPages {
    static let start = Date(timeIntervalSince1970: 1_780_000_000)

    static func passage(_ page: UUID, key: String, words: String?, kind: PassageKind = .writing, time: TimeInterval? = nil,
                        y: Double = 10) -> NotebookPassage {
        NotebookPassage(id: NotebookPassage.id(page: page, firstStroke: key), kind: kind, x: 10, y: y, width: 200, height: 30, strokeCount: 3,
                        strokeDigest: PassageGrouping.digest(of: [key]), start: start.addingTimeInterval(time ?? 0),
                        end: start.addingTimeInterval((time ?? 0) + 4), time: time, words: words)
    }

    static func page(_ id: UUID = UUID(), order: Double = 1, _ passages: [NotebookPassage]) -> NotebookPage {
        var page = NotebookPage(id: id, order: order, now: start)
        let digest = AudioDigest.sha256(data: Data(id.uuidString.utf8))
        page.drawing = PageDrawing(relativePath: PageDrawing.relativePath(page: id, sha256: digest), sha256: digest, byteCount: 900,
                                   strokeCount: 3, editedAt: start, contentVersion: 1)
        page.reading = PageReading(drawingSHA256: digest, passages: passages, readAt: start,
                                   settings: ProcessingSettings(modelID: "pencilkit/stroke-recognizer",
                                                                parameters: ["grouping": String(PassageGrouping.version)], createdAt: start))
        return page
    }

    /// What reading a sketch found.
    static func analysis(of passage: NotebookPassage, caption: String?, text: String? = nil, informative: Bool = true) -> SketchAnalysis {
        SketchAnalysis(passageID: passage.id, strokeDigest: passage.strokeDigest,
                       analysis: PhotoAnalysis(caption: caption, recognizedText: text, labels: informative ? ["diagram"] : nil, isInformative: informative,
                                               settings: ProcessingSettings(modelID: "apple-vision/system", createdAt: start), createdAt: start))
    }
}
