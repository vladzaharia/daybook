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
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSpeakerProfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        try? FileManager.default.removeItem(at: root)
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
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.status ?? "", file: file, line: line)
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
        let changed = await coordinator.refresh()
        XCTAssertFalse(changed, "Nothing left to do")
    }
}
