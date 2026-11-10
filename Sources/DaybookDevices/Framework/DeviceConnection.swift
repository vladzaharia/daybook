import DaybookCaptions
import DaybookCore
import Foundation
import Observation

// The common interface every connection method implements, and the optional abilities some add.

/// Where a connection is, in words the interface can use directly.
public enum ConnectionState: Equatable {
    /// The method has no configuration yet: no recorder remembered, no folder chosen.
    case notSetUp
    case notConnected
    /// Looking for the recorder.
    case searching
    case connecting
    /// The link dropped unexpectedly and Daybook is trying again on its own.
    case reconnecting
    /// Connected to the recorder, or watching the folder.
    case connected
    /// The radio is off, permission is denied, or the folder is gone: see `problem`.
    case unavailable

    public var isConnected: Bool { self == .connected }
    public var isBusy: Bool { [.searching, .connecting, .reconnecting].contains(self) }
}

/// What a connection can do beyond listing and importing. The device page shows only what's here.
public struct DeviceCapabilities: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let battery = Self(rawValue: 1 << 0)
    public static let caseBattery = Self(rawValue: 1 << 1)
    public static let storage = Self(rawValue: 1 << 2)
    public static let liveListening = Self(rawValue: 1 << 3)
    public static let recordControl = Self(rawValue: 1 << 4)
    /// Firmware, serial number, and technical facts in Device Details.
    public static let details = Self(rawValue: 1 << 5)
    /// Transfers that need the recorder nearby; the page says so while importing.
    public static let wirelessTransfer = Self(rawValue: 1 << 6)
}

/// A recording on a recorder or in its export folder.
public struct DeviceRecording: Identifiable, Hashable {
    /// Stable across launches and Macs, stored on the imported track: a Soundcore recording's
    /// start time, or a file's name and size.
    public let id: String
    public var startedAt: Date?
    public var length: RecordingLength?
    public var byteCount: UInt64?
    /// Still being recorded: shown as "Recording now", never offered for import.
    public var isInProgress = false
    /// A file name, for recordings that have one.
    public var fileName: String?
    /// When a file appeared, for recordings without a start time.
    public var addedAt: Date?

    /// "Today, 10:02 AM", or the file name when there's no start time.
    public var title: String {
        if let startedAt { return DeviceDateFormat.title(startedAt) }
        return fileName ?? "Recording"
    }

    /// "48 min", "About 22 min", or "12.4 MB · Today, 9:12 AM" for a file.
    public var detail: String {
        if let length, length.seconds > 0 { return length.label }
        var parts: [String] = []
        if let byteCount, byteCount > 0 { parts.append(Int64(byteCount).formatted(.byteCount(style: .file))) }
        if startedAt == nil, let addedAt { parts.append(DeviceDateFormat.title(addedAt)) }
        return parts.isEmpty ? "Length unknown" : parts.joined(separator: " · ")
    }

    /// For ordering: the start time, or when the file appeared.
    public var sortDate: Date? { startedAt ?? addedAt }

    public init(id: String, startedAt: Date? = nil, length: RecordingLength? = nil, byteCount: UInt64? = nil, isInProgress: Bool = false, fileName: String? = nil, addedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.length = length
        self.byteCount = byteCount
        self.isInProgress = isInProgress
        self.fileName = fileName
        self.addedAt = addedAt
    }
}

/// Where one transfer is. The bar is indeterminate while preparing; the same bar becomes
/// determinate once the size is known.
public enum TransferPhase: Equatable {
    /// Before any audio arrives: key exchange, the file request.
    case preparing
    /// Audio is arriving. The fraction is nil while the expected size is unknown.
    case receiving(fraction: Double?)
    /// Everything arrived; Daybook is checking and saving it.
    case finishing

    public var fraction: Double? {
        switch self {
        case .preparing: return nil
        case .receiving(let fraction): return fraction.map { min(1, max(0, $0)) }
        case .finishing: return 1
        }
    }

    /// "Preparing…", "64%", "Finishing…".
    public var label: String {
        switch self {
        case .preparing: return "Preparing…"
        case .receiving(let fraction):
            guard let fraction else { return "Importing…" }
            return "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
        case .finishing: return "Finishing…"
        }
    }
}

