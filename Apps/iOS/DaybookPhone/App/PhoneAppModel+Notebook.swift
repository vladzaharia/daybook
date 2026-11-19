import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import PencilKit

// The notebook pages a recording has in hand (docs/notebook.md): the conversation's own when it records into one (Keep
// Recording, or a Mac's request), with their strokes where this iPhone has them.
extension PhoneAppModel {
    /// Takes the pages of the conversation this recording goes into, and tells the recorder where their strokes are.
    func loadNotebookPages(of id: UUID) {
        let controller = library.controller
        recorder.conversationDrawing = { [weak self] drawing in
            if let url = self?.fetchedPageDrawings[drawing.sha256], let data = try? Data(contentsOf: url) { return data }
            guard controller.hasLocalPageDrawing(drawing, in: id) else { return nil }
            let url = controller.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)")
            return try? Data(contentsOf: url)
        }
        recorder.loadPages(from: controller.meeting(id))
    }

    /// Brings a loaded page's strokes onto this iPhone from iCloud; false when they can't be had now.
    func fetchPageDrawing(_ pageID: UUID) async -> Bool {
        guard let drawing = recorder.pages.first(where: { $0.page.id == pageID })?.page.drawing, let id = recorder.captureID else { return false }
        do {
            fetchedPageDrawings[drawing.sha256] = try await audio.localPageDrawing(for: drawing, in: id)
            return true
        } catch {
            return false
        }
    }
}

extension PhoneLibrary {
    /// Reads, one at a time, the pages of a conversation that have strokes on this iPhone and no reading of them (a recording's
    /// last page, a crash before reading, or a page read by an older grouping). Times already read stay (`applyPageReading`).
    @MainActor
    func readPages(in id: UUID) async {
        for page in controller.meeting(id)?.visiblePages ?? [] where page.needsReading {
            guard let drawing = page.drawing, controller.hasLocalPageDrawing(drawing, in: id),
                  let data = try? Data(contentsOf: rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)")),
                  let strokes = try? PKDrawing(data: data) else { continue }
            let reading = await NotebookReader.read(strokes, sha256: drawing.sha256, page: page) { _ in (nil, nil) }
            controller.applyPageReading(reading, to: page.id, in: id)
        }
    }
}
