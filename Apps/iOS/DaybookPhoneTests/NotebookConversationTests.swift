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

    // The canvas's begin callback samples a moment after the stroke's creation date, so a sample trails the moment it speaks for.

    func testBehaviorFirstPassageAfterOpeningIsTimedFromTheSampleThatTrailsIt() {
        let clock = PlayerClock()
        let track = UUID()
        clock.sample(playing: true, position: 100, track: track, at: t0.addingTimeInterval(0.4))
        let placed = clock.anchor(t0)
        XCTAssertEqual(placed.trackID, track)
        XCTAssertEqual(placed.time ?? 0, 99.6, accuracy: 0.001)
        XCTAssertNil(clock.anchor(t0.addingTimeInterval(-5)).time, "not for a moment well before any sample")
    }

    func testBehaviorFirstStrokeAfterPausingGetsNoTime() {
        let clock = PlayerClock()
        let track = UUID()
        clock.sample(playing: true, position: 100, track: track, at: t0)
        clock.sample(playing: false, position: 110, track: track, at: t0.addingTimeInterval(10))
        // Written at 20 s; the begin callback sampled at 20.4 s.
        clock.sample(playing: false, position: 110, track: track, at: t0.addingTimeInterval(20.4))
        XCTAssertNil(clock.anchor(t0.addingTimeInterval(20)).time, "nothing was playing")
        XCTAssertEqual(clock.anchor(t0.addingTimeInterval(5)).time ?? 0, 105, accuracy: 0.001, "what was written before the pause keeps its time")
    }

    func testBehaviorFirstStrokeAfterSeekingUsesThePositionAfterIt() {
        let clock = PlayerClock()
        let track = UUID()
        clock.sample(playing: true, position: 100, track: track, at: t0)
        clock.sample(playing: true, position: 20, track: track, at: t0.addingTimeInterval(10))
        clock.sample(playing: true, position: 25.4, track: track, at: t0.addingTimeInterval(15.4))
        XCTAssertEqual(clock.anchor(t0.addingTimeInterval(15)).time ?? 0, 25, accuracy: 0.001)
    }

    func testBehaviorFirstStrokeAfterAnotherTrackStartsUsesThatTrack() {
        let clock = PlayerClock()
        let first = UUID(), second = UUID()
        clock.sample(playing: true, position: 100, track: first, at: t0)
        clock.sample(playing: true, position: 5, track: second, at: t0.addingTimeInterval(10))
        clock.sample(playing: true, position: 7.4, track: second, at: t0.addingTimeInterval(12.4))
        let placed = clock.anchor(t0.addingTimeInterval(12))
        XCTAssertEqual(placed.trackID, second)
        XCTAssertEqual(placed.time ?? 0, 7, accuracy: 0.001)
    }

    func testBehaviorPlayerSpeedCarriesTheTimeOn() {
        let clock = PlayerClock()
        clock.sample(playing: true, position: 100, track: UUID(), rate: 2, at: t0)
        XCTAssertEqual(clock.anchor(t0.addingTimeInterval(10)).time ?? 0, 120, accuracy: 0.001)
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
        XCTAssertTrue(notebook.saveDraft(page.id, data, nil), "a draft protects the strokes meanwhile")
        let sha = try await notebook.commit(page.id, data, drawing.strokes.count, 1)
        XCTAssertEqual(controller.meeting(id)?.page(page.id)?.drawing?.sha256, sha)
        XCTAssertEqual(notebook.content(page.id), .strokes(data), "read back from the library's file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page.id).path), "the draft goes once the commit is durable")
    }

    func testBehaviorDraftStaysUntilTheConversationIsOnDisk() async throws {
        let model = try makeModel()
        try await model.library.reload()
        let controller = model.library.controller
        controller.saveDelay = .seconds(60)
        let id = controller.newMeeting(title: "Design review")
        let page = NotebookPage(order: 1, now: t0)
        controller.addPage(page, to: id)
        let drafts = PageDrafts(root: model.library.rootURL, meeting: id)
        let drawing = SyntheticInk.drawing("hello", start: t0)
        let data = drawing.dataRepresentation()
        // The save can't be made: the draft is the only copy of the strokes.
        struct NotSaved: Error {}
        let failing = NotebookModel.conversation(id, model: model, player: PlaybackController(), provider: LocalAudioProvider(library: model.library),
                                                 drafts: drafts, durably: { _ in throw NotSaved() })
        XCTAssertTrue(failing.saveDraft(page.id, data, nil))
        let sha = try await failing.commit(page.id, data, drawing.strokes.count, 1)
        XCTAssertEqual(controller.meeting(id)?.page(page.id)?.drawing?.sha256, sha)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drafts.url(page.id).path), "not on disk yet: the draft stays")
        // Saved for real: the meeting file holds the drawing by the time the draft goes.
        let notebook = NotebookModel.conversation(id, model: model, player: PlaybackController(), provider: LocalAudioProvider(library: model.library), drafts: drafts)
        _ = try await notebook.commit(page.id, data, drawing.strokes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page.id).path))
        let saved = try Data(contentsOf: model.library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/meeting.json"))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains(sha), "the conversation reached the disk before the draft went")
    }

    private func conversationWithPage(_ model: PhoneAppModel, drawing: PKDrawing? = nil) async throws -> (id: UUID, page: UUID, drafts: PageDrafts) {
        try await model.library.reload()
        let controller = model.library.controller
        let id = controller.newMeeting(title: "Design review")
        let page = NotebookPage(order: 1, now: t0)
        controller.addPage(page, to: id)
        if let drawing {
            try await controller.commitPageDrawing(drawing.dataRepresentation(), page: page.id, in: id, strokeCount: drawing.strokes.count, contentVersion: 1, device: "Other")
        }
        return (id, page.id, PageDrafts(root: model.library.rootURL, meeting: id))
    }

    private func storedStrokes(_ model: PhoneAppModel, _ id: UUID, _ page: UUID) throws -> Set<String> {
        let drawing = try XCTUnwrap(model.library.controller.meeting(id)?.page(page)?.drawing)
        let data = try Data(contentsOf: model.library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)"))
        return Set(NotebookReader.strokes(of: try PKDrawing(data: data)).map(\.key))
    }

    func testBehaviorRecoveryMergesADraftWithWhatAnotherDeviceCommitted() async throws {
        let model = try makeModel()
        let first = SyntheticInk.drawing("hello", start: t0)
        let theirs = SyntheticInk.drawing("hi", start: t0.addingTimeInterval(500))
        let (id, page, drafts) = try await conversationWithPage(model, drawing: PKDrawing(strokes: first.strokes + theirs.strokes))
        // The draft began from the strokes before the other device's, and holds one more of this device's own.
        let mine = SyntheticInk.drawing("ok", start: t0.addingTimeInterval(900))
        let draft = PKDrawing(strokes: first.strokes + mine.strokes)
        XCTAssertTrue(drafts.write(draft.dataRepresentation(), page: page, base: "older-sha"))
        await drafts.recover(in: id, library: model.library.controller, device: "Test")
        let keys = { (drawing: PKDrawing) in Set(NotebookReader.strokes(of: drawing).map(\.key)) }
        XCTAssertEqual(try storedStrokes(model, id, page), keys(first).union(keys(theirs)).union(keys(mine)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page).path))
    }

    func testBehaviorRecoveryCommitsAnOlderDraftWhenNothingChangedElsewhere() async throws {
        let model = try makeModel()
        let first = SyntheticInk.drawing("hello", start: t0)
        let (id, page, drafts) = try await conversationWithPage(model, drawing: first)
        let stored = try XCTUnwrap(model.library.controller.meeting(id)?.page(page)?.drawing)
        let draft = SyntheticInk.drawing("hello ok", start: t0)
        XCTAssertTrue(drafts.write(draft.dataRepresentation(), page: page, base: stored.sha256))
        // Older than the committed drawing by the file's date, but it holds strokes that were never committed.
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: drafts.url(page).path)
        await drafts.recover(in: id, library: model.library.controller, device: "Test")
        XCTAssertEqual(try storedStrokes(model, id, page), Set(NotebookReader.strokes(of: draft).map(\.key)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page).path))
    }

    func testBehaviorRecoveryKeepsTheDraftWhenTheStoredStrokesAreNotHere() async throws {
        let model = try makeModel()
        let (id, page, drafts) = try await conversationWithPage(model)
        let sha = String(repeating: "cd", count: 32)
        model.library.controller.update(id) {
            $0.pages?[0].drawing = PageDrawing(relativePath: PageDrawing.relativePath(page: page, sha256: sha), sha256: sha, byteCount: 10,
                                               strokeCount: 4, editedAt: t0.addingTimeInterval(100))
        }
        XCTAssertTrue(drafts.write(SyntheticInk.drawing("hello", start: t0).dataRepresentation(), page: page, base: nil))
        await drafts.recover(in: id, library: model.library.controller, device: "Test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: drafts.url(page).path), "never over a drawing that isn't here: kept for when it arrives")
        XCTAssertEqual(model.library.controller.meeting(id)?.page(page)?.drawing?.sha256, sha)
    }

    func testBehaviorRecoveryDropsADraftOfADeletedPageAndRestoresAMissingOne() async throws {
        let model = try makeModel()
        let (id, page, drafts) = try await conversationWithPage(model)
        let draft = SyntheticInk.drawing("hello", start: t0)
        XCTAssertTrue(drafts.write(draft.dataRepresentation(), page: page, base: nil))
        _ = model.library.controller.removePage(page, in: id)
        await drafts.recover(in: id, library: model.library.controller, device: "Test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(page).path), "its page is deleted")
        XCTAssertNil(model.library.controller.meeting(id)?.page(page)?.drawing)

        let missing = UUID()
        XCTAssertTrue(drafts.write(draft.dataRepresentation(), page: missing, base: nil))
        await drafts.recover(in: id, library: model.library.controller, device: "Test")
        XCTAssertNotNil(model.library.controller.meeting(id)?.page(missing)?.drawing, "the page comes back with its strokes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drafts.url(missing).path))
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
        for _ in 0..<500 where !session.unavailable.contains(page.id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.unavailable.contains(page.id))
        XCTAssertFalse(session.isWritable(page.id))
        let view = try XCTUnwrap(session.canvas(for: page.id))
        view.load(SyntheticInk.drawing("hello", start: t0))
        session.changed(view)
        await session.settle(.close)
        XCTAssertEqual(controller.meeting(id)?.page(page.id)?.drawing?.sha256, String(repeating: "ab", count: 32), "the conversation's strokes are untouched")
    }

    func testBehaviorLeavingAPageOutOfSummariesIsKeptInTheLibraryAndUndone() async throws {
        let model = try makeModel()
        let (id, page, drafts) = try await conversationWithPage(model)
        let notebook = NotebookModel.conversation(id, model: model, player: PlaybackController(), provider: LocalAudioProvider(library: model.library), drafts: drafts)
        let session = NotebookSession()
        session.bind(notebook)
        session.setHiddenFromSummary(page, true)
        XCTAssertEqual(model.library.controller.meeting(id)?.page(page)?.hiddenFromSummary, true)
        XCTAssertEqual(notebook.pages().first?.hiddenFromSummary, true, "the notebook's page shows it")
        session.setHiddenFromSummary(page, false)
        XCTAssertNil(model.library.controller.meeting(id)?.page(page)?.hiddenFromSummary)
    }
}
