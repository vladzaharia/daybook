import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookLink
import DaybookTestSupport
import DaybookUI
import XCTest
@testable import Daybook

/// The Mac's live captions with scripted captioners and fake capture sources: You and Call from a
/// synthetic recording, the speakers' echo left out (and kept with headphones), captions that never
/// touch the recording, the Mac-local store the transcript replaces, and no captions (and no
/// errors) where the system can't make them. No microphone, tap, speech recognition, or download.
@MainActor
final class LiveCaptionsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookCaptions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Harness

    /// A recorder on fake sources, with captions fed by its tap.
    private struct Rig {
        let recorder: RecordingController
        let captions: LiveCaptionsController
        let mic: FakeCaptureSource
        let system: FakeSystemAudio
        let clock: FakeHostClock
        let you: TapCaptioner
        let call: TapCaptioner
        let route: (AudioOutputRoute) -> Void
    }

    private func rig(route: AudioOutputRoute.Kind, callCaptioner: (any LiveCaptioning)? = nil) -> Rig {
        let clock = FakeHostClock()
        clock.now = 50
        let system = FakeSystemAudio()
        let mic = FakeCaptureSource(method: "microphone")
        let box = RouteBox()
        let current = AudioOutputRoute(kind: route, deviceName: route == .headphones ? "AirPods Pro" : "MacBook Pro Speakers", transport: nil)
        let environment = CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { mic }, systemAudio: system,
            currentRoute: { current }, observeRoutes: { handler in box.handler = handler; return NSObject() },
            hostTime: { clock.now })
        let recorder = RecordingController(environment: environment)
        let you = TapCaptioner(), call = TapCaptioner()
        let captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: root)) { source -> (any LiveCaptioning)? in
            if source == .microphone { return you }
            return callCaptioner ?? call
        }
        captions.follow(recorder)
        return Rig(recorder: recorder, captions: captions, mic: mic, system: system, clock: clock, you: you, call: call,
                   route: { box.handler?($0) })
    }

    private final class RouteBox: @unchecked Sendable { var handler: (@Sendable (AudioOutputRoute) -> Void)? }

    private func start(_ rig: Rig, meeting: UUID) async throws {
        rig.recorder.captionTap = rig.captions.prepare(meetingID: meeting, includesCall: true)
        let zoom = CallAppTarget(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
        try await rig.recorder.start(in: root.appendingPathComponent("Staging-\(meeting.uuidString)"), includeSystemAudio: true, callApp: zoom)
        await rig.captions.start(locale: Locale(identifier: "en_US"))
    }

    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval, tentative: Bool = false) -> LiveCaptionSegment {
        LiveCaptionSegment(start: start, end: end, text: text, isTentative: tentative)
    }

    // MARK: You and Call

    func testYouAndCallAreCaptionedFromTheirOwnSourcesOnTheRecordingsTimeline() async throws {
        let rig = rig(route: .headphones)
        let meeting = UUID()
        try await start(rig, meeting: meeting)
        XCTAssertTrue(rig.captions.isShowing(for: meeting))
        XCTAssertEqual(rig.you.startedLocale?.identifier, "en_US")
        let tap = try XCTUnwrap(rig.system.taps.first)

        // Two seconds in, the call and the microphone deliver audio at their own rates.
        rig.clock.now = 52
        for index in 0..<5 {
            tap.emit(CallSignals.tone(channels: 2, level: 0.1, frames: 480), at: 52 + Double(index) * 0.01)
            rig.mic.emit(CallSignals.tone(rate: 44_100, frames: 4_410), at: 52.5 + Double(index) * 0.1)
        }
        XCTAssertEqual(rig.you.fed.count, 5, "the microphone's buffers go to You")
        XCTAssertEqual(rig.call.fed.count, 5, "the call's buffers go to Call")
        XCTAssertEqual(rig.call.fed.first?.time ?? 0, 2, accuracy: 0.001, "seconds since the recording began")
        XCTAssertEqual(rig.you.fed.first?.time ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(rig.you.fed.first?.rate, 44_100)

        rig.call.post([line("Thanks for joining.", 2.0, 3.1)])
        rig.you.post([line("Happy to be here.", 3.4, 4.6, tentative: true)])
        try await waitUntil("both sources") { rig.captions.segments.count == 2 }
        XCTAssertEqual(rig.captions.segments.map(\.text), ["Thanks for joining.", "Happy to be here."])
        XCTAssertEqual(rig.captions.segments.map(\.source), [.call, .microphone])
        XCTAssertEqual(rig.captions.recent(1).first?.isTentative, true)

        let result = try await XCTUnwrapAsync(await rig.recorder.stop())
        XCTAssertEqual(Set(result.tracks.map(\.role)), [.microphone, .systemAudio])
        XCTAssertTrue(result.tracks.allSatisfy { $0.frameCount > 0 }, "the same buffers reached the recording")
        await rig.captions.finish()
        XCTAssertTrue(rig.you.finished && rig.call.finished)
        XCTAssertFalse(rig.captions.isShowing(for: meeting))
    }

    // MARK: Echo

    func testOnSpeakersTheMicrophonesEchoOfTheCallIsLeftOut() async throws {
        let rig = rig(route: .speakers)
        try await start(rig, meeting: UUID())
        rig.call.post([line("So the launch moves to the 14th, and Priya owns the checklist.", 10, 13.5)])
        rig.you.post([
            line("Can we lock the date?", 6, 7.2),
            // The speakers' copy of the call, a moment later and heard a little differently.
            line("so the launch moves to the fourteenth and priya owns the check list", 10.2, 13.8),
            line("Great, I'll draft it tonight.", 15, 16.4)
        ])
        try await waitUntil("captions") { rig.captions.segments.count == 3 }
        XCTAssertEqual(rig.captions.segments.map(\.text), ["Can we lock the date?", "So the launch moves to the 14th, and Priya owns the checklist.",
                                                          "Great, I'll draft it tonight."])
        XCTAssertEqual(rig.captions.segments.map(\.source), [.microphone, .call, .microphone])

        // Headphones go on 30 s in: from then on, a You line that repeats the call is something you said.
        rig.clock.now = 80
        rig.route(AudioOutputRoute(kind: .headphones, deviceName: "AirPods Pro", transport: "bluetooth"))
        rig.call.post([line("So the launch moves to the 14th, and Priya owns the checklist.", 10, 13.5),
                       line("Legal signs off by Friday.", 40, 41.5)])
        rig.you.post([
            line("Can we lock the date?", 6, 7.2),
            line("so the launch moves to the fourteenth and priya owns the check list", 10.2, 13.8),
            line("Great, I'll draft it tonight.", 15, 16.4),
            line("Legal signs off by Friday?", 41, 42.2)
        ])
        try await waitUntil("the repeated question") { rig.captions.segments.contains { $0.text == "Legal signs off by Friday?" } }
        XCTAssertFalse(rig.captions.segments.contains { $0.text.hasPrefix("so the launch") }, "still left out: it was heard on speakers")
        _ = await rig.recorder.stop()
        await rig.captions.finish()
    }

    func testWithHeadphonesBothSourcesShowInFull() async throws {
        let rig = rig(route: .headphones)
        try await start(rig, meeting: UUID())
        rig.call.post([line("So the launch moves to the 14th.", 10, 12)])
        rig.you.post([line("so the launch moves to the fourteenth", 10.1, 12.2)])
        try await waitUntil("both") { rig.captions.segments.count == 2 }
        XCTAssertEqual(rig.captions.segments.map(\.source), [.call, .microphone])
        _ = await rig.recorder.stop()
        await rig.captions.finish()
    }

    func testOnlyHeadphonesKeepTheMicrophoneFromHearingTheCall() async throws {
        XCTAssertFalse(CaptionEcho.canEcho(.headphones))
        XCTAssertTrue(CaptionEcho.canEcho(.speakers))
        XCTAssertTrue(CaptionEcho.canEcho(.bluetooth), "a Bluetooth device of unknown form may be a speaker")
        // On speakers, your own words mid-call stay yours; the echo is too far from the call's line to be it.
        let rig = rig(route: .speakers)
        try await start(rig, meeting: UUID())
        rig.call.post([line("We still need legal to sign off on the pricing page before Friday.", 20, 24)])
        rig.you.post([line("I can ask legal today.", 21, 22), line("we still need legal to sign off on the pricing page", 40, 43)])
        try await waitUntil("all three") { rig.captions.segments.count == 3 }
        XCTAssertEqual(rig.captions.segments.map(\.source), [.call, .microphone, .microphone])
        _ = await rig.recorder.stop()
        await rig.captions.finish()
    }

    // MARK: Every source

    func testOtherDevicesCaptionsJoinThisMacsLabelledAndSavedWithTheirNames() async throws {
        let rig = rig(route: .headphones)
        let meetingID = UUID()
        try await start(rig, meeting: meetingID)
        rig.you.post([line("Can we start?", 1, 2)])
        // A recorder that began ten seconds before this Mac, and a phone that began five seconds after it.
        rig.captions.received([line("From before this Mac recorded.", 1, 3), line("The recorder heard this.", 14, 16)],
                              from: .device("sim"), name: "Soundcore", offset: -10)
        rig.captions.received([line("Sent from the phone", 2, 3, tentative: true)], from: .device("phone:x"), name: "iPhone",
                              offset: 5, changesOnly: true)
        try await waitUntil("every source") { rig.captions.segments.count == 3 }
        XCTAssertEqual(rig.captions.segments.map(\.text), ["Can we start?", "The recorder heard this.", "Sent from the phone"])
        XCTAssertEqual(rig.captions.segments[1].start, 4, accuracy: 0.001, "on this Mac's timeline")
        XCTAssertEqual(rig.captions.segments.map { rig.captions.label(for: $0.source) }, ["You", "Soundcore", "iPhone"])
        // Floating Notes: You in the time lane; another device's line names the device before its words.
        let lines = rig.captions.segments.map { LiveCaptionLabels.line($0, names: rig.captions.sourceNames) }
        XCTAssertEqual(lines.map(\.source), ["You", nil, nil])
        XCTAssertEqual(lines.map(\.speaker), [nil, "Soundcore", "iPhone"])
        var named = rig.captions.segments[1]
        named.speaker = LiveCaptionSpeaker(slot: "S1", name: "Priya")
        XCTAssertEqual(LiveCaptionLabels.line(named, names: rig.captions.sourceNames).speaker, "Priya", "a recognized person comes first")

        _ = await rig.recorder.stop()
        await rig.captions.finish()
        let saved = try XCTUnwrap(rig.captions.store.captions(for: meetingID))
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false, false], "every source's lines kept as heard")
        XCTAssertEqual(LiveCaptionTurn.turns(saved.segments, names: saved.sourceNames ?? [:]).map(\.label), ["You", "Soundcore", "iPhone"])
        // Nothing arrives once the recording's captions are done.
        rig.captions.received([line("Late", 30, 31)], from: .device("sim"), name: "Soundcore", offset: 0)
        XCTAssertTrue(rig.captions.segments.isEmpty)
    }

    func testAPairedPhonesCaptionsJoinTheRecordingTheyShare() async throws {
        let root = self.root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("LiveCaptionsTests.phone"))
        await state.initialize()
        let id = UUID(), mic = TapCaptioner()
        state.captions.makeCaptioner = { $0 == .microphone ? mic : nil }
        _ = state.captions.prepare(meetingID: id, includesCall: false)
        state.recordingID = id
        state.recordingStartedAt = Date(timeIntervalSince1970: 1_000)
        let phone = UUID()
        // The phone began four seconds after this Mac (no clock samples here: its clock is taken as is).
        let dropped = UUID()
        state.phoneCaptioned(LinkCaptions(conversationID: id, startedAt: Date(timeIntervalSince1970: 1_004), lines: [
            .init(id: UUID(), start: 1, end: 2, text: "Heard on the phone.", isTentative: false, speakerSlot: "S1", speakerName: "Priya"),
            .init(id: UUID(), start: 3, end: 4, text: "Heard by its recorder.", isTentative: true, device: "Soundcore"),
            .init(id: dropped, start: 6, end: 6.5, text: "and then", isTentative: true),
        ]), from: phone)
        state.phoneCaptioned(LinkCaptions(conversationID: UUID(), startedAt: Date(), lines: [
            .init(id: UUID(), start: 0, end: 1, text: "Another conversation", isTentative: false)]), from: phone)
        try await waitUntil("the phone's lines") { state.captions.segments.count == 3 }
        // Its recognizer took back the words it was still revising.
        state.phoneCaptioned(LinkCaptions(conversationID: id, startedAt: Date(timeIntervalSince1970: 1_004), lines: [], removed: [dropped]),
                             from: phone)
        try await waitUntil("taken back") { state.captions.segments.count == 2 }
        XCTAssertEqual(state.captions.segments.map(\.text), ["Heard on the phone.", "Heard by its recorder."])
        XCTAssertEqual(state.captions.segments.first?.start ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(state.captions.segments.first?.speaker?.name, "Priya")
        XCTAssertEqual(state.captions.segments.map { state.captions.label(for: $0.source) }, ["iPhone", "Soundcore"])
        let forwarded = await state.captions.session.forwardable()
        XCTAssertTrue(forwarded.isEmpty, "a phone's lines are never sent on")
        await state.captions.finish()
    }

    /// LC-08: the call's lines go to an iPhone recording the conversation too that shows other devices'
    /// captions, a second at a time and only what changed, with what was taken back; never You.
    func testTheCallsLinesGoToAPhoneRecordingTheConversationToo() async throws {
        let rig = rig(route: .headphones)
        let meeting = UUID(), phone = UUID()
        try await start(rig, meeting: meeting)
        var sent: [LinkCaptions] = []
        rig.captions.shareCall(conversation: meeting, startedAt: Date(timeIntervalSince1970: 1_000), recipients: { [phone] },
                               send: { message, to in if to == phone { sent.append(message) } })
        let revised = UUID(), thanks = line("Thanks for joining.", 2, 3.1)
        rig.call.post([thanks, LiveCaptionSegment(id: revised, start: 3.5, end: 4, text: "So", isTentative: true)])
        rig.you.post([line("Happy to be here.", 3.4, 4.6)])
        try await waitUntil("sent", timeout: 5) { sent.flatMap(\.lines).count >= 2 }
        XCTAssertEqual(Set(sent.flatMap(\.lines).map(\.text)), ["Thanks for joining.", "So"], "the call's lines only")
        XCTAssertEqual(sent.first?.conversationID, meeting)
        // The recognizer drops the words it was still revising.
        rig.call.post([thanks])
        try await waitUntil("taken back", timeout: 5) { sent.contains { $0.removed == [revised] } }
        _ = await rig.recorder.stop()
        await rig.captions.finish()
    }

    // MARK: Never in the recording's way

    func testACaptionerThatFailsNeverAffectsTheRecordingOrTheOtherSource() async throws {
        let failing = FailingCaptioner()
        let rig = rig(route: .headphones, callCaptioner: failing)
        let meeting = UUID()
        try await start(rig, meeting: meeting)
        let tap = try XCTUnwrap(rig.system.taps.first)
        for index in 0..<10 {
            rig.clock.now = 51 + Double(index) * 0.1
            tap.emit(CallSignals.tone(channels: 2, level: 0.1), at: rig.clock.now)
            rig.mic.emit(CallSignals.tone(), at: rig.clock.now)
        }
        try await waitUntil("the call's captions to fail") { rig.captions.states[.call] == .failed("Captions stopped: test") }
        XCTAssertEqual(rig.recorder.state, .recording)
        XCTAssertEqual(failing.appended, 10, "appending to a failed captioner is harmless")
        rig.you.post([line("Still captioning me.", 1, 2)])
        try await waitUntil("You") { rig.captions.segments.map(\.text) == ["Still captioning me."] }
        XCTAssertEqual(rig.captions.state, .listening)
        XCTAssertTrue(rig.captions.isShowing(for: meeting))
        let result = try await XCTUnwrapAsync(await rig.recorder.stop())
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        await rig.captions.finish()
    }

    // MARK: Stored on this Mac, replaced by the transcript

    func testCaptionsAreKeptOnThisMacUntilTheTranscriptReplacesThem() async throws {
        let rig = rig(route: .speakers)
        let meetingID = UUID()
        try await start(rig, meeting: meetingID)
        rig.call.post([line("Thanks for joining.", 2, 3)])
        rig.you.post([line("Happy to be here", 3.4, 4.6, tentative: true)])
        try await waitUntil("captions") { rig.captions.segments.count == 2 }
        _ = await rig.recorder.stop()
        await rig.captions.finish()

        let store = rig.captions.store
        let saved = try XCTUnwrap(store.captions(for: meetingID))
        let capture = try XCTUnwrap(saved.captureID)
        XCTAssertEqual(store.url(for: saved.key).path,
                       root.appendingPathComponent("LiveCaptions/\(meetingID.uuidString).\(capture.uuidString).json").path,
                       "beside the library, outside Meetings/, so sync never sees it; one file per recording")
        XCTAssertEqual(saved.segments.map(\.text), ["Thanks for joining.", "Happy to be here"])
        XCTAssertEqual(saved.segments.map(\.source), [.call, .microphone])
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false], "what stood at Stop is kept as heard")
        XCTAssertNotNil(rig.captions.lastSave)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        let file = try FileManager.default.attributesOfItem(atPath: store.url(for: saved.key).path)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600, "readable by this user only, as on the iPhone")
        XCTAssertEqual(file[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication, "and protected as on the iPhone")

        var meeting = Meeting(id: meetingID, title: "Launch planning", date: saved.createdAt)
        let earlier = Meeting(id: UUID(), title: "Earlier")
        XCTAssertEqual(SavedCaptions.shown(saved, for: meeting), saved, "until the transcript exists")
        // A transcript made before the captions (an earlier recording of the conversation) doesn't replace them.
        let track = UUID()
        meeting.transcripts = [TrackTranscript(trackID: track, segments: [], createdAt: saved.createdAt.addingTimeInterval(-600))]
        XCTAssertNotNil(SavedCaptions.shown(saved, for: meeting))
        await store.prune(meetings: [meeting, earlier], keeping: nil)
        XCTAssertNotNil(store.captions(for: meetingID))

        // The transcript lands: the captions are gone from the page and from this Mac.
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: [], createdAt: Date()))
        XCTAssertNil(SavedCaptions.shown(saved, for: meeting))
        await store.prune(meetings: [meeting, earlier], keeping: nil)
        XCTAssertNil(store.captions(for: meetingID))

        // A conversation moved to the Trash takes its captions; the one being recorded keeps them.
        let recording = UUID(), trashed = UUID()
        try await store.save(LiveCaptions(meetingID: recording, localeIdentifier: "en_US", segments: [line("Hi", 0, 1)]))
        try await store.save(LiveCaptions(meetingID: trashed, localeIdentifier: "en_US", segments: [line("Bye", 0, 1)]))
        await store.prune(meetings: [earlier], keeping: recording)
        XCTAssertNotNil(store.captions(for: recording))
        XCTAssertNil(store.captions(for: trashed))
    }

    // MARK: Read as the iPhone reads them

    func testBehaviorSavedCaptionsStandInForTheTranscriptAndPlayTheirRecordingAsOnTheIPhone() async throws {
        let began = Date().addingTimeInterval(-120)
        let microphone = RecordingTrack(source: .microphone, relativePath: "m.m4a", fileName: "m.m4a", createdAt: began.addingTimeInterval(0.4))
        let earlier = RecordingTrack(source: .microphone, relativePath: "e.m4a", fileName: "e.m4a", createdAt: began.addingTimeInterval(-3_600))
        var meeting = Meeting(title: "Launch planning", date: began)
        meeting.tracks = [earlier, microphone]
        var heard = line("Can we lock the date?", 3, 5)
        heard.source = .microphone
        var device = line("The recorder heard this.", 6, 7)
        device.source = .device("sim")
        let captions = LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US", segments: [heard, device], createdAt: began,
                                    sourceNames: [LiveCaptionSource.device("sim").rawValue: "Soundcore"])
        XCTAssertTrue(SavedCaptions.standsIn(for: meeting))
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions)
        // This Mac's captions aren't filed with a recording: their times play the one that began as they did.
        XCTAssertEqual(SavedCaptions.recording(of: captions, in: meeting)?.id, microphone.id)
        XCTAssertEqual(SavedCaptions.playback(heard, captions: captions, in: meeting), .source(microphone, 3))
        XCTAssertEqual(SavedCaptions.playing(at: 4, trackID: microphone.id, captions: captions, in: meeting), heard.id)
        XCTAssertNil(SavedCaptions.playing(at: 4, trackID: earlier.id, captions: captions, in: meeting), "another recording playing")
        let store = LiveCaptionStore(libraryRoot: root)
        try await store.save(captions)
        XCTAssertEqual(SavedCaptions.hits(in: [meeting], query: "LOCK the", store: store).map(\.segment.id), [heard.id], "search finds them")

        // Who each line is from, as every strip and the saved captions name them.
        let lines = captions.segments.map { CaptionLine($0, names: captions.sourceNames ?? [:]) }
        XCTAssertEqual(lines.map(\.source), ["You", nil])
        XCTAssertEqual(lines.map(\.speaker), [nil, "Soundcore"])
        XCTAssertEqual(LiveCaptionsSection.lines(captions.segments, names: captions.sourceNames ?? [:], listening: true).map(\.speaker),
                       ["You", "Soundcore"], "the page while recording, with no lane: the source before the words")
        XCTAssertFalse(LiveCaptionStrip.shows(segments: [], state: .off, locale: .current), "off: not even the label")
        XCTAssertTrue(LiveCaptionStrip.shows(segments: [], state: .listening, locale: .current), "Listening…")

        // The transcript arrives: it replaces them, and pruning takes them.
        meeting.unifiedTranscript = [TranscriptSegment(trackID: microphone.id, start: 3, end: 5, text: "Can we lock the date?")]
        meeting.transcripts = [TrackTranscript(trackID: microphone.id, segments: meeting.unifiedTranscript)]
        XCTAssertFalse(SavedCaptions.standsIn(for: meeting))
        XCTAssertNil(SavedCaptions.shown(captions, for: meeting))
        await store.prune(meetings: [meeting], keeping: nil)
        XCTAssertNil(store.captions(for: meeting.id))
    }

    /// The case where the apps once disagreed: a conversation transcribed before, recorded into again with
    /// captions on. Both read `SavedCaptions.shown`, so both show the new captions, after the earlier
    /// transcript; this Mac's transcript page, view switch, and search follow it.
    func testBehaviorCaptionsOfARecordingIntoATranscribedConversationReadAfterItsTranscriptOnBothApps() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("LiveCaptionsTests.transcribed"))
        await state.initialize()
        let id = state.newMeeting(title: "Launch planning")
        let began = Date()
        let track = UUID()
        let passage = TranscriptSegment(trackID: track, start: 0, end: 4, text: "Last week we agreed on the date.")
        state.update(id) { meeting in
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [passage], createdAt: began.addingTimeInterval(-600))]
            meeting.unifiedTranscript = [passage]
        }
        var meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        var heard = line("Can we lock the venue too?", 3, 5)
        heard.source = .microphone
        let captions = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [heard], createdAt: began)

        // The one rule: their own, not replaced by a transcript from before them; after it, not in its place.
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions)
        XCTAssertFalse(SavedCaptions.standsIn(for: meeting))
        XCTAssertEqual(SavedCaptions.hits(in: [meeting], query: "venue", captions: [id: captions]).map(\.segment.id), [heard.id])

        // This Mac reads them off the main actor once saved, and shows them as the iPhone does.
        try await state.captions.store.save(captions)
        XCTAssertNil(state.savedCaptions(for: meeting), "not read yet")
        await state.captions.readSaved()
        XCTAssertEqual(state.savedCaptions(for: meeting), captions)
        XCTAssertTrue(state.hasTranscriptPage(meeting))
        state.window.searchText = "venue"
        XCTAssertTrue(state.searchHits.isEmpty, "nothing else in the conversation says it")
        let found = await LibraryCaptionSearch.hits(in: state.meetings, query: state.window.searchText, excluding: Set(state.searchHits.map(\.meetingID)),
                                                    libraryRoot: state.library.rootURL)
        XCTAssertEqual(found.map(\.meeting.id), [id], "search finds them")
        state.window.searchText = "agreed on the date"
        let again = await LibraryCaptionSearch.hits(in: state.meetings, query: "venue", excluding: Set(state.searchHits.map(\.meetingID)),
                                                    libraryRoot: state.library.rootURL)
        XCTAssertTrue(again.isEmpty, "a conversation the search found is listed once")
        state.window.searchText = ""
        state.recordingID = id
        XCTAssertNil(state.savedCaptions(for: meeting), "while this Mac records it, the page shows them live")
        state.recordingID = nil

        // The new recording's transcript replaces them on the page at once, and pruning takes them.
        state.update(id) { $0.transcripts.append(TrackTranscript(trackID: UUID(), segments: [], createdAt: Date())) }
        meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertNil(state.savedCaptions(for: meeting))
        XCTAssertTrue(state.hasTranscriptPage(meeting), "the transcript's page still has the transcript")
        try await waitUntil("pruned and read again") { state.captions.saved[id] == nil }
        XCTAssertNil(state.captions.store.captions(for: id))
    }

    func testBehaviorSavedCaptionsAloneOpenTheTranscriptPage() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(libraryURL: root, defaults: makeTestDefaults("LiveCaptionsTests.alone"))
        await state.initialize()
        let id = state.newMeeting(title: "Onboarding design review")
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertFalse(state.hasTranscriptPage(meeting), "nothing to turn to")
        try await state.captions.store.save(LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Hi", 0, 1)]))
        await state.captions.readSaved()
        XCTAssertTrue(SavedCaptions.standsIn(for: meeting))
        XCTAssertTrue(state.hasTranscriptPage(meeting), "the captions stand in for the transcript")
        try await state.captions.store.save(LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("  ", 0, 1)]))
        await state.captions.readSaved()
        XCTAssertFalse(state.hasTranscriptPage(meeting), "nothing to read, nothing to turn to")
    }

    /// LC-07: each save while recording reads that conversation's captions again, not every conversation's.
    func testBehaviorASaveReadsOnlyTheConversationSavedAgain() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let captions = LiveCaptionsController(store: store) { _ in nil }
        let recorded = UUID(), other = UUID()
        try await store.save(LiveCaptions(meetingID: recorded, localeIdentifier: "en_US", segments: [line("Before", 0, 1)]))
        try await store.save(LiveCaptions(meetingID: other, localeIdentifier: "en_US", segments: [line("Another", 0, 1)]))
        await captions.readSaved()
        XCTAssertEqual(Set(captions.saved.keys), [recorded, other])
        // Both change on disk; only the recording's are saved here.
        try await store.save(LiveCaptions(meetingID: other, localeIdentifier: "en_US", segments: [line("Another, changed", 0, 1)],
                                          updatedAt: Date().addingTimeInterval(5)))
        try await store.save(LiveCaptions(meetingID: recorded, localeIdentifier: "en_US", segments: [line("After", 0, 1)],
                                          updatedAt: Date().addingTimeInterval(5)))
        await captions.readSaved(recorded)
        XCTAssertEqual(captions.saved[recorded]?.map { $0.segments.map(\.text) }, [["After"]])
        XCTAssertEqual(captions.saved[other]?.map { $0.segments.map(\.text) }, [["Another"]], "not read again")
        await store.remove(recorded)
        await captions.readSaved(recorded)
        XCTAssertNil(captions.saved[recorded])
    }

    func testBehaviorPruningFollowsTranscriptsAndConversationsNeverNotes() {
        var meeting = Meeting(title: "Launch planning")
        let before = LiveCaptionStore.transcriptDates([meeting])
        meeting.notes = "Typing notes changes nothing pruning reads."
        XCTAssertEqual(LiveCaptionStore.transcriptDates([meeting]), before)
        meeting.transcripts = [TrackTranscript(trackID: UUID(), segments: [])]
        XCTAssertNotEqual(LiveCaptionStore.transcriptDates([meeting]), before, "a transcript does")
        XCTAssertNotEqual(LiveCaptionStore.transcriptDates([meeting, Meeting(title: "Another")]).count, before.count, "and a conversation")
    }

    // MARK: macOS 15

    func testOnMacOS15TheLanguagesAreTheLiveRecognizers() {
        let latin = ["en", "es", "fr", "it", "pt", "de"]
        let offered = LiveCaptionLanguages.options(speech: [], live: latin, selected: nil)
        XCTAssertEqual(Set(offered.map(\.identifier)), Set(latin), "the downloaded recognizers' languages, not only Same as This Mac")
        XCTAssertEqual(offered.map { LiveCaptionAvailability.name($0) }, offered.map { LiveCaptionAvailability.name($0) }.sorted(), "by name")
        XCTAssertTrue(LiveCaptionLanguages.supported(systemCaptions: false, liveLanguages: latin), "the switch works whatever this Mac's language")
        // Where the Speech framework exists, its languages come first, then those only a downloaded recognizer covers.
        let speech = [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")]
        let both = LiveCaptionLanguages.options(speech: speech, live: latin, selected: "en_US")
        XCTAssertEqual(Array(both.prefix(2)), speech)
        XCTAssertEqual(Set(both.dropFirst(2).map(\.identifier)), ["es", "fr", "it", "pt", "de"], "English is the Speech framework's already")
        // A language chosen before its model was removed stays chosen, and the footer says why it's quiet.
        XCTAssertEqual(LiveCaptionLanguages.options(speech: [], live: latin, selected: "ja").last?.identifier, "ja")
        XCTAssertEqual(LiveCaptionLanguages.footer(systemCaptions: false, liveLanguages: latin, liveCovers: false, enabled: true,
                                                   locale: Locale(identifier: "ja"), availability: nil),
                       "Live transcription doesn’t cover \(LiveCaptionAvailability.name(Locale(identifier: "ja"))).")
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: false, liveLanguages: latin, liveCovers: true, enabled: true,
                                                 locale: Locale(identifier: "de"), availability: nil))
        XCTAssertEqual(LiveCaptionLanguages.footer(systemCaptions: false, liveLanguages: [], liveCovers: false, enabled: true,
                                                   locale: .current, availability: nil),
                       "Live captions need macOS 26, or Live transcription from Settings › Models.")
        XCTAssertFalse(LiveCaptionLanguages.supported(systemCaptions: false, liveLanguages: []))
    }

    func testWithoutSpeechSupportThereAreNoCaptionsAndNoErrors() async throws {
        let defaults = makeTestDefaults("LiveCaptionsTests")
        let settings = LiveCaptionSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled, "on by default, as on the iPhone")
        // macOS 15 has no SpeechAnalyzer: the system makes no captioner, whatever the setting.
        XCTAssertNil(MacCaptioners.speechCaptioner(for: .microphone, allowsDownload: false, supported: false))
        XCTAssertNil(MacCaptioners.speechCaptioner(for: .call, allowsDownload: false, supported: false))
        // Tests never reach the Speech framework, and captions turned off make none either.
        XCTAssertNil(MacCaptioners.recordingFactory(settings: settings)(.microphone))
        settings.isEnabled = false
        XCTAssertEqual(LiveCaptionSettings(defaults: defaults).isEnabled, false, "remembered on this Mac")
        XCTAssertNil(MacCaptioners.recorderFactory(settings: settings)())

        let clock = FakeHostClock()
        let mic = FakeCaptureSource(method: "microphone")
        let recorder = RecordingController(environment: CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { mic }, systemAudio: FakeSystemAudio(),
            currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
            observeRoutes: { _ in NSObject() }, hostTime: { clock.now }))
        let captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: root)) { source in
            MacCaptioners.speechCaptioner(for: source, allowsDownload: false, supported: false)
        }
        captions.follow(recorder)
        let meeting = UUID()
        recorder.captionTap = captions.prepare(meetingID: meeting, includesCall: true)
        XCTAssertNil(recorder.captionTap, "no tap: the recording is exactly as without captions")
        try await recorder.start(in: root.appendingPathComponent("Staging"), includeSystemAudio: false)
        await captions.start(locale: .current)
        mic.emit(CallSignals.tone(), at: clock.now + 0.1)
        XCTAssertFalse(captions.isShowing(for: meeting))
        XCTAssertEqual(captions.state, .off)
        XCTAssertTrue(captions.segments.isEmpty)
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        await captions.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: captions.store.directory.path), "nothing saved")
    }
}

