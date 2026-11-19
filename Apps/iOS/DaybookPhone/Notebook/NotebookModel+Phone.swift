import DaybookCore
import DaybookKit
import DaybookUI
import Foundation

// What the notebook is told about where its pages are kept: the recording's while it runs, a saved conversation's in the
// library (docs/notebook.md).
extension NotebookModel {
    /// The recording's pages, while it runs: strokes in its staging folder, the records in its journal.
    @MainActor
    static func recording(_ model: PhoneAppModel) -> NotebookModel {
        let recorder = model.recorder
        return NotebookModel(
            pages: { visiblePages(recorder.pages.map(\.page)) },
            content: { id in
                switch recorder.pageStrokes(id) {
                case .strokes(let data): return .strokes(data)
                case .blank: return .blank
                case .notLoaded: return .notLoaded
                }
            },
            fetch: { id in await model.fetchPageDrawing(id) },
            add: { recorder.addPage($0) },
            saveDraft: { recorder.saveDraft($0, data: $1) },
            commit: { id, data, count, version in try recorder.commitPage(id, data: data, strokeCount: count, contentVersion: version) },
            applyReading: { recorder.applyPageReading($0, $1) },
            correct: { recorder.correctPassage(pageID: $0, passageID: $1, text: $2) },
            remove: { id in
                recorder.removePage(id)
                return { recorder.restorePage(id) }
            },
            recordErasures: { recorder.recordErasures(pageID: $0, $1) },
            logTurn: { turn in
                // Turns before the clock has a sample (nothing written yet) have no recording time; they're kept without one.
                recorder.logPageTurn(turn)
            },
            sampleClock: { recorder.sampleClock() },
            anchor: { moment in (nil, RecordingClockMap.elapsed(at: moment, samples: recorder.pageClock)) },
            origin: .thisIPhone(installation: model.library.installationID))
    }

    /// The pages that aren't deleted, in the order a conversation shows them.
    static func visiblePages(_ pages: [NotebookPage]) -> [NotebookPage] {
        var stand = Meeting(title: "")
        stand.pages = pages
        return stand.visiblePages
    }
}
