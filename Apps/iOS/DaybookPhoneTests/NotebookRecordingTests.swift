import DaybookCore
import DaybookKit
import DaybookUI
import XCTest

@testable import DaybookPhone

/// The notebook while a recording runs: Stop settles the open pages first, what the notebook logs while recording is
/// journaled and filed with the conversation, and the pill's Notebook button shows only where two pages fit.
@MainActor
final class NotebookRecordingTests: XCTestCase {
    private func makeModel() throws -> (PhoneAppModel, RecorderRig) {
        let rig = RecorderRig()
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  environment: try .test(self))
        return (model, rig)
    }

    func testBehaviorStopSettlesPagesBeforeFiling() async throws {
        let (model, rig) = try makeModel()
        try await model.library.reload()
        try await model.startRecording()
        rig.pump(2)
        let page = NotebookPage(order: 1, now: rig.clock.now())
        model.recorder.addPage(page)
        let ink = Data("settled-strokes".utf8)
        var settled = false
        model.settleNotebook = {
            // What the open notebook does at Stop: its strokes are committed.
            settled = true
            _ = try? model.recorder.commitPage(page.id, data: ink, strokeCount: 3, contentVersion: 1)
        }
        let id = try XCTUnwrap(model.recorder.captureID)
        rig.pump(2)
        try await model.stopRecording()
        XCTAssertTrue(settled)
        let filed = try XCTUnwrap(model.library.controller.meeting(id)?.page(page.id))
        XCTAssertEqual(filed.drawing?.sha256, AudioDigest.sha256(data: ink), "the strokes settled at Stop are in the conversation")
    }

    func testBehaviorTurnsAndErasuresAreJournaledAndFiled() async throws {
        let (model, rig) = try makeModel()
        try await model.library.reload()
        try await model.startRecording()
        rig.pump(2)
        let recorder = model.recorder
        let page = NotebookPage(order: 1, now: rig.clock.now())
        recorder.addPage(page)
        recorder.sampleClock()
        _ = try recorder.commitPage(page.id, data: Data("ink".utf8), strokeCount: 1, contentVersion: 1)
        recorder.recordErasures(pageID: page.id, [ErasedStroke(key: "1-2-3-4", madeAt: rig.clock.now(), erasedAt: rig.clock.now(), time: 2)])
        recorder.logPageTurn(PageTurn(at: rig.clock.now(), pages: [page.id], time: 2))
        recorder.logPageTurn(PageTurn(at: rig.clock.now().addingTimeInterval(3), pages: [], time: 5))
        rig.pump(3)
        let id = try XCTUnwrap(recorder.captureID)
        try await model.stopRecording()
        let meeting = try XCTUnwrap(model.library.controller.meeting(id))
        XCTAssertEqual(meeting.page(page.id)?.erased?.map(\.key), ["1-2-3-4"])
        XCTAssertEqual(meeting.pageTurns?.map(\.pages), [[page.id], []])
        XCTAssertNotNil(meeting.pageTurns?.first?.trackID, "placed on the recording's track")
    }

    func testBehaviorNotebookButtonOnlyWhenSpreadFits() {
        let page = CGSize(width: NotebookPage.a5.width, height: NotebookPage.a5.height)
        XCTAssertTrue(NotebookLayout.resolve(size: CGSize(width: 867, height: 635), crease: 475.5, page: page).isSpread, "the open Duo")
        XCTAssertFalse(NotebookLayout.resolve(size: CGSize(width: 382, height: 644), crease: nil, page: page).isSpread, "the cover")
    }

    func testBehaviorFoldKeepsNotebookOpenAsSinglePage() throws {
        let store = NotebookSession()
        var pages = [NotebookPage(order: 1)]
        store.resolve(.spread(scale: 0.86))
        store.bind(NotebookModel(pages: { pages }, content: { _ in .blank }, add: { pages.append($0) }, saveDraft: { _, _ in true },
                                 commit: { _, _, _, _ in "" }, applyReading: { _, _ in }, correct: { _, _, _ in }, remove: { _ in nil },
                                 recordErasures: { _, _ in }, logTurn: { _ in }, anchor: { _ in (nil, nil) }))
        XCTAssertEqual(store.visible.count, 2)
        store.resolve(.single(scale: 0.85))
        XCTAssertEqual(store.visible.count, 1, "folded shut: one page, the notebook still open")
        XCTAssertEqual(store.visible.first?.id, pages[0].id)
        store.resolve(.spread(scale: 0.86))
        XCTAssertEqual(store.visible.count, 2, "opened again: two pages")
    }
}
