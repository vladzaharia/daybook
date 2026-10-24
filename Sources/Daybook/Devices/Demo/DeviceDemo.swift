#if DEBUG
import AppKit
import DaybookCaptions
import DaybookCore
import DaybookDevices
import DaybookKit
import SwiftUI

/// Debug-only representative states for every device surface, without Bluetooth or a recorder:
///
///     --device-demo <scenario>
///
/// Scenarios: connected, importing, selected, imported, not-connected, reconnecting, connecting,
/// error (disconnected during import), integrity, stalled, bluetooth-off, denied, rejected,
/// live, recording, low-storage, empty, folder (Soundcore through its export folder only),
/// other (an Other Recorder), other-empty, folder-missing, setup (Add Device), setup-soundcore,
/// scanning, not-found, connecting-setup, details (Device Details open), settings, none.
///
/// `--place device` opens the first device (the scenario does this itself); `--device other`
/// opens the Other Recorder instead. `--snapshot-appearance light|dark` sets the appearance.
/// `--device-simulator` instead runs the real Soundcore connection against a simulated recorder
/// (in a throwaway preferences suite); `--autopilot` then sets it up, connects, and imports on its own.
enum DeviceDemoScenario: String, CaseIterable {
    case connected, importing, selected, imported, notConnected = "not-connected", reconnecting, connecting
    case error, integrity, stalled, bluetoothOff = "bluetooth-off", denied, rejected
    case live, recording, lowStorage = "low-storage", empty, folder, other, otherEmpty = "other-empty"
    case folderMissing = "folder-missing", setup, setupSoundcore = "setup-soundcore", scanning, notFound = "not-found"
    case connectingSetup = "connecting-setup", details, settings, none
}

@MainActor
enum DeviceDemo {
    static let scenario: DeviceDemoScenario? = LaunchOptions.value(after: "--device-demo").flatMap(DeviceDemoScenario.init(rawValue:))
    static let usesSimulator = CommandLine.arguments.contains("--device-simulator")
    static let simulatorSuite = "local.daybook.device-simulator"
    static var isRequested: Bool { scenario != nil }

    /// Hands the hub what a demo or the simulator replaces. Call before the hub is made.
    static func install() {
        DeviceHub.demo = DeviceHubDemo(transport: transport, simulatorSuite: usesSimulator ? simulatorSuite : nil,
                                       isRequested: isRequested, load: { load(into: $0) }, prepareSetup: { prepareSetup($0) })
    }

    /// Demos use an inert link and the simulator a simulated recorder: neither touches Bluetooth.
    static var transport: (() -> any SoundcoreTransport)? {
        if usesSimulator { return { SimulatedSoundcoreTransport(device: .demo()) } }
        if isRequested { return { InertSoundcoreTransport() } }
        return nil
    }

    private static let soundcoreID = "demo-soundcore"
    private static let otherID = "demo-other"
    private static let peripheral = UUID(uuidString: "5C0DC0DE-0000-4000-8000-00000000D320")!
    private static let serial = "D3200A21F07F3A"

    // MARK: Fixtures

