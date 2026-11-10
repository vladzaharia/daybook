import AppKit
import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import Daybook

/// The inspector sits in a split view with the page. Moving between a conversation and a device
/// page keeps that split view's items, so an inspector animation still running (as at launch)
/// never finishes on an item that was taken out, which AppKit answers with an exception.
@MainActor
final class LibraryInspectorTests: XCTestCase {
    func testSwitchingPagesKeepsTheInspectorsSplitItems() async throws {
        let root = makeTemporaryFolder("DaybookInspector")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        defaults.set(true, forKey: "isInspectorPresented")
        let id = state.newMeeting(title: "Vendor walkthrough")
        state.window.openID = id

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(state: state).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1400, height: 860))
        defer { window.close() }
        try await settle()
        let split = try XCTUnwrap(inspectorSplit(in: window.contentView), "The inspector's split view")
        let items = split.splitViewItems.map(ObjectIdentifier.init)

        // The page changes while the inspector collapses and expands again, as a device page opening at launch does.
        for place in [LibraryPlace.device("demo-phone"), .section(.all), .device("demo-phone"), .section(.all)] {
            state.window.place = place
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(split.splitViewItems.map(ObjectIdentifier.init), items, "Showing \(place) keeps the split view's items")
        }
        try await settle()
        XCTAssertEqual(split.splitViewItems.map(ObjectIdentifier.init), items)
        let inspector = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .inspector })
        XCTAssertNotNil(inspector.viewController.view.superview, "The inspector is still in the window")
    }

    /// Regression: the inspector said "Waiting for audio from Soundcore Work." under the page's line without the
    /// period. A recording to come reads as the page's status does, and no line ends in a period.
    func testBehaviorARecordingToComeReadsAsThePageSaysIt() {
        let start = Date().addingTimeInterval(-600)
        var link = CompanionRecording(deviceID: "work", deviceKind: SoundcoreWorkIntegration.id, deviceName: "Soundcore Work",
                                      macStartedAt: start, state: .recording, startedByDaybook: true)
        XCTAssertEqual(SourceHooks.companionLine(link, recordingNow: true), "Also recording on Soundcore Work")
        link.macEndedAt = start.addingTimeInterval(300)
        link.state = .stopped
        let waiting = SourceHooks.companionLine(link, recordingNow: false)
        XCTAssertEqual(waiting, ProcessingStatus.awaitingDetail([SourceHooks.awaited(link)]))
        XCTAssertEqual(waiting, "Waiting for audio from Soundcore Work")
        var meeting = Meeting(title: "Call")
        meeting.companions = [link]
        XCTAssertEqual(meeting.awaitedRecordings(), [SourceHooks.awaited(link)], "the inspector shows it while the page does")
    }

    /// Regression: while this Mac recorded another conversation, a recording's Play looked available and did nothing.
    func testBehaviorPlayIsDimmedWhileThisMacRecordsAnotherConversation() async throws {
        let state = AppState(libraryURL: makeTemporaryFolder("DaybookInspectorPlay"), defaults: makeTestDefaults())
        await state.initialize()
        let id = state.newMeeting(title: "Vendor walkthrough")
        var meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        meeting.tracks = [RecordingTrack(source: .imported, relativePath: "Originals/a.m4a", fileName: "a.m4a")]
        func play() -> ConversationAction.Availability? {
            ConversationActions.track(meeting.tracks[0], in: meeting, context: MeetingInspector.context(state, meeting))
                .flatMap(\.actions).first { $0.id == .play }?.availability
        }
        XCTAssertEqual(play(), .available)
        state.recordingID = UUID()
        defer { state.recordingID = nil }
        XCTAssertFalse(MeetingInspector.context(state, meeting).isRecording, "another conversation is recording")
        XCTAssertEqual(play(), .unavailable("Recording now"), "dimmed, with its reason, as the Mac won't play it")
    }

    /// Regression: taking a recording out of a conversation the person paused started it again, summary and all.
    /// It stays paused until Resume, and a recording moved out of it waits in its new conversation; once resumed,
    /// a change writes the summary again.
    func testBehaviorTakingARecordingOutOfAPausedConversationLeavesItPaused() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let id = try await rig.macConversation("Weekly sync", at: Date().addingTimeInterval(-600), seconds: 0.5,
                                               audio: try rig.audio("weekly-mic.wav", frequency: 300))
        let installed = state.installedModels
        state.installedModels = []
        try await state.importFiles([try rig.audio("weekly-call.wav", frequency: 520)], source: .imported, attachTo: id)
        state.installedModels = installed
        state.processor.queue.awaitingModels.remove(id)
        let tracks = try XCTUnwrap(rig.meeting(id)?.tracks)
        XCTAssertEqual(tracks.count, 2)
        state.update(id) { meeting in
            meeting.transcripts = tracks.map { track in
                TrackTranscript(trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0, end: 0.5, text: "Words from \(track.fileName).")])
            }
            meeting.summary = MeetingSummary(overview: "They met.")
            meeting.status = .ready
        }
        await state.library.realign(id)
        state.processor.queue.paused = [id]
        var heard: [UUID] = []
        func changed(_ source: UUID? = nil) -> @MainActor (UUID, ProcessingRequest.Mode) -> Void {
            let processAgain = MeetingInspector.processAgain(state, source: source)
            return { changed, mode in heard.append(changed); processAgain(changed, mode) }
        }

        let call = try XCTUnwrap(tracks.first { $0.source == .imported }), mic = try XCTUnwrap(tracks.first { $0.source == .microphone })
        XCTAssertTrue(state.library.removeRecording(call.id, from: id, undoManager: nil, changed: changed()))
        try await waitUntil("the change to be heard") { heard == [id] }
        XCTAssertTrue(state.processor.queue.paused.contains(id), "still paused")
        XCTAssertFalse(state.processor.queue.queuedIDs.contains(id))
        XCTAssertNil(state.processor.queue.runningID)

        let moved = try await state.library.moveRecordingToNewConversation(mic.id, from: id, audio: { track in
            try await state.library.audioURL(for: track, in: id)
        }, undoManager: nil, changed: changed(id))
        XCTAssertEqual(heard.last, moved, "its own conversation would be summarized where the paused one was")
        XCTAssertFalse(state.processor.queue.queuedIDs.contains(moved), "and waits to be asked")
        XCTAssertNil(state.processor.queue.runningID)
        XCTAssertTrue(rig.inference.summarized.isEmpty)

        // Resumed, a change writes the summary again.
        state.processor.queue.paused = []
        XCTAssertTrue(state.library.putBackRecording(call.id, in: id, undoManager: nil, changed: changed()))
        try await waitUntil("the summary to be written again") { rig.inference.summarized.count == 1 }
        try await rig.processed(id)
    }

    /// A device's page has no inspector. Tags… and the byline's people there open the conversation it shows in the
    /// library, with the inspector beside it; with no conversation on the page they change nothing, so the inspector
    /// doesn't open unasked on the next conversation.
    func testBehaviorAskingForTheInspectorOnADevicePageOpensItsConversation() async throws {
        let root = makeTemporaryFolder("DaybookInspectorAsk")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        defaults.set(false, forKey: "isInspectorPresented")
        let id = state.newMeeting(title: "Imported from the recorder")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(state: state).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1400, height: 860))
        defer { window.close() }
        try await settle()

        state.window.place = .device("demo-phone")
        try await settle()
        state.showInspector()
        try await settle()
        XCTAssertEqual(state.window.place, .device("demo-phone"), "nothing to open")
        XCTAssertFalse(defaults.bool(forKey: "isInspectorPresented"), "not stored for later")

        // The page shows an imported recording's conversation.
        state.deviceConversationID = id
        try await settle()
        state.showInspector()
        try await settle()
        XCTAssertEqual(state.window.place, .section(.all))
        XCTAssertEqual(state.window.openID, id)
        XCTAssertTrue(defaults.bool(forKey: "isInspectorPresented"))
    }

    /// With the inspector asked for and the window too narrow for it (it waits), the sidebar still steps aside below
    /// 1000 pt, in the window's split view and not only in the binding, and stays aside as the window comes forward.
    func testBehaviorANarrowWindowWithTheInspectorAskedForStillPutsTheSidebarAside() async throws {
        let root = makeTemporaryFolder("DaybookInspectorNarrow")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        defaults.set(true, forKey: "isInspectorPresented")
        state.window.openID = state.newMeeting(title: "Weekly product sync with the design and research teams")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: LibraryView(state: state).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 720, height: 480))
        defer { window.close() }
        try await settle()
        let sidebar = try XCTUnwrap(ColumnFit.sidebarItem(in: window.contentView), "The window's sidebar")
        XCTAssertTrue(sidebar.isCollapsed, "the sidebar steps aside")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await settle()
        XCTAssertTrue(sidebar.isCollapsed, "still aside once the window comes forward")
    }

    /// Lets SwiftUI update and its animations run.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }

    /// The split view controller that holds the inspector, found through the window's views.
    private func inspectorSplit(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = (view as? NSSplitView)?.delegate as? NSSplitViewController,
           split.splitViewItems.contains(where: { $0.behavior == .inspector }) { return split }
        for subview in view.subviews { if let found = inspectorSplit(in: subview) { return found } }
        return nil
    }
}
