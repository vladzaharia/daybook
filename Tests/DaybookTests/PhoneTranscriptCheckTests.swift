import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Which iPhone recording a Mac checks after a sync pass: one the iPhone transcribed itself, never one whose Transcribe
/// request the iPhone took back and a Mac transcribed.
@MainActor
final class PhoneTranscriptCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let phone = ProcessingRequest.Device(id: "phone-1", name: "Alex's iPhone")

    /// An iPhone's conversation of its own: its one recording, transcribed.
    private func transcribedPhoneRecording() -> Meeting {
        let track = RecordingTrack(source: .microphone, relativePath: "p.m4a", fileName: "p.m4a", sha256: "p",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1", recordingID: "rec-1"))
        return Meeting(title: "Walk", tracks: [track],
                       transcripts: [TrackTranscript(trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "Hi")])])
    }

    func testBehaviorAWithdrawnRequestIsntATranscriptFromThePhone() throws {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookPhoneCheck"), defaults: makeTestDefaults("local.daybook.tests.phone-check"))
        let observations = ClaimObservations()
        var withdrawn = transcribedPhoneRecording()
        let request = ProcessingRequest(meetingID: withdrawn.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        // Cancelled on the iPhone; a Mac that transcribes synced recordings transcribed it later.
        withdrawn.upsertProcessingRequest(try XCTUnwrap(request.withdrawn(by: phone, at: now, observations: observations)))
        XCTAssertNil(state.phoneTranscriptToCheck(withdrawn), "a Mac transcribed it: nothing to check")

        var own = transcribedPhoneRecording()
        let asked = ProcessingRequest(meetingID: own.id, mode: .newAudio, requestedBy: phone, createdAt: now)
        own.upsertProcessingRequest(try XCTUnwrap(asked.completed(by: phone, at: now.addingTimeInterval(60), observations: observations)))
        XCTAssertEqual(state.phoneTranscriptToCheck(own)?.id, own.tracks.first?.id, "transcribed on the iPhone that asked")
    }
}