/// Audio a connection handed over, ready for the library to copy.
public struct TransferredAudio {
    public let url: URL
    /// Staged by Daybook (delete after import) rather than the person's own file (never touch).
    public let isStaged: Bool
    /// The recorder's serial number, when it reports one.
    public var serial: String?

    public init(url: URL, isStaged: Bool, serial: String? = nil) {
        self.url = url
        self.isStaged = isStaged
        self.serial = serial
    }
}

/// Why a transfer didn't produce audio. Nothing partial is ever handed to the library.
public enum DeviceTransferError: Error, Equatable {
    /// The link dropped. The recording waits and imports again after a reconnect.
    case disconnected
    /// Nothing arrived for too long.
    case stalled
    /// Some audio was missing, out of order, or didn't decode.
    case integrity(String)
    /// The recorder refused the request.
    case rejected(String)
    /// The file couldn't be read.
    case unreadable(String)
    /// Not connected when the transfer was due to start.
    case notConnected

    /// Worth one quiet automatic retry before telling the person.
    public var isRetryable: Bool {
        switch self {
        case .stalled, .integrity: return true
        default: return false
        }
    }
}

/// A recorder's last confirmed status. Cached values carry their time, so they're never shown as live.
public struct DeviceStatus: Codable, Equatable {
    public struct Battery: Codable, Equatable {
        public var level: Int?
        public var charging = false

        public init(level: Int? = nil, charging: Bool = false) {
            self.level = level
            self.charging = charging
        }
    }
    public struct Storage: Codable, Equatable {
        public var freeBytes: UInt64
        public var totalBytes: UInt64
        /// How fast this recorder fills its storage, for "About 210 hours left".
        public var bytesPerHour: Double
        public var hoursLeft: Double { bytesPerHour > 0 ? Double(freeBytes) / bytesPerHour : 0 }

        public init(freeBytes: UInt64, totalBytes: UInt64, bytesPerHour: Double) {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
            self.bytesPerHour = bytesPerHour
        }
    }

    public var battery: Battery?
    public var caseBattery: Battery?
    public var storage: Storage?
    public var isRecording: Bool?
    /// When the recording in progress started.
    public var recordingStartedAt: Date?
    public var firmware: String?
    public var caseFirmware: String?
    public var serial: String?
    public var updatedAt: Date

    public init(battery: Battery? = nil, caseBattery: Battery? = nil, storage: Storage? = nil, isRecording: Bool? = nil, recordingStartedAt: Date? = nil, firmware: String? = nil, caseFirmware: String? = nil, serial: String? = nil, updatedAt: Date) {
        self.battery = battery
        self.caseBattery = caseBattery
        self.storage = storage
        self.isRecording = isRecording
        self.recordingStartedAt = recordingStartedAt
        self.firmware = firmware
        self.caseFirmware = caseFirmware
        self.serial = serial
        self.updatedAt = updatedAt
    }
}

/// One line in Device Details.
public struct DeviceDetail: Identifiable, Hashable {
    public let label: String
    public let value: String
    /// Copyable in full while showing a shortened value (a serial number).
    public var copyValue: String?
    public var id: String { label }

    public init(label: String, value: String, copyValue: String? = nil) {
        self.label = label
        self.value = value
        self.copyValue = copyValue
    }
}

/// A problem with copy from the device page banner table: what happened, what is safe, and at
/// most two actions.
public struct DeviceProblem: Identifiable, Equatable {
    /// Stable code for tests and equality: "bluetoothOff", "disconnectedDuringImport".
    public let id: String
    public let title: String
    public let message: String
    public let actions: [DeviceProblemAction]
    /// Happened while a recording was importing; cleared when the queue moves on.
    public var isTransferProblem = false

    public init(id: String, title: String, message: String, actions: [DeviceProblemAction], isTransferProblem: Bool = false) {
        self.id = id
        self.title = title
        self.message = message
        self.actions = actions
        self.isTransferProblem = isTransferProblem
    }
}

public enum DeviceProblemAction: Equatable {
    case openBluetoothSettings, openPrivacySettings
    /// Set up the device's files method (the fallback that always works).
    case setUpFolder
    case chooseFolder
    case tryAgain, technicalDetails, reconnect, connect, dismiss, refreshStatus