    /// A local time `days` ago as a device recording ID (its Unix start time).
    private static func id(daysAgo days: Int, _ hour: Int, _ minute: Int) -> UInt32 {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -days, to: Date())!
        var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        if date > Date() { date = calendar.date(byAdding: .day, value: -1, to: date)! }
        return UInt32(date.timeIntervalSince1970)
    }

    private static func recording(_ id: UInt32, minutes: Double, exact: Bool = true) -> SoundcoreRecording {
        let seconds = minutes * 60
        return SoundcoreRecording(id: id, size: UInt32(seconds * SoundcoreRecording.bytesPerSecond),
                                  endTimestamp: exact ? id + UInt32(seconds) : nil)
    }

    static var newRecordings: [SoundcoreRecording] {
        [recording(id(daysAgo: 0, 10, 2), minutes: 48),
         recording(id(daysAgo: 1, 15, 28), minutes: 72),
         recording(id(daysAgo: 3, 9, 15), minutes: 22, exact: false)]
    }

    /// At the times the demo library's conversations were recorded, so they match.
    static var importedRecordings: [SoundcoreRecording] {
        [recording(id(daysAgo: 2, 11, 0), minutes: 35),
         recording(id(daysAgo: 5, 9, 0), minutes: 63),
         recording(id(daysAgo: 8, 17, 0), minutes: 50),
         recording(id(daysAgo: 12, 19, 30), minutes: 41),
         recording(id(daysAgo: 20, 14, 0), minutes: 45),
         recording(id(daysAgo: 26, 16, 0), minutes: 28)]
    }

    private static var info: SoundcoreDeviceInfo {
        SoundcoreDeviceInfo(microphoneBattery: 80, caseBattery: 60, microphoneCharging: false, caseCharging: true,
                            firmware: "2.1.4", caseFirmware: "1.0.9", serial: serial,
                            totalBytes: 7_200_000_000, freeBytes: 6_100_000_000, isRecording: false)
    }

    private static func snapshot(lastSeen: Date, recordings: [SoundcoreRecording]) -> SoundcoreSnapshot {
        var snapshot = SoundcoreSnapshot(deviceID: peripheral, name: "soundcore Work")
        snapshot.apply(info, at: lastSeen)
        snapshot.lastConnectedAt = lastSeen
        snapshot.recordings = recordings
        snapshot.recordingsUpdatedAt = lastSeen
        return snapshot
    }

    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Daybook Import", isDirectory: true)
    }

    private static func file(_ name: String, megabytes: Double, hoursAgo: Double) -> DeviceRecording {
        let size = Int(megabytes * 1_000_000)
        return DeviceRecording(id: ImportFolderWatcher.recordingID(name: name, size: size), startedAt: nil, length: nil,
                               byteCount: UInt64(size), fileName: name, addedAt: Date().addingTimeInterval(-hoursAgo * 3_600))
    }

    // MARK: Loading

    private static var includesSoundcore: Bool {
        guard let scenario else { return false }
        return ![.other, .otherEmpty, .folderMissing, .setup, .setupSoundcore, .scanning, .notFound, .connectingSetup, .none].contains(scenario)
    }

    private static var includesOther: Bool {
        guard let scenario else { return false }
        return ![.setup, .scanning, .notFound, .connectingSetup, .none].contains(scenario)
    }

    static func load(into hub: DeviceHub) {
        guard let scenario else { return }
        var devices: [ConfiguredDevice] = []
        let added = Date().addingTimeInterval(-40 * 86_400)
        if includesSoundcore {
            var device = ConfiguredDevice(id: soundcoreID, kind: SoundcoreWorkIntegration().kind, addedAt: added)
            device.automaticImportsSince = .distantFuture
            devices.append(device)
        }
        if includesOther {
            devices.append(ConfiguredDevice(id: otherID, kind: OtherRecorderIntegration().kind, name: "Zoom H1n", addedAt: added))
        }
        for session in hub.loadDemo(devices) {
            session.demoFrozen = true
            if session.id == soundcoreID { applySoundcore(scenario, session) }
            if session.id == otherID { applyOther(scenario, session) }
        }
    }

    private static func applySoundcore(_ scenario: DeviceDemoScenario, _ session: DeviceSession) {
        guard let direct = session.direct as? SoundcoreConnection, let files = session.files else { return }
        let now = Date()
        let all = newRecordings + importedRecordings
        let imported = importedRecordings
        session.demoLinks = { meetings in links(for: imported, in: meetings) }
        files.applyDemo(folder: folder, recordings: [], completed: [], lastImport: now.addingTimeInterval(-7_400))

        let standard = info
        func connected(_ status: SoundcoreDeviceInfo? = nil, recordings: [SoundcoreRecording]? = nil, active: UInt32? = nil) {
            let recordings = recordings ?? all
            direct.applyDemo(phase: .connected(peripheral), remembered: snapshot(lastSeen: now, recordings: recordings),
                             info: status ?? standard, listing: recordings, activeRecordingID: active)
        }
        func disconnected(problem: DeviceProblem? = nil, phase: SoundcoreConnection.Phase = .idle, attempt: Int = 0) {
            direct.applyDemo(phase: phase, remembered: snapshot(lastSeen: now.addingTimeInterval(-9_000), recordings: all),
                             info: nil, listing: all, activeRecordingID: nil, problem: problem, reconnectAttempt: attempt)
        }
        let queueOf: (Bool) -> DeviceImportQueue = { suspended in
            var queue = DeviceImportQueue()
            queue.enqueue(newRecordings.map { $0.deviceRecording() }, method: .direct)
            _ = queue.startNext()
            if suspended { queue.failCurrent(requeue: true) }
            return queue
        }
        switch scenario {
        case .connected, .settings, .details:
            connected()
            if scenario == .details {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    session.browser.showsTechnicalDetails = true
                    session.browser.showingDetails = true
                }
            }
        case .selected:
            connected()
            session.browser.selection = [.recording(String(newRecordings[1].id))]
        case .imported:
            connected()
            session.browser.showsImported = true
            session.browser.selection = [.recording(String(imported[1].id))]
        case .importing:
            connected()
            session.applyDemo(queue: queueOf(false), phase: .receiving(fraction: 0.64), secondsLeft: 372, failures: [],
                              transferProblem: nil, receivedBytes: 1_843_200)
        case .notConnected:
            disconnected()
        case .reconnecting:
            disconnected(phase: .backingOff(attempt: 2), attempt: 2)
        case .connecting:
            disconnected(phase: .connecting(peripheral))
        case .error:
            disconnected()
            session.applyDemo(queue: queueOf(true), phase: nil, secondsLeft: nil, failures: [],
                              transferProblem: SoundcoreIssue.disconnectedDuringImport.problem)
        case .integrity, .stalled:
            connected()
            let issue: SoundcoreIssue = scenario == .integrity ? .integrity : .stalled
            session.applyDemo(queue: DeviceImportQueue(), phase: nil, secondsLeft: nil,
                              failures: [DeviceImportFailure(recording: newRecordings[2].deviceRecording(), method: .direct,
                                                             message: scenario == .integrity ? "Some audio didn’t arrive intact." : "Stopped sending audio.",
                                                             date: now.addingTimeInterval(-60))],
                              transferProblem: issue.problem)
        case .bluetoothOff:
            disconnected(problem: SoundcoreIssue.bluetoothOff.problem, phase: .unavailable(.poweredOff))
        case .denied:
            disconnected(problem: SoundcoreIssue.bluetoothDenied.problem, phase: .unavailable(.unauthorized))
        case .rejected:
            disconnected(problem: SoundcoreIssue.rejected.problem)
        case .live, .recording:
            var recordingInfo = info
            recordingInfo.isRecording = true
            let active = UInt32(now.timeIntervalSince1970 - 761)
            connected(recordingInfo, active: active)
            session.browser.selection = [.recordingNow]
            if scenario == .live {
                direct.live.isListening = true
                direct.live.receivedSeconds = 236
                direct.live.captions = [
                    LiveCaptionSegment(start: 221.4, end: 225.8, text: "So the launch moves to the 14th, and Priya owns the checklist.", isTentative: false),
                    LiveCaptionSegment(start: 226.3, end: 230.9, text: "We still need legal to sign off on the pricing page before Friday.", isTentative: false),
                    LiveCaptionSegment(start: 231.6, end: 233.2, text: "I’ll send the deck around", isTentative: true)
                ]
                direct.live.captionState = .listening
            }
        case .lowStorage:
            var low = info
            low.freeBytes = 172_800_000
            low.microphoneBattery = 20
            low.caseCharging = false
            connected(low)
        case .empty:
            connected(recordings: imported)
        case .folder:
            direct.applyDemo(phase: .idle, remembered: nil, info: nil, listing: [], activeRecordingID: nil)
            files.applyDemo(folder: folder,
                            recordings: [file("Weekly sync.mp3", megabytes: 21.4, hoursAgo: 2), file("Client call.m4a", megabytes: 9.8, hoursAgo: 30)],
                            completed: [], lastImport: now.addingTimeInterval(-7_400))
            session.demoLinks = { meetings in
                var links = DeviceLibraryLinks()
                if let meeting = meetings.first(where: { $0.title == "Weekly product sync" }) {
                    links.imported[ImportFolderWatcher.recordingID(name: "Weekly sync.mp3", size: 21_400_000)] = meeting.id
                    links.recent = [.init(recordingID: ImportFolderWatcher.recordingID(name: "Weekly sync.mp3", size: 21_400_000),
                                          meetingID: meeting.id, trackID: UUID(), importedAt: now.addingTimeInterval(-7_400), fileName: "Weekly sync.mp3")]
                }
                return links
            }
        default:
            connected()
        }
    }

    private static func applyOther(_ scenario: DeviceDemoScenario, _ session: DeviceSession) {
        guard let files = session.files else { return }
        let now = Date()
        switch scenario {
        case .otherEmpty:
            files.applyDemo(folder: folder.deletingLastPathComponent().appendingPathComponent("Recorder"), recordings: [], completed: [],
                            lastImport: nil)
        case .folderMissing:
            files.applyDemo(folder: folder.deletingLastPathComponent().appendingPathComponent("Recorder"), recordings: [], completed: [],
                            lastImport: now.addingTimeInterval(-90_000), problem: ImportFolderWatcher.missing)
        default:
            let failed = file("ZOOM0007.WAV", megabytes: 2.1, hoursAgo: 3)
            let recordings = [file("ZOOM0009.WAV", megabytes: 58.2, hoursAgo: 0.4), failed,
                              file("ZOOM0004.WAV", megabytes: 101.7, hoursAgo: 50), file("ZOOM0002.WAV", megabytes: 74.3, hoursAgo: 140)]
            files.applyDemo(folder: folder.deletingLastPathComponent().appendingPathComponent("Recorder"), recordings: recordings,
                            completed: Set(recordings.map(\.id)), lastImport: now.addingTimeInterval(-1_500))
            session.applyDemo(queue: DeviceImportQueue(), phase: nil, secondsLeft: nil,
                              failures: [DeviceImportFailure(recording: failed, method: .files, message: "Couldn’t read this file.",
                                                             date: now.addingTimeInterval(-10_000))],
                              transferProblem: nil)
            session.demoLinks = { meetings in
                var links = DeviceLibraryLinks()
                let titles = ["Distributed systems, week 6", "Backend engineer interview"]
                for (recording, title) in zip([recordings[2], recordings[3]], titles) {
                    guard let meeting = meetings.first(where: { $0.title == title }) else { continue }
                    links.imported[recording.id] = meeting.id
                    links.recent.append(.init(recordingID: recording.id, meetingID: meeting.id, trackID: UUID(),
                                              importedAt: recording.addedAt ?? now, fileName: recording.fileName ?? ""))
                }
                return links
            }
        }
    }

    /// Demo links: each imported recording matched to the conversation nearest its start time.
    private static func links(for imported: [SoundcoreRecording], in meetings: [Meeting]) -> DeviceLibraryLinks {
        var links = DeviceLibraryLinks()
        for recording in imported {
            let start = Date(timeIntervalSince1970: TimeInterval(recording.id))
            guard let meeting = meetings.min(by: { abs($0.date.timeIntervalSince(start)) < abs($1.date.timeIntervalSince(start)) }),
                  abs(meeting.date.timeIntervalSince(start)) < 3_600 else { continue }
            links.imported[String(recording.id)] = meeting.id
            links.recent.append(.init(recordingID: String(recording.id), meetingID: meeting.id, trackID: UUID(),
                                      importedAt: start.addingTimeInterval(TimeInterval(recording.size) / 8_000 + 600), fileName: ""))
        }
        links.recent.sort { $0.importedAt > $1.importedAt }
        links.recent = Array(links.recent.prefix(4))
        return links
    }

    // MARK: Simulator autopilot

    /// `--device-simulator --autopilot`: sets up the simulated recorder through the real Add Device
    /// flow, connects to it, and imports everything new, so the whole path can be watched or captured.
    private static func autopilot(_ state: AppState) {
        state.requestAddDevice(kind: SoundcoreWorkIntegration.id, method: .direct)
        Task { @MainActor in
            func wait(_ condition: () -> Bool) async -> Bool {
                for _ in 0..<300 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
                return false
            }
            guard await wait({ (state.devices.pendingSetup?.direct as? SoundcoreConnection)?.discovered.isEmpty == false }),
                  let direct = state.devices.pendingSetup?.direct as? SoundcoreConnection else { return }
            try? await Task.sleep(for: .seconds(1.5))
            direct.connect(to: direct.discovered[0])
            guard await wait({ state.selectedDevice?.isLinked == true && state.selectedDevice?.newRecordings.isEmpty == false }),
                  let session = state.selectedDevice else { return }
            try? await Task.sleep(for: .seconds(1.5))
            session.importRecordings(session.newRecordings)
        }
    }

    // MARK: Setup demos

    /// A device being set up during a setup demo shows found recorders, nothing found, or connecting.
    static func prepareSetup(_ session: DeviceSession) {
        guard let scenario, let direct = session.direct as? SoundcoreConnection else { return }
        session.demoFrozen = true
        let found = [DiscoveredRecorder(id: peripheral.uuidString, name: "soundcore Work", signal: .nearby),
                     DiscoveredRecorder(id: UUID().uuidString, name: "soundcore Work · 2", signal: .fartherAway)]
        switch scenario {
        case .scanning:
            direct.applyDemo(phase: .searching(target: nil), remembered: nil, info: nil, listing: [], activeRecordingID: nil, discovered: found)
        case .notFound:
            direct.applyDemo(phase: .idle, remembered: nil, info: nil, listing: [], activeRecordingID: nil, searchFoundNothing: true)
        case .connectingSetup:
            direct.applyDemo(phase: .connecting(peripheral), remembered: nil, info: nil, listing: [], activeRecordingID: nil,
                             discovered: found, connectingTo: peripheral.uuidString)
        default:
            break
        }
    }

    // MARK: The window

    /// Opens the scenario's place, selection, and sheet once the library is ready.
    static func apply(to state: AppState) {
        if let appearance = LaunchOptions.value(after: "--snapshot-appearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if usesSimulator, CommandLine.arguments.contains("--autopilot") { autopilot(state) }
        guard let scenario else { return }
        HandoffDemo.apply(to: state)
        let wantsOther = LaunchOptions.value(after: "--device") == "other"
        if let session = wantsOther ? state.devices.session(otherID) : (state.devices.session(soundcoreID) ?? state.devices.sessions.first) {
            state.place = .device(session.id)
        }
        switch scenario {
        case .setup: state.addDeviceRequest = AddDeviceRequest()
        case .setupSoundcore: state.addDeviceRequest = AddDeviceRequest(kindID: SoundcoreWorkIntegration.id)
        case .scanning, .notFound, .connectingSetup:
            state.addDeviceRequest = AddDeviceRequest(kindID: SoundcoreWorkIntegration.id, method: .direct)
        default: break
        }
    }
}
#endif
