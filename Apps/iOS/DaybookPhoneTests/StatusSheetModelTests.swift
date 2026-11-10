import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI
import XCTest

@testable import DaybookPhone

/// What the status sheet adds to the overview both apps draw (docs/iphone.md, "Status sheet"): its sizes, where a
/// line leads, and its rows' own words. What each line says is DaybookKitTests' `StatusOverviewModelTests`.
@MainActor
final class StatusSheetModelTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func recorder(_ change: (inout RecorderFacts) -> Void = { _ in }) -> RecorderFacts {
    var recorder = RecorderFacts(
      id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
      state: .connected, isLinked: true)
    recorder.batteryLevel = 80
    change(&recorder)
    return recorder
  }

  private func line(_ recorder: RecorderFacts) -> StatusLineWords {
    StatusOverviewModel.recorderLine(recorder, here: "this iPhone", now: now)
  }

  // MARK: Sizes

  /// Medium shows the cards; large, the cards with what can be done there.
  func testBehaviorTheSheetsSizesSetHowDeepTheOverviewGoes() {
    XCTAssertEqual(StatusDetent.medium.density, .cards)
    XCTAssertEqual(StatusDetent.large.density, .manage)
    XCTAssertFalse(StatusSheetModel.showsManagement(.medium))
    XCTAssertTrue(
      StatusSheetModel.showsManagement(.large),
      "the recorder cards grow their storage, actions, and waiting recordings")
  }

  // MARK: This iPhone

  func testThisIPhonesDownloadedAudio() {
    // Downloads and recordings made here together, in Settings' words.
    XCTAssertEqual(StatusSheetModel.audioOnThisIPhone(bytes: 0), "No audio on this iPhone")
    XCTAssertEqual(
      StatusSheetModel.audioOnThisIPhone(bytes: 1_200_000_000),
      "\(ByteCountFormatter.string(fromByteCount: 1_200_000_000, countStyle: .file)) of audio")
  }

  // MARK: Where a line leads

  /// ux-iphone-02: a line that needs the person leads to its fix; the rest show more.
  func testBehaviorALineThatNeedsThePersonLeadsToItsFix() throws {
    var inputs = StatusOverviewInputs(words: .iPhone())
    let reason = CloudAvailability.signedOutMessage
    inputs.syncTone = .attention
    inputs.syncOff = true
    inputs.syncLine = StatusSheetModel.unavailablePhrase(reason)
    inputs.syncShort = "Off"
    let sync = try XCTUnwrap(StatusOverviewModel.syncLine(inputs))
    XCTAssertEqual(sync.text, "Signed out", "the reason, not a bare Off")
    XCTAssertEqual(sync.shortText, "Off", "Off where it's narrow")
    XCTAssertEqual(sync.symbol, "icloud.slash")
    XCTAssertEqual(StatusSheetModel.route(for: sync, inputs), .open(.icloud))
    XCTAssertEqual(StatusSheetModel.hint(for: .open(.icloud)), "Opens iCloud settings")
    XCTAssertEqual(
      StatusSheetModel.unavailablePhrase(CloudAvailability.iCloudDriveOffMessage),
      "iCloud Drive is off")
    XCTAssertEqual(
      StatusSheetModel.unavailablePhrase(CloudAvailability.unsetMessage),
      "Not available in this build"
    )

    // A Mac that isn't set up to transcribe, paired here or not: the Macs card, where its row says what to do (the
    // Mac's own page says only "Transcribes: Not set up").
    let studio = UUID()
    inputs.mac = .notProcessing(name: "Studio Mac", lastSeen: now)
    inputs.pairedMacs = [
      StatusOverviewInputs.Mac(
        id: studio, name: "Studio Mac", line: "Connected", isConnected: true, notProcessing: true)
    ]
    let mac = try XCTUnwrap(StatusOverviewModel.macLine(inputs, now: now))
    XCTAssertEqual(mac.tone, .attention)
    XCTAssertEqual(StatusSheetModel.route(for: mac, inputs), .showFix(.macs))
    XCTAssertEqual(StatusSheetModel.hint(for: .showFix(.macs)), "Shows how to fix it")
    XCTAssertTrue(StatusOverviewModel.sections(inputs, now: now).contains(.macs), "the sheet shows the card")
    let row = StatusOverviewModel.macRows(inputs, now: now).first
    XCTAssertEqual(row?.text, "Not set up to transcribe", "not \"Connected\"")
    XCTAssertEqual(row?.fix, "Finish in Daybook › Settings on Studio Mac.")
    XCTAssertTrue(row?.needsYou == true)
    inputs.pairedMacs = []
    XCTAssertEqual(StatusSheetModel.route(for: mac, inputs), .showFix(.macs))
    XCTAssertEqual(
      StatusOverviewModel.macRows(inputs, now: now).first?.fix,
      "Finish in Daybook › Settings on Studio Mac.")
    // What a Mac couldn’t finish: the Macs card too, where its queue row says what happened.
    var failing = inputs
    failing.liveProgress = [
      LiveProgress(LinkProcessingProgress(meetingID: UUID(), phase: .failed, macName: "Studio Mac"))
    ]
    let failed = try XCTUnwrap(StatusOverviewModel.macLine(failing, now: now))
    XCTAssertEqual(failed.text, "Couldn’t finish")
    XCTAssertEqual(StatusSheetModel.route(for: failed, failing), .showFix(.macs))

    // A paired Mac that can't connect (its pairing to make again, Local Network): its page.
    let damaged = UUID()
    var link = StatusOverviewInputs(words: .iPhone())
    link.pairedMacs = [
      StatusOverviewInputs.Mac(id: damaged, name: "Studio Mac", line: "Pair again", isConnected: false, problem: true)
    ]
    let pairing = try XCTUnwrap(StatusOverviewModel.lines(link, now: now).first)
    XCTAssertEqual(pairing.tone, .attention)
    XCTAssertEqual(StatusSheetModel.route(for: pairing, link), .open(.mac(damaged)))

    // A recorder's problem: its page.
    let problem = line(
      recorder {
        $0.state = .unavailable
        $0.isLinked = false
        $0.problem = "Bluetooth is off"
      })
    XCTAssertEqual(StatusSheetModel.route(for: problem, inputs), .open(.device("sc")))
    // Calm lines show more.
    XCTAssertEqual(StatusSheetModel.route(for: line(recorder()), inputs), .showMore)
    XCTAssertEqual(StatusSheetModel.hint(for: .showMore), "Shows more")
  }

  // MARK: The queues' rows

  /// ux-iphone-12: a conversation that couldn't finish offers Try Again with what it asked for, as its page does, and
  /// one this iPhone asked for says so.
  func testBehaviorAQueuedConversationsRowOffersWhatItsPageDoes() {
    let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    let studio = ProcessingRequest.Device(id: "studio", name: "Studio Mac")
    func failed(
      _ title: String, mode: ProcessingRequest.Mode = .newAudio, ago: TimeInterval,
      reason: String = "Out of memory"
    ) -> Meeting {
      var meeting = Meeting(
        title: title,
        tracks: [
          RecordingTrack(
            id: UUID(), source: .microphone, relativePath: "m.caf", fileName: "m.caf",
            offset: 0, sha256: title)
        ])
      meeting.status = .imported
      meeting.processingRequests = [
        ProcessingRequest(
          meetingID: meeting.id, mode: mode, requestedBy: phone,
          createdAt: now.addingTimeInterval(-ago - 60)
        )
        .failed(by: studio, at: now.addingTimeInterval(-ago), reason: reason)
      ].compactMap { $0 }
      return meeting
    }
    let recent = failed("Recent", ago: 3_600)
    let summary = failed("Summary", mode: .summaryOnly, ago: 3_600)
    let old = failed("Old", ago: 8 * 86_400)
    let silent = failed("Silent", ago: 60, reason: "No speech was recognized.")
    let queue = StatusOverviewModel.queue(
      meetings: [recent, summary, old, silent], liveProgress: [:], words: .iPhone(id: phone.id), now: now)
    XCTAssertEqual(queue.map(\.title), ["Recent", "Summary"])
    XCTAssertEqual(queue[0].retry, .newAudio)
    XCTAssertEqual(
      queue[1].retry, .summaryOnly, "Try Again asks again for what failed, as the page does")
    let item = queue[0].item(under: "Studio Mac")
    XCTAssertEqual(item.actions, [.tryAgain(.newAudio)])
    XCTAssertTrue(item.isProblem)
    XCTAssertEqual(item.line, "Couldn’t finish")
    XCTAssertEqual(
      item.detail, "The speech model couldn’t start on Studio Mac. The recording is saved.",
      "in the plain words both apps give its kind")
    XCTAssertEqual(item.details, "Out of memory")
    XCTAssertNil(item.note, "a failure isn't “Requested from this iPhone”")
    XCTAssertEqual(
      queue[0].item(under: nil).line, "Studio Mac couldn’t finish",
      "at the top of the card, it names the Mac")

    var asked = Meeting(title: "Asked")
    asked.processingRequests = [
      ProcessingRequest(meetingID: asked.id, mode: .newAudio, requestedBy: phone, createdAt: now)
    ]
    let waiting = StatusOverviewModel.queue(
      meetings: [asked], liveProgress: [:], words: .iPhone(id: phone.id), now: now)
    XCTAssertEqual(waiting.first?.item(under: "Studio Mac").note, "Requested from this iPhone")
  }

  // MARK: The strip

  /// The strip's tap: a line that needs the person opens where it's fixed, inside the sheet; any other line, the sheet
  /// at medium.
  func testBehaviorTappingTheStripAsksForTheSheetWhereTheLineLeads() {
    XCTAssertEqual(StatusRequest(.open(.icloud)).route, .icloud)
    XCTAssertEqual(StatusRequest(.open(.icloud)).detent, .large, "a full screen opens at full height")
    XCTAssertEqual(StatusRequest(.showFix(.macs)).fix, .macs)
    XCTAssertEqual(StatusRequest(.showFix(.macs)).detent, .medium)
    XCTAssertNil(StatusRequest(.showMore).route)
    XCTAssertNil(StatusRequest(.showMore).fix)
    XCTAssertEqual(StatusSheetModel.title, "Devices", "the sheet's title, and More's item for it")
  }
}