    public var title: String {
        switch self {
        case .openBluetoothSettings: return "Open Bluetooth Settings"
        case .openPrivacySettings: return "Open Privacy Settings"
        case .setUpFolder: return "Set Up Folder…"
        case .chooseFolder: return "Choose Folder…"
        case .tryAgain: return "Try Again"
        case .technicalDetails: return "Technical Details"
        case .reconnect: return "Reconnect"
        case .connect: return "Connect"
        case .dismiss: return "Dismiss"
        case .refreshStatus: return "Refresh Status"
        }
    }
}

/// The interface every connection method implements. Connections are main-actor `@Observable` objects: views read
/// them through their device's session, and redraw for what they read.
@MainActor
public protocol DeviceConnection: AnyObject, Observable {
    var method: ConnectionMethodKind { get }
    var state: ConnectionState { get }
    var capabilities: DeviceCapabilities { get }
    /// The recordings available through this method, newest first.
    var recordings: [DeviceRecording] { get }
    var inventoryUpdatedAt: Date? { get }
    var isRefreshing: Bool { get }
    /// `recordings` reflects the device now: listed since it connected, and not being listed again.
    /// Until then it may be a remembered list that names a recording since started, grown, or
    /// finished, so nothing is imported from it.
    var isInventoryCurrent: Bool { get }
    /// Live while connected, otherwise the last confirmed values with their time.
    var status: DeviceStatus? { get }
    var problem: DeviceProblem? { get }
    /// When the recorder was last connected, for "Last connected today, 2:14 PM".
    var lastConnectedAt: Date? { get }
    /// One line for the page's "How recordings arrive" and Settings: "Watching iCloud Drive › Daybook Import".
    var summary: String { get }
    /// The method has its configuration (a remembered recorder, a chosen folder).
    var isSetUp: Bool { get }

    /// An import, Listen Live, or a Start or Pause is waiting for another app on the same link to finish its
    /// transfer (the Soundcore app, over the link iOS shares between apps). False for most connections.
    var isWaitingForOtherApp: Bool { get }

    /// Called by the session when state or inventory changes, so it can resume or auto-import.
    var onChange: (() -> Void)? { get set }

    /// The device's preferences changed (Settings › Devices, the recorder's page): its name, which methods
    /// are on, automatic import, Fast Transfer. Each connection takes what applies to it.
    func preferencesChanged(_ device: ConfiguredDevice)

    /// Restores saved configuration and, where the person allowed it, reconnects quietly.
    func activate()
    func connect()
    func disconnect()
    /// Re-reads status and the recording list.
    func refresh()
    /// Refreshes only what's older than a minute (the device page appearing).
    func refreshIfStale()
    func dismissProblem()
    /// Forgets this method's configuration. Recordings already imported stay.
    func forget()
    /// Ends everything for good (the device was removed or the app quits).
    func shutDown()

    /// Moves one recording to this device. Throws `DeviceTransferError`, or `CancellationError` when
    /// the task is cancelled. Partial audio is discarded before throwing.
    func transfer(_ recording: DeviceRecording,
                  progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio
    /// Recordings to import without asking: new since `since`, not in the library, not excluded.
    func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording]
    /// The recording is in the library now.
    func didImport(_ recording: DeviceRecording)
}

extension DeviceConnection {
    public var isInventoryCurrent: Bool { !isRefreshing }
    public var isWaitingForOtherApp: Bool { false }
    public func refreshIfStale() {
        guard state.isConnected, !isRefreshing else { return }
        if inventoryUpdatedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
    }
    public func preferencesChanged(_ device: ConfiguredDevice) {}
    public func didImport(_ recording: DeviceRecording) {}
    public func shutDown() { disconnect() }
}

// MARK: - Optional abilities

/// Finds recorders nearby for setup.
@MainActor
public protocol DiscoveringConnection: DeviceConnection {
    var discovered: [DiscoveredRecorder] { get }
    /// The last search ended without finding a recorder.
    var searchFoundNothing: Bool { get }
    /// The recorder being connected to from the setup list.
    var connectingTo: String? { get }
    func search()
    func stopSearching()
    func connect(to recorder: DiscoveredRecorder)
}

/// A recorder found nearby. Signal is shown only in words.
public struct DiscoveredRecorder: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var signal: SignalStrength

    public init(id: String, name: String, signal: SignalStrength) {
        self.id = id
        self.name = name
        self.signal = signal
    }
}

