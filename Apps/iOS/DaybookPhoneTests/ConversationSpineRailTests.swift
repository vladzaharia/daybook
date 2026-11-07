import DaybookKit
import XCTest

@testable import DaybookPhone

@MainActor
final class ConversationSpineRailTests: XCTestCase {
 private func track(
  _ name: String, duration: TimeInterval? = nil, offset: TimeInterval? = nil,
  alignment: SourceAlignment? = nil
 ) -> RecordingTrack {
  RecordingTrack(
   relativePath: "Originals/\(name).m4a", fileName: "\(name).m4a",
   duration: duration, offset: offset, alignment: alignment)
 }

 private func segment(_ end: TimeInterval) -> TranscriptSegment {
  TranscriptSegment(trackID: UUID(), start: 0, end: end, text: "")
 }

 func testExtentAndNormalizedBookmarksUseTheMeetingTimeline() throws {
  let recording = track("placed", duration: 120)
  var meeting = Meeting(
   tracks: [recording], unifiedTranscript: [segment(200)],
   alignmentReports: [.init(trackID: recording.id, method: .anchors, offset: 20, rate: 2)],
   highlights: [
    .init(time: 0), .init(time: 65), .init(trackID: recording.id, time: 15),
    .init(time: 1_000),
   ])
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting))
  XCTAssertEqual(rail.duration, 260, "a placed recording's offset and rate extend the timeline")
  XCTAssertEqual(
   rail.bookmarks, [0, 0.25, 50.0 / 260.0, 1], "source-local bookmarks are aligned; outliers clamp")
  XCTAssertNil(rail.playhead(at: 10), "no loaded player")
  let player = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: recording.id, duration: 120)
  let playing = try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: player))
  XCTAssertEqual(
   try XCTUnwrap(playing.playhead(at: 15)), rail.bookmarks[2], accuracy: 0.000_001,
   "the playhead uses the same fused offset and rate as the source bookmark")

  meeting.unifiedTranscript.append(segment(300))
  let longerTranscript = try XCTUnwrap(ConversationSpineRailData(meeting: meeting))
  XCTAssertEqual(
   longerTranscript.duration, 300, "the furthest unified passage can extend it instead")
  XCTAssertEqual(longerTranscript.bookmarks[1], 65.0 / 300.0, accuracy: 0.000_001)
 }

 func testStoredPlacementWithoutReportPlacesBookmarkAtPlayhead() throws {
  let recording = track(
   "manual", duration: 100, alignment: .init(method: .manual, offset: 20, rate: 2))
  let meeting = Meeting(
   tracks: [recording], highlights: [.init(trackID: recording.id, time: 15)])
  let player = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: recording.id, duration: 100)
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: player))
  XCTAssertEqual(rail.bookmarks.count, 1)
  let bookmark = try XCTUnwrap(rail.bookmarks.first)
  XCTAssertEqual(bookmark, 50.0 / 220.0, accuracy: 0.000_001)
  XCTAssertEqual(try XCTUnwrap(rail.playhead(at: 15)), bookmark, accuracy: 0.000_001)
 }

 func testStoredPlacementTakesPrecedenceOverStaleReportForBookmark() throws {
  let recording = track(
   "manual", duration: 100, alignment: .init(method: .manual, offset: 20, rate: 2))
  let meeting = Meeting(
   tracks: [recording],
   alignmentReports: [.init(trackID: recording.id, method: .anchors, offset: 5, rate: 1)],
   highlights: [.init(trackID: recording.id, time: 15)])
  let player = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: recording.id, duration: 100)
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: player))
  XCTAssertEqual(rail.bookmarks.count, 1)
  let bookmark = try XCTUnwrap(rail.bookmarks.first)
  XCTAssertEqual(bookmark, 50.0 / 220.0, accuracy: 0.000_001)
  XCTAssertEqual(try XCTUnwrap(rail.playhead(at: 15)), bookmark, accuracy: 0.000_001)
 }

 func testUnalignedMissingInvalidAndRemovedSourcesAreExcluded() throws {
  let reference = track("reference", duration: 100)
  let unaligned = track("unaligned", duration: 10_000, offset: 0)
  let pending = track("pending", duration: 10_000, alignment: .init(method: .pending))
  let noReport = track("no-report", duration: 10, offset: 0)
  let invalidRate = track("invalid-rate", duration: 10_000)
  let beforeZero = track("early", duration: 30)
  let sourceUnaligned = track(
   "source-unaligned", duration: 10_000, alignment: .init(method: .unaligned))
  var removed = track("removed", duration: 10_000)
  removed.removal = RecordingRemoval(removedAt: Date())
  let meeting = Meeting(
   tracks: [
    reference, unaligned, pending, noReport, invalidRate, beforeZero, sourceUnaligned, removed,
   ],
   alignmentReports: [
    .init(trackID: reference.id, method: .reference),
    .init(trackID: unaligned.id, method: .unaligned),
    .init(trackID: invalidRate.id, method: .anchors, rate: 0),
    .init(trackID: beforeZero.id, method: .anchors, offset: -40),
    .init(trackID: sourceUnaligned.id, method: .anchors),
    .init(trackID: removed.id, method: .anchors),
   ],
   highlights: [
    .init(trackID: reference.id, time: 50), .init(trackID: unaligned.id, time: 5),
    .init(trackID: pending.id, time: 5), .init(trackID: noReport.id, time: 5),
    .init(trackID: invalidRate.id, time: 5), .init(trackID: beforeZero.id, time: 5),
    .init(trackID: sourceUnaligned.id, time: 5), .init(trackID: removed.id, time: 5),
   ])
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting))
  XCTAssertEqual(rail.duration, 100)
  XCTAssertEqual(
   rail.bookmarks, [0.5, 0.05], "only placed source-local bookmarks get timeline positions")

  // Even the first track must not acquire the usual reference-at-zero fallback if fusion says unaligned.
  let firstUnaligned = Meeting(
   tracks: [unaligned], unifiedTranscript: [segment(100)],
   alignmentReports: [.init(trackID: unaligned.id, method: .unaligned)],
   highlights: [.init(trackID: unaligned.id, time: 50)])
  let player = ConversationSpineRailData.Player(
   meetingID: firstUnaligned.id, trackID: unaligned.id, duration: 10_000)
  let firstRail = try XCTUnwrap(ConversationSpineRailData(meeting: firstUnaligned, player: player))
  XCTAssertEqual(firstRail.duration, 100)
  XCTAssertTrue(firstRail.bookmarks.isEmpty)
  XCTAssertNil(firstRail.playhead(at: 50))
 }

 func testEmptyAndNonfiniteDataNeverProduceInvalidFractions() throws {
  XCTAssertNil(ConversationSpineRailData(meeting: Meeting()))
  let invalid = track("invalid", duration: .infinity, offset: 0)
  let noExtent = Meeting(
   tracks: [invalid],
   unifiedTranscript: [segment(.nan), segment(.infinity), segment(-1), segment(0)],
   highlights: [.init(time: 500)])
  XCTAssertNil(ConversationSpineRailData(meeting: noExtent), "bookmarks cannot invent a duration")

  let overflowing = track("overflow", duration: .greatestFiniteMagnitude)
  let meeting = Meeting(
   tracks: [overflowing], unifiedTranscript: [segment(10), segment(.infinity)],
   alignmentReports: [.init(trackID: overflowing.id, method: .anchors, rate: 2)],
   highlights: [
    .init(time: .nan), .init(time: .infinity), .init(time: -1),
    .init(trackID: overflowing.id, time: .greatestFiniteMagnitude),
    .init(time: 0), .init(time: 20),
   ])
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting))
  XCTAssertEqual(rail.duration, 10, "an overflowing aligned recording end is ignored")
  XCTAssertEqual(rail.bookmarks, [0, 1])
 }

 func testPlayerUsesItsPlacedTrackAndLoadedDuration() throws {
  let recording = track("placed", alignment: .init(method: .manual, offset: 20, rate: 2))
  let meeting = Meeting(
   tracks: [recording], unifiedTranscript: [segment(50)], highlights: [.init(time: 55)])
  let player = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: recording.id, duration: 100)
  let rail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: player))
  XCTAssertEqual(rail.duration, 220, "loaded audio supplies the missing recording length")
  XCTAssertEqual(rail.bookmarks, [0.25])
  XCTAssertEqual(try XCTUnwrap(rail.playhead(at: 40)), 100.0 / 220.0, accuracy: 0.000_001)
  XCTAssertEqual(rail.playhead(at: 1_000), 1, "a position past the extent clamps")
  XCTAssertNil(rail.playhead(at: -1))
  XCTAssertNil(rail.playhead(at: .nan))
  XCTAssertNil(rail.playhead(at: .infinity))
  XCTAssertNil(rail.playhead(at: .greatestFiniteMagnitude), "overflow is not a playhead")

  let otherMeeting = ConversationSpineRailData.Player(
   meetingID: UUID(), trackID: recording.id, duration: 100)
  let otherRail = try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: otherMeeting))
  XCTAssertEqual(otherRail.duration, 50, "another conversation's player doesn't change this extent")
  XCTAssertNil(otherRail.playhead(at: 40))
  let missingTrack = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: UUID(), duration: 100)
  XCTAssertNil(
   try XCTUnwrap(ConversationSpineRailData(meeting: meeting, player: missingTrack)).playhead(at: 40)
  )

  let early = track("early", duration: 100, alignment: .init(method: .manual, offset: -20))
  let earlyMeeting = Meeting(tracks: [early])
  let earlyPlayer = ConversationSpineRailData.Player(
   meetingID: earlyMeeting.id, trackID: early.id, duration: 100)
  let earlyRail = try XCTUnwrap(
   ConversationSpineRailData(meeting: earlyMeeting, player: earlyPlayer))
  let unknownLength = ConversationSpineRailData.Player(
   meetingID: meeting.id, trackID: recording.id, duration: .nan)
  let unknownLengthRail = try XCTUnwrap(
   ConversationSpineRailData(meeting: meeting, player: unknownLength))
  XCTAssertEqual(
   unknownLengthRail.duration, 50, "a nonfinite player duration cannot enlarge the extent")
  XCTAssertEqual(try XCTUnwrap(unknownLengthRail.playhead(at: 10)), 0.8, accuracy: 0.000_001)
  XCTAssertNil(
   earlyRail.playhead(at: 10), "a valid local position before timeline zero is excluded")
  XCTAssertEqual(earlyRail.playhead(at: 20), 0)
 }

 @MainActor
 func testOnlyAnOpenConversationWithoutASheetSuppliesTheRail() {
  let session = ReadingSession()
  let first = UUID()
  let second = UUID()
  XCTAssertNil(session.spineMeetingID)
  session.select(first)
  XCTAssertNil(session.spineMeetingID, "a library preview isn't the open spread")
  session.open(first)
  XCTAssertEqual(session.spineMeetingID, first)
  session.open(second)
  XCTAssertEqual(session.spineMeetingID, second, "only the selected conversation supplies data")
  session.sheet = .info(second)
  XCTAssertNil(session.spineMeetingID, "a page sheet covers the rail")
  session.sheet = .share([])
  XCTAssertNil(session.spineMeetingID, "a system share sheet hides it too")
  session.sheet = nil
  session.showsSummarySettingsSheet = true
  XCTAssertNil(session.spineMeetingID, "the summary's system Settings sheet hides it too")
  session.showsSummarySettingsSheet = false
  session.showsRecordingPicker = true
  XCTAssertNil(session.spineMeetingID, "Files covers the page")
  session.showsRecordingPicker = false
  session.cameraFor = second
  XCTAssertNil(session.spineMeetingID, "the camera covers the page")
  session.cameraFor = nil
  XCTAssertEqual(session.spineMeetingID, second)
  session.closeConversation()
  XCTAssertNil(session.spineMeetingID)
 }
}
