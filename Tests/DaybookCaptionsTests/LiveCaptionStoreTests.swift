import AVFoundation
@testable import DaybookCaptions
import DaybookTestSupport
import XCTest

/// The store and the recording session both apps share: one rule for when a transcript replaces live
/// captions, files only this user can read, saves that land in order off the main actor, pruning that
/// reads only what it must, and a session that saves while it listens and keeps what stands at the end.
/// Scripted captioners and a temporary folder; no speech recognition.
@MainActor
final class LiveCaptionStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCaptionStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ text: String, _ start: TimeInterval, tentative: Bool = false) -> LiveCaptionSegment {
        LiveCaptionSegment(start: start, end: start + 1, text: text, isTentative: tentative)
    }

    // MARK: The rule

    func testBehaviorATranscriptReplacesCaptionsOnlyOnceOneIsMadeAfterThem() {
        let id = UUID(), began = Date(timeIntervalSince1970: 1_000)
        let captions = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Heard", 0)], createdAt: began)
        XCTAssertFalse(LiveCaptionStore.isReplaced(captions, transcriptsMadeAt: []))
        XCTAssertFalse(LiveCaptionStore.isReplaced(captions, transcriptsMadeAt: [began.addingTimeInterval(-60)]),
                       "an earlier recording's transcript doesn't cover them")
        XCTAssertTrue(LiveCaptionStore.isReplaced(captions, transcriptsMadeAt: [began.addingTimeInterval(-60), began.addingTimeInterval(300)]))
        XCTAssertEqual(LiveCaptionStore.shown(captions, conversation: id, transcriptsMadeAt: []), captions)
        XCTAssertNil(LiveCaptionStore.shown(captions, conversation: UUID(), transcriptsMadeAt: []), "another conversation's never show")
        XCTAssertNil(LiveCaptionStore.shown(captions, conversation: id, transcriptsMadeAt: [began]))
        let blank = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("  ", 0)], createdAt: began)
        XCTAssertNil(LiveCaptionStore.shown(blank, conversation: id, transcriptsMadeAt: []), "nothing to read, nothing shown")
    }

    // MARK: Files

    func testBehaviorEachFileIsThisUsersAloneAndProtected() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let id = UUID()
        try await store.save(LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Private", 0)]))
        XCTAssertEqual(store.url(for: id).path, root.appendingPathComponent("LiveCaptions/\(id.uuidString).json").path,
                       "beside the library, outside Meetings/, so sync never sees it")
        let folder = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let file = try FileManager.default.attributesOfItem(atPath: store.url(for: id).path)
        XCTAssertEqual(folder[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(file[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(store.captions(for: id)?.segments.map(\.text), ["Private"])
        XCTAssertEqual(store.conversations(), [id])
    }

    func testBehaviorASaveStillOnItsWayNeverPutsBackWhatALaterOneReplaced() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let id = UUID(), began = Date().addingTimeInterval(-60)
        let early = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Half a sen", 0, tentative: true)],
                                 createdAt: began, updatedAt: began.addingTimeInterval(10))
        let final = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Half a sentence, whole.", 0)],
                                 createdAt: began, updatedAt: began.addingTimeInterval(12))
        try await store.save(final)
        try await store.save(early)
        XCTAssertEqual(store.captions(for: id)?.segments.map(\.text), ["Half a sentence, whole."], "the older snapshot is left out")

        // Filed with its recording: a later save that doesn't know the recording keeps it.
        let track = UUID()
        try await store.update(id) { captions in captions.trackID = track; captions.updatedAt = Date(); return true }
        var later = final
        later.updatedAt = Date().addingTimeInterval(1)
        later.segments.append(line("And more.", 2))
        try await store.save(later)
        XCTAssertEqual(store.captions(for: id)?.trackID, track)
        XCTAssertEqual(store.captions(for: id)?.segments.count, 2)

        // An edit that finds the captions changed leaves them.
        let unchanged = try await store.update(id) { _ in false }
        XCTAssertNil(unchanged)
        XCTAssertEqual(store.captions(for: id)?.segments.count, 2)
    }

    func testBehaviorPruningRemovesReplacedAndOrphanedCaptionsAndKeepsTheRecording() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let began = Date()
        let untranscribed = UUID(), olderTranscript = UUID(), replaced = UUID(), trashed = UUID(), recording = UUID()
        for id in [untranscribed, olderTranscript, replaced, trashed, recording] {
            try await store.save(LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Hi", 0)], createdAt: began))
        }
        await store.prune([untranscribed: [], olderTranscript: [began.addingTimeInterval(-600)], replaced: [began.addingTimeInterval(60)]],
                          keeping: [recording])
        XCTAssertEqual(Set(store.conversations()), [untranscribed, olderTranscript, recording])
        await store.remove(untranscribed)
        XCTAssertNil(store.captions(for: untranscribed))
    }

    // MARK: A recording

    func testBehaviorASessionSavesAsItListensAndKeepsWhatStandsAtTheEnd() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let session = LiveCaptionSession(store: store, saveInterval: .milliseconds(50))
        let captioner = ScriptedCaptioner(lines: [])
        let id = UUID()
        XCTAssertTrue(session.begin(meetingID: id, captioners: [(.microphone, captioner)]))
        XCTAssertEqual(session.states[.microphone], .preparing)
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        captioner.apply(text: "Budget agreed", start: 0.4, end: 1.5, isFinal: true)
        captioner.apply(text: "Next we", start: 1.6, end: 1.9, isFinal: false)
        try await waitUntil("saved while listening") { session.lastSave != nil && store.captions(for: id)?.segments.count == 2 }
        XCTAssertEqual(store.captions(for: id)?.segments.last?.isTentative, true)

        // A recorder recording along, a second ahead of this device.
        session.received([line("The recorder heard this.", 5)], from: .device("sim"), name: "Soundcore", offset: -1)
        XCTAssertEqual(session.segments.map(\.text), ["Budget agreed", "Next we", "The recorder heard this."])
        XCTAssertEqual(session.segments.last?.start ?? 0, 4, accuracy: 0.001)

        await session.finish()
        let saved = try XCTUnwrap(store.captions(for: id))
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false, false], "what stood at the end is kept as heard")
        XCTAssertEqual(saved.sourceNames?[LiveCaptionSource.device("sim").rawValue], "Soundcore")
        XCTAssertNil(session.meetingID)
        XCTAssertTrue(session.segments.isEmpty)
        session.received([line("Late", 9)], from: .device("sim"), name: "Soundcore", offset: 0)
        XCTAssertTrue(session.segments.isEmpty, "nothing joins once the recording's captions are done")
    }

    func testBehaviorWithoutACaptionerThereIsNothingToCaption() async {
        let session = LiveCaptionSession(store: LiveCaptionStore(libraryRoot: root))
        XCTAssertFalse(session.begin(meetingID: UUID(), captioners: []))
        XCTAssertFalse(session.isActive)
        await session.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nothing saved")
    }

    func testBehaviorAScriptFinishedBeforeItStartsSaysNothingMore() async {
        let captioner = ScriptedCaptioner(lines: [.init(at: 0, text: "Never heard")], wordInterval: 0.01)
        let states = Task { var all: [LiveCaptionState] = []; for await state in captioner.states { all.append(state) }; return all }
        await captioner.finish()
        await captioner.start(locale: .current, sourceFormat: nil)
        let said = await states.value
        XCTAssertEqual(said, [.finished], "a captioner finished first never starts listening")
    }

    // MARK: Words

    func testBehaviorEachLineSaysWhoItsFrom() {
        let names = [LiveCaptionSource.device("sim").rawValue: "Soundcore"]
        var you = line("Mine", 0)
        you.source = .microphone
        var recorder = line("Theirs", 1)
        recorder.source = .device("sim")
        var named = recorder
        named.speaker = LiveCaptionSpeaker(slot: "S1", name: "Priya")
        XCTAssertEqual(LiveCaptionLabels.lane(you), "You")
        XCTAssertNil(LiveCaptionLabels.lane(recorder), "another device's line has no lane")
        XCTAssertNil(LiveCaptionLabels.speaker(you, names: names))
        XCTAssertEqual(LiveCaptionLabels.speaker(recorder, names: names), "Soundcore")
        XCTAssertEqual(LiveCaptionLabels.speaker(named, names: names), "Priya", "a recognized person comes first")
        XCTAssertNil(LiveCaptionLabels.lane(line("Single source", 0)))
        XCTAssertEqual(LiveCaptionTurn.turns([you, recorder, named], names: names).map(\.label), ["You", "Soundcore", "Priya"])
        XCTAssertEqual(LiveCaptionStatus.line(.listening, locale: .current), "Listening…", "the same words before anything is heard, everywhere")
        XCTAssertNil(LiveCaptionStatus.line(.finished, locale: .current))
    }

    func testBehaviorSettingsOfferEveryLanguageCaptionsCanRunInAndSpeakOnlyWhileTheyreOn() {
        let speech = [Locale(identifier: "en_US")]
        let offered = LiveCaptionLanguages.options(speech: speech, live: ["en", "de"], selected: nil)
        XCTAssertEqual(offered.map(\.identifier), ["en_US", "de"], "a language only a downloaded recognizer covers can be chosen")
        let german = Locale(identifier: "de")
        let download = LiveCaptionAvailability.needsDownload(german)
        XCTAssertNotNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: [], liveCovers: false, enabled: true,
                                                    locale: german, availability: download))
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: ["de"], liveCovers: true, enabled: true,
                                                 locale: german, availability: download),
                     "a downloaded recognizer covers it: nothing to download, nothing to say")
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: [], liveCovers: false, enabled: false,
                                                 locale: german, availability: .unavailable("Not here.")), "off: no footer")
    }
}
