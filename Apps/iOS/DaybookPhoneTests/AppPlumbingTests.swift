import DaybookCore
import DaybookKit
import DaybookLink
import XCTest
@testable import DaybookPhone

/// The app's plumbing, typed: the debug launch arguments parsed once, segment files named and read back
/// by one rule, a recording's lead written as the journal always wrote it, iCloud's reasons with their
/// sentences, what a model built for a test reaches, and the words with plurals the language makes.
@MainActor
final class AppPlumbingTests: XCTestCase {
    // MARK: Debug launch arguments

    func testBehaviorDebugLaunchParsesEveryFlagOnceAndTyped() {
        let launch = DebugLaunch(arguments: ["app", "--open-settings", "speaker-profile:Vlad", "--status-open", "add-recorder",
                                             "--handoff-demo", "overdue", "--demo-transfer", "other-app", "--stop-after", "12",
                                             "--demo-mac", "Studio Mac:5", "--info-detent", "large", "--confirm-merge",
                                             "--placement-demo", "countdown", "--select", "Weekly product sync"],
                                 environment: [:])
        #if DEBUG
        XCTAssertEqual(launch.settingsPage, .speakerProfile("Vlad"))
        XCTAssertEqual(launch.openSettings, "speaker-profile:Vlad", "as views that match the flag's spelling read it")
        XCTAssertEqual(launch.statusPage, .addRecorder)
        XCTAssertEqual(launch.statusOpen, "add-recorder")
        XCTAssertEqual(launch.handoffDemo, .overdue)
        XCTAssertTrue(launch.handoffDemo?.startsManagedByMac == true)
        XCTAssertEqual(launch.demoTransfer, .otherApp)
        XCTAssertEqual(launch.stopAfter, 12)
        XCTAssertEqual(launch.demoMac, DebugLaunch.DemoMac(name: "Studio Mac", hoursAgo: 5))
        XCTAssertEqual(launch.infoDetent, "large")
        XCTAssertTrue(launch.confirmMerge)
        XCTAssertEqual(launch.placementDemo, "countdown")
        XCTAssertEqual(launch.reading.select, "Weekly product sync", "the reading surface's, in the same value")
        #endif
        XCTAssertFalse(launch.isRunningTests)
        XCTAssertTrue(DebugLaunch(arguments: [], environment: ["XCTestBundlePath": "/x"]).isRunningTests)
    }

    func testBehaviorAFlagWithoutItsValueIsntGivenTheNextFlag() {
        XCTAssertNil(DebugLaunch.value(after: "--open-settings", in: ["app", "--open-settings", "--scroll-end"]))
        XCTAssertEqual(DebugLaunch.value(after: "--library", in: ["app", "--library", "/tmp/x"]), "/tmp/x")
        XCTAssertNil(DebugLaunch.value(after: "--library", in: ["app", "--library"]))
        #if DEBUG
        let bare = DebugLaunch(arguments: ["app", "--open-settings", "--scroll-end"], environment: [:])
        XCTAssertEqual(bare.settingsPage, .root)
        XCTAssertTrue(bare.scrollEnd)
        XCTAssertEqual(DebugLaunch(arguments: ["app", "--open-settings", "nowhere"], environment: [:]).settingsPage, .root)
        XCTAssertEqual(DebugLaunch(arguments: ["app", "--caption-probe"], environment: [:]).captionProbe, "")
        #endif
    }

    func testBehaviorADemoMacWithoutANameIsIgnored() {
        XCTAssertNil(DebugLaunch.demoMac(":"))
        XCTAssertNil(DebugLaunch.demoMac(":3"))
        XCTAssertNil(DebugLaunch.demoMac(""))
        XCTAssertEqual(DebugLaunch.demoMac("Studio"), DebugLaunch.DemoMac(name: "Studio", hoursAgo: 2))
        XCTAssertEqual(DebugLaunch.demoMac("Studio:x"), DebugLaunch.DemoMac(name: "Studio", hoursAgo: 2))
        XCTAssertEqual(DebugLaunch.SettingsPage(argument: "device-details"), .deviceDetails)
        XCTAssertNil(DebugLaunch.SettingsPage(argument: "speaker-profile:"))
        for (spelling, page) in DebugLaunch.SettingsPage.plain { XCTAssertEqual(page.argument, spelling) }
    }

    // MARK: Recording files and journals

    func testBehaviorSegmentFilesAreNamedAndReadBackByOneRule() {
        XCTAssertEqual(CaptureSegment.fileName(index: 0), "segment-000.m4a")
        XCTAssertEqual(CaptureSegment.fileName(index: 12), "segment-012.m4a")
        XCTAssertEqual(CaptureSegment.fileName(index: 1_234), "segment-1234.m4a")
        for index in [0, 7, 999, 1_234] { XCTAssertEqual(CaptureSegment.index(fromFileName: CaptureSegment.fileName(index: index)), index) }
        XCTAssertNil(CaptureSegment.index(fromFileName: "segment-.m4a"))
        XCTAssertNil(CaptureSegment.index(fromFileName: "segment-01a.m4a"))
        XCTAssertNil(CaptureSegment.index(fromFileName: "photo-1.jpg"))
        XCTAssertNil(CaptureSegment.index(fromFileName: PhoneCaptureJournal.finalFileName))
    }

