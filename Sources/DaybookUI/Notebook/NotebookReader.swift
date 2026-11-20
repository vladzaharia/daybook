#if canImport(PencilKit)
import DaybookCore
import Foundation
import PencilKit

/// Reads a page's strokes on this device (docs/notebook.md, "Reading"): grouped into passages by time and place
/// (`PassageGrouping`), each group read on its own, told apart as writing or a sketch, and timed from its first stroke.
public enum NotebookReader {
    /// What the strokes of a drawing are to Core, in drawing order, with unique keys and bounds in page points.
    public static func strokes(of drawing: PKDrawing) -> [NotebookStroke] {
        let drawn = drawing.strokes
        let keys = NotebookStroke.uniqued(drawn.map(key(of:)))
        return zip(drawn, keys).map { stroke, key in
            let path = stroke.path
            let bounds = stroke.renderBounds
            let end = path.count > 0 ? path.creationDate.addingTimeInterval(max(0, Double(path[path.count - 1].timeOffset))) : path.creationDate
            return NotebookStroke(key: key, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height,
                                  start: path.creationDate, end: end)
        }
    }

    /// The canvas's strokes together with the ones `stored` (the library's copy, changed since the canvas was loaded) has that the
    /// canvas lacks, matched by stroke key, in creation order. `erasedHere` are the keys the person took out since then: they stay out.
    public static func merging(_ canvas: PKDrawing, with stored: PKDrawing, erasedHere: Set<String>) -> PKDrawing {
        let here = Set(strokes(of: canvas).map(\.key))
        let theirs = zip(stored.strokes, strokes(of: stored).map(\.key))
            .filter { !here.contains($0.1) && !erasedHere.contains($0.1) }.map(\.0)
        guard !theirs.isEmpty else { return canvas }
        let ordered = (canvas.strokes + theirs).enumerated()
            .sorted { ($0.element.path.creationDate, $0.offset) < ($1.element.path.creationDate, $1.offset) }.map(\.element)
        return PKDrawing(strokes: ordered)
    }

    /// The key a stroke has before duplicates are told apart. The first point is the path's, before the stroke's transform,
    /// so a stroke the lasso moved keeps its key.
    static func key(of stroke: PKStroke) -> String {
        let path = stroke.path
        let first = path.count > 0 ? path[0].location : .zero
        return NotebookStroke.key(began: path.creationDate, pointCount: path.count, firstX: first.x, firstY: first.y)
    }

    /// Groups, reads, classifies, and times a page's strokes. `anchor` places a moment on the recording clock.
    public static func read(_ drawing: PKDrawing, sha256: String, page: NotebookPage, now: Date = Date(),
                            anchor: (Date) -> (trackID: UUID?, time: TimeInterval?)) async -> PageReading {
        let strokes = strokes(of: drawing)
        let groups = PassageGrouping.group(strokes, page: page.id)
        let byKey = Dictionary(zip(strokes.map(\.key), drawing.strokes), uniquingKeysWith: { first, _ in first })
        var reader = GroupReader(drawing: drawing, byKey: byKey)
        var passages: [NotebookPassage] = []
        for group in groups {
            let found = await reader.read(group)
            let placed = anchor(group.start)
            passages.append(NotebookPassage(
                id: group.id, kind: PassageKind.decide(words: found.words, textCoverage: found.coverage),
                x: group.x, y: group.y, width: group.width, height: group.height, strokeCount: group.strokes.count,
                strokeDigest: group.digest, start: group.start, end: group.end, trackID: placed.trackID, time: placed.time,
                words: found.words))
        }
        passages.sort { ($0.y, $0.x) < ($1.y, $1.x) }
        var parameters = ["grouping": String(PassageGrouping.version)]
        let model = reader.usedRecognizer ? "pencilkit/stroke-recognizer" : "apple-vision/system"
        if let version = reader.recognitionVersion { parameters["recognitionVersion"] = String(version) }
        return PageReading(drawingSHA256: sha256, passages: passages, readAt: now,
                           settings: ProcessingSettings(modelID: model, parameters: parameters, createdAt: now))
    }

    /// Reads one group at a time, keeping the page's recognizer between them (it holds one drawing).
    private struct GroupReader {
        let drawing: PKDrawing
        let byKey: [String: PKStroke]
        var usedRecognizer = false
        var recognitionVersion: Int?
        private var recognizer: Any?

        init(drawing: PKDrawing, byKey: [String: PKStroke]) {
            self.drawing = drawing; self.byKey = byKey
        }

        mutating func read(_ group: PassageGrouping.Group) async -> (words: String?, coverage: Double?) {
            if #available(iOS 27.0, macOS 27.0, *) {
                if recognizer == nil {
                    let made = PKStrokeRecognizer()
                    await made.updateDrawing(drawing)
                    recognizer = made
                    recognitionVersion = PKStrokeRecognizer.recognitionVersion
                }
                if let made = recognizer as? PKStrokeRecognizer, let found = await Self.recognize(group, byKey: byKey, with: made) {
                    usedRecognizer = true
                    return found
                }
            }
            #if os(iOS)
            return await Self.vision(group, byKey: byKey)
            #else
            return (nil, nil)
            #endif
        }

        @available(iOS 27.0, macOS 27.0, *)
        private static func recognize(_ group: PassageGrouping.Group, byKey: [String: PKStroke],
                                      with recognizer: PKStrokeRecognizer) async -> (words: String?, coverage: Double?)? {
            let ids = Set(group.strokes.compactMap { byKey[$0.key]?.id })
            guard !ids.isEmpty else { return nil }
            guard let text = await recognizer.recognizedText(strokeIDs: ids)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                // A group of three or more strokes with nothing read is tried by Vision; a short one has no words.
                return group.strokes.count >= 3 ? nil : ("", nil)
            }
            var covered = Set<UUID>()
            var seen = Set<String>()
            let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
            for word in words where seen.insert(word.lowercased()).inserted && seen.count <= 40 {
                for hit in await recognizer.search(word, fullWordsOnly: true, caseMatchingOnly: false) {
                    covered.formUnion(hit.strokes.intersection(ids))
                }
            }
            return (text, Double(covered.count) / Double(ids.count))
        }

        #if os(iOS)
        private static func vision(_ group: PassageGrouping.Group, byKey: [String: PKStroke]) async -> (words: String?, coverage: Double?) {
            let drawn = PKDrawing(strokes: group.strokes.compactMap { byKey[$0.key] })
            guard let found = await InkRecognizer.textWithBoxes(in: drawn) else { return (nil, nil) }
            guard !found.words.isEmpty else { return ("", nil) }
            let inside = group.strokes.filter { stroke in
                let centre = CGPoint(x: stroke.x + stroke.width / 2, y: stroke.y + stroke.height / 2)
                return found.boxes.contains { $0.insetBy(dx: -4, dy: -4).contains(centre) }
            }
            return (found.words, Double(inside.count) / Double(max(1, group.strokes.count)))
        }
        #endif
    }
}
#endif