/// A captioner that keeps what the recorder's tap hands it (time on the recording's timeline, rate)
/// and posts captions when told. No speech recognition.
final class TapCaptioner: LiveCaptioning, @unchecked Sendable {
    struct Fed { var time: TimeInterval; var rate: Double }
    let updates: AsyncStream<[LiveCaptionSegment]>
    let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let lock = NSLock()
    private var buffers: [Fed] = []
    private var locale: Locale?
    private var done = false

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream()
        (states, statesContinuation) = AsyncStream.makeStream()
    }

    var fed: [Fed] { lock.withLock { buffers } }
    var startedLocale: Locale? { lock.withLock { locale } }
    var finished: Bool { lock.withLock { done } }

    func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        lock.withLock { self.locale = locale }
        statesContinuation.yield(.listening)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let seconds = time.map { Double($0.sampleTime) / $0.sampleRate } ?? -1
        lock.withLock { buffers.append(Fed(time: seconds, rate: buffer.format.sampleRate)) }
    }

    func post(_ segments: [LiveCaptionSegment]) { updatesContinuation.yield(segments) }

    func finish() async {
        lock.withLock { done = true }
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
    }
}

/// A captioner that fails as soon as it starts, as the Speech framework might mid-call.
final class FailingCaptioner: LiveCaptioning, @unchecked Sendable {
    let updates: AsyncStream<[LiveCaptionSegment]>
    let states: AsyncStream<LiveCaptionState>
    private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
    private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation
    private let lock = NSLock()
    private var count = 0

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream()
        (states, statesContinuation) = AsyncStream.makeStream()
    }

    var appended: Int { lock.withLock { count } }

    func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
        statesContinuation.yield(.failed("Captions stopped: test"))
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) { lock.withLock { count += 1 } }

    func finish() async {
        statesContinuation.yield(.finished)
        updatesContinuation.finish()
        statesContinuation.finish()
    }
}