    func testBehaviorARecordingsLeadIsWrittenAsJournalsAlwaysWroteIt() throws {
        let mac = UUID()
        let session = MultipointSession(conversationID: UUID(), role: .macLed(macID: mac), leadStartedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let encoded = try JournalCoding.encoder().encode(session.journaled)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""role" : "macLed""#))
        let decoded = try JournalCoding.decoder().decode(CaptureMultipoint.self, from: encoded)
        XCTAssertEqual(decoded.role, .macLed)
        XCTAssertEqual(MultipointSession(conversationID: session.conversationID, journaled: decoded)?.role, .macLed(macID: mac))
        // A role a later build might write still recovers the recording, as this iPhone's own.
        let later = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "macLed", with: "watchLed")
        XCTAssertEqual(try JournalCoding.decoder().decode(CaptureMultipoint.self, from: Data(later.utf8)).role, .phoneLed)
    }

    func testBehaviorTheTimelineZeroIsTheOneRuleForNotesAndFiling() throws {
        let zero = Date(timeIntervalSince1970: 1_800_000_000)
        let session = MultipointSession(conversationID: UUID(), role: .macLed(macID: UUID()), leadStartedAt: zero.addingTimeInterval(30),
                                        timelineStart: zero, leadClockOffset: 0.5)
        XCTAssertEqual(session.timelineZero, zero.addingTimeInterval(-0.5))
        let older = MultipointSession(conversationID: UUID(), role: .macLed(macID: UUID()), leadStartedAt: zero.addingTimeInterval(30))
        XCTAssertEqual(older.timelineZero, zero.addingTimeInterval(30), "an older Mac began its timeline with its own recording")
    }

    func testBehaviorWaitingForTheFirstSampleEndsWhenItArrivesOrAfterABriefWhile() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Waits")
        let started = ContinuousClock.now
        await rig.recorder.waitForFirstSample()
        XCTAssertNil(rig.recorder.startedAt, "no audio arrived")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(1_000))
        rig.pump(0.5)
        await rig.recorder.waitForFirstSample()
        XCTAssertNotNil(rig.recorder.startedAt)
        _ = await rig.recorder.stop()
    }

    // MARK: iCloud

    func testBehaviorICloudsReasonsAreTypedWithTheirSentences() async {
        let unsigned = await CloudAvailability.check(container: "$(DAYBOOK_ICLOUD_CONTAINER)")
        XCTAssertEqual(unsigned.reason, .notSetUp)
        XCTAssertFalse(unsigned.settingsCanFix)
        let signedOut = await CloudAvailability.check(container: "iCloud.local.daybook", signedIn: { false })
        XCTAssertEqual(signedOut.reason, .signedOut)
        XCTAssertEqual(signedOut.message, CloudAvailability.signedOutMessage)
        XCTAssertTrue(signedOut.settingsCanFix)
        let other = CloudAvailability.unavailable("iCloud isn’t available for Daybook right now. Try again in a moment.")
        XCTAssertNil(other.reason)
        XCTAssertTrue(other.settingsCanFix)
        XCTAssertFalse(CloudAvailability.checking.settingsCanFix)
    }

    // MARK: What a model built for a test reaches

    func testBehaviorAModelForATestReachesNothingRealAndKeepsOutOfTheAppsPreferences() throws {
        let environment = try PhoneAppEnvironment.test(self)
        XCTAssertFalse(environment.startsLink)
        XCTAssertFalse(environment.makesCaptioners)
        XCTAssertFalse(environment.spotlight.isActive)
        XCTAssertEqual(environment.deviceMode, .inert)
        XCTAssertNil(environment.continuedProcessing())
        XCTAssertTrue(environment.linkKeys() is MemoryLinkKeyStore)
        XCTAssertNotEqual(environment.defaults, UserDefaults.standard)
        XCTAssertTrue(PhoneAppEnvironment.inert.modelRoot().path.hasPrefix(InertScratch.root.path), "a test host's models are scratch")

        let settings = PhoneSettings(defaults: environment.defaults)
        settings.showsLiveActivity = false
        XCTAssertEqual(environment.defaults.object(forKey: PhoneSettings.Keys.showsLiveActivity) as? Bool, false, "kept in the test's own suite")
    }

    func testBehaviorAnEarlierBuildsDecisionsDateGoes() {
        let defaults = makeTestDefaults("AppPlumbingTests")
        defaults.set(Date(), forKey: PhoneSettings.retiredDecisionsSinceKey)
        _ = PhoneSettings(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: PhoneSettings.retiredDecisionsSinceKey))
    }

    func testBehaviorEncryptingOverCellularIsReadThroughSettingsFromAnyQueue() async {
        let defaults = makeTestDefaults("AppPlumbingTests")
        let settings = PhoneSettings(defaults: defaults)
        settings.encryptsOverCellular = true
        let read = await Task.detached { settings.encryptsOverCellularNow }.value
        XCTAssertTrue(read)
    }

    // MARK: Words

    func testBehaviorCountsUseTheLanguagesPlurals() {
        XCTAssertEqual(SharedRecordingState.bookmarks(1), "1 bookmark")
        XCTAssertEqual(SharedRecordingState.bookmarks(3), "3 bookmarks")
        XCTAssertEqual(PhoneAppModel.importFailures(2), "Couldn’t import 2 files.")
        XCTAssertEqual(Meeting.defaultTitle(startingAt: Date(timeIntervalSince1970: 0)),
                       "Conversation at \(Date(timeIntervalSince1970: 0).formatted(date: .omitted, time: .shortened))")
    }
}