/// Starts and pauses recording on the device. Only the device's own report changes the state.
@MainActor
public protocol RecordControlConnection: DeviceConnection {
    var recordCommandPending: Bool { get }
    /// The person's Record and Pause (the device page, its menu): sent as soon as it can be, with no deadline.
    func startRecording()
    func pauseRecording()
    /// A Start or Pause that acts now or not at all (docs/devices.md, "Record commands come first"): it goes ahead of
    /// imports, and answers within `deadline`. One still waiting to be sent by then is dropped; one already sent that
    /// the recorder confirms late is undone where that's safe (a Start nobody waits for any more is paused again).
    /// A nil deadline waits as long as it takes.
    func recordCommand(_ command: RecordCommand, deadline: Duration?) async -> RecordCommandOutcome
}

/// Start or Pause.
public enum RecordCommand: Equatable, Sendable {
    case start, pause

    /// The recording state it asks for.
    public var records: Bool { self == .start }
}

/// What a Start or Pause with a deadline came to.
public enum RecordCommandOutcome: Equatable, Sendable {
    /// The recorder confirmed the state it was asked for.
    case confirmed
    /// It didn't confirm in time. Nothing was sent, or what was sent is undone if it confirms late (a Start).
    case notConfirmed
    /// It couldn't be asked: not connected, or another Start or Pause is under way.
    case unavailable
}

extension RecordControlConnection {
    /// For a device that answers on its own terms (Daybook on iPhone over the link): asks, then watches its state
    /// until `deadline` (15 seconds when there's none).
    public func recordCommand(_ command: RecordCommand, deadline: Duration?) async -> RecordCommandOutcome {
        guard state.isConnected, !recordCommandPending else { return .unavailable }
        if command == .start { startRecording() } else { pauseRecording() }
        let limit = ContinuousClock.now.advanced(by: deadline ?? .seconds(15))
        let confirmed = { self.status?.isRecording == command.records && !self.recordCommandPending }
        while !confirmed() {
            guard ContinuousClock.now < limit, (try? await Task.sleep(for: .milliseconds(100))) != nil else { break }
        }
        return confirmed() ? .confirmed : .notConfirmed
    }
}

/// What a recorder is recording, as one device knows it: live while connected, otherwise as last
/// confirmed. A `RecordingStateConnection` publishes it (for the device page, the iPhone's Live Activity,
/// the link's `recording.state`, and multipoint).
public struct RecorderRecordingState: Equatable, Sendable {
    /// The recorder said it's recording.
    public var isRecording: Bool
    /// The recording it names as in progress (its `DeviceRecording.id`): recording, or paused on firmware
    /// that keeps the file open. Nil when it names none.
    public var recordingID: String?
    /// When that recording started, by the recorder's clock corrected by its measured offset.
    public var startedAt: Date?
    /// When the recorder last confirmed this.
    public var asOf: Date
    /// Connected now: live. Otherwise remembered, and shown with its time.
    public var isLive: Bool
    /// This device asked the recorder to start this recording.
    public var startedHere: Bool

    public init(isRecording: Bool, recordingID: String? = nil, startedAt: Date? = nil, asOf: Date, isLive: Bool,
                startedHere: Bool = false) {
        self.isRecording = isRecording
        self.recordingID = recordingID
        self.startedAt = startedAt
        self.asOf = asOf
        self.isLive = isLive
        self.startedHere = startedHere
    }
}

/// What a recorder is recording, as one device knows it: live while connected, otherwise as last
/// confirmed for a while. A recording state the recorder pushes unasked is its button
/// (docs/devices.md, "What the recorder is recording").
@MainActor
public protocol RecordingStateConnection: RecordControlConnection {
    /// Nil when it isn't recording, or nothing recent enough is known.
    func recordingState(at now: Date) -> RecorderRecordingState?
    /// The recorder's own button started (true) or stopped (false) a recording: a pushed state that
    /// changes what this device knew, while no Start or Pause of its own is waiting for an answer.
    var onButton: ((Bool) -> Void)? { get set }
    /// Holds the link while the recorder is in range, so its button is heard (the iPhone, for a recorder
    /// that records along with it): never let go when idle, and back at once after a drop.
    var staysConnected: Bool { get set }
    /// Whether this device already expects a recording (its `DeviceRecording.id`): one a handoff brought, or a shared
    /// recording's. The held link coming back to find it just started isn't the button (`SoundcoreTiming.buttonCatchUp`).
    var expectsRecording: ((String) -> Bool)? { get set }
}

