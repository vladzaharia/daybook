import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Speaker profiles in a library: the person's actions, the coordinator that keeps profiles in step,
/// and profiles with their voiceprints syncing between two Macs through a temporary folder that stands
/// in for the iCloud container. Synthetic embeddings; no models, iCloud, or network.
@MainActor
final class SpeakerProfileLibraryTests: XCTestCase {
    private var root: URL!
    private var suites: [String: String] = [:]
    private var controllers: [LibrarySyncController] = []
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }
    private let space = "fluid-community1-embedding-df2625ac79a7ac6b"
    private let me = SyntheticVoice.person(1), other = SyntheticVoice.person(2)

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookSpeakerProfiles")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
    }

    private func library(_ name: String, synced: Bool = true) async throws -> LibraryController {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        guard synced else {
            let library = LibraryController(rootURL: libraryRoot, sync: nil)
            try await library.load()
            return library
        }
        let suite = suites[name] ?? makeTestSuite("daybook.speaker-profiles.\(name)")
        suites[name] = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults)
        controllers.append(sync)
        sync.replica = .mac(displayName: name, canProcess: true)
        sync.syncDebounce = nil
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        try sync.connect(to: container, monitorChanges: false)
        return library
    }

    @discardableResult
    private func sync(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        await library.flush()
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.statusText ?? "", file: file, line: line)
        return applied
    }

    /// A conversation with one speaker per voice, talking in turn ("<title>:<voice>").
    @discardableResult
    private func conversation(_ title: String, in library: LibraryController, daysAgo: Double,
                              _ voices: [(String, [Float], Double)]) -> UUID {
        let id = library.newMeeting(title: title, date: Date().addingTimeInterval(-daysAgo * 86_400))
        library.update(id) { meeting in
            let track = UUID()
            var time = 0.0
            var segments: [TranscriptSegment] = []
            for (index, voice) in voices.enumerated() {
                let speakerID = "\(title):\(voice.0)"
                segments.append(TranscriptSegment(trackID: track, start: time, end: time + voice.2, text: "Words", speakerID: speakerID))
                time += voice.2
                meeting.speakers.append(Speaker(id: speakerID, name: "Speaker \(index + 1)", sourceTrackID: track,
                                                embedding: voice.1, embeddingModelID: space))
            }
            meeting.transcripts = [TrackTranscript(trackID: track, segments: segments)]
        }
        return id
    }

    private func name(_ library: LibraryController, _ id: UUID, _ speakerID: String) -> String? {
        library.meeting(id)?.speakers.first { $0.id == speakerID }?.name
    }

    private func mine(_ seed: UInt64) -> [Float] { SyntheticVoice.near(me, similarity: 0.95, seed: seed) }

    private func settle(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<6 where await library.reconcileSpeakerProfiles(options: .init()) {}
        let again = await library.reconcileSpeakerProfiles(options: .init())
        XCTAssertFalse(again, "Reconciling didn't settle", file: file, line: line)
    }

    private func activeVoiceprints(_ library: LibraryController) -> [Voiceprint] { (library.metadata.voiceprints ?? []).compactMap(\.value) }

    // MARK: Sync

    func testProfilesAndVoiceprintsSyncAndTwoMacsTeachingOneProfileKeepEveryVoiceprint() async throws {
        let studio = try await library("Studio"), laptop = try await library("Laptop")
        let one = conversation("one", in: studio, daysAgo: 20, [("me", mine(11), 200)])
        studio.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(studio)
        await sync(studio)
        await sync(laptop)

        let vlad = try XCTUnwrap(laptop.speakerProfiles.first)
        XCTAssertEqual(vlad.name, "Vlad")
        XCTAssertEqual(activeVoiceprints(laptop).map(\.id), activeVoiceprints(studio).map(\.id), "Voiceprints travel with the profile")
        XCTAssertEqual(activeVoiceprints(laptop).first?.vector, activeVoiceprints(studio).first?.vector)
        XCTAssertEqual(laptop.meeting(one)?.speakerIdentity("one:me")?.source, .named)

        // Before they sync again, each Mac teaches Vlad something new.
        let two = conversation("two", in: laptop, daysAgo: 5, [("me", mine(12), 300), ("x", SyntheticVoice.near(other, similarity: 0.95, seed: 13), 60)])
        await settle(laptop)
        XCTAssertEqual(name(laptop, two, "two:me"), "Vlad", "Recognized on the laptop from what the studio Mac taught")
        let three = conversation("three", in: studio, daysAgo: 1, [("me", mine(14), 120)])
        studio.renameSpeaker("three:me", to: "Vlad", in: three)
        await settle(studio)

        await sync(laptop); await sync(studio); await sync(laptop)
        for library in [studio, laptop] {
            await settle(library)
            let prints = activeVoiceprints(library)
            XCTAssertEqual(Set(prints.map(\.meetingID)), [one, two, three])
            XCTAssertEqual(Set(prints.filter { $0.origin == .named }.map(\.meetingID)), [one, three])
            XCTAssertEqual(prints.first { $0.meetingID == two }?.origin, .recognized)
            XCTAssertEqual(library.speakerProfiles.map(\.id), [vlad.id])
            XCTAssertEqual(name(library, two, "two:me"), "Vlad")
            XCTAssertEqual(name(library, two, "two:x"), "Speaker 2")
        }
        await sync(studio); await sync(laptop)
        XCTAssertEqual(studio.metadata.speakerProfiles, laptop.metadata.speakerProfiles)
        XCTAssertEqual(studio.metadata.voiceprints, laptop.metadata.voiceprints)
    }

    /// A name given on another device (an iPhone, which doesn't reconcile) teaches the profile on the
    /// Mac when it arrives, and the Mac labels its other conversations.
    func testANameGivenElsewhereTeachesTheMac() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone")
        let one = conversation("one", in: mac, daysAgo: 20, [("me", mine(21), 200)])
        let two = conversation("two", in: mac, daysAgo: 2, [("me", mine(22), 200)])
        await sync(mac); await sync(phone)
        phone.renameSpeaker("one:me", to: "Vlad", in: one)
        await sync(phone); await sync(mac)
        await settle(mac)
        XCTAssertEqual(name(mac, two, "two:me"), "Vlad")
        await sync(mac); await sync(phone)
        XCTAssertEqual(name(phone, two, "two:me"), "Vlad")
        XCTAssertEqual(phone.meeting(two)?.speakerIdentity("two:me")?.source, .recognized)
        XCTAssertEqual(phone.speakerProfiles.map(\.name), ["Vlad"])
    }

    // MARK: The person's actions

    func testNotThemPutsTheNameBackAndTheProfileForgetsWhatItLearned() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(31), 200)])
        let two = conversation("two", in: library, daysAgo: 2, [("me", mine(32), 300)])
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        XCTAssertEqual(name(library, two, "two:me"), "Vlad")
        XCTAssertTrue(activeVoiceprints(library).contains { $0.meetingID == two && $0.origin == .recognized })

        library.rejectSpeakerProfile("two:me", in: two)
        XCTAssertEqual(name(library, two, "two:me"), "Speaker 1")
        XCTAssertEqual(library.meeting(two)?.speakerIdentity("two:me")?.source, .dismissed)
        XCTAssertFalse(activeVoiceprints(library).contains { $0.meetingID == two })
        await settle(library)
        XCTAssertEqual(name(library, two, "two:me"), "Speaker 1", "Not offered again")
        XCTAssertFalse(activeVoiceprints(library).contains { $0.meetingID == two }, "Not learned again")
    }

    func testConfirmingASuggestionNamesTheSpeakerAndTeachesTheProfile() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(41), 200)])
        let print = try XCTUnwrap(library.meeting(one)?.speakers.first?.embedding)
        let two = conversation("two", in: library, daysAgo: 2, [("me", SyntheticVoice.near(print, similarity: 0.75, seed: 42), 200)])
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        XCTAssertEqual(library.meeting(two)?.speakerIdentity("two:me")?.source, .suggested)
        XCTAssertEqual(name(library, two, "two:me"), "Speaker 1")

        library.confirmSpeakerProfile("two:me", in: two)
        XCTAssertEqual(name(library, two, "two:me"), "Vlad")
        XCTAssertEqual(library.meeting(two)?.speakerIdentity("two:me")?.source, .confirmed)
        XCTAssertEqual(library.meeting(two)?.revisions.last?.field, "speaker:two:me", "In Version History like any rename")
        await settle(library)
        XCTAssertEqual(library.meeting(two)?.speakerIdentity("two:me")?.source, .confirmed)
        XCTAssertEqual(activeVoiceprints(library).first { $0.meetingID == two }?.origin, .confirmed)
    }

    func testProfilesCanBeRenamedDeletedAndTheirLearningUndone() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(51), 200)])
        let two = conversation("two", in: library, daysAgo: 2, [("me", mine(52), 300)])
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        let vlad = try XCTUnwrap(library.speakerProfiles.first)

        XCTAssertTrue(library.renameSpeakerProfile(vlad.id, to: "Vladimir"))
        await settle(library)
        XCTAssertEqual(name(library, two, "two:me"), "Vladimir", "Labels follow the profile")
        XCTAssertEqual(name(library, one, "one:me"), "Vlad", "The person's own name stays")
        XCTAssertEqual(library.speakers(of: vlad.id).count, 2)

        library.forgetLearnedVoiceprints(of: vlad.id)
        XCTAssertEqual(activeVoiceprints(library).map(\.origin), [.named])

        library.deleteSpeakerProfile(vlad.id)
        await settle(library)
        XCTAssertTrue(library.speakerProfiles.isEmpty)
        XCTAssertTrue(activeVoiceprints(library).isEmpty)
        XCTAssertEqual(name(library, two, "two:me"), "Speaker 1")
        XCTAssertEqual(name(library, one, "one:me"), "Vlad")
    }

    /// The same person named two ways on one Mac, merged there: the other Mac ends with one profile,
    /// the person's names, and the merged profile's speakers.
    func testMergingTwoProfilesOnOneMacReachesTheOther() async throws {
        let studio = try await library("Studio"), laptop = try await library("Laptop")
        let one = conversation("one", in: studio, daysAgo: 20, [("me", mine(71), 200)])
        let two = conversation("two", in: studio, daysAgo: 10, [("me", mine(72), 200)])
        studio.renameSpeaker("one:me", to: "Vlad", in: one)
        studio.renameSpeaker("two:me", to: "Vladimir", in: two)
        await settle(studio)
        XCTAssertEqual(studio.speakerProfiles.map(\.name), ["Vlad", "Vladimir"])
        let vlad = try XCTUnwrap(studio.speakerProfiles.first), vladimir = try XCTUnwrap(studio.speakerProfiles.last)
        XCTAssertFalse(studio.renameSpeakerProfile(vladimir.id, to: "vlad"), "Another profile has the name")
        XCTAssertEqual(studio.speakerProfile(named: " VLAD ", besides: vladimir.id)?.id, vlad.id, "So the window can offer a merge")
        await sync(studio); await sync(laptop)

        XCTAssertTrue(studio.mergeSpeakerProfile(vladimir.id, into: vlad.id))
        XCTAssertFalse(studio.mergeSpeakerProfile(vladimir.id, into: vlad.id))
        await settle(studio)
        await sync(studio); await sync(laptop)
        await settle(laptop)
        for library in [studio, laptop] {
            XCTAssertEqual(library.speakerProfiles.map(\.id), [vlad.id])
            XCTAssertEqual(library.meeting(two)?.speakerIdentity("two:me")?.profileID, vlad.id)
            XCTAssertEqual(name(library, two, "two:me"), "Vladimir", "The person's name stays")
            XCTAssertEqual(library.speakers(of: vlad.id).map(\.meeting.id), [two, one])
            XCTAssertEqual(Set(library.metadata.voiceprints(of: vlad.id).map(\.meetingID)), [one, two])
        }
        await sync(studio); await sync(laptop)
        XCTAssertEqual(studio.metadata.speakerProfiles, laptop.metadata.speakerProfiles)

        // Deleting the kept profile takes what the merged one taught too.
        studio.deleteSpeakerProfile(vlad.id)
        XCTAssertTrue(studio.speakerProfiles.isEmpty)
        XCTAssertTrue(activeVoiceprints(studio).isEmpty)
    }

    /// Not on a label that a summary already used: the summary gets the earlier name back too.
    func testNotThemPutsTheEarlierNameBackInTheSummary() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(81), 200)])
        let two = conversation("two", in: library, daysAgo: 2, [("me", mine(82), 300)])
        library.update(two) { $0.summary = MeetingSummary(overview: "Speaker 1 will send the deck.") }
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        XCTAssertEqual(library.meeting(two)?.summary?.overview, "Vlad will send the deck.")

        library.rejectSpeakerProfile("two:me", in: two)
        XCTAssertEqual(name(library, two, "two:me"), "Speaker 1")
        XCTAssertEqual(library.meeting(two)?.summary?.overview, "Speaker 1 will send the deck.")
        XCTAssertEqual(library.meeting(two)?.revisions.filter { $0.field == "summary" }.count, 2, "Both changes are in Version History")
    }

    /// Not on the microphone's own speaker, when the person named the owner it stands for: the profile
    /// keeps the voice the person named.
    func testNotThemKeepsAVoiceTheOwnerWasNamedWith() async throws {
        let library = try await library("Mac", synced: false)
        let earlier = conversation("earlier", in: library, daysAgo: 20, [("me", mine(90), 200)])
        library.renameSpeaker("earlier:me", to: "Vlad", in: earlier)
        let id = conversation("call", in: library, daysAgo: 1, [("mic", mine(91), 300)])
        library.update(id) { meeting in
            let track = meeting.speakers[0].sourceTrackID
            meeting.speakers.append(Speaker(id: "owner", name: "Me", sourceTrackID: track))
            meeting.fusionSummary = FusionSummary(sources: [], words: 100, corroboratedWords: 0, disputedWords: 0, ownerSpeakerID: "owner",
                                                  speakerMappings: [FusionSpeakerMapping(sourceSpeakerID: "call:mic", trackID: track ?? UUID(),
                                                                                         speakerID: "owner", reason: .owner, share: 0.9)])
        }
        library.renameSpeaker("owner", to: "Vlad", in: id)
        await settle(library)
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:mic")?.source, .recognized)
        XCTAssertTrue(activeVoiceprints(library).contains { $0.meetingID == id && $0.origin == .named })

        library.rejectSpeakerProfile("call:mic", in: id)
        XCTAssertTrue(activeVoiceprints(library).contains { $0.meetingID == id && $0.origin == .named }, "The voice the person named stays")
        await settle(library)
        XCTAssertTrue(activeVoiceprints(library).contains { $0.meetingID == id && $0.origin == .named })
        XCTAssertEqual(name(library, id, "owner"), "Vlad")
    }

    func testTheCoordinatorKeepsProfilesInStepAsTheLibraryChanges() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(61), 200)])
        let two = conversation("two", in: library, daysAgo: 2, [("me", mine(62), 200)])
        let coordinator = SpeakerProfileCoordinator(library: library, options: { .init() })
        coordinator.delay = .milliseconds(20)
        coordinator.start()
        defer { coordinator.stop() }
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        try await waitUntil("the other conversation's speaker to be named", state: { self.name(library, two, "two:me") ?? "" }) {
            name(library, two, "two:me") == "Vlad"
        }
        // A conversation processed later is labelled too.
        let three = conversation("three", in: library, daysAgo: 0, [("me", mine(63), 200)])
        try await waitUntil("a new conversation's speaker to be named") { name(library, three, "three:me") == "Vlad" }
        // Its voice turns out to be only in background audio (a TV, found when the Mac listened to the
        // recording later): the label comes off.
        library.update(three) { $0.backgroundPassages = $0.transcripts[0].segments }
        try await waitUntil("the label to come off a voice heard only in background audio") { name(library, three, "three:me") == "Speaker 1" }
        // Unlearning can take more than one pass; it settles, with what the voice taught forgotten.
        try await waitUntilAsync("nothing left to do") {
            await !coordinator.refresh() && !activeVoiceprints(library).contains { $0.meetingID == three }
        }
    }

    // MARK: The profile that is the person

    func testBehaviorMarkingASpeakerAsMeNamesTheOwnerOfOtherCallsUntilThePersonSaysNot() async throws {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 20, [("me", mine(70), 200)])
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        let vlad = try XCTUnwrap(library.speakerProfiles.first { $0.name == "Vlad" })
        XCTAssertNil(library.ownerProfileID)
        XCTAssertFalse(library.markSpeakerAsMe(["nobody"], in: one), "no such speaker")

        // A call fused before the choice was made, with a voice that isn't Vlad's.
        let call = conversation("call", in: library, daysAgo: 1, [("mic", SyntheticVoice.near(other, similarity: 0.95, seed: 71), 300)])
        library.update(call) { meeting in
            let track = meeting.speakers[0].sourceTrackID
            meeting.speakers.append(Speaker(id: "owner", name: "Me", sourceTrackID: track))
            meeting.fusionSummary = FusionSummary(sources: [], words: 100, corroboratedWords: 0, disputedWords: 0, ownerSpeakerID: "owner",
                                                  speakerMappings: [FusionSpeakerMapping(sourceSpeakerID: "call:mic", trackID: track ?? UUID(),
                                                                                         speakerID: "owner", reason: .owner, share: 0.9)])
        }
        await settle(library)
        XCTAssertEqual(name(library, call, "owner"), "Me")

        XCTAssertTrue(library.markSpeakerAsMe(["one:me"], in: one))
        XCTAssertEqual(library.ownerProfileID, vlad.id)
        await settle(library)
        XCTAssertEqual(name(library, call, "owner"), "Vlad", "picked up on the next pass, without fusing again")
        XCTAssertEqual(library.meeting(call)?.speakerIdentity("owner")?.profileID, vlad.id)

        // Not Vlad takes it back, and it stays back.
        library.rejectSpeakerProfile("owner", in: call)
        await settle(library)
        XCTAssertEqual(name(library, call, "owner"), "Me")

        // Clearing: no one is me, and the choice stays a choice.
        library.setOwnerProfile(nil)
        XCTAssertNil(library.ownerProfileID)
        XCTAssertNotNil(library.metadata.choice(.ownerProfile))
        // The profile deleted: no one is me either.
        library.setOwnerProfile(vlad.id)
        library.deleteSpeakerProfile(vlad.id)
        XCTAssertNil(library.ownerProfileID)
    }

    func testBehaviorTheOwnerProfileSyncsBetweenDevicesTheLaterChangeWinning() async throws {
        let a = try await library("A"), b = try await library("B")
        let id = UUID()
        a.setOwnerProfile(id, at: Date(timeIntervalSince1970: 1_000))
        await sync(a); await sync(b)
        XCTAssertEqual(b.metadata.ownerProfileSelection, id)
        b.setOwnerProfile(nil, at: Date(timeIntervalSince1970: 2_000))
        await sync(b); await sync(a)
        XCTAssertNil(a.metadata.ownerProfileSelection)
        XCTAssertNotNil(a.metadata.choice(.ownerProfile))
    }

    /// A library with Vlad (named, me not chosen yet) and Bob, and a conversation with one speaker to mark.
    private func markingLibrary() async throws -> (library: LibraryController, vlad: SpeakerProfile, bob: SpeakerProfile) {
        let library = try await library("Mac", synced: false)
        let one = conversation("one", in: library, daysAgo: 30, [("me", mine(80), 200)])
        let two = conversation("two", in: library, daysAgo: 29, [("bob", SyntheticVoice.near(other, similarity: 0.95, seed: 81), 200)])
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        library.renameSpeaker("two:bob", to: "Bob", in: two)
        await settle(library)
        return (library, try XCTUnwrap(library.speakerProfiles.first { $0.name == "Vlad" }), try XCTUnwrap(library.speakerProfiles.first { $0.name == "Bob" }))
    }

    func testBehaviorThisIsMeIsOfferedOnlyWhereItDoesSomething() async throws {
        let (library, vlad, _) = try await markingLibrary()
        let one = try XCTUnwrap(library.meetings.first { $0.title == "one" }).id
        let spare = conversation("spare", in: library, daysAgo: 5, [("x", SyntheticVoice.near(SyntheticVoice.person(5), similarity: 0.95, seed: 82), 200)])
        XCTAssertTrue(library.canMarkSpeakerAsMe(["one:me"], in: one), "a name the person gave, with a profile")
        XCTAssertFalse(library.canMarkSpeakerAsMe(["spare:x"], in: spare), "Speaker 1 with no me-profile yet")
        library.update(spare) { $0.setSpeakerIdentity(SpeakerIdentity(speakerID: "spare:x", profileID: vlad.id, source: .suggested, similarity: 0.7), for: "spare:x") }
        XCTAssertFalse(library.canMarkSpeakerAsMe(["spare:x"], in: spare), "a suggestion isn't adopted")
        XCTAssertFalse(library.markSpeakerAsMe(["spare:x"], in: spare))
        XCTAssertNil(library.ownerProfileID)

        library.setOwnerProfile(vlad.id)
        XCTAssertFalse(library.canMarkSpeakerAsMe(["one:me"], in: one), "already the person's me")
        XCTAssertTrue(library.canMarkSpeakerAsMe(["spare:x"], in: spare), "a me-profile exists: anyone can be named as it")
    }

    func testBehaviorMarkingASuggestedSpeakerConfirmsItAndKeepsTheLibrarysChoice() async throws {
        let (library, vlad, bob) = try await markingLibrary()
        library.setOwnerProfile(vlad.id)
        let id = conversation("spare", in: library, daysAgo: 5, [("x", SyntheticVoice.near(SyntheticVoice.person(5), similarity: 0.95, seed: 82), 200)])
        library.update(id) { $0.setSpeakerIdentity(SpeakerIdentity(speakerID: "spare:x", profileID: vlad.id, source: .suggested, similarity: 0.7), for: "spare:x") }
        XCTAssertTrue(library.markSpeakerAsMe(["spare:x"], in: id))
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("spare:x")?.source, .confirmed)
        XCTAssertEqual(name(library, id, "spare:x"), "Vlad")
        XCTAssertEqual(library.ownerProfileID, vlad.id)
        XCTAssertNotEqual(library.ownerProfileID, bob.id)
    }

    /// With a me-profile, "Speaker n", "Me", and a wrong Recognized/Maybe profile are all named as the person, by hand;
    /// the library's choice never changes from inside a conversation, and Bob is off what the speaker rejected.
    func testBehaviorMarkingAnyoneAsMeWithAMeProfileNamesThemAsItWithoutChangingTheChoice() async throws {
        let (library, vlad, bob) = try await markingLibrary()
        library.setOwnerProfile(vlad.id)
        let id = conversation("call", in: library, daysAgo: 1, [("a", SyntheticVoice.near(SyntheticVoice.person(6), similarity: 0.95, seed: 83), 200),
                                                                ("b", SyntheticVoice.near(other, similarity: 0.95, seed: 84), 200)])
        library.update(id) { meeting in
            meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "call:a", profileID: bob.id, source: .suggested, similarity: 0.7,
                                                       rejectedProfileIDs: [vlad.id]), for: "call:a")
        }
        // "Speaker 2" recognized as the wrong profile (Bob, by voice).
        await settle(library)
        XCTAssertEqual(name(library, id, "call:b"), "Bob")
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:b")?.source, .recognized)

        for speaker in ["call:a", "call:b"] {
            XCTAssertTrue(library.canMarkSpeakerAsMe([speaker], in: id))
            XCTAssertTrue(library.markSpeakerAsMe([speaker], in: id))
            XCTAssertEqual(name(library, id, speaker), "Vlad")
            XCTAssertFalse(library.meeting(id)?.speakerIdentity(speaker)?.rejectedProfileIDs?.contains(vlad.id) ?? false)
        }
        await settle(library)
        XCTAssertEqual(library.ownerProfileID, vlad.id)
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:b")?.profileID, vlad.id)
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:b")?.source, .named)
        XCTAssertFalse(library.canMarkSpeakerAsMe(["call:b"], in: id), "now the person's me")
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// One action, as a menu or a button makes it: its own undo group.
    private func grouped(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    func testBehaviorThisIsMeFromAConversationCanBeUndoneAndRedone() async throws {
        let library = try await library("Mac", synced: false)
        let id = conversation("quiet", in: library, daysAgo: 1, [("me", mine(87), 5)])
        library.renameSpeaker("quiet:me", to: "Vlad", in: id)
        let undo = undoManager()
        grouped(undo) { XCTAssertTrue(library.markSpeakerAsMe(["quiet:me"], in: id, undoManager: undo)) }
        XCTAssertEqual(library.metadata.ownerProfileSelection, SpeakerProfile.id(forName: "Vlad"))
        XCTAssertEqual(undo.undoActionName, "This Is Me")
        undo.undo()
        XCTAssertNil(library.metadata.ownerProfileSelection, "the choice it made is taken back")
        XCTAssertEqual(name(library, id, "quiet:me"), "Vlad", "the name the person gave stays")
        undo.redo()
        XCTAssertEqual(library.metadata.ownerProfileSelection, SpeakerProfile.id(forName: "Vlad"))
    }

    func testBehaviorThisIsMeNamingAnotherSpeakerAsMeUndoesToTheNameItHad() async throws {
        let (library, vlad, _) = try await markingLibrary()
        library.setOwnerProfile(vlad.id)
        let id = conversation("call", in: library, daysAgo: 1, [("a", SyntheticVoice.near(SyntheticVoice.person(6), similarity: 0.95, seed: 83), 200)])
        let before = name(library, id, "call:a")
        let undo = undoManager()
        grouped(undo) { XCTAssertTrue(library.markSpeakerAsMe(["call:a"], in: id, undoManager: undo)) }
        XCTAssertEqual(name(library, id, "call:a"), "Vlad")
        undo.undo()
        XCTAssertEqual(name(library, id, "call:a"), before)
        XCTAssertEqual(library.ownerProfileID, vlad.id)
    }

    func testBehaviorReplacingMeFromSpeakerProfilesSaysSoAndUndoPutsTheEarlierOneBack() async throws {
        let (library, vlad, bob) = try await markingLibrary()
        library.setOwnerProfile(vlad.id)
        XCTAssertEqual(library.ownerProfileName, "Vlad")
        XCTAssertEqual(library.speakerProfilesSummary, "2 profiles · Me: Vlad")
        let undo = undoManager()
        grouped(undo) { library.setOwnerProfile(bob.id, actionName: SpeakerProfileWords.thisIsMe, undoManager: undo) }
        XCTAssertEqual(library.ownerProfileID, bob.id)
        XCTAssertEqual(undo.undoActionName, "This Is Me")
        undo.undo()
        XCTAssertEqual(library.ownerProfileID, vlad.id)
        undo.redo()
        XCTAssertEqual(library.ownerProfileID, bob.id)
        library.setOwnerProfile(nil)
        XCTAssertEqual(library.speakerProfilesSummary, "2 profiles", "no me, nothing added")
    }

    func testBehaviorMarkingARecognizedSpeakerAdoptsItsProfileAndConfirmsIt() async throws {
        let (library, vlad, _) = try await markingLibrary()
        let id = conversation("call", in: library, daysAgo: 1, [("me", mine(85), 200)])
        await settle(library)
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:me")?.source, .recognized)
        XCTAssertTrue(library.markSpeakerAsMe(["call:me"], in: id))
        XCTAssertEqual(library.ownerProfileID, vlad.id)
        XCTAssertEqual(library.meeting(id)?.speakerIdentity("call:me")?.source, .confirmed, "keeps its label")
    }

    func testBehaviorMarkingANamedSpeakerWithoutAProfileMarksTheProfileItsNameStarts() async throws {
        let library = try await library("Mac", synced: false)
        let id = conversation("quiet", in: library, daysAgo: 1, [("me", mine(86), 5)])
        XCTAssertFalse(library.canMarkSpeakerAsMe(["quiet:me"], in: id), "Speaker 1")
        library.renameSpeaker("quiet:me", to: "Vlad", in: id)
        XCTAssertTrue(library.canMarkSpeakerAsMe(["quiet:me"], in: id))
        XCTAssertTrue(library.markSpeakerAsMe(["quiet:me"], in: id))
        XCTAssertEqual(library.metadata.ownerProfileSelection, SpeakerProfile.id(forName: "Vlad"))
        XCTAssertNil(library.ownerProfileID, "no profile yet")
        // A deleted profile's ID is never marked.
        library.setOwnerProfile(nil)
        let (other, vlad, _) = try await markingLibrary()
        other.deleteSpeakerProfile(vlad.id)
        let one = try XCTUnwrap(other.meetings.first { $0.title == "one" }).id
        XCTAssertFalse(other.canMarkSpeakerAsMe(["one:me"], in: one))
        XCTAssertNil(other.ownerProfileID)
    }

    func testBehaviorTheCoordinatorSeesAChoiceThatArrivesBySync() async throws {
        let a = try await library("A"), b = try await library("B")
        let options = SpeakerProfileOptions()
        let before = SpeakerProfileCoordinator.inputs(b, options: options, skipping: [])
        a.setOwnerProfile(UUID(), at: Date(timeIntervalSince1970: 1_000))
        await sync(a); await sync(b)
        XCTAssertNotNil(b.metadata.ownerProfileSelection)
        XCTAssertNotEqual(SpeakerProfileCoordinator.inputs(b, options: options, skipping: []), before, "a pass is due")
    }
}
