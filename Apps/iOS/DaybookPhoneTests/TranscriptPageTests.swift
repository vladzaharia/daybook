import DaybookKit
import DaybookUI
import SwiftUI
import UIKit
import XCTest
@testable import DaybookPhone

/// The iPhone's side of the shared transcript, photos, and the conversation's tools: where its sheets go, and what
/// its photo views do through the reading session.
@MainActor
final class TranscriptPageTests: XCTestCase {
    private func library() async throws -> LibraryController {
        let library = LibraryController(rootURL: try temporaryDirectory(), sync: nil)
        try await library.load()
        return library
    }

    func testBehaviorTheTranscriptsSheetsAreReadingSheetsTheDuoShowsOnItsRightPage() {
        let meeting = UUID(), segment = UUID(), track = UUID()
        XCTAssertEqual(PhoneTranscriptPage.readingSheet(.correct(segmentID: segment), meetingID: meeting),
                       .correct(meetingID: meeting, segmentID: segment))
        XCTAssertEqual(PhoneTranscriptPage.readingSheet(.reviewCorrections, meetingID: meeting), .reviewCorrections(meeting),
                       "Review… on this iPhone, never \"Review it on your Mac\"")
        XCTAssertEqual(PhoneTranscriptPage.readingSheet(.adjustTiming(trackID: track), meetingID: meeting),
                       .adjustTiming(meetingID: meeting, trackID: track))
        XCTAssertEqual(PhoneTranscriptPage.readingSheet(.originalTranscript(trackID: track), meetingID: meeting),
                       .originalTranscript(meetingID: meeting, trackID: track))

        let sheets: [ReadingSheet] = [.reviewCorrections(meeting), .adjustTiming(meetingID: meeting, trackID: track),
                                      .adjustTiming(meetingID: meeting, trackID: nil), .originalTranscript(meetingID: meeting, trackID: track),
                                      .correct(meetingID: meeting, segmentID: segment), .heardIn(meetingID: meeting, segmentID: segment)]
        XCTAssertEqual(Set(sheets.map(\.id)).count, sheets.count, "each sheet is its own, so one replaces another")
    }

    func testBehaviorPhotosOpenShareAndShowTheirMomentThroughTheReadingSession() async throws {
        let library = try await library()
        let session = ReadingSession()
        let services = PhotoServices.phone(library: library, session: session, provider: LocalAudioProvider())
        let meetingID = library.newMeeting(title: "Whiteboard")
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.png", fileName: "a.png", sha256: "", capturedAt: Date())

        XCTAssertEqual(services.handoff, .share)
        XCTAssertEqual(services.handoff.title, "Share Photo")
        XCTAssertNil(services.reveal, "no Finder on the iPhone")

        services.open?(photo, meetingID)
        XCTAssertEqual(session.sheet, .photo(meetingID: meetingID, photoID: photo.id))
        services.add(meetingID)
        XCTAssertEqual(session.sheet, .importPhotos(meetingID))

        let meeting = try XCTUnwrap(library.meeting(meetingID))
        services.showInTranscript(photo, meeting)
        XCTAssertEqual(session.transcriptRequest?.target, photo.id.uuidString)
        XCTAssertEqual(session.pageMode, .transcript)
    }

    func testBehaviorAPageSheetClosesThroughTheSharedAction() {
        var closed = false
        let action = ClosePageSheetAction { closed = true }
        action()
        XCTAssertTrue(closed)
        XCTAssertEqual(action, ClosePageSheetAction { }, "a page making its closure again doesn't redraw the sheet")
    }
}