/// A direct connection to a recorder that only one device may manage at a time (a synced
/// `RecorderOwnership`; docs/devices.md, "One owner per recorder").
@MainActor
public protocol ManagedConnection: DeviceConnection {
    /// The recorder's serial number, once a connection has reported it: the identity ownership uses.
    var recorderSerial: String? { get }
    /// The serial of the recorder this method remembers, whether or not it's connected now: what the
    /// library's links match its tracks by. Nil until a connection has reported one.
    var rememberedSerial: String? { get }
    /// Another device manages this recorder. While set, this device doesn't connect to it.
    var managedElsewhere: RecorderOwnership? { get set }
    /// Connects as soon as the recorder is free, with no deadline: after a handoff, the device that
    /// had it may still be letting go, and a recorder talks to one device at a time.
    func connectWhenAvailable()
}

extension ManagedConnection {
    public var rememberedSerial: String? { recorderSerial }
    public func connectWhenAvailable() { connect() }
}

/// Hears a recording while it's being made, saving it to this device as it arrives: Listen Live, and a
/// shared recording's live audio (docs/devices.md, "A recorder's audio in a shared recording").
@MainActor
public protocol LiveListeningConnection: DeviceConnection {
    var live: LiveCapture { get }
    /// The conversation the live audio being received is saved into, when it's a shared recording's.
    var liveConversation: UUID? { get }
    /// The listening under way: it ends once what arrived has been handed on to be saved (`onLiveSaved`).
    var listeningTask: Task<Void, Never>? { get }
    /// A live portion to save: the staged file (the handler removes it once it's saved), the recording's ID,
    /// its length, and the conversation it was captured for, if any.
    var onLiveSaved: ((URL, String, TimeInterval, UUID?) -> Void)? { get set }
    /// Listen Live, captioned.
    func startListening()
    /// Receives the recording in progress and saves it as it arrives; with `conversation`, into that shared
    /// recording, captioned when `captions`. False when it can't start now (not connected, not recording,
    /// already listening).
    @discardableResult
    func startListening(into conversation: UUID?, captions: Bool) -> Bool
    /// Saves what arrived. The recorder keeps recording.
    func stopListening()
}

/// Brings long recordings over the recorder's own Wi‑Fi rather than Bluetooth (Fast Transfer, iPhone;
/// docs/direct-soundcore.md, "Wi‑Fi Fast Transfer").
@MainActor
public protocol FastTransferConnection: DeviceConnection {
    /// This device can join a recorder's network, so the preference applies here.
    var joinsRecorderWiFi: Bool { get }
    /// This device can bring recordings over the recorder's Wi‑Fi now.
    var offersFastTransfer: Bool { get }
    /// Where Fast Transfer is while it runs.
    var fastTransferStage: FastTransferStage? { get }
    /// The person chose these recordings to come over Wi‑Fi, whatever their length.
    func requestFastTransfer(_ ids: [String])
    /// Another recording from this recorder is waiting in the import queue (the session sets it): the
    /// Wi‑Fi link stays open for it.
    var hasMoreQueued: (() -> Bool)? { get set }
    /// The person declined joining the recorder's network: their No turns the device's Fast Transfer off,
    /// and its switch is the way back.
    var onFastTransferDeclined: (() -> Void)? { get set }
}

/// Imports on its own when the recorder is in range, waiting between attempts so its own app can reach it.
@MainActor
public protocol AutomaticImportScheduling: DeviceConnection {
    /// When the wait before the next automatic attempt ends, on the wall clock.
    var automaticDueAt: Date? { get }
    /// A background wake (iOS app refresh, which runs no timers while suspended): an attempt whose wait has
    /// run out starts now.
    func resumeAutomaticImportIfDue(now: Date)
}

/// A connection whose recordings are in the library already, because they arrive through sync
/// (Daybook on iPhone). Its session hands it the library's conversations whenever they change, and
/// it lists the recordings from them; nothing transfers.
@MainActor
public protocol LibraryBackedConnection: DeviceConnection {
    func libraryChanged(_ meetings: [Meeting])
}

/// Device Details: the status, versions, and technical facts.
@MainActor
public protocol DetailedConnection: DeviceConnection {
    var details: [DeviceDetail] { get }
    var technicalDetails: [DeviceDetail] { get }
    /// The underlying error behind the last problem, for Technical Details only.
    var lastTechnicalProblem: String? { get }
}

