import XCTest
@testable import Daybook

/// When a call starts (docs/capture.md, "Calls"): Off, Ask, or Record Automatically, and each app's own answer; the
/// monitor saying what became of a call; the apps it knows; and the prompt's answers.
@MainActor
final class CallPolicyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let zoom = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", windowTitle: "Zoom Meeting", hasInputActivity: true,
                                        hasOutputActivity: true, hasMeetingWindow: true, isBrowser: false)

    // MARK: Deciding

    func testBehaviorTheAppsOwnAnswerComesBeforeThePolicy() {
        let decide = { (policy: CallRecordingPolicy, choice: CallAppChoice?) in
            CallPolicy.decision(for: "us.zoom.xos", policy: policy, choices: choice.map { ["us.zoom.xos": $0] } ?? [:], busy: false)
        }
        XCTAssertEqual(decide(.ask, nil), .ask)
        XCTAssertEqual(decide(.record, nil), .record)
        XCTAssertEqual(decide(.ask, .always), .record, "Always Record Zoom Calls")
        XCTAssertEqual(decide(.record, .never), .ignore, "Never for Zoom")
        XCTAssertEqual(decide(.record, .ask), .ask, "an app can ask while every other records")
        XCTAssertEqual(decide(.off, .always), .ignore, "Off is off, whatever an app says")
        XCTAssertEqual(CallPolicy.decision(for: "us.zoom.xos", policy: .record, choices: [:], busy: true), .ignore,
                       "nothing while a recording is under way")
    }

    func testBehaviorTheOldSwitchBecomesThePolicyAndANewInstallationAsks() throws {
        let defaults = makeTestDefaults("CallPolicyTests")
        XCTAssertEqual(CallPolicy.stored(in: defaults), .ask, "a new installation asks")
        defaults.set(true, forKey: CallPolicy.legacyKey)
        XCTAssertEqual(CallPolicy.stored(in: defaults), .record, "Record calls automatically, on, records")
        defaults.set(false, forKey: CallPolicy.legacyKey)
        XCTAssertEqual(CallPolicy.stored(in: defaults), .ask, "and off asks")

        CallPolicy.save(.off, choices: ["us.zoom.xos": .always, "com.hnc.Discord": .never], in: defaults)
        XCTAssertEqual(CallPolicy.stored(in: defaults), .off, "the policy wins over the old switch once saved")
        XCTAssertFalse(defaults.bool(forKey: CallPolicy.legacyKey), "an older Daybook reads off")
        XCTAssertEqual(CallPolicy.storedChoices(in: defaults), ["us.zoom.xos": .always, "com.hnc.Discord": .never])
        CallPolicy.save(.record, choices: [:], in: defaults)
        XCTAssertTrue(defaults.bool(forKey: CallPolicy.legacyKey), "and on when every call is recorded")
    }

    func testBehaviorTheAppStateKeepsItsPolicyAndAnswers() async throws {
        let root = makeTemporaryFolder("CallPolicyTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = makeTestDefaults("CallPolicyTests.state")
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertEqual(state.callPolicy, .ask)
        XCTAssertFalse(state.automaticRecording)

        state.answered(.never, about: zoom)
        XCTAssertEqual(state.callAppChoices, ["us.zoom.xos": .never], "Never for Zoom is Zoom's from then on")
        XCTAssertEqual(state.monitor.statusText, MeetingMonitor.paused, "and this call is left alone until it ends")
        state.callPolicy = .record
        XCTAssertTrue(state.automaticRecording)

        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        XCTAssertEqual(restarted.callPolicy, .record)
        XCTAssertEqual(restarted.callAppChoices, ["us.zoom.xos": .never])
    }

    // MARK: The monitor

    private func monitor(_ response: CallResponse, ended: @escaping (MeetingCandidate?) -> Void = { _ in }) -> MeetingMonitor {
        let monitor = MeetingMonitor(read: { _ in .failed })
        monitor.onMeetingStarted = { _ in response }
        monitor.onMeetingEnded = { call in ended(call); return false }
        return monitor
    }

    private func start(_ monitor: MeetingMonitor) {
        monitor.apply(.seen([zoom], windowsReadable: true), at: epoch)
        monitor.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(6))
    }

    func testBehaviorTheLineSaysDaybookIsAskingAndThenThatItsRecording() {
        let asking = monitor(.asking)
        start(asking)
        XCTAssertEqual(asking.statusText, "Asking whether to record the Zoom call.")
        asking.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(8))
        XCTAssertEqual(asking.statusText, "Asking whether to record the Zoom call.", "until it's answered")
        asking.callRecordingStarted()
        XCTAssertEqual(asking.statusText, "Recording a Zoom call.")
    }

    func testBehaviorACallThatIsntRecordedPausesTheMonitorUntilItEnds() {
        let declined = monitor(.notRecorded)
        start(declined)
        XCTAssertFalse(declined.isMeetingActive)
        XCTAssertEqual(declined.statusText, MeetingMonitor.paused)
        declined.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(30))
        XCTAssertFalse(declined.isMeetingActive, "not asked about again while it goes on")
    }

    func testBehaviorTheEndOfACallSaysWhichCallItWas() {
        var ended: MeetingCandidate?
        let watching = monitor(.recording) { ended = $0 }
        start(watching)
        watching.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(10))
        watching.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(56))
        XCTAssertEqual(ended?.bundleID, zoom.bundleID, "so a recording the person started can be asked about by name")
    }

    // MARK: The apps it knows

    func testBehaviorAnAppThatOnlyCallsStartsOnTheMicrophoneAndEndsWithItsAudio() {
        let facetime = MeetingActivityReader.candidates(rules: MeetingAppRule.defaults, processes: [
            AudioProcessInfo(objectID: 1, pid: 10, bundleID: "com.apple.FaceTime", isRunningOutput: true, isRunningInput: true)
        ], windows: [.init(bundleID: "com.apple.FaceTime", title: "FaceTime")])
        let call = try? XCTUnwrap(facetime.first)
        XCTAssertEqual(call?.appName, "FaceTime")
        XCTAssertEqual(call?.canStart, true, "its window is there all along: the microphone says the call")
        XCTAssertEqual(call?.hasMeetingWindow, false)

        let open = MeetingActivityReader.candidates(rules: MeetingAppRule.defaults, processes: [],
                                                    windows: [.init(bundleID: "com.hnc.Discord", title: "Discord")])
        XCTAssertTrue(open.isEmpty, "Discord open, with nothing on the microphone, is no call")

        var quiet = zoom
        quiet.bundleID = "com.hnc.Discord"; quiet.needsMeetingWindow = false
        quiet.hasInputActivity = false; quiet.hasOutputActivity = false; quiet.hasMeetingWindow = false
        XCTAssertFalse(quiet.canContinue, "and its call ends with its audio, not when its window closes")
    }

    func testBehaviorTeamsHelperAndOrionsWebKitAudioCountAsTheirApps() {
        let found = MeetingActivityReader.candidates(rules: MeetingAppRule.defaults, processes: [
            AudioProcessInfo(objectID: 1, pid: 10, bundleID: "com.microsoft.vcxpc", isRunningOutput: true, isRunningInput: true),
            AudioProcessInfo(objectID: 2, pid: 11, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true, isRunningInput: true)
        ], windows: [.init(bundleID: "com.microsoft.teams2", title: "Weekly sync | Meeting | Microsoft Teams"),
                     .init(bundleID: "com.kagi.kagimacOS", title: "Meet - Design review")])
        let byApp = Dictionary(found.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byApp["com.microsoft.teams2"]?.canStart, true, "Teams' audio helper is Teams")
        XCTAssertEqual(byApp["com.kagi.kagimacOS"]?.canStart, true, "Orion plays through WebKit's GPU process, as Safari does")
        XCTAssertNil(byApp["com.apple.Safari"]?.hasMeetingWindow == true ? byApp["com.apple.Safari"] : nil,
                     "Safari, with no meeting window, isn't the call")
    }

    func testBehaviorEveryAppIsKnownOnceAndNamed() {
        let ids = MeetingAppRule.defaults.map(\.bundleID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(CallPolicy.appName(for: "com.brave.Browser"), "Brave")
        XCTAssertEqual(CallPolicy.appName(for: "com.example.unknown"), "com.example.unknown")
        let browsers = MeetingAppRule.defaults.filter(\.isBrowser).map(\.displayName)
        for browser in ["Safari", "Chrome", "Firefox", "Edge", "Arc", "Dia", "Brave", "Vivaldi", "Opera", "Orion"] {
            XCTAssertTrue(browsers.contains(browser), browser)
        }
    }

    // MARK: The prompt

    func testBehaviorThePromptLeavesACallAloneAndARecordingGoingWhenItsTimeRunsOut() {
        XCTAssertEqual(CallPromptQuestion.record(zoom).unanswered, .notNow)
        XCTAssertEqual(CallPromptQuestion.ended(zoom).unanswered, .keepRecording, "a recording the person started is never stopped for them")
        XCTAssertEqual(CallPromptQuestion.record(zoom).announcement, "Zoom call started. Record it?")
        XCTAssertEqual(CallPromptQuestion.ended(zoom).announcement, "The Zoom call ended. Stop recording?")
        let notes = NSRect(x: 1000, y: 300, width: 360, height: 560)
        let prompt = CallPromptWindow.frame(under: notes)
        XCTAssertEqual(prompt.maxX, notes.maxX, "in Floating Notes' top-trailing corner, so Record grows it into the notes")
        XCTAssertEqual(prompt.maxY, notes.maxY)
    }
}
