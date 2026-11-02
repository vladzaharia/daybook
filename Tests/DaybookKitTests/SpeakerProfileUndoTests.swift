import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Speaker Profiles' destructive actions can be undone on both apps: Delete Profile, Remove Voiceprint, and Forget
/// Learned Voiceprints write back what they replaced as newer records, so the profile and its voiceprints return
/// and win wherever they sync. Synthetic voices in a temporary library; no models.
@MainActor
final class SpeakerProfileUndoTests: XCTestCase {
    private var root: URL!
    private let space = "fluid-community1-embedding-df2625ac79a7ac6b"
    private let me = SyntheticVoice.person(1)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookProfileUndo-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library() async throws -> LibraryController {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        return library
    }

    @discardableResult
    private func conversation(_ title: String, in library: LibraryController, daysAgo: Double, seed: UInt64) -> UUID {
        let id = library.newMeeting(title: title, date: Date().addingTimeInterval(-daysAgo * 86_400))
        library.update(id) { meeting in
            let track = UUID()
            meeting.speakers = [Speaker(id: "\(title):me", name: "Speaker 1", sourceTrackID: track,
                                        embedding: SyntheticVoice.near(me, similarity: 0.95, seed: seed), embeddingModelID: space)]
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [
                TranscriptSegment(trackID: track, start: 0, end: 200, text: "Words", speakerID: "\(title):me"),
            ])]
        }
        return id
    }

    private func settle(_ library: LibraryController) async {
        for _ in 0..<6 where await library.reconcileSpeakerProfiles(options: .init()) {}
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

    private func active(_ library: LibraryController) -> [Voiceprint] { (library.metadata.voiceprints ?? []).compactMap(\.value) }

    func testBehaviorUndoingDeleteProfilePutsTheProfileAndItsVoiceprintsBackAsNewerRecords() async throws {
        let library = try await library()
        let one = conversation("one", in: library, daysAgo: 20, seed: 11)
        conversation("two", in: library, daysAgo: 2, seed: 12)
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        let vlad = try XCTUnwrap(library.speakerProfiles.first)
        let prints = active(library)
        XCTAssertEqual(prints.count, 2, "named in one, learned from two")
        let undo = undoManager()

        grouped(undo) { library.deleteSpeakerProfile(vlad.id, undoManager: undo, at: Date()) }
        XCTAssertTrue(library.speakerProfiles.isEmpty)
        XCTAssertTrue(active(library).isEmpty)
        XCTAssertEqual(undo.undoActionName, "Delete Profile")
        let deletedAt = try XCTUnwrap(library.metadata.speakerProfiles?.first?.modifiedAt)

        undo.undo()
        XCTAssertEqual(library.speakerProfiles.map(\.id), [vlad.id])
        XCTAssertEqual(library.speakerProfiles.first?.name, "Vlad")
        XCTAssertEqual(Set(active(library).map(\.id)), Set(prints.map(\.id)))
        let restored = try XCTUnwrap(library.metadata.speakerProfiles?.first)
        XCTAssertGreaterThan(restored.modifiedAt, deletedAt, "newer than the deletion, so it wins wherever it syncs")

        undo.redo()
        XCTAssertTrue(library.speakerProfiles.isEmpty, "redo deletes it again")
    }

    func testBehaviorUndoingARemovedVoiceprintOrForgottenLearningPutsThemBack() async throws {
        let library = try await library()
        let one = conversation("one", in: library, daysAgo: 20, seed: 21)
        let two = conversation("two", in: library, daysAgo: 2, seed: 22)
        library.renameSpeaker("one:me", to: "Vlad", in: one)
        await settle(library)
        let vlad = try XCTUnwrap(library.speakerProfiles.first)
        let learned = try XCTUnwrap(active(library).first { $0.meetingID == two })
        XCTAssertEqual(learned.origin, .recognized)
        let undo = undoManager()

        grouped(undo) { library.removeVoiceprint(learned.id, undoManager: undo) }
        XCTAssertFalse(active(library).contains { $0.id == learned.id })
        undo.undo()
        XCTAssertTrue(active(library).contains { $0.id == learned.id })

        grouped(undo) { library.forgetLearnedVoiceprints(of: vlad.id, undoManager: undo) }
        XCTAssertEqual(active(library).map(\.origin), [.named], "the name the person gave stays")
        XCTAssertEqual(undo.undoActionName, "Forget Learned Voiceprints")
        undo.undo()
        XCTAssertEqual(Set(active(library).map(\.meetingID)), [one, two])

        // Nothing changed, nothing to undo (and nothing registered outside a group, which would raise).
        let fresh = undoManager()
        library.removeVoiceprint("no-such-voiceprint", undoManager: fresh)
        XCTAssertFalse(fresh.canUndo)
    }
}
