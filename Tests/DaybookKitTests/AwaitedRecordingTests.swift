import DaybookCore
@testable import DaybookKit
import Foundation
import XCTest

/// "Waiting for iPhone audio": derived from a conversation's synced multipoint links, so the Mac's
/// list, page, and Floating Notes, and the iPhone, all say it the same way.
final class AwaitedRecordingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mac = UUID()

    /// This Mac's audio transcribed and summarized, with links to devices that recorded along.
    private func meeting(_ links: [CompanionRecording]) -> Meeting {
        var meeting = Meeting(title: "Design review", tracks: [RecordingTrack(id: mac, source: .microphone, relativePath: "m.caf",
                                                                               fileName: "m.caf", offset: 0, sha256: "m")],
                              transcripts: [TrackTranscript(trackID: mac, segments: [TranscriptSegment(trackID: mac, start: 0, end: 2, text: "Hi")])],
                              summary: MeetingSummary(overview: "Hi"))
        meeting.companions = links
        return meeting
    }

    private func link(_ kind: String = DaybookPhoneIntegration.id, name: String = "Alex's iPhone", state: CompanionRecording.State = .stopped,
                      recordingID: String? = "rec-1", ended: TimeInterval = -60) -> CompanionRecording {
        var link = CompanionRecording(deviceID: "phone-1", deviceKind: kind, deviceSerial: "phone-1", deviceName: name,
                                      macStartedAt: now.addingTimeInterval(ended - 600), state: state, startedByDaybook: true)
        link.macEndedAt = now.addingTimeInterval(ended)
        link.recordingID = recordingID
        return link
    }

    func testDoneWithThisMacsAudioAndWaitingForThePhones() {
        let status = ProcessingStatus(meeting([link()]), now: now)
        let awaited = [AwaitedRecording(deviceName: "Alex's iPhone", deviceKind: DaybookPhoneIntegration.id, since: now.addingTimeInterval(-60))]
        XCTAssertEqual(status, .awaitingRecordings(awaited))
        XCTAssertFalse(status.isPending, "Nothing is running or queued: the person can work on it")
        XCTAssertEqual(ProcessingStatus.awaitingLine(awaited), "Waiting for iPhone audio")
        XCTAssertEqual(ProcessingStatus.awaitingDetail(awaited), "Waiting for audio from Alex's iPhone")

        // While this Mac works on its own audio, the work says what's still to come.
        XCTAssertEqual(ProcessingStatus(meeting([link()]), queue: .init(running: UUID()), now: now), .awaitingRecordings(awaited),
                       "The queue runs another conversation")
        var running = meeting([link()])
        running.id = UUID()
        guard case .processing(let own) = ProcessingStatus(running, queue: .init(running: running.id, fraction: 0.4), now: now) else {
            return XCTFail("processing")
        }
        XCTAssertEqual(own.awaiting.map(\.deviceName), ["Alex's iPhone"])
    }

    func testOnlyARecordingThatMayExistAndHasntArrivedIsAwaited() {
        for state in [CompanionRecording.State.recording, .alreadyRecording, .stopping, .stopped, .stopFailed] {
            XCTAssertEqual(meeting([link(state: state)]).awaitedRecordings(now: now).count, 1, "\(state)")
        }
        for state in [CompanionRecording.State.starting, .unavailable, .failed, .attached] {
            XCTAssertTrue(meeting([link(state: state)]).awaitedRecordings(now: now).isEmpty, "\(state)")
        }
        XCTAssertTrue(meeting([link(ended: -3 * 86_400)]).awaitedRecordings(now: now).isEmpty, "Let go after two days")
        XCTAssertEqual(ProcessingStatus(meeting([link(ended: -3 * 86_400)]), now: now), .done)
    }

    func testTheRecordingArrivingEndsTheWait() {
        var arrived = meeting([link()])
        arrived.tracks.append(RecordingTrack(source: .microphone, relativePath: "p.m4a", fileName: "p.m4a", sha256: "p",
                                             device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1", recordingID: "rec-1")))
        XCTAssertEqual(ProcessingStatus(arrived, now: now), .recorded, "Its audio is here, to be transcribed")
        // On the iPhone, whose copy holds its own recording: never waiting for itself.
        XCTAssertTrue(arrived.awaitedRecordings(now: now).isEmpty)
        // A Listen Live portion of the recording counts too.
        var portion = meeting([link()])
        portion.tracks.append(RecordingTrack(source: .soundcore, relativePath: "s.mp3", fileName: "s.mp3", sha256: "s",
                                             device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1",
                                                                             recordingID: "rec-1" + DeviceLibraryLinks.partialSuffix)))
        XCTAssertTrue(portion.awaitedRecordings(now: now).isEmpty)
        // Another phone's recording doesn't.
        var other = meeting([link()])
        other.tracks.append(RecordingTrack(source: .microphone, relativePath: "o.m4a", fileName: "o.m4a", sha256: "o",
                                           device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-2", recordingID: "rec-9")))
        XCTAssertEqual(other.awaitedRecordings(now: now).count, 1)
        // Without a recording ID, one from that device that started after this Mac did.
        var unnamed = meeting([link(recordingID: nil)])
        var track = RecordingTrack(source: .microphone, relativePath: "u.m4a", fileName: "u.m4a", sha256: "u",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1", recordingID: "rec-2"))
        track.startedAt = now.addingTimeInterval(-640)
        unnamed.tracks.append(track)
        XCTAssertTrue(unnamed.awaitedRecordings(now: now).isEmpty)
    }

    func testAnArrivedRecordingItWaitedForIsToBeAdded() {
        XCTAssertFalse(meeting([link()]).hasAwaitedRecordingToAdd(now: now), "Not here yet")
        let phone = RecordingTrack(source: .microphone, relativePath: "p.m4a", fileName: "p.m4a", sha256: "p",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1", recordingID: "rec-1"))
        var arrived = meeting([link()])
        arrived.tracks.append(phone)
        XCTAssertTrue(arrived.hasAwaitedRecordingToAdd(now: now))
        // Once it's added: transcribed, or its link attached.
        var transcribed = arrived
        transcribed.transcripts.append(TrackTranscript(trackID: phone.id, segments: []))
        XCTAssertFalse(transcribed.hasAwaitedRecordingToAdd(now: now))
        var attached = arrived
        attached.companions?[0].state = .attached
        attached.companions?[0].trackID = phone.id
        XCTAssertFalse(attached.hasAwaitedRecordingToAdd(now: now))
        // Another phone's recording isn't the one it waited for, and one past the wait is let go.
        var other = meeting([link()])
        other.tracks.append(RecordingTrack(source: .microphone, relativePath: "o.m4a", fileName: "o.m4a", sha256: "o",
                                           device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-2", recordingID: "rec-9")))
        XCTAssertFalse(other.hasAwaitedRecordingToAdd(now: now))
        var late = meeting([link(ended: -3 * 86_400)])
        late.tracks.append(phone)
        XCTAssertFalse(late.hasAwaitedRecordingToAdd(now: now))
    }

    func testBehaviorDontWaitStopsTheWaitAndStillTakesTheRecordingIfItComes() {
        var waiting = meeting([link(), link("soundcore.work", name: "Soundcore Work", recordingID: "1800000000")])
        XCTAssertEqual(waiting.awaitedRecordings(now: now).count, 2)
        XCTAssertTrue(waiting.stopWaitingForRecordings(at: now))
        XCTAssertEqual(ProcessingStatus(waiting, now: now), .done, "Nothing left to wait for: the page says nothing")
        XCTAssertEqual(waiting.companions?.map(\.stoppedWaitingAt), [now, now], "Kept on each link, so it syncs")
        XCTAssertEqual(waiting.companions?.map(\.state), [.stopped, .stopped], "What the recorders did is unchanged")
        XCTAssertFalse(waiting.stopWaitingForRecordings(at: now), "Nothing more to stop waiting for")

        // The recording still arrives: it's added, as one waited for is.
        let phone = RecordingTrack(source: .microphone, relativePath: "p.m4a", fileName: "p.m4a", sha256: "p",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone-1", recordingID: "rec-1"))
        waiting.tracks.append(phone)
        XCTAssertTrue(waiting.hasAwaitedRecordingToAdd(now: now))

        // Links that weren't waited for are left alone.
        var never = meeting([link(state: .failed), link(ended: -3 * 86_400)])
        XCTAssertFalse(never.stopWaitingForRecordings(at: now))
        XCTAssertEqual(never.companions?.compactMap(\.stoppedWaitingAt), [])
    }

    func testBehaviorDontWaitActsOnTheLinksItNamesAndIsTakenBackByThem() {
        let phone = link(), recorder = link("soundcore.work", name: "Soundcore Work", recordingID: "1800000000")
        var waiting = meeting([phone, recorder, link(state: .failed)])
        XCTAssertEqual(waiting.awaitedLinks(now: now), [phone.id, recorder.id], "only the links it waits for")
        XCTAssertTrue(waiting.stopWaitingForRecordings(at: now, links: [phone.id]))
        XCTAssertEqual(waiting.companions?.map(\.stoppedWaitingAt), [now, nil, nil])
        XCTAssertEqual(waiting.awaitedLinks(now: now), [recorder.id])

        XCTAssertTrue(waiting.waitAgain(for: [phone.id]))
        XCTAssertEqual(waiting.awaitedLinks(now: now), [phone.id, recorder.id])
        XCTAssertFalse(waiting.waitAgain(for: [phone.id]), "already waited for")
        XCTAssertFalse(waiting.waitAgain(for: [UUID()]))
    }

    func testBehaviorDontWaitSurvivesASyncMerge() {
        let base = meeting([link()])
        var local = base
        local.stopWaitingForRecordings(at: now)
        var remote = base
        remote.title = "Design review, renamed"
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(merged.companions?.first?.stoppedWaitingAt, now)
        XCTAssertEqual(merged.title, "Design review, renamed")
        XCTAssertTrue(merged.awaitedRecordings(now: now).isEmpty)
    }

    func testSeveralDevicesShareOneLine() {
        let recorder = link("soundcore.work", name: "Soundcore Work", recordingID: "1800000000")
        let awaited = meeting([link(), recorder]).awaitedRecordings(now: now)
        XCTAssertEqual(ProcessingStatus.awaitingLine(awaited), "Waiting for iPhone and Soundcore Work audio")
        XCTAssertEqual(ProcessingStatus.awaitingDetail(awaited), "Waiting for audio from Alex's iPhone and Soundcore Work")
        // Untranscribed audio still comes first: it needs the person, or the queue.
        var untranscribed = meeting([link()])
        untranscribed.transcripts = []
        XCTAssertEqual(ProcessingStatus(untranscribed, now: now), .recorded)
    }
}
