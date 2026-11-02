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
        XCTAssertEqual(ids(mac), [[.copySummary, .share, .export], [.showFloatingNotes, .addPhotos, .addRecording], [.reprocess],
                                  [.versionHistory], [.rename, .moveToFolder, .tags, .moveTo(.personal), .showInFinder], [.moveToTrash]])
        XCTAssertEqual(ids(phone), [[.copySummary, .share], [.takePhoto, .addPhotos, .addRecordingFromFile], [.reprocess], [.versionHistory],
                                    [.moveToFolder, .tags, .moveTo(.personal)], [.moveToTrash]])
        // The filing the Mac's menu lacked, and the recording the iPhone's lacked, are on both now; so is Share.
        XCTAssertEqual(phone[0].actions[1].title, "Share")
        XCTAssertEqual(phone[0].actions[1].children.map(\.id), [.shareMarkdown, .shareJSON, .shareAudio])
        XCTAssertEqual(mac[0].actions[1].title, "Share")
        XCTAssertEqual(mac[0].actions[1].children.map(\.title), ["Markdown…", "Audio…"], "the Mac's sharing picker asks where")
        XCTAssertEqual(mac[0].actions[2].title, "Export")
        XCTAssertEqual(mac[0].actions[2].children.map(\.title), ["Markdown…", "Full Data (JSON)…"])
        XCTAssertEqual(mac[1].actions.map(\.title), ["Show Floating Notes", "Add Photos…", "Add Recording"])
        XCTAssertEqual(mac[1].actions[2].children.map(\.title), ["From a File…"])
        XCTAssertEqual(phone[1].actions.map(\.title), ["Take Photo", "Add Photos…", "Add Recording…"], "Files, with no recorders to list")
        XCTAssertEqual(phone[3].actions.map(\.title), ["Version History…"], "the same ellipsis on both")
        XCTAssertEqual(mac[5].actions.first?.role, .destructive)
    }

    func testBehaviorAudioIsSharedOnlyWhenThereIsSome() {
        let notes = Meeting(title: "Notes")
        for platform in [ConversationAction.Platform.mac, .iPhone] {
            let share = ConversationActions.actions(for: notes, context: .init(platform: platform))[0].actions[1]
            XCTAssertEqual(share.children.last?.id, .shareAudio)
            XCTAssertEqual(share.children.last?.availability, .unavailable("No recording yet"))
            XCTAssertTrue(share.children[0].isAvailable, "a conversation's words share without a recording")
        }
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
        let phoneRecording = ConversationActions.actions(for: meeting(), context: .init(platform: .iPhone, isRecording: true, canTakePhoto: true))
        XCTAssertEqual(phoneRecording[1].actions[2].availability, .unavailable("Recording now"))
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

    func testBehaviorARecordingStaysWhileAnotherDeviceProcessesIt() throws {
        var two = meeting()
        two.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav", duration: 60))
        let track = try XCTUnwrap(two.tracks.last)
        let mac = ProcessingRequest.Device(id: "mac", name: "Studio Mac")
        let request = ProcessingRequest(meetingID: two.id, mode: .newAudio, requestedBy: .init(id: "phone", name: "iPhone"))
        func availability(_ status: ProcessingStatus?, _ id: ConversationAction.ID) -> ConversationAction.Availability? {
            ConversationActions.track(track, in: two, context: .init(platform: .iPhone, status: status))
                .flatMap(\.actions).first { $0.id == id }?.availability
        }
        // The Mac would write to the recording as it leaves (its timing, its transcript).
        let processing = ProcessingStatus.processing(.init(stage: .transcribing, fraction: 0.4, device: mac))
        XCTAssertEqual(availability(processing, .removeRecording), .unavailable("Processing now"))
        XCTAssertEqual(availability(processing, .moveToNewConversation), .unavailable("Processing now"))
        XCTAssertEqual(availability(.requested(.device(request)), .removeRecording), .unavailable("Waiting to process"))
        XCTAssertEqual(availability(.requested(.device(request)), .moveToNewConversation), .unavailable("Waiting to process"))
        XCTAssertEqual(availability(processing, .play), .available, "it still plays")
        XCTAssertEqual(availability(.requested(.queued(position: 0, after: nil)), .removeRecording), .unavailable("Waiting to process"))
        XCTAssertEqual(availability(.requested(.paused), .removeRecording), .available, "paused waits for the person")
        XCTAssertEqual(availability(.requested(.models), .moveToNewConversation), .available, "nothing works on it until the models are here")
        XCTAssertEqual(availability(.recorded, .removeRecording), .available)
        XCTAssertEqual(availability(nil, .moveToNewConversation), .available)
    }

    func testBehaviorPlayWaitsWhileThisMacRecordsAnotherConversation() throws {
        var two = meeting()
        two.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav", duration: 60))
        let track = try XCTUnwrap(two.tracks.first)
        let elsewhere = ConversationActions.track(track, in: two, context: .init(platform: .mac, isDeviceRecording: true)).flatMap(\.actions)
        XCTAssertEqual(elsewhere.first { $0.id == .play }?.availability, .unavailable("Recording now"), "the Mac plays nothing while it records")
        XCTAssertEqual(elsewhere.first { $0.id == .removeRecording }?.availability, .available, "this conversation can still change")
        let here = ConversationActions.track(track, in: two, context: .init(platform: .mac, isRecording: true, isDeviceRecording: true))
        XCTAssertEqual(here.flatMap(\.actions).first { $0.id == .play }?.availability, .unavailable("Recording now"))
        let idle = ConversationActions.track(track, in: two, context: .init(platform: .mac))
        XCTAssertEqual(idle.flatMap(\.actions).first { $0.id == .play }?.availability, .available)
    }

    func testBehaviorEverySymbolIsOnTheOldestSystemThatShowsIt() throws {
        // SF Symbols' own record: the release each name arrived in, and each release's first system.
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let symbols = plist["symbols"] as? [String: String],
              let releases = plist["year_to_release"] as? [String: [String: String]] else {
            throw XCTSkip("This system has no record of SF Symbols' releases")
        }
        func version(_ text: String) -> [Int] { Array((text.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]).prefix(3)) }
        // Package.swift and both apps' projects: macOS 15, iOS 26.
        let oldest: [(platform: ConversationAction.Platform, key: String, minimum: String)] = [(.mac, "macOS", "15.0"), (.iPhone, "iOS", "26.0")]
        func check(_ symbol: String, title: String, on platforms: Set<ConversationAction.Platform>) throws {
            let release = try XCTUnwrap(symbols[symbol], "\(title): “\(symbol)” isn't a symbol")
            for (platform, key, minimum) in oldest where platforms.contains(platform) {
                let first = try XCTUnwrap(releases[release]?[key], "\(release) has no \(key) release")
                XCTAssertFalse(version(minimum).lexicographicallyPrecedes(version(first)), "\(title): “\(symbol)” first shipped in \(key) \(first)")
            }
        }

        var two = meeting(transcribed: false)
        two.tracks.append(RecordingTrack(source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav", duration: 60))
        var other = Meeting(title: "Notes")
        other.placement = .personal
        var groups: [ConversationActionGroup] = []
        for platform in [ConversationAction.Platform.mac, .iPhone] {
            let context = ConversationActions.Context(platform: platform, canTakePhoto: true)
            for conversation in [meeting(), two, other] { groups += ConversationActions.actions(for: conversation, context: context) }
            groups += ConversationActions.batch([two.id, other.id], in: [two, other], context: context)
            groups += ConversationActions.track(two.tracks[0], in: two, context: context)
        }
        func all(_ actions: [ConversationAction]) -> [ConversationAction] { actions.flatMap { [$0] + all($0.children) } }
        let actions = all(groups.flatMap(\.actions))
        XCTAssertTrue(actions.contains { $0.id == .process(.newAudio) } && actions.contains { $0.id == .moveTo(.work) })
        for action in actions {
            guard action.id != .showInFinder else {
                XCTAssertEqual(action.symbol, ConversationAction.showInFinderSymbol, "Finder's symbol goes through its check of the system")
                continue
            }
            try check(action.symbol, title: action.title, on: action.platforms)
        }
        // Finder's own symbol only where the system has it; macOS 15 gets one it has.
        try check(ConversationAction.finderFallbackSymbol, title: "Show in Finder", on: [.mac])
        XCTAssertEqual(releases[try XCTUnwrap(symbols[ConversationAction.finderSymbol])]?["macOS"], "26.0")
    }
}
