import AVFoundation
import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import Observation
import XCTest
@testable import Daybook

@MainActor
final class AppStateTests: XCTestCase {
    func testConcurrentImportsPreserveBothSourcesAndCurrentNotes() async throws {
        let (state, root, _) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = state.newMeeting(title: "Concurrent import")
        let one = try audio(root, name: "one.wav", frequency: 220)
        let two = try audio(root, name: "two.wav", frequency: 440)
        async let first: Void = state.importFiles([one], source: .soundcore, attachTo: id)
        async let second: Void = state.importFiles([two], source: .imported, attachTo: id)
        await Task.yield()
        state.editNotes(id, text: "Keep this note while both sources are importing.")
        state.update(id) { $0.highlights.append(Highlight(time: 12, text: "Imported marker")) }
        try await first; try await second
        await state.flush()
        let store = try MeetingStore(rootURL: root)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.tracks.count, 2)
        XCTAssertEqual(state.meetings.first?.tracks.count, 2)
        XCTAssertEqual(saved.notes, "Keep this note while both sources are importing.")
        XCTAssertTrue(saved.revisions.contains { $0.field == "notes" })
        XCTAssertEqual(saved.highlights.count, 1)
        XCTAssertEqual(saved.status, .imported)
    }

    func testSameRecordingIsNotImportedAgainAsAnotherMeeting() async throws {
        let (state, root, _) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try audio(root, name: "first.wav", frequency: 440)
        try await state.importFiles([one], source: .soundcore, attachTo: nil)
        await state.flush()
        let two = root.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: one, to: two)
        try await state.importFiles([two], source: .imported, attachTo: nil)
        await state.flush()
        XCTAssertEqual(state.meetings.count, 1)
        XCTAssertEqual(state.meetings.first?.tracks.count, 1)
        XCTAssertTrue(state.notice?.contains("already") == true)
    }

    func testPendingRecordingCannotBeTrashed() async throws {
        let (state, root, _) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = state.newMeeting()
        state.isStartingRecording = true
        state.trashMeeting(id)
        await state.flush()
        XCTAssertNotNil(state.meetings.first { $0.id == id })
        let store = try MeetingStore(rootURL: root)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.id, id)
        state.isStartingRecording = false
    }

    func testRestartPreservesNotesAndPendingAudioWithoutModels() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try audio(root, name: "meeting.wav", frequency: 220)
        try await state.importFiles([one], source: .imported, attachTo: nil)
        let id = try XCTUnwrap(state.meetings.first?.id)
        state.editNotes(id, text: "The original note.")
        await state.flush()
        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        XCTAssertEqual(restarted.meetings.first?.notes, "The original note.")
        XCTAssertEqual(restarted.meetings.first?.tracks.count, 1)
        XCTAssertFalse(restarted.canProcess)
        XCTAssertFalse(restarted.automaticRecording)
    }

    func testSignedTimelineLabelsRetainEarlierWearableAudio() {
        XCTAssertEqual(TimeLabel.format(-15), "−00:15")
        XCTAssertEqual(TimeLabel.format(3661), "1:01:01")
        XCTAssertEqual(TimeLabel.format(.nan), "00:00")
        XCTAssertEqual(TimeLabel.short(14), "0:14")
        XCTAssertEqual(TimeLabel.short(-15), "−0:15")
        XCTAssertEqual(TimeLabel.short(3661), "1:01:01")
    }

    func testRecoveryNeverResurrectsTrashedConversation() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = state.newMeeting(title: "Intentionally trashed")
        await state.flush()
        let store = try MeetingStore(rootURL: root)
        _ = try await store.moveToTrash(id)
        let staged = root.appendingPathComponent("Staging/\(id.uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        _ = try audio(staged, name: "microphone.caf", frequency: 220)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 1, includeSystemAudio: false)
        try encoder.encode(manifest).write(to: staged.appendingPathComponent("capture-session.json"))
        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        await restarted.flush()
        XCTAssertTrue(restarted.meetings.isEmpty)
        XCTAssertNil(restarted.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("microphone.caf").path))
    }

    func testBehaviorQuittingWhileRecordingAsksAndASecondQuitWaitsForTheFirst() {
        XCTAssertEqual(QuitDecision.decide(quitting: false, hasState: true, recording: true, poweringOff: false), .askToStopRecording)
        XCTAssertEqual(QuitDecision.decide(quitting: false, hasState: true, recording: true, poweringOff: true), .finishThenQuit,
                       "Logging out or shutting down stops the recording without asking")
        XCTAssertEqual(QuitDecision.decide(quitting: false, hasState: true, recording: false, poweringOff: false), .finishThenQuit)
        XCTAssertEqual(QuitDecision.decide(quitting: false, hasState: false, recording: false, poweringOff: false), .now)
        // A second ⌘Q or the Dock's Quit while the first stops and saves is turned down, never quits at once; a logout
        // waits for it.
        XCTAssertEqual(QuitDecision.decide(quitting: true, hasState: true, recording: true, poweringOff: false), .alreadyQuitting)
        XCTAssertEqual(QuitDecision.decide(quitting: true, hasState: true, recording: false, poweringOff: true), .waitForQuit)
        XCTAssertEqual(QuitDecision.decide(finished: true, quitting: true, hasState: true, recording: false, poweringOff: false), .now,
                       "The work done, the quit it asks for goes ahead")
    }

    /// AppKit doesn't ask again on a second quit while an answer is pending (`.terminateLater`): it quits at once. So an
    /// ordinary quit is turned down while its work runs and asked again once it's done, and a quit meanwhile is turned
    /// down too. A logout, restart, or shutdown is answered later instead, since turning it down would stop it.
    func testBehaviorAQuitIsTurnedDownWhileItsWorkRunsThenAskedAgainAndALogoutWaitsForIt() async throws {
        let (state, _, _) = try await makeState()
        let delegate = DaybookDelegate()
        delegate.state = state
        var replies = 0, askedAgain = 0
        let reply = { replies += 1 }, quitAgain = { askedAgain += 1 }
        XCTAssertEqual(delegate.shouldTerminate(poweringOff: false, reply: reply, quitAgain: quitAgain), .terminateCancel)
        XCTAssertEqual(delegate.shouldTerminate(poweringOff: false, reply: reply, quitAgain: quitAgain), .terminateCancel,
                       "A second ⌘Q while the first stops and saves")
        XCTAssertEqual(delegate.shouldTerminate(poweringOff: true, reply: reply, quitAgain: quitAgain), .terminateLater,
                       "A logout meanwhile waits for that work")
        try await waitUntil("the work to finish, the logout's answer, and the quit asked again") { replies == 1 && askedAgain == 1 }
        XCTAssertEqual(delegate.shouldTerminate(poweringOff: false, reply: reply, quitAgain: quitAgain), .terminateNow)

        let (other, _, _) = try await makeState()
        let shuttingDown = DaybookDelegate()
        shuttingDown.state = other
        XCTAssertEqual(shuttingDown.shouldTerminate(poweringOff: true, reply: reply, quitAgain: quitAgain), .terminateLater)
        try await waitUntil("answered once its work is done") { replies == 2 }
        XCTAssertEqual(askedAgain, 1, "Answered, it isn't asked again")
    }

    /// Logging out, restarting, and shutting down are told apart by the reason the quit event carries, read for each
    /// request: a logout another app called off leaves nothing behind for the next Quit.
    func testBehaviorOnlyTheMacsOwnQuitEventsCountAsPoweringOff() {
        func quit(reason: OSType?, asParameter: Bool = false) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            if let reason {
                let value = NSAppleEventDescriptor(typeCode: reason)
                if asParameter { event.setParam(value, forKeyword: AEKeyword(kAEQuitReason)) }
                else { event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason)) }
            }
            return event
        }
        XCTAssertTrue(QuitDecision.isPowerOff(quit(reason: OSType(kAEShutDown))))
        XCTAssertTrue(QuitDecision.isPowerOff(quit(reason: OSType(kAERestart))))
        XCTAssertTrue(QuitDecision.isPowerOff(quit(reason: OSType(kAEReallyLogOut))))
        XCTAssertTrue(QuitDecision.isPowerOff(quit(reason: OSType(kAEShutDown), asParameter: true)))
        XCTAssertFalse(QuitDecision.isPowerOff(quit(reason: nil)), "The Dock's Quit")
        XCTAssertFalse(QuitDecision.isPowerOff(nil), "⌘Q, or the menu")
        let open = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        open.setAttribute(NSAppleEventDescriptor(typeCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
        XCTAssertFalse(QuitDecision.isPowerOff(open), "Only a quit event")
    }

    // MARK: The Trash, with Undo

    /// Three conversations, newest first in the list: "Monday" (newest), "Tuesday", "Wednesday".
    private func threeConversations(_ state: AppState) async -> [UUID] {
        let now = Date()
        let ids = ["Wednesday", "Tuesday", "Monday"].enumerated().map { index, title in
            state.newMeeting(title: title, date: now.addingTimeInterval(Double(-index) * 3600))
        }
        await state.flush()
        return ids
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    func testBehaviorMoveToTrashSelectsTheNextRowAndEditUndoPutsItBack() async throws {
        let (state, _, _) = try await makeState()
        let ids = await threeConversations(state)
        XCTAssertEqual(state.listedMeetingIDs, ids)
        let undo = undoManager()
        state.selectedID = ids[1]
        state.trashMeetings([ids[1]], undoManager: undo)
        try await waitUntil("it to go to the Trash") { !state.meetings.contains { $0.id == ids[1] } }
        XCTAssertEqual(state.selectedID, ids[2], "The row after it, not the top of the list")
        XCTAssertEqual(state.noticeLines, ["Moved “Tuesday” to the Trash."])
        XCTAssertEqual(state.shownNoticeAction?.title, "Undo")
        XCTAssertEqual(undo.undoActionName, "Move to Trash")

        undo.undo()
        try await waitUntil("it to come back") { state.meetings.contains { $0.id == ids[1] } }
        XCTAssertEqual(state.selectedID, ids[1], "Back, and selected")
        XCTAssertNil(state.notice, "The notice's line goes with what it said")
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(undo.redoActionName, "Move to Trash")
        undo.redo()
        try await waitUntil("it to go again") { !state.meetings.contains { $0.id == ids[1] } }
        XCTAssertTrue(undo.canUndo, "Undoable again")
        await state.flush()
    }

    func testBehaviorTheNoticesUndoPutsTrashedConversationsBackAndLeavesNothingToUndo() async throws {
        let (state, _, _) = try await makeState()
        let ids = await threeConversations(state)
        let undo = undoManager()
        state.selectedID = ids[2]
        state.trashMeetings([ids[1], ids[2]], undoManager: undo)
        try await waitUntil("both to go") { state.meetings.count == 1 }
        XCTAssertEqual(state.selectedID, ids[0], "The last rows went: the one before them")
        XCTAssertEqual(state.noticeLines, ["Moved 2 conversations to the Trash."])
        state.performNoticeAction()
        try await waitUntil("both to come back") { state.meetings.count == 3 }
        XCTAssertFalse(undo.canUndo, "Undone from the notice: Edit › Undo has nothing left to take back")
        XCTAssertNil(state.notice)
        await state.flush()
    }

    /// Several rows at once: each move lets the list look, and the list selects its first row once the selected one is
    /// gone. The neighbour is selected as the selected row goes, so the list finds it there.
    func testBehaviorTrashingSeveralRowsKeepsThePlaceWhileTheListLooksBetweenMoves() async throws {
        let (state, _, _) = try await makeState()
        let now = Date()
        let ids = ["A", "B", "C", "D", "E"].enumerated().map { index, title in
            state.newMeeting(title: title, date: now.addingTimeInterval(Double(-index) * 3600))
        }
        await state.flush()
        XCTAssertEqual(state.listedMeetingIDs, ids)
        state.selectedID = ids[1]
        let list = ListSelectionFollower()
        list.follow(state)
        state.trashMeetings([ids[1], ids[2]], undoManager: nil)
        try await waitUntil("both to go") { state.meetings.count == 3 }
        try await waitUntil("the list to look") { list.looks > 0 }
        XCTAssertEqual(state.selectedID, ids[3], "The row after them, not the top of the list")
        list.stop()
        await state.flush()
    }

    func testBehaviorTheRowSelectedAfterATrashIsItsNeighbour() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertEqual(AppState.neighbour(of: [b], in: [a, b, c, d]), c)
        XCTAssertEqual(AppState.neighbour(of: [b, c], in: [a, b, c, d]), d)
        XCTAssertEqual(AppState.neighbour(of: [d], in: [a, b, c, d]), c, "At the end, the one before")
        XCTAssertEqual(AppState.neighbour(of: [a, c], in: [a, b, c, d]), d, "After the last of them")
        XCTAssertNil(AppState.neighbour(of: [a, b], in: [a, b]))
        XCTAssertNil(AppState.neighbour(of: [UUID()], in: [a, b]), "Not in the list")
    }

    func testBehaviorFilingIsUndoneByTheMenuItemsName() async throws {
        let (state, _, _) = try await makeState()
        let id = state.newMeeting(title: "Retro")
        let folder = UUID()
        state.saveFolder(LibraryFolder(id: folder, name: "Clients"))
        let undo = undoManager()
        undo.beginUndoGrouping()
        state.moveToFolder([id], folder, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Move to Folder")
        undo.beginUndoGrouping()
        state.setPlacement([id], .personal, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Move to Personal")
        undo.undo()
        XCTAssertNil(state.meetings.first { $0.id == id }?.placement)
        undo.undo()
        XCTAssertNil(state.meetings.first { $0.id == id }?.folderID)
        XCTAssertEqual(AppState.placementActionName(.work), "Move to Work")
        await state.flush()
    }

    // MARK: Starting, and what goes wrong

    func testBehaviorARecordingThatCantStartLeavesNoEmptyConversationAndOffersSettings() async throws {
        let microphone = FakeCaptureSource(method: "microphone")
        let capture = CaptureEnvironment(microphoneAuthorization: { false }, makeMicrophone: { microphone }, systemAudio: FakeSystemAudio(),
                                         currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
                                         observeRoutes: { _ in nil }, hostTime: { 100 })
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookStart"), defaults: makeTestDefaults(), capture: capture)
        await state.initialize()
        state.includeComputerAudio = false
        let earlier = state.newMeeting(title: "Earlier")
        await state.startRecording()
        try await waitUntil("the empty conversation to go") { state.meetings.map(\.id) == [earlier] }
        XCTAssertEqual(state.selectedID, earlier, "The selection goes back")
        XCTAssertEqual(state.shownProblem?.title, "Couldn’t Start Recording")
        XCTAssertEqual(state.shownProblem?.privacyPane, .microphone, "The alert offers Open System Settings")
        XCTAssertNil(state.recordingID)

        // Recording into a note: the note stays as it was, and isn't marked as a failure.
        state.dismissProblem()
        let note = state.newNote()
        state.editNotes(note, text: "Agenda")
        let before = try XCTUnwrap(state.meetings.first { $0.id == note }).status
        await state.startRecording(into: note)
        let kept = try XCTUnwrap(state.meetings.first { $0.id == note })
        XCTAssertEqual(kept.status, before)
        XCTAssertNotEqual(kept.status, .failed)
        XCTAssertNil(kept.errorMessage)
        XCTAssertEqual(kept.notes, "Agenda")
        XCTAssertNotNil(state.shownProblem)
        await state.flush()
    }

    func testBehaviorAudioWorkThePersonDidntStartNeverRaisesAnAlert() async throws {
        let (state, _, _) = try await makeState()
        let id = state.newMeeting(title: "Synced")
        let missing = RecordingTrack(relativePath: "../../outside.wav", fileName: "outside.wav")
        let background = await state.availableAudioURL(for: missing, in: id)
        XCTAssertNil(background)
        XCTAssertNil(state.shownProblem, "Placing or comparing a recording that arrived says nothing over the window")
        let asked = await state.audioURL(for: missing, meetingID: id)
        XCTAssertNil(asked)
        XCTAssertEqual(state.shownProblem?.title, "Couldn’t Open the Audio", "Playing it is the person's: that's said")
        await state.flush()
    }

    func testBehaviorALibraryThatCantOpenSaysSoOnThePageAndOpensWhenTriedAgain() async throws {
        let folder = makeTemporaryFolder("DaybookUnopenable")
        let root = folder.appendingPathComponent("Library")
        try Data("not a folder".utf8).write(to: root)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults())
        await state.initialize()
        XCTAssertFalse(state.isReady)
        XCTAssertEqual(state.libraryProblem?.title, "Couldn’t Open Your Library")
        XCTAssertEqual(state.libraryProblem?.message, "Its folder couldn’t be opened. Check it in Finder, then try again.")
        XCTAssertNotNil(state.libraryProblem?.details, "The system's words are behind Details…")
        XCTAssertNil(state.shownProblem, "No alert over an empty window")

        try FileManager.default.removeItem(at: root)
        await state.retryOpeningLibrary()
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.libraryProblem)
        await state.flush()
    }

    // MARK: Menus

    func testBehaviorFloatingNotesOpensOnTheRecordingElseWhatTheWindowShows() async throws {
        let (state, _, _) = try await makeState()
        let shown = state.newMeeting(title: "Shown")
        XCTAssertEqual(state.floatingNotesFocus, shown)
        state.multiSelection = [shown, state.newMeeting(title: "Other", selecting: false)]
        XCTAssertNil(state.floatingNotesFocus, "Several selected: its home")
        state.multiSelection = []
        let recording = state.newMeeting(title: "Recording", selecting: false)
        state.recordingID = recording
        XCTAssertEqual(state.floatingNotesFocus, recording)
        state.recordingID = nil
        await state.flush()
    }

    func testBehaviorAddBookmarkMarksTheRecordingOrThePlayersMoment() async throws {
        let (state, root, _) = try await makeState()
        let url = try audio(root, name: "review.wav", frequency: 330)
        try await state.importFiles([url], source: .imported, attachTo: nil)
        let id = try XCTUnwrap(state.meetings.first?.id)
        let track = try XCTUnwrap(state.meetings.first?.tracks.first)
        XCTAssertFalse(state.canAddBookmark(in: id), "Nothing recording, nothing loaded")

        let found = await state.audioURL(for: track, meetingID: id)
        let playable = try XCTUnwrap(found)
        state.playback.play(url: playable, at: 0.2, trackID: track.id, meetingID: id)
        state.playback.mute()
        state.playback.pause()
        XCTAssertTrue(state.canAddBookmark(in: id))
        XCTAssertFalse(state.canAddBookmark(in: UUID()), "Another conversation on screen")
        state.addBookmark(in: id)
        let mark = try XCTUnwrap(state.meetings.first?.highlights.first)
        XCTAssertEqual(mark.trackID, track.id)
        XCTAssertEqual(mark.time, state.playback.position, accuracy: 0.05)
        state.playback.unload()

        state.recordingID = state.newMeeting(title: "Live", selecting: false)
        XCTAssertTrue(state.canAddBookmark(in: nil), "While recording, wherever the person is")
        state.recordingID = nil
        await state.flush()
    }

    private func makeState() async throws -> (AppState, URL, UserDefaults) {
        let root = makeTemporaryFolder("DaybookAppTests")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.errorMessage)
        return (state, root, defaults)
    }
    private func audio(_ root: URL, name: String, frequency: Double) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for index in 0..<8_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * frequency * 2 * .pi / 16_000) * 0.2) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// What the library window's list does as its rows change (`LibraryView.reconcileSelection`), when SwiftUI runs it: on a
/// later turn of the main queue, it selects the first row once the selected one is gone.
@MainActor
private final class ListSelectionFollower {
    private(set) var looks = 0
    private var following = false

    func follow(_ state: AppState) {
        following = true
        observe(state)
    }

    func stop() { following = false }

    private func observe(_ state: AppState) {
        withObservationTracking { _ = state.visibleMeetings.map(\.id) } onChange: { [weak self, weak state] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let state, self.following else { return }
                    self.looks += 1
                    let visible = state.visibleMeetings
                    if state.isReady, !state.isSearching, !state.place.isDevice, !visible.contains(where: { $0.id == state.selectedID }) {
                        state.multiSelection = []
                        state.selectedID = visible.first?.id
                    }
                    self.observe(state)
                }
            }
        }
    }
}
