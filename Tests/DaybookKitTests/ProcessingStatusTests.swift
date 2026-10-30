import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// The table in docs/iphone.md: Recorded, Requested, Processing, Done, Couldn't finish, from the
/// conversation's data alone (the iPhone) and with a Mac's own queue.
final class ProcessingStatusTests: XCTestCase {
    private let phone = ProcessingRequest.Device(id: "phone", name: "iPhone")
    private let mac = ProcessingRequest.Device(id: "mac", name: "Mac Studio")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func recorded() -> Meeting {
        Meeting(title: "Walk and talk", tracks: [RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", sha256: "a")],
                status: .imported)
    }

    private func transcribed(_ meeting: Meeting, summaryAt date: Date) -> Meeting {
        var meeting = meeting
        meeting.transcripts = meeting.tracks.map { TrackTranscript(trackID: $0.id, segments: [], createdAt: date) }
        meeting.setSummary(MeetingSummary(overview: "Plans", modelID: "m", createdAt: date))
        meeting.status = .ready
        return meeting
    }

    func testAudioWithoutATranscriptOrARequestIsRecorded() {
        XCTAssertEqual(ProcessingStatus(recorded(), now: now), .recorded)
        XCTAssertTrue(ProcessingStatus(recorded(), now: now).isRecorded)
    }

    func testNotesOnlyAndProcessedConversationsAreDone() {
        XCTAssertEqual(ProcessingStatus(Meeting(title: "Notes", notes: "Agenda"), now: now), .done)
        XCTAssertEqual(ProcessingStatus(transcribed(recorded(), summaryAt: now), now: now), .done)
    }

    func testATranscriptWithoutASummaryIsTranscribed() {
        var meeting = recorded()
        let track = meeting.tracks[0].id
        let words = TranscriptSegment(trackID: track, start: 0, end: 2, text: "Agenda first.")
        meeting.transcripts = [TrackTranscript(trackID: track, segments: [words], createdAt: now)]
        meeting.unifiedTranscript = [words]
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .transcribed)
        XCTAssertFalse(ProcessingStatus(meeting, now: now).isPending, "Summarize can be asked for")
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(), now: now), .transcribed, "On a Mac at rest too")
        // Summarize writes a request, which waits for a Mac; the summary settles it.
        let request = ProcessingRequest(meetingID: meeting.id, mode: .summaryOnly, requestedBy: phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .requested(.device(request)))
        meeting.setSummary(MeetingSummary(overview: "Plans", modelID: "m", createdAt: now.addingTimeInterval(60)))
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .done)
        // A transcript without words has nothing to summarize.
        var silent = recorded()
        silent.transcripts = [TrackTranscript(trackID: silent.tracks[0].id, segments: [], createdAt: now)]
        XCTAssertEqual(ProcessingStatus(silent, now: now), .done)
    }

    func testAnOpenRequestWaitsForAMac() {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .requested(.device(request)))
        XCTAssertTrue(ProcessingStatus(meeting, now: now).isPending)
    }

    func testAClaimedRequestIsProcessingOnThatMacUntilTheClaimExpires() throws {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        let claimed = try XCTUnwrap(request.claimed(by: mac, at: now, lease: 600)?.renewed(by: mac, at: now.addingTimeInterval(60), lease: 600,
                                                                                                    stage: .transcribing, fraction: 0.4))
        meeting.upsertProcessingRequest(claimed)
        XCTAssertEqual(ProcessingStatus(meeting, now: now.addingTimeInterval(61)),
                       .processing(.init(stage: .transcribing, fraction: 0.4, device: mac)))
        // The Mac went quiet: the request is waiting again, and any Mac may take it.
        guard case .requested(.device(let waiting)) = ProcessingStatus(meeting, now: now.addingTimeInterval(661)) else {
            return XCTFail("An expired claim reads as waiting")
        }
        XCTAssertEqual(waiting.id, request.id)
    }

    func testAFailedRequestShowsTheMacsReasonUntilANewOneIsMade() throws {
        var meeting = recorded()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        let failed = try XCTUnwrap(request.claimed(by: mac, at: now)?.failed(by: mac, at: now.addingTimeInterval(5), reason: "Not enough memory."))
        meeting.upsertProcessingRequest(failed)
        guard case .failed(let failure) = ProcessingStatus(meeting, now: now.addingTimeInterval(6)) else { return XCTFail("Couldn’t finish") }
        XCTAssertEqual(failure.reason, "Not enough memory.")
        XCTAssertEqual(failure.device, mac)
        XCTAssertEqual(failure.request?.id, request.id)
        XCTAssertFalse(failure.hadTranscripts)

        // Try Again writes a new request.
        let retry = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(10))
        meeting.upsertProcessingRequest(retry)
        XCTAssertEqual(ProcessingStatus(meeting, now: now.addingTimeInterval(11)), .requested(.device(retry)))
    }

    func testAConversationThatFailedHereIsCouldntFinish() {
        var meeting = recorded()
        meeting.status = .failed
        meeting.errorMessage = "No speech was recognized."
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .failed(.init(reason: "No speech was recognized.", hadTranscripts: false)))
    }

    func testARequestTheConversationAlreadySatisfiesIsNotWaiting() {
        // A Mac transcribed the phone's recording as it arrived through sync, without claiming the request.
        var meeting = recorded()
        meeting.upsertProcessingRequest(ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now))
        XCTAssertEqual(ProcessingStatus(transcribed(meeting, summaryAt: now.addingTimeInterval(60)), now: now), .done)
        // A summary from before the request doesn't count.
        var older = transcribed(meeting, summaryAt: now.addingTimeInterval(-60))
        older.upsertProcessingRequest(ProcessingRequest(meetingID: meeting.id, mode: .summaryOnly, requestedBy: phone, createdAt: now))
        guard case .requested = ProcessingStatus(older, now: now) else { return XCTFail("Summarize Again still waits") }
    }

    func testTheMacsOwnQueueComesFirst() {
        let meeting = recorded()
        let other = UUID()
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(running: meeting.id, fraction: 0.25), now: now),
                       .processing(.init(stage: .transcribing, fraction: 0.25)))
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(running: meeting.id, identifyingSpeakers: true), now: now),
                       .processing(.init(stage: .identifyingSpeakers, fraction: 0)))
        var summarizing = meeting
        summarizing.status = .summarizing
        XCTAssertEqual(ProcessingStatus(summarizing, queue: .init(running: meeting.id, identifyingSpeakers: true), now: now),
                       .processing(.init(stage: .summarizing, fraction: 0)))
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(running: other, queued: [UUID(), meeting.id]), now: now),
                       .requested(.queued(position: 1, after: other)))
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(awaitingModels: [meeting.id]), now: now), .requested(.models))
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(canProcess: false), now: now), .requested(.models),
                       "Audio waits for models this Mac doesn't have")
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(paused: [meeting.id]), now: now), .requested(.paused))
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(), now: now), .recorded)
    }

    func testTheQueueOutranksAFailureAndASyncedRequest() {
        var meeting = recorded()
        meeting.status = .failed
        meeting.errorMessage = "Out of memory"
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(queued: [meeting.id]), now: now), .requested(.queued(position: 0, after: nil)),
                       "Try Again on a failed conversation reads as waiting everywhere")
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(canProcess: false), now: now),
                       .failed(.init(reason: "Out of memory", hadTranscripts: false)), "A failure isn't hidden behind missing models")
        let request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(), now: now), .requested(.device(request)), "A newer request waits")
    }

    func testLibraryControllerAnswersForAConversation() async throws {
        let root = makeTemporaryFolder("DaybookStatus")
        let library = await LibraryController(rootURL: root, sync: nil)
        try await library.load()
        let id = await library.newMeeting(title: "Notes only")
        let status = await library.processingStatus(for: id)
        XCTAssertEqual(status, .done)
        let missing = await library.processingStatus(for: UUID())
        XCTAssertNil(missing)
    }
}
