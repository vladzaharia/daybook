import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// One list of what can be done to a conversation, in one order, for every menu on both apps.
final class ConversationActionsTests: XCTestCase {
    private func meeting(transcribed: Bool = true, summary: Bool = true, revisions: Bool = true) -> Meeting {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60)
        var meeting = Meeting(title: "Weekly product sync", tracks: [track])
        if transcribed {
            let segment = TranscriptSegment(trackID: track.id, start: 0, end: 4, text: "Ship it")
            meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [segment])]
            meeting.unifiedTranscript = [segment]
        }
        if summary { meeting.summary = MeetingSummary(overview: "Shipping") }
        if revisions { meeting.revisions = [MeetingRevision(field: "notes", oldValue: "", newValue: "Hi")] }
        return meeting
    }

    private func ids(_ groups: [ConversationActionGroup]) -> [[ConversationAction.ID]] { groups.map { $0.actions.map(\.id) } }

    func testBehaviorBothAppsListTheSameGroupsInTheSameOrder() {
        let mac = ConversationActions.actions(for: meeting(), context: .init(platform: .mac))
        let phone = ConversationActions.actions(for: meeting(), context: .init(platform: .iPhone, canTakePhoto: true))
        XCTAssertEqual(mac.map(\.id), [.share, .add, .reprocess, .history, .filing, .trash])
        XCTAssertEqual(phone.map(\.id), mac.map(\.id))
        XCTAssertEqual(ids(mac), [[.copySummary, .export], [.showFloatingNotes, .addPhotos, .addRecording], [.reprocess], [.versionHistory],
                                  [.rename, .moveToFolder, .tags, .moveTo(.personal), .showInFinder], [.moveToTrash]])
        XCTAssertEqual(ids(phone), [[.copySummary, .export], [.takePhoto, .addPhotos, .addRecording], [.reprocess], [.versionHistory],
                                    [.moveToFolder, .tags, .moveTo(.personal)], [.moveToTrash]])
        // The filing the Mac's menu lacked, and the recording and JSON the iPhone's lacked, are on both now.
        XCTAssertEqual(phone[0].actions[1].title, "Share")
        XCTAssertEqual(phone[0].actions[1].children.map(\.id), [.exportMarkdown, .exportJSON, .shareAudio])
        XCTAssertEqual(mac[0].actions[1].title, "Export")
        XCTAssertEqual(mac[0].actions[1].children.map(\.title), ["Markdown…", "Full Data (JSON)…"])
        XCTAssertEqual(mac[1].actions.map(\.title), ["Show Floating Notes", "Add Photos…", "Add Recording"])
        XCTAssertEqual(mac[5].actions.first?.role, .destructive)
    }

    func testBehaviorReprocessSaysAgainNotWhereAndListsWhatApplies() {
        let reprocess = ConversationActions.actions(for: meeting(), context: .init(platform: .iPhone))[2].actions[0]
        XCTAssertEqual(reprocess.title, "Reprocess")
        XCTAssertEqual(reprocess.symbol, "arrow.triangle.2.circlepath", "it may run here, on a Mac, or in the cloud")
        XCTAssertEqual(reprocess.children.map(\.title), ["Summarize Again", "Identify Speakers Again", "Transcribe Everything Again"])
        let recorded = ConversationActions.actions(for: meeting(transcribed: false, summary: false), context: .init(platform: .mac))[2].actions[0]
        XCTAssertEqual(recorded.children.map(\.title), ["Transcribe", "Summarize Again", "Identify Speakers Again", "Transcribe Everything Again"])
        XCTAssertEqual(recorded.children[1].availability, .unavailable("No transcript yet"), "dimmed on a Mac, left out on an iPhone")
        XCTAssertEqual(recorded.children[2].availability, .unavailable("Not transcribed yet"))
    }

    func testBehaviorWhatCantBeDoneNowSaysWhy() {
        let bare = ConversationActions.actions(for: meeting(transcribed: false, summary: false, revisions: false), context: .init(platform: .mac))
        XCTAssertEqual(bare[0].actions[0].availability, .unavailable("No summary yet"))
        XCTAssertEqual(bare[3].actions[0].availability, .unavailable("No changes yet"))
        let recording = ConversationActions.actions(for: meeting(), context: .init(platform: .mac, isRecording: true))
        XCTAssertEqual(recording[2].actions[0].availability, .unavailable("Recording now"))
        XCTAssertEqual(recording[5].actions[0].availability, .unavailable("Recording now"))
        XCTAssertEqual(recording[1].actions[2].availability, .unavailable("Recording now"), "Add Recording waits too")
        let pending = ConversationActions.actions(for: meeting(), context: .init(platform: .iPhone, status: .requested(.paused)))
        XCTAssertEqual(pending[2].actions[0].availability, .unavailable("Already asked for"))
        let notes = ConversationActions.actions(for: Meeting(title: "Notes"), context: .init(platform: .iPhone))
        XCTAssertEqual(notes[2].actions[0].availability, .unavailable("No recording yet"))
        let noCamera = ConversationActions.actions(for: meeting(), context: .init(platform: .iPhone, canTakePhoto: false))
        XCTAssertFalse(noCamera[1].actions[0].isAvailable)
    }

    func testBehaviorAPersonalConversationMovesToWork() {
        var personal = meeting()
        personal.placement = .personal
        let filing = ConversationActions.actions(for: personal, context: .init(platform: .iPhone))[4].actions
        XCTAssertEqual(filing.map(\.title), ["Move to Folder…", "Tags…", "Move to Work"])
        XCTAssertEqual(filing[2].symbol, "briefcase")
    }

    func testBehaviorSeveralSelectedAreFiledSummarizedOrTrashedTogether() {
        let a = meeting(), b = meeting(transcribed: false)
        let groups = ConversationActions.batch([a.id, b.id], in: [a, b], context: .init(platform: .mac))
        XCTAssertEqual(groups.map(\.id), [.reprocess, .filing, .trash])
        XCTAssertEqual(groups[0].actions.map(\.title), ["Summarize Again"])
        XCTAssertEqual(groups[1].actions.map(\.title), ["Move to Folder", "Tags…", "Move to Personal"])
        XCTAssertEqual(groups[2].actions.map(\.title), ["Move 2 to Trash…"])
        XCTAssertEqual(ids(ConversationActions.batch([a.id], in: [a, b], context: .init(platform: .mac))),
                       ids(ConversationActions.actions(for: a, context: .init(platform: .mac))), "one selected is the conversation's own menu")
        XCTAssertTrue(ConversationActions.batch([], in: [a], context: .init(platform: .mac)).isEmpty)
        let none = ConversationActions.batch([b.id, Meeting(title: "Notes").id], in: [b], context: .init(platform: .iPhone))
        XCTAssertEqual(none.first?.id, .share, "a single match is its own menu")
    }

    func testBehaviorARecordingCanBeMovedToItsOwnConversationOrRemoved() throws {
        var two = meeting()
        two.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav", duration: 60))
        let track = try XCTUnwrap(two.tracks.first)
        let mac = ConversationActions.track(track, in: two, context: .init(platform: .mac))
        XCTAssertEqual(ids(mac), [[.play], [.adjustTiming, .showOriginalTranscript], [.moveToNewConversation, .showInFinder], [.removeRecording]])
        XCTAssertEqual(mac[2].actions[0].title, "Move to New Conversation")
        XCTAssertEqual(mac[3].actions[0].title, "Remove Recording…")
        XCTAssertEqual(mac[3].actions[0].role, .destructive)
        let phone = ConversationActions.track(track, in: two, context: .init(platform: .iPhone))
        XCTAssertEqual(ids(phone), [[.play], [.adjustTiming, .showOriginalTranscript], [.moveToNewConversation], [.removeRecording]])
        let one = ConversationActions.track(track, in: meeting(), context: .init(platform: .mac))
        XCTAssertEqual(one[1].actions[0].availability, .unavailable("The only recording"))
        XCTAssertEqual(one[2].actions[0].availability, .unavailable("The only recording"))
        let busy = ConversationActions.track(track, in: two, context: .init(platform: .mac, isProcessingHere: true))
        XCTAssertEqual(busy[3].actions[0].availability, .unavailable("Processing now"))
    }
}
