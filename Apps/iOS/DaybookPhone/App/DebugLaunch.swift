import DaybookUI
import Foundation
import SwiftUI

/// Every debug launch argument, parsed once, for checking the app in the simulator without recording
/// anything real. The app builds one (`DaybookPhoneApp`), keeps it on the model (`PhoneAppModel.options`),
/// and puts it in the environment (`\.debugLaunch`).
///
/// Recording and devices:
///
///     --synthetic-audio          synthetic speech instead of the microphone; no audio session
///     --start-recording          start recording at launch (use with --synthetic-audio)
///     --demo-notes               type a few notes and add bookmarks while recording
///     --stop-after <seconds>     stop the recording after this long
///     --simulate-interruption <seconds>   a call interrupts the recording after this long and ends 4 s later (synthetic audio only)
///     --demo-multipoint <Mac name>        show the recording as also recording on that Mac (no network)
///     --demo-captions            scripted live captions while recording (no speech recognition)
///     --demo-recorder-only <name>  only that recorder records a shared recording; this iPhone's microphone didn't start
///                                (use with --synthetic-audio; nothing is recorded)
///     --interface-orientation portrait|landscape|preview-portrait   turn the interface in table mode, and the library
///                                (the simulator can't turn the device)
///     --write-notes              table mode opens with Write Notes on (notes on the standing half, the keyboard below)
///     --recorder-sheet mini|collapsed|expanded|full   open the recorder's sheet expanded to this level (without it: at rest)
///     --caption-probe [file]     log what live captions can do here (and, if ready, caption the file); never downloads
///     --device-simulator         Soundcore runs against DaybookDevices' simulated recorder
///     --device-autopilot         with --device-simulator: add the recorder, connect, and import
///     --handoff-demo <state>     with --device-simulator --device-autopilot: a recorder handoff state for screenshots
///                                (managed, asking, finishing, waiting, overdue, refused, connecting, done, handing)
///     --demo-live-captions       with --device-simulator --device-autopilot: the recorder records and streams scripted captions
///     --demo-transfer wifi|joining|other-app   with --device-simulator --device-autopilot: the next recording imports over the
///                                simulated recorder's Wi‑Fi (joining: held where iOS would ask to join it), or waits for
///                                another app's transfer, for screenshots
///
/// Sync and Macs:
///
///     --demo-link                paired Macs and a Mac to pair with, for Settings › Macs (no network)
///     --sync-folder <path>       sync through this folder instead of the iCloud container (relative: in the app's tmp)
///     --demo-mac <name>[:<hours>]  a Mac that last synced that many hours ago (2 when not given), in the sync folder
///
/// The library and reading:
///
///     --library <path>           use this folder as the library
///     --library-demo             fill a scratch library with every reading state (`ReadingDemo`; `--demo-library` too)
///     --speaker-demo             with --library-demo: speaker profiles, a Recognized speaker and a Maybe (`SpeakerProfileDemo`)
///     --import-file <path>       import this audio file at launch, as the share sheet does
///     --show-importer            open Import Audio's file picker at launch
///     --open-latest              open the newest conversation's page
///     --select, --page, --spread, --place, --search, --select-many, --sheet, --info, --scroll-to, --summary-scroll,
///     --play [<seconds>], --play-muted, --simulate-download, --simulate-offline
///                                a reading surface on screen (`reading`, `ReadingLaunch` has each one's values)
///     --info-scroll <id>         Info scrolled to that section
///     --info-detent large        Info at full height
///     --history-change <title>   Version History with that change open
///     --placement-demo countdown|waiting|cloud|mac-countdown|colophon   where a summary runs (`PhonePlacementDemo`)
///     --upgrade-demo mac|here|cloud|waiting   with --library-demo: an "Upgrade" offer on Weekly product sync (`PhoneUpgradeDemo`)
///     --lock-demo locked|unlocked|focus   the Personal lock on and locked or unlocked, or a Focus hiding Personal; Unlock is
///                                refused, so Face ID is never asked (DaybookKit's `PersonalLockDemo`, read in `DaybookPhoneApp`)
///
/// Settings and the status sheet:
///
///     --open-settings [<screen>] Settings, at a screen (`SettingsScreen`): icloud, macs, devices, device, device-details,
///                                device-live, device-recordings, pairing, storage, models, cloud, cloud-key, templates, template, vocabulary,
///                                speaker-profiles, speaker-profile:<name>, recording, library-devices, about,
///                                acknowledgements, add-device (straight to Soundcore's setup), add-recorder (the list of
///                                kinds), add-term (Vocabulary with Add Term showing)
///     --scroll-end               a Settings screen opened with --open-settings, scrolled to its foot
///     --cloud-demo none|anthropic|both|never|failed   Settings › Cloud with in-memory keys and the catalog's models (no
///                                network, no keychain); open it with --open-settings cloud (failed: cloud-key)
///     --profile-name <name>, --merge-into <name>, --confirm-merge   a speaker profile's page, its Merge Into, and the
///                                merge's confirmation
///     --status-detent medium|large   open the status sheet at this size (on the right page when open)
///     --status-scroll-end        the status sheet's content scrolled to its foot
///     --status-open device|mac|storage|icloud|add-recorder   the status sheet at full height, showing that screen
///     --status-demo phone-working|phone-paused   this iPhone's own work in the status strip and sheet (`StatusSheetDemo`)
///     --status-choose mac|sync|recorder   tap that line as the status strip would, for screenshots of where it leads
///
/// The device:
///
///     --posture closed|open|partial[:degrees]   force the fold posture (`DevicePosture`, which reads it in every build:
///                                it only changes layout)
///     --show-posture             show the posture in a small badge
///     --log-geometry             log window size, safe area, screen, and posture on every change
///
/// Release builds ignore every one of them except `--posture`.
struct DebugLaunch {
    var syntheticAudio = false
    var startRecording = false
    var demoNotes = false
    var stopAfter: TimeInterval?
    var interruptAfter: TimeInterval?
    var demoMultipointMac: String?
    var demoLink = false
    var syncFolder: String?
    var demoMac: DemoMac?
    var deviceSimulator = false
    var deviceAutopilot = false
    var importFile: String?
    var showImporter = false
    var demoCaptions = false
    var writeNotes = false
    var recorderSheet: RecorderSheetSize?
    var demoInk = false
    var demoInkWriting = false
    var interfaceOrientation: String?
    var captionProbe: String?
    var settingsPage: SettingsPage?
    var scrollEnd = false
    var showPosture = false
    var logGeometry = false
    var openLatest = false
    var libraryPath: String?
    var statusDetent: StatusDetent?
    var statusScrollEnd = false
    var statusPage: StatusPage?
    var handoffDemo: HandoffDemo?
    var demoLiveCaptions = false
    var demoRecorderOnly: String?
    var demoTransfer: TransferDemo?
    var placementDemo: String?
    var upgradeDemo: String?
    var cloudDemo: String?
    var infoScroll: String?
    var infoDetent: String?
    var historyChange: String?
    var profileName: String?
    var mergeInto: String?
    var confirmMerge = false
    var libraryDemo = false
    var speakerDemo = false
    var simulateDownload = false
    var simulateOffline = false
    /// The reading surface's arguments (`--select`, `--page`, `--sheet`…), as `ReadingLaunch` reads them.
    var reading: ReadingLaunch
    /// Hosted unit tests: no recovery, no Live Activities, an inert UI. The one place the app asks
    /// whether it runs tests; what the app reaches in the system follows `PhoneAppEnvironment`.
    var isRunningTests = false