/// Listen Live, observed separately so its captions don't redraw every surface of the device.
@MainActor
@Observable
public final class LiveCapture {
    /// What Stop Listening saved.
    public struct Saved: Equatable {
        public let seconds: TimeInterval
        public let recordingID: String
        /// Time the stream lost (packets missing, or one that didn't decode), kept as silence so what followed kept
        /// its place.
        public let filledSeconds: TimeInterval

        public init(seconds: TimeInterval, recordingID: String, filledSeconds: TimeInterval = 0) {
            self.seconds = seconds
            self.recordingID = recordingID
            self.filledSeconds = filledSeconds
        }
    }

    public var isListening = false
    /// The live audio is behind the recording and arriving faster than real time to catch up (a recorder streams
    /// what it recorded before listening began first): "Catching up…", and the meter shows no level meanwhile, so
    /// earlier audio never reads as live.
    public internal(set) var isCatchingUp = false
    /// Where the live stream starts, on this device's clock: when its audio arrived less its place in the stream,
    /// the earliest so far. A stream that starts now counts from its first buffer; one that starts with what was
    /// recorded before listening began settles on the recording's start once it has caught up. Captions of the
    /// stream are placed from it (`LiveCaptureCaptions.Update.startedAt`).
    @ObservationIgnored public private(set) var streamStartedAt: Date?
    /// Recent arrivals and their place in the stream, for its pace.
    @ObservationIgnored private var pace: [(at: Date, position: TimeInterval)] = []
    /// The pace is judged over this long.
    static let paceWindow: TimeInterval = 3
    /// Faster than this, the stream is catching up.
    static let catchUpPace = 1.25
    /// What's being said, as tentative live captions made on this device (DaybookCaptions), oldest
    /// first. Never the transcript. Empty when not listening.
    public var captions: [LiveCaptionSegment] = []
    /// Where the captioner stands: getting ready, downloading, listening, unavailable (and why), or
    /// stopped. `.off` when captions are off or not listening.
    public var captionState: LiveCaptionState = .off
    public var saved: Saved?
    public var receivedSeconds: TimeInterval = 0

    /// How loud the arriving audio is, 0…1 for a meter (−60…0 dBFS), and when it last arrived. Not
    /// observed, so nothing redraws at the audio's pace: a meter samples it (`level(at:)`).
    @ObservationIgnored public private(set) var meterValue: Double = 0
    @ObservationIgnored public private(set) var heardAt: Date?
    /// How long a level counts as current after the audio it came from.
    public static let levelLifetime: TimeInterval = 1

    /// The level while audio keeps arriving; nil before any has, once it stops, and while the stream catches up (the
    /// audio arriving then isn't what's being said now).
    public func level(at now: Date = Date()) -> Double? {
        guard let heardAt, now.timeIntervalSince(heardAt) < Self.levelLifetime, !isCatchingUp else { return nil }
        return meterValue
    }

    /// A buffer of the live audio arrived: its level is now the meter's.
    func heard(rms: Float, at now: Date = Date()) {
        meterValue = Double(max(0, min(1, (rms + 60) / 60)))
        heardAt = now
    }

    /// The stream's audio up to `position` seconds into it has arrived `now`: where the stream starts on this device's
    /// clock, and whether it's catching up (more than 1.25 seconds of audio a second, over the last three seconds).
    func streamed(to position: TimeInterval, at now: Date = Date()) {
        let origin = now.addingTimeInterval(-position)
        if streamStartedAt.map({ origin < $0 }) ?? true { streamStartedAt = origin }
        pace.append((now, position))
        pace.removeAll { now.timeIntervalSince($0.at) > Self.paceWindow }
        guard let first = pace.first, now.timeIntervalSince(first.at) >= Self.paceWindow / 2 else { return }
        let catching = (position - first.position) / now.timeIntervalSince(first.at) > Self.catchUpPace
        if catching != isCatchingUp { isCatchingUp = catching }
    }

    /// Listening began or ended: no level, pace, or start until audio arrives again.
    func clearLevel() {
        meterValue = 0
        heardAt = nil
        streamStartedAt = nil
        pace = []
        if isCatchingUp { isCatchingUp = false }
    }
}
