import DaybookCore
import SwiftUI
import XCTest
@testable import DaybookPhone

/// Posture, the notes timeline, and the intents' routing.
@MainActor
final class ShellTests: XCTestCase {
    func testPostureLaunchArgumentForcesTheFold() {
        let open = DevicePosture(arguments: ["app", "--posture", "open"])
        XCTAssertEqual(open.fold, .open)
        XCTAssertEqual(open.angle, 180)
        XCTAssertTrue(open.isForced)
        open.update(fold: .closed, angle: 0)
        XCTAssertEqual(open.fold, .open, "a forced posture ignores the hinge")

        let tent = DevicePosture(arguments: ["app", "--posture", "partial:95"])
        XCTAssertEqual(tent.fold, .partiallyOpen)
        XCTAssertEqual(tent.angle, 95)

        XCTAssertNil(DevicePosture.override(in: ["app", "--posture", "sideways"]))
        XCTAssertEqual(DevicePosture(arguments: ["app"]).fold, .none)
    }

    func testPostureSurvivesTheMoveBetweenDisplays() {
        let posture = DevicePosture()
        posture.hingeUnavailable()
        XCTAssertEqual(posture.fold, .none, "an iPhone without a hinge")
        posture.update(fold: .open, angle: 180)
        posture.hingeUnavailable()
        XCTAssertEqual(posture.fold, .open, "a momentary gap while the app moves to the other display")
        XCTAssertEqual(posture.angle, 180)
    }

    func testPostureChoosesTheLayout() {
        let posture = DevicePosture()
        XCTAssertEqual(posture.layout(isRecording: false, horizontalSizeClass: .compact), .pocket)
        XCTAssertEqual(posture.layout(isRecording: false, horizontalSizeClass: .regular), .notebook)
        posture.update(fold: .closed, angle: 0)
        XCTAssertEqual(posture.layout(isRecording: true, horizontalSizeClass: .regular), .pocket)
        posture.update(fold: .open, angle: 180)
        XCTAssertEqual(posture.layout(isRecording: true, horizontalSizeClass: .compact), .notebook)
        posture.update(fold: .partiallyOpen, angle: 100)
        XCTAssertEqual(posture.layout(isRecording: true, horizontalSizeClass: .regular), .table)
        XCTAssertEqual(posture.layout(isRecording: false, horizontalSizeClass: .regular), .notebook)
        XCTAssertEqual(posture.summary, "Partly open · 100°")
    }

    func testBookmarksSitBetweenTheParagraphsAroundThem() {
        let anchors = [TimedNote(time: 2, text: "One"), TimedNote(time: 10, text: "Two"), TimedNote(time: nil, text: "Three")]
        let items = NotesTimeline.items(notes: "One\nTwo\n\nThree", anchors: anchors,
                                        bookmarks: [Highlight(time: 12, text: ""), Highlight(time: 4, text: "")])
        XCTAssertEqual(items.map(\.time), [2, 4, 10, nil, 12])
        XCTAssertEqual(items.map(\.isBookmark), [false, true, false, false, true])
    }

    func testPhotosSitBetweenTheParagraphsAroundThemWithBookmarks() {
        let anchors = [TimedNote(time: 2, text: "One"), TimedNote(time: 10, text: "Two")]
        let photo = CapturePhoto(fileName: "photo-a.heic", capturedAt: Date(), time: 6)
        let items = NotesTimeline.items(notes: "One\nTwo", anchors: anchors, bookmarks: [Highlight(time: 4, text: "")], photos: [photo])
        XCTAssertEqual(items.map(\.time), [2, 4, 6, 10])
        XCTAssertEqual(items.map(\.id).dropFirst().first?.hasPrefix("b"), true)
        XCTAssertEqual(items[2].kind, .photo("photo-a.heic"))
    }

    func testIntentsRouteToTheApp() async throws {
        let previous = RecordingCommands.handler
        defer { RecordingCommands.handler = previous }
        let handler = FakeCommands()
        RecordingCommands.handler = handler

        _ = try await StartRecordingIntent().perform()
        _ = try await AddBookmarkIntent().perform()
        _ = try await StopRecordingIntent().perform()
        XCTAssertEqual(handler.calls, ["start", "bookmark", "stop"])

        var toggle = ToggleRecordingIntent()
        toggle.value = true
        _ = try await toggle.perform()
        XCTAssertEqual(handler.calls.last, "start")
        toggle.value = false
        _ = try await toggle.perform()
        XCTAssertEqual(handler.calls.last, "stop")

        RecordingCommands.handler = nil
        do {
            _ = try await StartRecordingIntent().perform()
            XCTFail("without the app there is nothing to record with")
        } catch {}
    }

    func testSharedStateRoundTripsThroughTheAppGroup() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DaybookPhoneTests-\(UUID().uuidString)"))
        var state = SharedRecordingState()
        state.phase = .recording
        state.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.bookmarkCount = 2
        state.save(to: defaults)
        XCTAssertEqual(SharedRecordingState.load(from: defaults), state)
        XCTAssertTrue(SharedRecordingState.load(from: defaults).isActive)
    }

    func testICloudContainerComesFromTheBuildAndIsReportedHonestly() async {
        XCTAssertEqual(CloudAvailability.containerIdentifier, "iCloud.local.daybook")
        let unsigned = await CloudAvailability.check(container: "$(DAYBOOK_ICLOUD_CONTAINER)")
        XCTAssertEqual(unsigned.isAvailable, false)
        let signedOut = await CloudAvailability.check(container: "iCloud.local.daybook", signedIn: { false })
        XCTAssertEqual(signedOut.message, "Sign in to iCloud to sync your library.", "as the Mac says it")
        XCTAssertTrue(signedOut.settingsCanFix)
        let noContainer = await CloudAvailability.check(container: "iCloud.local.daybook", signedIn: { true }, resolve: { _ in nil })
        XCTAssertFalse(noContainer.isAvailable)
        XCTAssertEqual(noContainer.message, "Turn on iCloud Drive for Daybook in Settings.")
        XCTAssertTrue(noContainer.settingsCanFix)
        XCTAssertFalse(unsigned.settingsCanFix, "Settings can't fix a build without iCloud")
        let ready = await CloudAvailability.check(container: "iCloud.local.daybook", signedIn: { true },
                                                  resolve: { _ in URL(fileURLWithPath: "/container", isDirectory: true) })
        XCTAssertEqual(ready, .available(URL(fileURLWithPath: "/container/Documents/Daybook", isDirectory: true)))
        XCTAssertNil(ready.message)
    }

    func testActivityLevelIsCoarse() {
        XCTAssertEqual(RecordingActivityAttributes.ContentState.levelBucket(0.05), 0)
        XCTAssertEqual(RecordingActivityAttributes.ContentState.levelBucket(0.3), 0.33)
        XCTAssertEqual(RecordingActivityAttributes.ContentState.levelBucket(0.5), 0.66)
        XCTAssertEqual(RecordingActivityAttributes.ContentState.levelBucket(0.9), 1)
    }
}

@MainActor
private final class FakeCommands: RecordingCommandHandling {
    var calls: [String] = []
    var isRecordingActive = false
    func startRecording() async throws { calls.append("start"); isRecordingActive = true }
    func stopRecording() async throws { calls.append("stop"); isRecordingActive = false }
    func resumeRecording() async throws { calls.append("resume") }
    func addBookmark() async throws -> TimeInterval { calls.append("bookmark"); return 0 }
}