    /// A Mac's presence for `--demo-mac`: its name, and how long ago it last synced.
    struct DemoMac: Equatable, Sendable {
        var name: String
        var hoursAgo: Double
    }

    /// `--open-settings <screen>`: the Settings screen to open.
    enum SettingsPage: Equatable, Sendable {
        case root, icloud, macs, devices, device, deviceDetails, deviceLive, deviceRecordings, pairing, storage, models, cloud,
             cloudKey, templates,
             template, vocabulary, speakerProfiles, recording, libraryDevices, about, acknowledgements, addDevice,
             addRecorder, addTerm
        /// A speaker profile's page, by its name.
        case speakerProfile(String)

        static let plain: [(String, SettingsPage)] = [
            ("root", .root), ("icloud", .icloud), ("macs", .macs), ("devices", .devices), ("device", .device),
            ("device-details", .deviceDetails), ("device-live", .deviceLive), ("device-recordings", .deviceRecordings),
            ("pairing", .pairing), ("storage", .storage), ("models", .models),
            ("cloud", .cloud), ("cloud-key", .cloudKey), ("templates", .templates), ("template", .template),
            ("vocabulary", .vocabulary), ("speaker-profiles", .speakerProfiles), ("recording", .recording),
            ("library-devices", .libraryDevices), ("about", .about), ("acknowledgements", .acknowledgements),
            ("add-device", .addDevice), ("add-recorder", .addRecorder), ("add-term", .addTerm),
        ]
        private static let profilePrefix = "speaker-profile:"

        init?(argument: String) {
            if argument.hasPrefix(Self.profilePrefix) {
                let name = String(argument.dropFirst(Self.profilePrefix.count))
                guard !name.isEmpty else { return nil }
                self = .speakerProfile(name)
                return
            }
            guard let page = Self.plain.first(where: { $0.0 == argument })?.1 else { return nil }
            self = page
        }

        /// How the flag spells it.
        var argument: String {
            if case .speakerProfile(let name) = self { return Self.profilePrefix + name }
            return Self.plain.first { $0.1 == self }?.0 ?? "root"
        }
    }

    /// `--status-open <screen>`: the status sheet at full height, showing that screen.
    enum StatusPage: String, Equatable, Sendable {
        case device, mac, storage, icloud
        case addRecorder = "add-recorder"
    }

    /// `--handoff-demo <state>`: a recorder handoff state for screenshots.
    enum HandoffDemo: String, Equatable, Sendable, CaseIterable {
        case managed, asking, finishing, waiting, overdue, refused, connecting, done, handing

