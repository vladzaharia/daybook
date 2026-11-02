import DaybookCore
import DaybookDevices
import DaybookKit
import XCTest
@testable import Daybook

/// rd-09: the menu bar extra says what Floating Notes' home and the iPhone's status sheet say, in their words, and only
/// when there's something to say: this Mac's work and a summary's countdown with its choices, a recorder that's busy
/// or listening live, a paired iPhone that's recording or paused, and iCloud when it's a problem.
final class MenuBarStatusTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func recorder(_ change: (inout RecorderFacts) -> Void = { _ in }) -> RecorderFacts {
        var facts = RecorderFacts(id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
                                  state: .connected, isLinked: true)
        facts.batteryLevel = 80
        change(&facts)
        return facts
    }

    func testBehaviorNothingToSayMeansNoStatus() {
        var inputs = MenuBarStatus.Inputs()
        inputs.recorders = [recorder()]
        inputs.phones = [PeerFacts(id: "phone", name: "Alex’s iPhone", kind: .iPhone, isConnected: true)]
        inputs.sync = .upToDate(at: now)
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now), [], "a connected recorder, an idle iPhone, and iCloud up to date say nothing here")
    }

    func testBehaviorThisMacsWorkNamesItsConversationButNeverAPersonalOne() {
        let id = UUID()
        var work = MenuBarStatus.Work(id: id, title: "Weekly product sync", stage: .transcribing, fraction: 0.4, waiting: 2)
        XCTAssertEqual(MenuBarStatus.workLine(work, now: now).title, "Transcribing “Weekly product sync” · 40% · 2 waiting")
        XCTAssertEqual(MenuBarStatus.workLine(work, now: now).opens, .conversation(id))
        work.stage = .identifyingSpeakers
        work.waiting = 0
        XCTAssertEqual(MenuBarStatus.workLine(work, now: now).title, "Identifying speakers “Weekly product sync” · 40%")
        work.title = nil
        work.stage = .summarizing
        XCTAssertEqual(MenuBarStatus.workLine(work, now: now).title, "Summarizing a personal conversation…")
    }

    func testBehaviorASummarysCountdownOffersItsChoices() {
        let id = UUID()
        let work = MenuBarStatus.Work(id: id, title: "Roadmap", stage: .summarizing, fraction: nil, countdown: now.addingTimeInterval(12),
                                      choices: [.useCloud, .startNow])
        let line = MenuBarStatus.workLine(work, now: now)
        XCTAssertEqual(line.title, "Summarizing “Roadmap” in 12 s")
        XCTAssertEqual(line.choices.map(\.title), ["Use the Cloud", "Start Now"])
        XCTAssertEqual(line.choices.first?.action, .placement(.useCloud, id))
        var cloud = work
        cloud.countdown = nil
        cloud.choices = []
        cloud.cloudModel = "Claude Sonnet 5.5"
        XCTAssertEqual(MenuBarStatus.workLine(cloud, now: now).title, "Summarizing “Roadmap” with Claude Sonnet 5.5")
    }

    func testBehaviorARecorderSaysWhatsWorthSayingInItsOwnWords() {
        var inputs = MenuBarStatus.Inputs()
        inputs.recorders = [recorder { $0.isListeningLive = true }]
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Soundcore Work · Listening live"])
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).first?.opens, .device("sc"))

        inputs.recorders = [recorder { $0.importing = .init(position: 1, total: 3, fraction: 0.2) }]
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Importing from Soundcore Work · 1 of 3"])

        inputs.recorders = [recorder { $0.newCount = 2 }]
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Soundcore Work · 2 New Recordings…"])

        inputs.recorders = [recorder { $0.isLinked = false; $0.state = .unavailable; $0.problem = "Bluetooth is off" }]
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Soundcore Work · Bluetooth is off"])
    }

    func testBehaviorAPairedIPhoneRecordingOrPausedShows() {
        var inputs = MenuBarStatus.Inputs()
        inputs.phones = [PeerFacts(id: "phone", name: "Alex’s iPhone", kind: .iPhone, isConnected: true, activity: .paused)]
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Alex’s iPhone · Paused"])
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).first?.opens, .device("phone"))
        inputs.phones[0].activity = .recording
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).map(\.title), ["Alex’s iPhone · Recording"])
    }

    func testBehaviorICloudShowsOnlyWhenItsAProblem() {
        var inputs = MenuBarStatus.Inputs()
        inputs.sync = .syncing
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now), [])
        inputs.sync = .failure(details: "The operation couldn’t be completed.")
        let line = MenuBarStatus.lines(inputs, now: now).first
        XCTAssertEqual(line?.title, "iCloud · Sync paused")
        XCTAssertEqual(line?.choices.map(\.title), ["Open Sync Settings…"])
        inputs.sync = .storageFull
        XCTAssertEqual(MenuBarStatus.lines(inputs, now: now).first?.title, "iCloud storage is full", "iCloud isn't said twice")
    }
}
