import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import SwiftUI
import XCTest

@testable import DaybookPhone

/// What the status sheet adds to the overview both apps draw (docs/iphone.md, "Status sheet"): where it stands, its
/// sizes and what each holds, where a line leads, and its rows' own words. What each line says is DaybookKitTests'
/// `StatusOverviewModelTests`.
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

  // MARK: Where it stands

  /// The owner's call (2026-11-11): the standing sheet is back. In one column it's the system's sheet over the library;
  /// on two pages, and in one column on its side, it's drawn at the library page's foot; over a conversation, search,
  /// selection, or the Trash, nowhere.
  func testBehaviorTheSheetStandsWhileTheLibraryIsWhatsOnScreen() {
    func placement(
      twoPages: Bool = false, compactHeight: Bool = false, reading: Bool = false, searching: Bool = false,
      selecting: Bool = false, inTrash: Bool = false
    ) -> StatusSheetModel.Placement {
      StatusSheetModel.placement(
        twoPages: twoPages, compactHeight: compactHeight, reading: reading, searching: searching,
        selecting: selecting, inTrash: inTrash)
    }
    XCTAssertEqual(placement(), .sheet, "an 18 Pro upright, or the Duo closed: the system's sheet")
    XCTAssertEqual(placement(reading: true), .none, "a conversation pushed over the library")
    XCTAssertEqual(placement(searching: true), .none, "search has the keyboard")
    XCTAssertEqual(placement(selecting: true), .none, "selection has its own bar")
    XCTAssertEqual(placement(inTrash: true), .none, "nothing records into the Trash or searches it")

    // Turned: never the system's sheet, which iOS would show over the whole window; the same sheet at its compact
    // size at the foot, so Record, Import, and Search stay at the thumb through the turn.
    XCTAssertEqual(placement(compactHeight: true), .foot, "the Duo's cover on its side")
    XCTAssertEqual(placement(twoPages: true, compactHeight: true), .foot, "an 18 Pro on its side: two pages")
    XCTAssertEqual(placement(twoPages: true), .foot, "the open Duo's left page")
    XCTAssertEqual(placement(twoPages: true, inTrash: true), .none)
    XCTAssertEqual(placement(twoPages: true, searching: true), .none)
    XCTAssertEqual(placement(twoPages: true, selecting: true), .none)
  }

  /// More › Devices, a line's tap, or a recorder's notification drags the standing sheet up to the request's size while
  /// it stands; anywhere else it's shown on its own (a sheet over a conversation, the card on two pages). Back from a
  /// conversation or search, or turned, it's minimized, not wherever it was left.
  func testBehaviorAskingForMoreDragsTheStandingSheetUpElseShowsItOnItsOwn() {
    var state = StatusSheetState()
    XCTAssertEqual(state.size, .compact, "at rest it's minimized")
    let devices = StatusRequest()
    state.show(devices, standing: true)
    XCTAssertEqual(state.size, .medium, "More › Devices drags it up to medium")
    XCTAssertEqual(state.asked, devices)
    XCTAssertNil(state.request, "the same sheet, not another over it")
    let icloud = StatusRequest(.open(.icloud))
    state.show(icloud, standing: true)
    XCTAssertEqual(state.size, .large, "a screen opens at full height")
    XCTAssertEqual(state.asked?.route, .icloud)

    state.stepAside()
    XCTAssertEqual(state.size, .compact, "back from a conversation or search: minimized again")
    XCTAssertNil(state.asked)

    state.show(devices, standing: false)
    XCTAssertEqual(state.request, devices, "over a conversation, or on two pages: on its own")
    XCTAssertEqual(state.size, .compact, "the standing sheet stays minimized behind it")
  }

  // MARK: Sizes

  /// Minimized (compact) is the row; medium shows the lines and the cards; large, the cards with what can be done there.
  func testBehaviorTheSheetsSizesSetHowDeepTheOverviewGoes() {
    XCTAssertEqual(StatusDetent.allCases, [.compact, .medium, .large])
    XCTAssertEqual(StatusDetent.compact.density, .lines)
    XCTAssertEqual(StatusDetent.medium.density, .cards)
    XCTAssertEqual(StatusDetent.large.density, .manage)
    XCTAssertFalse(StatusSheetModel.showsManagement(.compact))
    XCTAssertFalse(StatusSheetModel.showsManagement(.medium))
    XCTAssertTrue(
      StatusSheetModel.showsManagement(.large),
      "the recorder cards grow their storage, actions, and waiting recordings")
    XCTAssertEqual(StatusQuickActions.spacing, 8, "one gap between Record, Import, and Search")
  }

  /// Compact holds no groups; medium and large the overview's, less iCloud's line, which the lines above them say.
  func testBehaviorEachSizeAddsTheGroupsOfWhatExists() {
    var inputs = StatusOverviewInputs(words: .iPhone())
    XCTAssertEqual(StatusSheetModel.groups(for: .compact, inputs, now: now), [])
    XCTAssertEqual(
      StatusSheetModel.groups(for: .medium, inputs, now: now), [.iphone],
      "nothing added: this iPhone alone, no Recorders or Macs cards")
    inputs.recording.recorders = [recorder()]
    inputs.syncTone = .attention
    inputs.syncLine = "Sync paused"
    XCTAssertEqual(StatusOverviewModel.sections(inputs, now: now), [.lines, .recorders, .iphone])
    XCTAssertEqual(StatusSheetModel.groups(for: .medium, inputs, now: now), [.recorders, .iphone])
    XCTAssertEqual(StatusSheetModel.groups(for: .large, inputs, now: now), [.recorders, .iphone])
    XCTAssertEqual(StatusSheetModel.groups(for: .compact, inputs, now: now), [])
  }

  /// The owner's call (2026-11-11): at rest the sheet is minimized, and small. With nothing to say it's Record, Import,
  /// and Search alone; with something to say, the one line that says it under them (what the strip said); dragged up,
  /// every line, one for each thing there is, and nothing of what isn't.
  func testBehaviorMinimizedIsTheRowAndTheLineWithSomethingToSay() {
    var inputs = StatusOverviewInputs(words: .iPhone())
    inputs.syncTone = .upToDate
    inputs.syncLine = "Up to date"
    XCTAssertEqual(StatusOverviewModel.lines(inputs, now: now), [], "no “None added”, no “Hasn’t synced”, no “Up to date”")
    XCTAssertEqual(StatusSheetModel.lines(for: .compact, []), [], "nothing to say: the row alone")

    // A connected recorder and an idle Mac exist, so dragged up they have lines; minimized they say nothing.
    inputs.recording.recorders = [recorder()]
    inputs.mac = .seen(name: "Studio Mac", lastSeen: now)
    let calm = StatusOverviewModel.lines(inputs, now: now)
    XCTAssertEqual(calm.map(\.id), ["recorder-sc", StatusOverviewModel.macID], "the devices that exist")
    XCTAssertEqual(StatusSheetModel.lines(for: .compact, calm), [], "calm: the row alone")
    XCTAssertEqual(StatusSheetModel.lines(for: .medium, calm), calm)

    // iCloud a problem: its line exists, and it's the one minimized says.
    inputs.syncTone = .attention
    inputs.syncLine = "Sync paused"
    let lines = StatusOverviewModel.lines(inputs, now: now)
    XCTAssertEqual(
      lines.map(\.id), ["recorder-sc", StatusOverviewModel.macID, StatusOverviewModel.syncID],
      "and iCloud only when it's a problem")
    XCTAssertEqual(StatusSheetModel.lines(for: .compact, lines).map(\.id), [StatusOverviewModel.syncID])
    XCTAssertEqual(StatusSheetModel.lines(for: .medium, lines), lines)
    XCTAssertEqual(StatusSheetModel.lines(for: .large, lines), lines)

    // A recorder recording has something to say; the idle Mac beside it doesn't.
    inputs.syncTone = .upToDate
    inputs.recording.recorders = [recorder { $0.isRecording = true }]
    XCTAssertEqual(
      StatusSheetModel.lines(for: .compact, StatusOverviewModel.lines(inputs, now: now)).map(\.id), ["recorder-sc"])
  }

  /// Minimized is small: the grabber's room and the row at a toolbar's size, measured from the fonts, never a share of
  /// the screen, but never so short that iOS floats the system's sheet as a tight capsule instead of a sheet; a notice
  /// over Record (an import under way) and the line with something to say make room for themselves while they're there.
  func testBehaviorMinimizedIsSmallButStillASheet() {
    let screen: CGFloat = 874  // an iPhone 18 Pro, upright
    let row = StatusCompactDetent.recordTop + StatusCompactDetent.rowHeight(at: .large) + StatusCompactDetent.bottomRoom
    let minimized = StatusCompactDetent.height(for: .large, maximum: screen)
    XCTAssertLessThan(row, StatusCompactDetent.sheetMinimum, "the row alone is shorter than a sheet")
    XCTAssertEqual(minimized, StatusCompactDetent.sheetMinimum, "so minimized is the shortest sheet, not a capsule")
    XCTAssertEqual(StatusCompactDetent.control, 44, "a toolbar button's touch target")
    XCTAssertEqual(StatusCompactDetent.rowHeight(at: .large), 52, "44 pt controls and their glass")
    XCTAssertLessThan(minimized, screen * 0.15, "never the quarter to a third of the list it once took")
    let withLine = StatusCompactDetent.height(for: .large, maximum: screen, line: true)
    XCTAssertEqual(
      withLine, row + StatusCompactDetent.recordGap + StatusCompactDetent.lineHeight(at: .large),
      "a line and the gap over it")
    XCTAssertGreaterThan(withLine, minimized)
    XCTAssertLessThan(withLine, screen * 0.15)
    XCTAssertGreaterThan(
      StatusCompactDetent.height(for: .large, maximum: screen, notice: true, line: true), withLine, "a notice over Record")

    // It grows with the text size up to the row's largest, then stops: Record's label would break beside the round
    // buttons, and each control shows the large content viewer instead. The line keeps growing: at the accessibility
    // sizes its title and words share four rows.
    var previous: CGFloat = 0
    for size in DynamicTypeSize.allCases {
      let height = StatusCompactDetent.height(for: size, maximum: 2_000)
      XCTAssertGreaterThanOrEqual(height, previous, "\(size) is no shorter than the size before")
      previous = height
    }
    XCTAssertEqual(
      StatusCompactDetent.rowHeight(at: .accessibility5), StatusCompactDetent.rowHeight(at: .accessibility1))
    XCTAssertLessThan(StatusCompactDetent.height(for: .accessibility5, maximum: 678), 678 * 0.25, "small on the Duo's cover too")
    XCTAssertGreaterThanOrEqual(
      StatusCompactDetent.lineHeight(at: .accessibility1),
      CGFloat(StatusMetrics.stackedRows) * StatusCompactDetent.lineHeight(.subheadline, at: .accessibility1))
    XCTAssertLessThanOrEqual(
      StatusCompactDetent.height(for: .accessibility5, maximum: 874, line: true), 874 * 0.55,
      "past the cap the line scrolls")
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

  // MARK: Asking for more

  /// A line's tap at the foot (or More › Devices): a line that needs the person opens where it's fixed, inside the
  /// sheet at full height; any other line, the sheet at medium (the card on the right page, on two pages).
  func testBehaviorTappingALineAsksForTheSheetWhereTheLineLeads() {
    XCTAssertEqual(StatusRequest(.open(.icloud)).route, .icloud)
    XCTAssertEqual(StatusRequest(.open(.icloud)).detent, .large, "a full screen opens at full height")
    XCTAssertEqual(StatusRequest(.showFix(.macs)).fix, .macs)
    XCTAssertEqual(StatusRequest(.showFix(.macs)).detent, .medium)
    XCTAssertNil(StatusRequest(.showMore).route)
    XCTAssertNil(StatusRequest(.showMore).fix)
    XCTAssertEqual(StatusSheetModel.title, "Devices", "the sheet's title, and More's item for it")
  }
}