        /// The states that begin with a Mac holding the recorder.
        var startsManagedByMac: Bool { [.managed, .asking, .finishing, .waiting, .overdue, .refused].contains(self) }
    }

    /// `--demo-transfer wifi|joining|other-app`: how the next simulated recording imports.
    enum TransferDemo: String, Equatable, Sendable {
        case wifi
        /// Over Wi‑Fi, held where iOS would ask to join the recorder's network.
        case joining
        case otherApp = "other-app"
    }

    /// `openSettings` as a string, for screens that still match the flag's spelling.
    var openSettings: String? { settingsPage?.argument }
    /// `statusOpen` as a string, likewise.
    var statusOpen: String? { statusPage?.rawValue }
    /// `--status-choose mac|sync|recorder`: the compact status sheet's line to tap.
    var statusChoose: String?

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        isRunningTests = Self.hostsTests(environment)
        reading = ReadingLaunch(arguments: arguments)
        #if DEBUG
        func value(_ flag: String) -> String? { Self.value(after: flag, in: arguments) }
        func has(_ flag: String) -> Bool { arguments.contains(flag) }
        syntheticAudio = has("--synthetic-audio")
        startRecording = has("--start-recording")
        demoNotes = has("--demo-notes")
        showPosture = has("--show-posture")
        logGeometry = has("--log-geometry")
        openLatest = has("--open-latest")
        demoLink = has("--demo-link")
        deviceSimulator = has("--device-simulator")
        deviceAutopilot = has("--device-autopilot")
        showImporter = has("--show-importer")
        demoCaptions = has("--demo-captions")
        writeNotes = has("--write-notes")
        recorderSheet = value("--recorder-sheet").flatMap(RecorderSheetSize.init(rawValue:))
        demoInk = has("--demo-ink")
        demoInkWriting = has("--demo-ink-writing")
        interfaceOrientation = value("--interface-orientation")
        if has("--caption-probe") { captionProbe = value("--caption-probe") ?? "" }
        stopAfter = value("--stop-after").flatMap(TimeInterval.init)
        interruptAfter = value("--simulate-interruption").flatMap(TimeInterval.init)
        demoMultipointMac = value("--demo-multipoint")
        // A relative folder is inside the app's temporary directory (handy in the simulator).
        syncFolder = value("--sync-folder").map { path in
            path.hasPrefix("/") ? path : FileManager.default.temporaryDirectory.appendingPathComponent(path, isDirectory: true).path
        }
        importFile = value("--import-file")
        libraryPath = value("--library")
        statusDetent = value("--status-detent").flatMap(StatusDetent.init(rawValue:))
        statusScrollEnd = has("--status-scroll-end")
        statusPage = value("--status-open").flatMap(StatusPage.init(rawValue:))
        statusChoose = value("--status-choose")
        scrollEnd = has("--scroll-end")
        handoffDemo = value("--handoff-demo").flatMap(HandoffDemo.init(rawValue:))
        demoLiveCaptions = has("--demo-live-captions")
        demoRecorderOnly = value("--demo-recorder-only")
        demoTransfer = value("--demo-transfer").flatMap(TransferDemo.init(rawValue:))
        if has("--open-settings") { settingsPage = value("--open-settings").map { SettingsPage(argument: $0) ?? .root } ?? .root }
        demoMac = value("--demo-mac").flatMap(Self.demoMac)
        placementDemo = value("--placement-demo")
        upgradeDemo = value("--upgrade-demo")
        cloudDemo = value("--cloud-demo")
        infoScroll = value("--info-scroll")
        infoDetent = value("--info-detent")
        historyChange = value("--history-change")
        profileName = value("--profile-name")
        mergeInto = value("--merge-into")
        confirmMerge = has("--confirm-merge")
        libraryDemo = has("--library-demo") || has("--demo-library")
        speakerDemo = has("--speaker-demo")
        simulateDownload = has("--simulate-download")
        simulateOffline = has("--simulate-offline")
        #endif
    }

    /// The value after `flag`, unless that's the next flag: `--open-settings --scroll-end` has none.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--") else { return nil }
        return arguments[index + 1]
    }

    /// `name[:hours]`; nil without a name (`--demo-mac :3`, `--demo-mac :`).
    static func demoMac(_ value: String) -> DemoMac? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        return DemoMac(name: name, hoursAgo: parts.count > 1 ? Double(parts[1]) ?? 2 : 2)
    }

    /// Whether `environment` is a hosted test run's.
    static func hostsTests(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    /// Whether this process hosts unit tests, whatever a value says: for code that has no `DebugLaunch` at hand
    /// (`PhoneDevices`). The app model asks its `PhoneAppEnvironment` instead.
    static var isTestHost: Bool { hostsTests(ProcessInfo.processInfo.environment) }
}

/// The name the rest of the app knows the launch arguments by.
typealias LaunchOptions = DebugLaunch

extension EnvironmentValues {
    /// The app's debug launch arguments (`DebugLaunch`), for views that set themselves up for a screenshot.
    @Entry var debugLaunch = DebugLaunch(arguments: [], environment: [:])
}
