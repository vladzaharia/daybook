import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookPhone

/// What Settings and the recorder and Mac pages say, and where the open iPhone Duo splits a sheet into
/// pages: each thing once, plain words, nothing across the crease.
@MainActor
final class SettingsWordsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Macs

    func testTheMacsFooterSaysOnlyWhatTheRowsDont() {
        let paired = ["Studio Mac"]
        XCTAssertNil(MacsSection.footer(.connected(name: "Studio Mac"), pairedNames: paired), "its row says it's connected")
        XCTAssertNil(MacsSection.footer(.seen(name: "Studio Mac", lastSeen: now), pairedNames: paired, now: now),
                     "a paired Mac is its row")
        XCTAssertNil(MacsSection.footer(.checking, pairedNames: paired), "no filler while checking")
        XCTAssertNil(MacsSection.footer(.unavailable("Sign in to iCloud to sync your library."), pairedNames: paired),
                     "iCloud's row says why")

        // A Mac that syncs the library but isn't paired here has no row, so the footer names it.
        XCTAssertEqual(MacsSection.footer(.seen(name: "Office iMac", lastSeen: now.addingTimeInterval(-7_200)),
                                          pairedNames: paired, now: now),
                       "Office iMac last synced 2 h ago.")
        // Something to do is always said.
        XCTAssertEqual(MacsSection.footer(.noMac, pairedNames: []), "No Mac has synced this library yet. Open Daybook on your Mac.")
        XCTAssertEqual(MacsSection.footer(.notProcessing(name: "Studio Mac", lastSeen: now), pairedNames: paired, now: now),
                       "Studio Mac isn’t set up to transcribe. Finish in Daybook › Settings on Studio Mac.")
    }

    // MARK: Recorders

    func testARecorderAwaySaysWhenItWasLastSeen() {
        let calendar = Calendar.current
        let earlier = calendar.date(byAdding: .hour, value: -1, to: now)!
        let line = PhoneDeviceCopy.lastSeen(earlier, now: now)
        XCTAssertTrue(line.hasPrefix("Last seen "), "never a bare time: \(line)")
        XCTAssertTrue(line.contains(earlier.formatted(date: .omitted, time: .shortened)))
    }

    func testFiguresFromEarlierSayAsOfOnce() {
        let calendar = Calendar.current
        let today = calendar.date(byAdding: .minute, value: -30, to: now)!
        XCTAssertEqual(PhoneDeviceCopy.asOf(today, now: now, calendar: calendar),
                       "As of \(today.formatted(date: .omitted, time: .shortened))")
        let before = calendar.date(byAdding: .day, value: -3, to: now)!
        let asOf = PhoneDeviceCopy.asOf(before, now: now, calendar: calendar)
        XCTAssertTrue(asOf.hasPrefix("As of "), asOf)
        XCTAssertFalse(asOf.contains(" on "), "not \"As of on 20 Oct\": \(asOf)")
        XCTAssertFalse(asOf.contains(" at "), asOf)
    }

    func testARecordersRoomIsAFigureInHours() {
        XCTAssertEqual(PhoneDeviceCopy.storageFigure(hours: 213), "210 hr")
        XCTAssertEqual(PhoneDeviceCopy.storageFigure(hours: 6.2), "6 hr")
        XCTAssertEqual(PhoneDeviceCopy.storageFigure(hours: 0.4), "< 1 hr")
    }

    func testARelativeTimeStartingALineIsCapitalized() {
        XCTAssertEqual(PhoneDeviceCopy.sentenceCase("just now"), "Just now")
        XCTAssertEqual(PhoneDeviceCopy.sentenceCase("2 hours ago"), "2 hours ago")
    }

    // MARK: Storage

    func testStorageSaysWhatTheAudioIsWithoutRepeatingTheTotal() {
        XCTAssertNil(StorageScreen.breakdown(bytes: 0, downloaded: 0), "nothing to say")
        XCTAssertEqual(StorageScreen.breakdown(bytes: 400_000, downloaded: 0), "Recorded on this iPhone")
        XCTAssertEqual(StorageScreen.breakdown(bytes: 400_000, downloaded: 400_000), "Downloaded for playback")
        let both = StorageScreen.breakdown(bytes: 3_000_000, downloaded: 1_000_000)
        XCTAssertEqual(both, "\(StorageScreen.bytes(1_000_000)) downloaded · \(StorageScreen.bytes(2_000_000)) recorded on this iPhone")
        // A count that's briefly ahead of the total never goes negative.
        XCTAssertEqual(StorageScreen.breakdown(bytes: 100, downloaded: 200), "Downloaded for playback")
    }

    // MARK: The open iPhone Duo

    func testASheetAcrossTheCreaseSplitsWhereTheCreaseFalls() {
        // The Duo's inner display is 951 pt; the crease is its middle. A sheet centred on it from x = 150.
        let crease = SheetCreaseSplit<EmptyView, EmptyView, EmptyView>.crease(
            width: 650, placement: WindowPlacement(windowWidth: 951, minX: 150))
        XCTAssertEqual(crease ?? 0, 325.5, accuracy: 0.01)
    }

    func testASheetToOneSideOfTheCreaseStaysOneColumn() {
        // Partly open, the system keeps a sheet on the left page: no page would be wide enough to read.
        XCTAssertNil(SheetCreaseSplit<EmptyView, EmptyView, EmptyView>.crease(
            width: 450, placement: WindowPlacement(windowWidth: 951, minX: 20)))
        // A sheet that barely reaches past the crease doesn't split into a sliver either.
        XCTAssertNil(SheetCreaseSplit<EmptyView, EmptyView, EmptyView>.crease(
            width: 600, placement: WindowPlacement(windowWidth: 951, minX: 0)))
        // An iPhone in the hand: the crease would be its middle, but a 402 pt window has no room for two pages.
        XCTAssertNil(SheetCreaseSplit<EmptyView, EmptyView, EmptyView>.crease(
            width: 402, placement: WindowPlacement(windowWidth: 402, minX: 0)))
    }

    // MARK: Cloud

    func testTheCloudRowSaysWhatSummariesUse() {
        XCTAssertEqual(CloudSetup.demo(providers: [], defaults: makeTestDefaults()).summary, "Off", "Nothing until a key is set")
        let openAI = CloudSetup.demo(providers: [.openai], defaults: makeTestDefaults())
        XCTAssertEqual(openAI.summary, "GPT-6.1 Sol", "The model Balanced resolves to")
        openAI.choose(.economy)
        XCTAssertEqual(openAI.summary, "GPT-6.1 Terra")
        openAI.preferences.policy = .never
        XCTAssertEqual(openAI.summary, "Never")
        XCTAssertEqual(CloudTier.allCases.map(CloudSettingsScreen.title), ["Best", "Balanced", "Economy"])
        XCTAssertEqual(CloudEffort.allCases.map(CloudSettingsScreen.title), ["Low", "Medium", "High"])
    }
}
