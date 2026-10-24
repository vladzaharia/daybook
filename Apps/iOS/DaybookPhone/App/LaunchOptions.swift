import Foundation

/// Debug launch arguments for checking the app in the simulator without recording anything real:
///
///     --synthetic-audio          synthetic speech instead of the microphone; no audio session
///     --start-recording          start recording at launch (use with --synthetic-audio)
///     --demo-notes               type a few notes and add bookmarks while recording
///     --stop-after <seconds>     stop the recording after this long
///     --simulate-interruption <seconds>   a call interrupts the recording after this long and ends 4 s later (synthetic audio only)
///     --demo-multipoint <Mac name>        show the recording as also recording on that Mac (no network)
///     --demo-link                paired Macs and a Mac to pair with, for Settings › Macs (no network)
///     --sync-folder <path>       sync through this folder instead of the iCloud container
///     --demo-mac <name>:<hours>  a Mac that last synced that many hours ago, in the sync folder
///     --device-simulator         Soundcore runs against DaybookDevices' simulated recorder
///     --device-autopilot         with --device-simulator: add the recorder, connect, and import
///     --import-file <path>       import this audio file at launch, as the share sheet does
///     --show-importer            open Import Audio's file picker at launch
///     --demo-captions            scripted live captions while recording (no speech recognition)
///     --interface-orientation portrait|landscape   turn the interface in table mode (the simulator can't turn the device)
///     --caption-probe [file]     log what live captions can do here (and, if ready, caption the file); never downloads
///     --open-settings [macs|devices|device|pairing|storage|templates|vocabulary|recording|add-device]
///     --posture closed|open|partial[:degrees]   force the fold posture (see DevicePosture)
///     --show-posture             show the posture in a small badge
///     --log-geometry             log window size, safe area, screen, and posture on every change
///     --open-latest              open the newest conversation's page
///     --library <path>           use this folder as the library
///     --status-detent compact|medium|large   open the status sheet (or the notebook's status panel) at this size
///     --handoff-demo <state>     with --device-simulator --device-autopilot: a recorder handoff state for screenshots
///                                (managed, asking, finishing, waiting, overdue, refused, connecting, done, handing)
///     --demo-live-captions       with --device-simulator --device-autopilot: the recorder records and streams scripted captions
///
/// Release builds ignore all of them except --posture, which only changes layout.
struct LaunchOptions {
    var syntheticAudio = false
    var startRecording = false
    var demoNotes = false
    var stopAfter: TimeInterval?
    var interruptAfter: TimeInterval?
    var demoMultipointMac: String?
    var demoLink = false
    var syncFolder: String?
    var demoMac: (name: String, hoursAgo: Double)?
    var deviceSimulator = false
    var deviceAutopilot = false
    var importFile: String?
    var showImporter = false
    var demoCaptions = false
    var interfaceOrientation: String?
    var captionProbe: String?
    var openSettings: String?
    var showPosture = false
    var logGeometry = false
    var openLatest = false
    var libraryPath: String?
    var statusDetent: StatusDetent?
    var handoffDemo: String?
    var demoLiveCaptions = false
    /// Hosted unit tests: no recovery, no Live Activities, an inert UI.
    var isRunningTests = false

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        isRunningTests = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        #if DEBUG
        syntheticAudio = arguments.contains("--synthetic-audio")
        startRecording = arguments.contains("--start-recording")
        demoNotes = arguments.contains("--demo-notes")
        showPosture = arguments.contains("--show-posture")
        logGeometry = arguments.contains("--log-geometry")
        openLatest = arguments.contains("--open-latest")
        demoLink = arguments.contains("--demo-link")
        deviceSimulator = arguments.contains("--device-simulator")
        deviceAutopilot = arguments.contains("--device-autopilot")
        showImporter = arguments.contains("--show-importer")
        demoCaptions = arguments.contains("--demo-captions")
        interfaceOrientation = Self.value(after: "--interface-orientation", in: arguments)
        if arguments.contains("--caption-probe") {
            let next = Self.value(after: "--caption-probe", in: arguments)
            captionProbe = next.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? ""
        }
        stopAfter = Self.value(after: "--stop-after", in: arguments).flatMap(TimeInterval.init)
        interruptAfter = Self.value(after: "--simulate-interruption", in: arguments).flatMap(TimeInterval.init)
        demoMultipointMac = Self.value(after: "--demo-multipoint", in: arguments)
        // A relative folder is inside the app's temporary directory (handy in the simulator).
        syncFolder = Self.value(after: "--sync-folder", in: arguments).map { path in
            path.hasPrefix("/") ? path : FileManager.default.temporaryDirectory.appendingPathComponent(path, isDirectory: true).path
        }
        importFile = Self.value(after: "--import-file", in: arguments)
        libraryPath = Self.value(after: "--library", in: arguments)
        statusDetent = Self.value(after: "--status-detent", in: arguments).flatMap(StatusDetent.init(rawValue:))
        handoffDemo = Self.value(after: "--handoff-demo", in: arguments)
        demoLiveCaptions = arguments.contains("--demo-live-captions")
        if arguments.contains("--open-settings") {
            let next = Self.value(after: "--open-settings", in: arguments)
            openSettings = next.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "root"
        }
        if let value = Self.value(after: "--demo-mac", in: arguments) {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            demoMac = (parts[0], parts.count > 1 ? Double(parts[1]) ?? 2 : 2)
        }
        #endif
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Whether this process hosts unit tests, whatever the options say (services then stay inert).
    static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }
}
