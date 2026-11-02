import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// Opening Daybook somewhere from outside it: a notification's tap goes where the notification says (the
/// recorder's devices' notifications too), Open Conversation and New Note go through the same way, and
/// Spotlight lists every conversation but Personal ones. Siri says what a recording command did. Temporary
/// libraries; nothing reaches the notification center or Spotlight.
@MainActor
final class AppDestinationTests: XCTestCase {
    private func makeModel(rig: RecorderRig? = nil) throws -> PhoneAppModel {
        let rig = rig ?? RecorderRig()
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             environment: try .test(self))
    }

    // MARK: Notifications

    func testBehaviorANotificationCarriesWhereItOpensAndTheDelegateReadsItBack() {
        let id = UUID()
        for destination: AppDestination in [.conversation(id), .library, .device("soundcore-1"), .recording, .newNote] {
            XCTAssertEqual(AppDestination(userInfo: destination.userInfo), destination)
        }
        // A recorder's notification, as DaybookDevices writes it.
        XCTAssertEqual(AppDestination(userInfo: ["daybook.place": "device", "daybook.deviceID": "soundcore-1"]), .device("soundcore-1"))
        XCTAssertEqual(AppDestination(userInfo: ["daybook.place": "conversation", "daybook.conversationID": id.uuidString]), .conversation(id))
        XCTAssertNil(AppDestination(userInfo: [:]), "one that says nowhere just opens Daybook")
        XCTAssertNil(AppDestination(userInfo: ["daybook.place": "conversation", "daybook.conversationID": "not an ID"]))
        XCTAssertEqual(PhoneNotices.Notice(id: "a", title: "t", body: "b", destination: .recording).destination.userInfo["daybook.place"], "recording")
    }

    func testBehaviorOpeningAConversationGoesToItsPageAndUncoversIt() async throws {
        let model = try makeModel()
        try await model.library.reload()
        let id = model.library.controller.newMeeting(title: "Design review")
        let session = ReadingSession()
        session.sheet = .history(UUID())
        session.isSelecting = true

        model.open(.conversation(id))
        let request = try XCTUnwrap(model.destination)
        XCTAssertTrue(DestinationRouter.go(to: request.destination, in: session, library: model.library.controller))
        model.reached(request)
        XCTAssertEqual(session.openID, id)
        XCTAssertTrue(session.reading)
        XCTAssertNil(session.sheet, "what covered it gives way")
        XCTAssertFalse(session.isSelecting)
        XCTAssertNil(model.destination, "gone there")

        // Asked again for the same place: a new request, so it goes again.
        model.open(.conversation(id))
        XCTAssertNotEqual(model.destination, request)
    }

    func testBehaviorAConversationThatsGoneOpensTheLibraryAndARecordersPageIsTheSheets() async throws {
        let model = try makeModel()
        try await model.library.reload()
        let session = ReadingSession()
        session.open(model.library.controller.newMeeting(title: "Open now"))
        session.place = .trash

        XCTAssertTrue(DestinationRouter.go(to: .conversation(UUID()), in: session, library: model.library.controller))
        XCTAssertFalse(session.reading)
        XCTAssertEqual(session.place, .library(.section(.all)))

        session.open(model.library.conversations[0].id)
        XCTAssertFalse(DestinationRouter.go(to: .device("soundcore-1"), in: session, library: model.library.controller),
                       "left for the status sheet")
        XCTAssertFalse(session.reading, "the conversation steps aside so the sheet is there")
    }

    func testBehaviorNewNoteOpensANoteAndWaitsForTheLibrary() async throws {
        let model = try makeModel()
        let session = ReadingSession()
        XCTAssertFalse(DestinationRouter.go(to: .newNote, in: session, library: model.library.controller), "the library is still loading")
        try await model.library.reload()
        XCTAssertTrue(DestinationRouter.go(to: .newNote, in: session, library: model.library.controller))
        let note = try XCTUnwrap(session.openID.flatMap(model.library.controller.meeting))
        XCTAssertTrue(note.title.hasPrefix("Note at "))
        XCTAssertEqual(session.focusNotesFor, note.id)
    }

    // MARK: Spotlight

    func testBehaviorSpotlightListsEveryConversationButPersonalOnesAndKeepsInStep() async throws {
        var work = Meeting(title: "Pricing review", date: Date(timeIntervalSince1970: 1_800_000_000))
        work.placement = .work
        var personal = Meeting(title: "Therapy", date: Date(timeIntervalSince1970: 1_800_000_100))
        personal.placement = .personal
        let unknown = Meeting(title: "Conversation at 10:15 AM", date: Date(timeIntervalSince1970: 1_800_000_200))
        XCTAssertEqual(ConversationIndex.entries([work, personal, unknown]).map(\.title), ["Conversation at 10:15 AM", "Pricing review"])

        var indexed: [[String]] = [], removed: [[UUID]] = []
        let index = ConversationIndex(indexer: ConversationIndex.Indexer(isActive: true, index: { indexed.append($0.map(\.title)) },
                                                                         remove: { removed.append($0) }))
        index.update(ConversationIndex.entries([work, unknown]))
        await index.settle()
        XCTAssertEqual(indexed, [["Conversation at 10:15 AM", "Pricing review"]], "newest first")

        // Renamed, and the other moved to Personal: one listed again, one taken out.
        var renamed = unknown
        renamed.title = "Hiring sync"
        var nowPersonal = work
        nowPersonal.placement = .personal
        index.update(ConversationIndex.entries([nowPersonal, renamed]))
        await index.settle()
        XCTAssertEqual(indexed.last, ["Hiring sync"])
        XCTAssertEqual(removed, [[work.id]])

        index.update(ConversationIndex.entries([nowPersonal, renamed]))
        await index.settle()
        XCTAssertEqual(indexed.count, 2, "nothing changed, nothing sent")
    }

    func testBehaviorAConversationIsAnEntityByItsTitleAndDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entity = ConversationEntity(ConversationIndex.Entry(id: UUID(), title: "Design review", date: date))
        XCTAssertEqual(entity.title, "Design review")
        XCTAssertEqual(entity.date, date)
    }

    // MARK: Siri and Shortcuts

    func testBehaviorSiriSaysWhatEachCommandDid() async throws {
        XCTAssertEqual(RecordingDialogs.recording, "Recording.")
        XCTAssertEqual(RecordingDialogs.bookmarked(at: 723), "Bookmarked at 12:03.")
        XCTAssertEqual(RecordingStopResult.saved.sentence, "Saved to Daybook.")

        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(2)
        try await model.stopRecording()
        XCTAssertEqual(model.lastStopResult, .saved)
    }

    func testBehaviorAStartFromTheBackgroundContinuesInFrontOnlyWhenTheMicrophoneWasNeverAsked() throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        XCTAssertFalse(model.microphoneNeedsAsking, "allowed: it starts where it is")
        rig.session.permissionAsked = false
        XCTAssertTrue(model.microphoneNeedsAsking, "never asked: iOS asks only with Daybook in front")
        rig.session.permissionAsked = true
        rig.session.permission = false
        XCTAssertFalse(model.microphoneNeedsAsking, "refused: the fix is Settings, and it says so")
    }

    func testBehaviorTheMicrophoneIsAskedForWhenNeverAskedAndAStartThenRecords() async throws {
        let rig = RecorderRig()
        rig.session.permissionAsked = false
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        XCTAssertEqual(rig.session.microphonePermission, .allowed)
        XCTAssertTrue(model.recorder.isActive)
        try await model.stopRecording()
    }
}
