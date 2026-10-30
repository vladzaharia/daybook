import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookLink
import DaybookTestSupport
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

    func testEchoNeedsMostOfTheLinesWordsNearbyInTime() {
        let call = [line("We still need legal to sign off on the pricing page before Friday.", 20, 24)]
        XCTAssertTrue(CaptionEcho.isEcho(line("we still need legal to sign off on the pricing page", 20.3, 23.9), of: call))
        XCTAssertTrue(CaptionEcho.isEcho(line("Let’s see — legal to sign off the pricing page by Friday", 21, 24), of: call), "close enough to be the echo")
        XCTAssertFalse(CaptionEcho.isEcho(line("I can ask legal today.", 21, 22), of: call), "your own words, even mid-call")
        XCTAssertFalse(CaptionEcho.isEcho(line("we still need legal to sign off on the pricing page", 40, 43), of: call), "too long after")
        XCTAssertEqual(CaptionEcho.words("Let’s go, Priya's 14th!"), ["lets", "go", "priyas", "14th"])
        XCTAssertEqual(CaptionEcho.sharedRun(["a", "b", "c", "d"], ["x", "a", "c", "y", "d"]), 3)
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
        state.phoneCaptioned(LinkCaptions(conversationID: id, startedAt: Date(timeIntervalSince1970: 1_004), lines: [
            .init(id: UUID(), start: 1, end: 2, text: "Heard on the phone.", isTentative: false, speakerSlot: "S1", speakerName: "Priya"),
            .init(id: UUID(), start: 3, end: 4, text: "Heard by its recorder.", isTentative: true, device: "Soundcore"),
        ]), from: phone)
        state.phoneCaptioned(LinkCaptions(conversationID: UUID(), startedAt: Date(), lines: [
            .init(id: UUID(), start: 0, end: 1, text: "Another conversation", isTentative: false)]), from: phone)
        XCTAssertEqual(state.captions.segments.map(\.text), ["Heard on the phone.", "Heard by its recorder."])
        XCTAssertEqual(state.captions.segments.first?.start ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(state.captions.segments.first?.speaker?.name, "Priya")
        XCTAssertEqual(state.captions.segments.map { state.captions.label(for: $0.source) }, ["iPhone", "Soundcore"])
        await state.captions.finish()
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
        XCTAssertEqual(store.url(for: meetingID).path, root.appendingPathComponent("LiveCaptions/\(meetingID.uuidString).json").path,
                       "beside the library, outside Meetings/, so sync never sees it")
        let saved = try XCTUnwrap(store.captions(for: meetingID))
        XCTAssertEqual(saved.segments.map(\.text), ["Thanks for joining.", "Happy to be here"])
        XCTAssertEqual(saved.segments.map(\.source), [.call, .microphone])
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false], "what stood at Stop is kept as heard")
        XCTAssertNotNil(rig.captions.lastSave)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)

        var meeting = Meeting(id: meetingID, title: "Launch planning", date: saved.createdAt)
        let earlier = Meeting(id: UUID(), title: "Earlier")
        XCTAssertEqual(LiveCaptionStore.shown(saved, for: meeting), saved, "until the transcript exists")
        // A transcript made before the captions (an earlier recording of the conversation) doesn't replace them.
        let track = UUID()
        meeting.transcripts = [TrackTranscript(trackID: track, segments: [], createdAt: saved.createdAt.addingTimeInterval(-600))]
        XCTAssertNotNil(LiveCaptionStore.shown(saved, for: meeting))
        store.prune(meetings: [meeting, earlier], keeping: nil)
        XCTAssertNotNil(store.captions(for: meetingID))

        // The transcript lands: the captions are gone from the page and from this Mac.
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: [], createdAt: Date()))
        XCTAssertNil(LiveCaptionStore.shown(saved, for: meeting))
        store.prune(meetings: [meeting, earlier], keeping: nil)
        XCTAssertNil(store.captions(for: meetingID))

        // A conversation moved to the Trash takes its captions; the one being recorded keeps them.
        let recording = UUID(), trashed = UUID()
        try store.save(LiveCaptions(meetingID: recording, localeIdentifier: "en_US", segments: [line("Hi", 0, 1)]))
        try store.save(LiveCaptions(meetingID: trashed, localeIdentifier: "en_US", segments: [line("Bye", 0, 1)]))
        store.prune(meetings: [earlier], keeping: recording)
        XCTAssertNotNil(store.captions(for: recording))
        XCTAssertNil(store.captions(for: trashed))
    }

    // MARK: macOS 15

    func testOnMacOS15TheLanguagesAreTheLiveRecognizers() {
        let latin = ["en", "es", "fr", "it", "pt", "de"]
        let offered = LiveCaptionLanguages.options(speech: [], live: latin, selected: nil)
        XCTAssertEqual(Set(offered.map(\.identifier)), Set(latin), "the downloaded recognizers' languages, not only Same as This Mac")
        XCTAssertEqual(offered.map { LiveCaptionAvailability.name($0) }, offered.map { LiveCaptionAvailability.name($0) }.sorted(), "by name")
        XCTAssertTrue(LiveCaptionLanguages.supported(systemCaptions: false, liveLanguages: latin), "the switch works whatever this Mac's language")
        // Where the Speech framework exists, its languages are offered as before.
        let speech = [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")]
        XCTAssertEqual(LiveCaptionLanguages.options(speech: speech, live: latin, selected: "en_US"), speech)
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
