import DaybookCore
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Mac first, with Daybook on iPhone recording along (docs/multipoint.md, "Mac first"): this Mac
/// transcribes and summarizes its own audio straight away and says it's waiting for the iPhone's;
/// when the phone's recording arrives through sync it's added, and the transcript and summary are
/// enhanced without losing the person's work. Loopback link, temporary libraries and sync folder, a
/// fake inference engine, synthetic audio.
@MainActor
final class MacFirstMultipointTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: true)
        addTeardownBlock { await rig.state.phoneLink.shutDown(); await rig.tearDown() }
        return rig
    }

    func testTheMacSummarizesItsOwnAudioWhileWaitingForThePhonesThenEnhances() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let link = try await PhoneLinkRig.connect(state)
        defer { Task { await link.tearDown(state) } }
        let phone = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { phone.tearDown() }
        let recordingID = UUID()
        let phoneStart = Date()
        link.recorder.answer = { request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: phoneStart, recordingID: recordingID.uuidString))
        }
        let macAudio = try rig.audio("mac.wav", frequency: 310)
        let phoneAudio = try rig.audio("iphone.wav", frequency: 470)
        try rig.inference.script(macAudio, [(0, "Agenda first."), (5, "Then the budget.")])
        try rig.inference.script(phoneAudio, [(0, "Agenda first."), (5, "Then the budget."), (10, "And someone near the phone agreed.")])

        // This Mac records with the phone along, and stops; the phone's recording is still on the phone.
        let id = state.newMeeting(title: "Design review")
        state.prepareSourceCapture(id)
        state.recordingID = id
        state.recordingStartedAt = Date()
        state.update(id) { $0.status = .recording }
        state.recordingDidStart(id)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()
        state.recordingWillFinish(id, at: Date())
        state.recordingID = nil
        state.recordingStartedAt = nil
        await state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
        try await storeMacRecording(rig, id, audio: macAudio, start: macStart)

        // Processing starts at once, on this Mac's audio, and says what it's waiting for.
        try rig.inference.block(macAudio)
        state.enqueue(id)
        try await waitUntil("this Mac's audio to be transcribing") { rig.inference.isWaiting(on: macAudio) }
        guard case .processing(let working) = state.processingStatus(for: try XCTUnwrap(rig.meeting(id))) else {
            return XCTFail("processing")
        }
        XCTAssertEqual(working.awaiting.map(\.deviceName), [PhoneLinkRig.phoneName])
        try rig.inference.unblock(macAudio)
        try await rig.processed(id)

        var meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(meeting.summary?.overview, "Summary 1", "Summarized from this Mac's audio without waiting")
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Agenda first.", "Then the budget."])
        let waiting = state.processingStatus(for: meeting)
        XCTAssertEqual(waiting, .awaitingRecordings([AwaitedRecording(deviceName: PhoneLinkRig.phoneName, deviceKind: DaybookPhoneIntegration.id,
                                                                      since: try XCTUnwrap(meeting.companions?.first?.macEndedAt))]))
        // Wherever processing status shows: the list row, the page line, Floating Notes.
        XCTAssertEqual(RowStatus(state: state, meeting: meeting).text, "Waiting for iPhone audio")
        XCTAssertEqual(FloatingStatusInputs.work(for: meeting, state: state), .awaiting("Waiting for iPhone audio"))
        if case .awaitingRecordings(let recordings) = waiting {
            XCTAssertEqual(ProcessingStatus.awaitingDetail(recordings), "Waiting for audio from \(PhoneLinkRig.phoneName)")
        }

        // The person works on it meanwhile.
        let corrected = try XCTUnwrap(meeting.unifiedTranscript.first)
        state.update(id) { $0.correctSegment(id: corrected.id, text: "Agenda first, please.") }
        if let speaker = corrected.speakerID { state.update(id) { $0.renameSpeaker(id: speaker, name: "Dana") } }
        state.editNotes(id, text: "Budget is the risk")
        await state.flush()

        // The iPhone sees it through sync: the Mac's summary, and its own recording still to add.
        await state.synchronizeLibrary()
        await phone.synchronize()
        try await phone.file(phoneAudio, recordingID: recordingID, into: id, start: phoneStart, duration: 0.5)
        let onPhone = try XCTUnwrap(phone.library.meeting(id))
        XCTAssertNotNil(onPhone.summary)
        guard case .requested = ProcessingStatus(onPhone) else { return XCTFail("The phone waits for a Mac to add its own recording") }

        // It arrives on this Mac: added, lined up, transcribed, and the summary written again from both.
        await phone.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("the phone's recording to be added and summarized", timeout: 20) {
            rig.meeting(id)?.summary?.overview == "Summary 2" && state.processingID == nil && state.queuedIDs.isEmpty
        }
        meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(state.processingStatus(for: meeting), .done)
        XCTAssertEqual(meeting.companions?.first?.state, .attached)
        XCTAssertEqual(meeting.tracks.count, 2)
        XCTAssertTrue(meeting.unifiedTranscript.contains { $0.text == "And someone near the phone agreed." }, "The phone heard more")
        XCTAssertTrue(meeting.unifiedTranscript.contains { $0.id == corrected.id && $0.text == "Agenda first, please." }, "The correction survives")
        if let speaker = corrected.speakerID { XCTAssertEqual(meeting.speakers.first { $0.id == speaker }?.name, "Dana") }
        XCTAssertEqual(meeting.notes, "Budget is the risk")
        XCTAssertTrue(meeting.revisions.contains { $0.field == "summary" && $0.newValue.contains("Summary 2") && $0.oldValue.contains("Summary 1") },
                      "The first summary is in Version History")
        XCTAssertEqual(rig.inference.transcribed.count, 2, "Each recording transcribed once")

        // And the phone sees it done.
        await state.synchronizeLibrary()
        await phone.synchronize()
        XCTAssertEqual(phone.library.processingStatus(for: id), .done)
    }

    /// This Mac's own recording of `id`, stored as capture stores it, without starting processing.
    private func storeMacRecording(_ rig: MultiSourceRig, _ id: UUID, audio: URL, start: Date) async throws {
        let installed = rig.state.installedModels
        rig.state.installedModels = []
        try await rig.state.importFiles([audio], source: .microphone, attachTo: id)
        rig.state.installedModels = installed
        rig.state.awaitingModels.remove(id)
        rig.state.update(id) { meeting in
            meeting.tracks[0].offset = 0
            meeting.tracks[0].createdAt = start
            meeting.tracks[0].duration = 0.5
            meeting.status = .imported
        }
        await rig.state.flush()
    }
}
