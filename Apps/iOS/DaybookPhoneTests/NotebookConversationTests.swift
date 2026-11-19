import DaybookCore
import DaybookKit
import DaybookUI
import PencilKit
import XCTest

@testable import DaybookPhone
@testable import DaybookUI

/// A saved conversation's notebook: strokes written while it plays are timed by the player, pages come from the library's files, and a
/// page whose strokes aren't on this iPhone is never written over.
@MainActor
final class NotebookConversationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorStrokesWrittenWhilePlayingTakeThePlayersPosition() {
        let clock = PlayerClock()
        let track = UUID()
        clock.sample(playing: true, position: 100, track: track, at: t0)
        let placed = clock.anchor(t0.addingTimeInterval(12))
        XCTAssertEqual(placed.trackID, track)
        XCTAssertEqual(placed.time ?? 0, 112, accuracy: 0.001, "the player moves on with the wall clock while it plays")
        // Seeked, and sampled again at the next stroke: the later sample speaks for later strokes.
        clock.sample(playing: true, position: 20, track: track, at: t0.addingTimeInterval(30))
        XCTAssertEqual(clock.anchor(t0.addingTimeInterval(35)).time ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(clock.anchor(t0.addingTimeInterval(12)).time ?? 0, 112, accuracy: 0.001, "earlier strokes keep their own")
    }

    func testBehaviorNotPlayingTimesNothingByThePlayer() {
        let clock = PlayerClock()
        XCTAssertNil(clock.anchor(t0).time, "no samples")
        clock.sample(playing: true, position: 10, track: UUID(), at: t0)
        clock.sample(playing: false, position: 15, track: UUID(), at: t0.addingTimeInterval(5))
        XCTAssertNil(clock.anchor(t0.addingTimeInterval(8)).time, "paused: wall clock only")
        XCTAssertNil(clock.anchor(t0.addingTimeInterval(500)).trackID)
        let late = PlayerClock()
        late.sample(playing: true, position: 10, track: UUID(), at: t0)
        XCTAssertNil(late.anchor(t0.addingTimeInterval(PlayerClock.reach + 1)).time, "a sample doesn't speak for long after")
    }

    private func makeModel() throws -> PhoneAppModel {
        let rig = RecorderRig()
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]), environment: try .test(self))
    }

    func testBehaviorConversationPagesCommitToTheLibraryAndOpenFromIt() async throws {
        let model = try makeModel()
        try await model.library.reload()
        let controller = model.library.controller
        let id = controller.newMeeting(title: "Design review")
        let page = NotebookPage(order: 1, now: t0)
        controller.addPage(page, to: id)
        let drafts = PageDrafts(root: model.library.rootURL, meeting: id)
        let notebook = NotebookModel.conversation(id, model: model, player: PlaybackController(), provider: LocalAudioProvider(library: model.library), drafts: drafts)
        XCTAssertEqual(notebook.content(page.id), .blank)
        let drawing = SyntheticInk.drawing("hello", start: t0)
        let data = drawing.dataRepresentation()
        XCTAssertTrue(notebook.saveDraft(page.id, data), "a draft protects the strokes meanwhile")
        let sha = try await notebook.commit(page.id, data, drawing.strokes.count, 1)
        XCTAssertEqual(controller.meeting(id)?.page(page.id)?.drawing?.sha256, sha)
        XCTAssertEqual(notebook.content(page.id), .strokes(data), "read back from the library's file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page.id).path), "the draft goes with the commit")
    }

    func testBehaviorPageWhoseStrokesAreNotHereIsNeverWrittenOver() async throws {
        let model = try makeModel()
        try await model.library.reload()
        let controller = model.library.controller
        let id = controller.newMeeting(title: "Design review")
        var page = NotebookPage(order: 1, now: t0)
        let path = PageDrawing.relativePath(page: page.id, sha256: String(repeating: "ab", count: 32))
        page.drawing = PageDrawing(relativePath: path, sha256: String(repeating: "ab", count: 32), byteCount: 10, strokeCount: 4, editedAt: t0)
        controller.addPage(page, to: id)
        let notebook = NotebookModel.conversation(id, model: model, player: PlaybackController(), provider: LocalAudioProvider(library: model.library),
                                                  drafts: PageDrafts(root: model.library.rootURL, meeting: id))
        XCTAssertEqual(notebook.content(page.id), .notLoaded)
        let session = NotebookSession(now: { self.t0 }, idleSettle: .seconds(60), draftDelay: .seconds(60))
        session.resolve(.single(scale: 1))
        session.bind(notebook)
        // Fetch fails (the audio provider can't reach it): the page says so, and writing is refused.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(session.unavailable.contains(page.id))
        XCTAssertFalse(session.isWritable(page.id))
        let view = try XCTUnwrap(session.canvas(for: page.id))
        view.load(SyntheticInk.drawing("hello", start: t0))
        session.changed(view)
        await session.settle(.close)
        XCTAssertEqual(controller.meeting(id)?.page(page.id)?.drawing?.sha256, String(repeating: "ab", count: 32), "the conversation's strokes are untouched")
    }
}
