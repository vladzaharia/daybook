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
        func replaced(_ made: [Date]) -> Bool { LiveCaptionCoverage(otherTranscripts: made).replacesAll(captions) }
        XCTAssertFalse(replaced([]))
        XCTAssertFalse(replaced([began.addingTimeInterval(-60)]), "an earlier recording's transcript doesn't cover them")
        XCTAssertTrue(replaced([began.addingTimeInterval(-60), began.addingTimeInterval(300)]))
        XCTAssertEqual(LiveCaptionStore.shown(captions, conversation: id, coverage: LiveCaptionCoverage()), captions)
        XCTAssertNil(LiveCaptionStore.shown(captions, conversation: UUID(), coverage: LiveCaptionCoverage()), "another conversation's never show")
        XCTAssertNil(LiveCaptionStore.shown(captions, conversation: id, coverage: LiveCaptionCoverage(otherTranscripts: [began])))
        let blank = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("  ", 0)], createdAt: began)
        XCTAssertNil(LiveCaptionStore.shown(blank, conversation: id, coverage: LiveCaptionCoverage()), "nothing to read, nothing shown")
    }

    /// An iPhone that began recording half an hour before a Mac joined: the Mac's transcript covers the second half
    /// only, so the first half's captions stay until the iPhone's own recording is transcribed.
    func testBehaviorAPhoneThatStartedFirstKeepsWhatTheMacsTranscriptDoesntCover() {
        let id = UUID(), began = Date(timeIntervalSince1970: 10_000), phoneTrack = UUID()
        let captions = LiveCaptions(meetingID: id, trackID: phoneTrack, localeIdentifier: "en_US",
                                    segments: [line("Before the Mac joined", 600), line("Once the Mac joined", 2_700)],
                                    createdAt: began, startedAt: began)
        var phone = LiveCaptionCoverage.Recording(trackID: phoneTrack, source: "microphone", deviceKind: "daybook.iphone", recordingID: "r",
                                                  startedAt: began, createdAt: began, duration: 3_600)
        let mac = LiveCaptionCoverage.Recording(trackID: UUID(), source: "microphone", startedAt: began.addingTimeInterval(1_800),
                                                createdAt: began.addingTimeInterval(3_600), duration: 1_800,
                                                transcribedAt: began.addingTimeInterval(3_700))
        var coverage = LiveCaptionCoverage(recordings: [phone, mac])
        XCTAssertEqual(coverage.shown(captions)?.segments.map(\.text), ["Before the Mac joined"])
        XCTAssertFalse(coverage.replacesAll(captions), "kept: the first half is still to read")
        phone.transcribedAt = began.addingTimeInterval(4_000)
        coverage = LiveCaptionCoverage(recordings: [phone, mac])
        XCTAssertNil(coverage.shown(captions))
        XCTAssertTrue(coverage.replacesAll(captions), "its own recording's transcript replaces every line")
    }

    /// On a Mac: a phone's lines wait for the phone's own recording, found by the ID the link gave it; this Mac's
    /// own lines go with this Mac's transcript; a line both heard goes with either.
    func testBehaviorAnotherDevicesLinesWaitForTheirOwnRecording() {
        let id = UUID(), began = Date(timeIntervalSince1970: 20_000), phone = LiveCaptionSource.device("phone:p")
        var mine = line("Mine", 10), theirs = line("The phone's", 20), both = line("Both heard", 30)
        mine.source = .microphone
        theirs.source = phone
        both.source = phone
        both.alsoHeard = [.microphone]
        let captions = LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [mine, theirs, both], createdAt: began, startedAt: began,
                                    tracks: [phone.rawValue: LiveCaptionTrack(deviceKind: "daybook.iphone", recordingID: "rec-1")])
        let macTrack = LiveCaptionCoverage.Recording(trackID: UUID(), source: "microphone", startedAt: began.addingTimeInterval(0.2),
                                                     createdAt: began.addingTimeInterval(60), duration: 60,
                                                     transcribedAt: began.addingTimeInterval(120))
        var phoneTrack = LiveCaptionCoverage.Recording(trackID: UUID(), source: "microphone", deviceKind: "daybook.iphone", recordingID: "rec-1",
                                                       startedAt: began, createdAt: began.addingTimeInterval(300), duration: 60)
        XCTAssertEqual(LiveCaptionCoverage(recordings: [macTrack]).shown(captions)?.segments.map(\.text), ["The phone's"],
                       "the phone's recording hasn't arrived: its line stays")
        XCTAssertEqual(LiveCaptionCoverage(recordings: [macTrack, phoneTrack]).shown(captions)?.segments.map(\.text), ["The phone's"],
                       "arrived, not transcribed")
        phoneTrack.transcribedAt = began.addingTimeInterval(400)
        XCTAssertTrue(LiveCaptionCoverage(recordings: [macTrack, phoneTrack]).replacesAll(captions))
        XCTAssertNil(LiveCaptionCoverage(recordings: [phoneTrack]).shown(captions),
                     "the phone's transcript covers this Mac's own lines' time too")
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
        XCTAssertProtectionClass(store.url(for: id), .completeUntilFirstUserAuthentication)
        XCTAssertEqual(store.captions(for: id)?.segments.map(\.text), ["Private"])
        XCTAssertEqual(store.conversations(), [id])
    }

    /// The iPhone keeps them as its recording in progress, until unlock: a locked iPhone writes them but can't read one
    /// back, so reading falls back to the copy last written, and filing them with their recording still works. A file
    /// made unreadable stands in for a locked iPhone; one that's gone reads as gone.
    func testBehaviorCaptionsKeptUntilUnlockReadAsTheLastCopyWhileTheyCantBeRead() async throws {
        let store = LiveCaptionStore(libraryRoot: root, protection: .completeUnlessOpen)
        let captions = LiveCaptions(meetingID: UUID(), captureID: UUID(), localeIdentifier: "en_US", segments: [line("Locked", 0)])
        try await store.save(captions)
        let url = store.url(for: captions.key)
        XCTAssertProtectionClass(url, .completeUnlessOpen)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        XCTAssertNil(try? Data(contentsOf: url))

        XCTAssertEqual(store.captions(for: captions.key)?.segments.map(\.text), ["Locked"])
        let track = UUID()
        let filed = try await store.update(captions.key) { $0.trackID = track; $0.updatedAt = Date(); return true }
        XCTAssertEqual(filed?.trackID, track)
        XCTAssertEqual(try JSONDecoder().decode(LiveCaptions.self, from: Data(contentsOf: url)).trackID, track, "written as a new file")

        await store.remove(captions.meetingID)
        XCTAssertNil(store.captions(for: captions.key))
        XCTAssertEqual(LiveCaptionStore(libraryRoot: root).protection, .completeUntilFirstUserAuthentication, "the Mac's")
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
        await store.prune([untranscribed: LiveCaptionCoverage(), olderTranscript: LiveCaptionCoverage(otherTranscripts: [began.addingTimeInterval(-600)]),
                           replaced: LiveCaptionCoverage(otherTranscripts: [began.addingTimeInterval(60)])],
                          keeping: [recording])
        XCTAssertEqual(Set(store.conversations()), [untranscribed, olderTranscript, recording])
        await store.remove(untranscribed)
        XCTAssertNil(store.captions(for: untranscribed))
    }

    func testBehaviorPruningWithTheTrashKeepsCaptionsOfAConversationNotFiledYet() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let began = Date()
        let unfiled = UUID(), trashed = UUID(), replaced = UUID()
        for id in [unfiled, trashed, replaced] {
            try await store.save(LiveCaptions(meetingID: id, localeIdentifier: "en_US", segments: [line("Hi", 0)], createdAt: began))
        }
        // The iPhone: a recording joins the library once it's filed, so only what's in the Trash is gone.
        await store.prune([replaced: LiveCaptionCoverage(otherTranscripts: [began.addingTimeInterval(60)])], keeping: [], trashed: [trashed])
        XCTAssertEqual(store.conversations(), [unfiled], "a recording stopped a moment ago, or left by a crash, keeps its captions")

        // Filed, its captions stay until a transcript replaces them, or it goes to the Trash.
        await store.prune([unfiled: LiveCaptionCoverage()], keeping: [], trashed: [])
        XCTAssertEqual(store.conversations(), [unfiled])
        await store.prune([:], keeping: [], trashed: [unfiled])
        XCTAssertTrue(store.conversations().isEmpty)
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
        try await waitUntil("the recorder's line") { session.segments.count == 3 }
        XCTAssertEqual(session.segments.map(\.text), ["Budget agreed", "Next we", "The recorder heard this."])
        XCTAssertEqual(session.segments.last?.start ?? 0, 4, accuracy: 0.001)

        await session.finish()
        let saved = try XCTUnwrap(store.captions(for: id))
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false, false], "what stood at the end is kept as heard")
        XCTAssertEqual(saved.sourceNames?[LiveCaptionSource.device("sim").rawValue], "Soundcore")
        XCTAssertNotNil(saved.captureID, "kept as this recording's")
        XCTAssertNotNil(saved.startedAt)
        XCTAssertNil(session.meetingID)
        XCTAssertTrue(session.segments.isEmpty)
        session.received([line("Late", 9)], from: .device("sim"), name: "Soundcore", offset: 0)
        XCTAssertTrue(session.segments.isEmpty, "nothing joins once the recording's captions are done")
    }

    /// Each recording into a conversation keeps its own captions: a second one doesn't overwrite the first's, nor
    /// take the recording the first was filed with.
    func testBehaviorASecondRecordingIntoAConversationKeepsTheFirstsCaptions() async throws {
        let store = LiveCaptionStore(libraryRoot: root)
        let session = LiveCaptionSession(store: store, saveInterval: .seconds(60))
        let id = UUID(), track = UUID()
        for text in ["The first recording", "Recorded into again"] {
            let captioner = ScriptedCaptioner(lines: [])
            XCTAssertTrue(session.begin(meetingID: id, captioners: [(.microphone, captioner)]))
            await session.start(locale: Locale(identifier: "en_US"))
            try await waitUntil("listening") { session.states[.microphone] == .listening }
            captioner.apply(text: text, start: 0.4, end: 1.5, isFinal: true)
            try await waitUntil("heard") { session.segments.map(\.text) == [text] }
            await session.finish()
            if text == "The first recording" { try await store.update(id) { $0.trackID = track; return true } }
        }
        let captures = store.captures(of: id)
        XCTAssertEqual(captures.map { $0.segments.map(\.text) }, [["The first recording"], ["Recorded into again"]])
        XCTAssertEqual(captures.map(\.trackID), [track, nil], "the second isn't filed with the first's recording")
        XCTAssertEqual(Set(captures.map(\.captureID)).count, 2)
        XCTAssertEqual(store.conversations(), [id])
        XCTAssertEqual(LiveCaptions.together(captures)?.segments.map(\.text), ["The first recording", "Recorded into again"],
                       "read together, the oldest first")
        await store.remove(id)
        XCTAssertTrue(store.keys().isEmpty)
    }

    /// A recording's last save has no later one to try it again: a write that fails as it stops is kept, read as it
    /// would have left the captions, built on by what comes after (filing), and written once it can be.
    func testBehaviorALastSaveThatFailsIsKeptAndWrittenOnceItCanBe() async throws {
        let store = LiveCaptionStore(libraryRoot: root, retryDelays: [0.05, 0.1, 0.2, 0.4, 0.8, 1.6])
        let session = LiveCaptionSession(store: store, saveInterval: .milliseconds(50))
        let captioner = ScriptedCaptioner(lines: [])
        let id = UUID(), track = UUID()
        XCTAssertTrue(session.begin(meetingID: id, captioners: [(.microphone, captioner)]))
        await session.start(locale: Locale(identifier: "en_US"))
        try await waitUntil("listening") { session.states[.microphone] == .listening }
        captioner.apply(text: "Budget agreed", start: 0.4, end: 1.5, isFinal: true)
        captioner.apply(text: "Next we", start: 1.6, end: 1.9, isFinal: false)
        try await waitUntil("saved while listening") { store.captions(for: id)?.segments.count == 2 }

        // The folder can't be written as the recording stops (full, or locked away).
        let folder = store.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let file = store.url(for: LiveCaptionKey(meetingID: id, captureID: session.captureID))
        func onDisk() throws -> LiveCaptions { try JSONDecoder().decode(LiveCaptions.self, from: Data(contentsOf: file)) }
        await session.finish()
        XCTAssertEqual(try onDisk().segments.last?.isTentative, true, "the file is still the last snapshot")
        XCTAssertEqual(store.captions(for: id)?.segments.map(\.isTentative), [false, false], "read as the last save left them")
        XCTAssertEqual(store.conversations(), [id])
        // Filed meanwhile, as the iPhone does: on top of the last save, not the file.
        _ = try? await store.update(id) { $0.trackID = track; return true }
        XCTAssertEqual(store.captions(for: id)?.trackID, track)
        XCTAssertEqual(store.captions(for: id)?.segments.last?.isTentative, false)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        try await waitUntil("written once it can be") { (try? onDisk())?.trackID == track }
        let saved = try onDisk()
        XCTAssertEqual(saved.segments.map(\.text), ["Budget agreed", "Next we"])
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false])
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
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: [], liveCovers: false, enabled: true,
                                                 locale: german, availability: download),
                     "the system fetching a language the first time it's recorded with is how it works, not a footer (VM-23)")
        XCTAssertEqual(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: [], liveCovers: false, enabled: true,
                                                   locale: german, availability: .unavailable("Not here.")), "Not here.")
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: ["de"], liveCovers: true, enabled: true,
                                                 locale: german, availability: download),
                     "a downloaded recognizer covers it: nothing to download, nothing to say")
        XCTAssertNil(LiveCaptionLanguages.footer(systemCaptions: true, liveLanguages: [], liveCovers: false, enabled: false,
                                                 locale: german, availability: .unavailable("Not here.")), "off: no footer")
    }
}
