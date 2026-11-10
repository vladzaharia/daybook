import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// The library's half of a conversation's actions, carried out once for both apps: what changes the library can be
/// undone, named as the menu item was from one conversation or several, and the rest change nothing themselves,
/// handing their app what to show, process, or copy. Each test opens its own library in a temporary folder.
@MainActor
final class ConversationActionPerformerTests: XCTestCase {
    /// What the performer asked of its app.
    private final class Host {
        var processed: [UUID] = []
        var modes: [ProcessingRequest.Mode] = []
        var shown: [ConversationActionPerformer.Request] = []
        var copied: [String] = []
        var confirmed: [String] = []
        var platform: [[UUID]] = []

        var asked: Bool { !processed.isEmpty || !shown.isEmpty || !copied.isEmpty }
    }

    private func makeLibrary() async throws -> LibraryController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationActionPerformerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        addTeardownBlock {
            await library.flush()
            try? FileManager.default.removeItem(at: root)
        }
        return library
    }

    /// A conversation every action applies to: a recording, its transcript, a summary, and a change in its history.
    private func conversation(_ title: String, in library: LibraryController, transcribed: Bool = true) -> UUID {
        let id = library.newMeeting(title: title)
        library.update(id) { meeting in
            let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60)
            meeting.tracks = [track]
            if transcribed {
                let segment = TranscriptSegment(trackID: track.id, start: 0, end: 4, text: "Ship it")
                meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [segment])]
                meeting.unifiedTranscript = [segment]
            }
            meeting.summary = MeetingSummary(overview: "Shipping on Friday.")
            meeting.revisions = [MeetingRevision(field: "notes", oldValue: "", newValue: "Hi")]
        }
        return id
    }

    private func performer(_ library: LibraryController, undoManager: UndoManager?, host: Host) -> ConversationActionPerformer {
        ConversationActionPerformer(library: library, undoManager: undoManager,
                                    process: { host.processed.append($0); host.modes.append($1) },
                                    show: { host.shown.append($0) },
                                    copy: { host.copied.append($0) },
                                    confirm: { host.confirmed.append($0.words) })
    }

    /// An undo manager that groups by hand, as a menu item's event would.
    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// Every action the menus list for these conversations, alone and together, on both apps, at any depth.
    private func listed(_ ids: [UUID], in library: LibraryController) -> [ConversationAction.ID] {
        var found: [ConversationAction.ID] = []
        func walk(_ actions: [ConversationAction]) {
            for action in actions {
                if !found.contains(action.id) { found.append(action.id) }
                walk(action.children)
            }
        }
        for platform in [ConversationAction.Platform.mac, .iPhone] {
            let context = ConversationActions.Context(platform: platform, canTakePhoto: true)
            for meeting in library.meetings where ids.contains(meeting.id) {
                ConversationActions.actions(for: meeting, context: context).forEach { walk($0.actions) }
            }
            ConversationActions.batch(ids, in: library.meetings, context: context).forEach { walk($0.actions) }
        }
        return found
    }

    /// What filing and undoing it touch.
    private struct Filing: Equatable {
        var placement: LibraryPlacement?
        var folderID: UUID?
        var tags: [String]?
    }

    private func filing(_ meetings: [Meeting]) -> [UUID: Filing] {
        Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, Filing(placement: $0.placement, folderID: $0.folderID, tags: $0.tags)) })
    }

    // MARK: Undo

    func testBehaviorEveryActionItCarriesOutIsUndoneOrLeavesTheLibraryAsItWas() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library), b = conversation("Roadmap review", in: library)
        // Work as well as Personal: the menus offer Move to Work only for one that's in Personal.
        var owned = listed([a, b], in: library).filter(ConversationActionPerformer.carriesOut)
        owned.append(.moveTo(.work))
        let expected: Set<ConversationAction.ID> = [.copySummary, .process(.summaryOnly), .process(.speakerRefresh),
                                                    .process(.fullRetranscription), .versionHistory, .moveToFolder, .tags,
                                                    .moveTo(.personal), .moveTo(.work), .moveToTrash]
        XCTAssertTrue(Set(owned).isSuperset(of: expected), "every menu's library actions are the performer's")

        var changing: Set<ConversationAction.ID> = []
        for id in owned {
            for selection in [[a], [a, b]] {
                let undo = undoManager(), host = Host()
                let before = library.meetings
                undo.beginUndoGrouping()
                performer(library, undoManager: undo, host: host).perform(id, on: selection) { host.platform.append($0.map(\.id)) }
                undo.endUndoGrouping()
                XCTAssertTrue(host.platform.isEmpty, "\(id) is the library's, not the app's")
                if library.meetings != before {
                    changing.insert(id)
                    XCTAssertTrue(undo.canUndo, "\(id) on \(selection.count) changed the library, so Edit › Undo takes it back")
                    undo.undo()
                    XCTAssertEqual(filing(library.meetings), filing(before), "\(id) on \(selection.count): undone in one step")
                } else {
                    XCTAssertTrue(host.asked, "\(id) changed nothing itself, so it asked the app for what it needs")
                }
            }
        }
        XCTAssertEqual(changing, [.moveTo(.personal), .moveTo(.work)], "only filing into Work or Personal writes at once")
    }

    func testBehaviorMoveToPersonalIsUndoneByOneNameFromOneConversationOrASelection() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library), b = conversation("Roadmap review", in: library)
        for selection in [[a], [a, b]] {
            let undo = undoManager()
            undo.beginUndoGrouping()
            performer(library, undoManager: undo, host: Host()).perform(.moveTo(.personal), on: selection) { _ in
                XCTFail("the library's")
            }
            undo.endUndoGrouping()
            XCTAssertEqual(undo.undoActionName, "Move to Personal", "the same from More, a row, or a selection of \(selection.count)")
            XCTAssertTrue(selection.allSatisfy { library.meeting($0)?.placement == .personal })
            undo.undo()
            XCTAssertTrue(selection.allSatisfy { library.meeting($0)?.placement == nil }, "one step puts them all back")
            XCTAssertFalse(undo.canUndo)
        }
        // Without an undo manager it's the plain edit.
        performer(library, undoManager: nil, host: Host()).perform(.moveTo(.work), on: [b]) { _ in }
        XCTAssertEqual(library.meeting(b)?.placement, .work)
    }

    // MARK: What the app is asked for

    func testBehaviorCopySummaryCopiesItsMarkdownThenSaysCopiedWhereverItCameFrom() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library)
        let host = Host()
        performer(library, undoManager: undoManager(), host: host).perform(.copySummary, on: [a]) { _ in }
        let meeting = try XCTUnwrap(library.meeting(a))
        XCTAssertEqual(host.copied, [MeetingExport.summaryMarkdown(meeting)])
        XCTAssertEqual(host.confirmed, ["Copied"], "a row's Copy Summary says so too, as More's does")
    }

    func testBehaviorRequestsCarryTheConversationsTheyreFor() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library), b = conversation("Roadmap review", in: library)
        let host = Host()
        let performer = performer(library, undoManager: undoManager(), host: host)
        for id in [ConversationAction.ID.tags, .moveToFolder, .moveToTrash, .versionHistory] {
            performer.perform(id, on: [a, b, UUID()]) { _ in XCTFail("the library's") }
        }
        // In the library's order, newest first.
        let both = library.meetings.map(\.id).filter { [a, b].contains($0) }
        XCTAssertEqual(Set(both), [a, b])
        XCTAssertEqual(host.shown, [.tags(both), .moveToFolder(both), .moveToTrash(both), .versionHistory(both[0])],
                       "only conversations in the library; Version History is one conversation's")
        performer.perform(.moveToTrash, on: [UUID()]) { _ in XCTFail("nothing to act on") }
        XCTAssertEqual(host.shown.count, 4, "none in the library: nothing to ask")
    }

    func testBehaviorSummarizeAgainPassesOverThoseWithNothingToSummarize() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library)
        let untranscribed = conversation("Voice memo", in: library, transcribed: false)
        let host = Host()
        let performer = performer(library, undoManager: nil, host: host)
        performer.perform(.process(.summaryOnly), on: [a, untranscribed]) { _ in XCTFail("the library's") }
        XCTAssertEqual(host.processed, [a])
        performer.perform(.process(.fullRetranscription), on: [a, untranscribed]) { _ in XCTFail("the library's") }
        XCTAssertEqual(Set(host.processed.dropFirst()), [a, untranscribed])
        XCTAssertEqual(host.modes, [.summaryOnly, .fullRetranscription, .fullRetranscription])
    }

    func testBehaviorTheAppsOwnActionsGoToItWithTheConversations() async throws {
        let library = try await makeLibrary()
        let a = conversation("Weekly product sync", in: library), b = conversation("Roadmap review", in: library)
        let theirs = listed([a, b], in: library).filter { !ConversationActionPerformer.carriesOut($0) }
        let expected: Set<ConversationAction.ID> = [.share, .shareMarkdown, .shareJSON, .shareAudio, .export, .exportMarkdown,
                                                    .exportJSON, .showFloatingNotes, .takePhoto, .addPhotos, .addRecording,
                                                    .addRecordingFromFile, .reprocess, .rename, .showInFinder]
        XCTAssertEqual(Set(theirs), expected)
        for id in theirs {
            let host = Host()
            let before = library.meetings
            performer(library, undoManager: undoManager(), host: host).perform(id, on: [b, a]) { host.platform.append($0.map(\.id)) }
            XCTAssertEqual(host.platform.count, 1, "\(id) is the app's")
            XCTAssertEqual(Set(host.platform.first ?? []), [a, b])
            XCTAssertFalse(host.asked)
            XCTAssertEqual(library.meetings, before)
        }
    }
}
