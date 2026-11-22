#if DEBUG
import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import PencilKit

/// Debug-only: `--notebook-demo` (with `--library-demo`) gives "Weekly product sync" three notebook pages of synthetic ink, one of them
/// left out of summaries, so the conversation's Notebook block can be captured without an iPhone or a Pencil.
@MainActor
enum NotebookDemo {
    static var isRequested: Bool { CommandLine.arguments.contains("--notebook-demo") }

    static func apply(to state: AppState) async {
        guard isRequested, let meeting = state.meetings.first(where: { $0.title == LibraryDemo.ready }), meeting.pages?.isEmpty != false else { return }
        let start = Date().addingTimeInterval(-3600)
        let layouts: [(paper: PagePaper, hidden: Bool, passages: [SyntheticInk.Passage], words: [String])] = [
            (.ruled, false, [.init(.words("hello world"), at: CGPoint(x: 70, y: 56), size: 40, after: 5),
                             .init(.words("hold the"), at: CGPoint(x: 70, y: 140), size: 40, after: 45),
                             .init(.words("owl"), at: CGPoint(x: 70, y: 224), size: 40, after: 80)], ["hello world", "hold the", "owl"]),
            (.ruled, false, [.init(.words("lower"), at: CGPoint(x: 70, y: 56), size: 40, after: 100),
                             .init(.sketch, at: CGPoint(x: 80, y: 240), size: 150, after: 130)], ["lower", ""]),
            (.plain, true, [.init(.words("do the"), at: CGPoint(x: 40, y: 60), size: 44, after: 200)], ["do the"]),
        ]
        for (index, layout) in layouts.enumerated() {
            var page = NotebookPage(order: Double(index + 1), paper: layout.paper)
            let drawing = SyntheticInk.page(passages: layout.passages, start: start)
            let data = drawing.dataRepresentation()
            state.library.addPage(page, to: meeting.id)
            guard let stored = try? await state.library.commitPageDrawing(data, page: page.id, in: meeting.id, strokeCount: drawing.strokes.count,
                                                                           contentVersion: nil, device: "Demo") else { continue }
            var reading = await NotebookReader.read(drawing, sha256: stored.sha256, page: page) { _ in (nil, nil) }
            for position in reading.passages.indices where layout.words.indices.contains(position) {
                reading.passages[position].words = layout.words[position]
                reading.passages[position].kind = layout.words[position].isEmpty ? .sketch : .writing
                reading.passages[position].time = Double(15 + index * 40 + position * 30)
            }
            page.drawing = stored
            state.library.applyPageReading(reading, to: page.id, in: meeting.id)
            if layout.hidden { state.library.setPageHiddenFromSummary(page.id, hidden: true, in: meeting.id) }
        }
    }
}
#endif
