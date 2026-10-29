import DaybookCore
import Foundation

/// Anker Soundcore Work (D3200). Direct Bluetooth is the primary path; the Soundcore app's export
/// folder is the fallback that works with every firmware.
public struct SoundcoreWorkIntegration: DeviceIntegration {
    public static let id = "soundcore.work"

    public init() {}

    public let kind = DeviceKind(
        id: Self.id,
        name: "Soundcore Work",
        shortName: "Soundcore",
        vendor: "Anker",
        systemImage: "waveform.badge.microphone",
        summary: "Over Bluetooth, or from the Soundcore app.",
        methods: [
            ConnectionMethod(kind: .direct, transport: .bluetoothLE, title: "Directly over Bluetooth",
                             summary: "Straight from the recorder. New recordings import on their own when it’s nearby.",
                             systemImage: "antenna.radiowaves.left.and.right", setupAction: "Continue…",
                             note: "macOS asks to allow Bluetooth."),
            ConnectionMethod(kind: .files, title: "From the Soundcore app",
                             summary: "Export recordings from the Soundcore app to a folder. Works with every firmware version.",
                             systemImage: "folder.badge.gearshape", setupAction: "Choose Folder…"),
            ConnectionMethod(kind: .account, title: "Soundcore account",
                             summary: "Not supported.",
                             systemImage: "person.crop.circle", setupAction: "", isImplemented: false)
        ],
        audioSource: .soundcore,
        allowsMultiple: false,
        discoveryTips: [
            DeviceTip(symbol: "moon.zzz", text: "Take it out of its case."),
            DeviceTip(symbol: "iphone.radiowaves.left.and.right", text: "Close the Soundcore app on your phone."),
            DeviceTip(symbol: "wave.3.right", text: "Bring it close to this Mac.")
        ],
        technicalNotes: [
            "Daybook speaks the recorder’s Bluetooth protocol directly. It was implemented from community protocol research, not from an Anker SDK.",
            "Tested against a simulated recorder built from that research. Testing with a physical recorder is still pending, and a firmware update could change the protocol.",
            "Direct Bluetooth audio is experimental: successful decoding does not guarantee an intact recording. Keep the originals on your recorder and verify important recordings through file export.",
            "The recorder’s audio protocol exposes its encryption secret during setup. Wireless privacy depends on Bluetooth link protection that has not yet been verified on a physical recorder.",
            "The import folder works with every firmware version."
        ],
        emptyHint: "Press its button once to start recording, and again to stop."
    )

    public func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice,
                        environment: DeviceEnvironment) -> (any DeviceConnection)? {
        guard method == .direct else { return nil }
        return SoundcoreConnection(device: device, environment: environment)
    }
}

/// Everything that can go wrong with the recorder, each with the copy from the device page banner
/// table (§8.6): what happened, what is safe, and at most two actions.
public enum SoundcoreIssue: String, CaseIterable {
    case bluetoothOff, bluetoothDenied, bluetoothUnsupported, notFound, connectTimeout, rejected
    case notConnected, disconnectedDuringImport, stalled, integrity, didNotConfirm, notRecording
    /// Connected, but the recorder didn't answer the request for its recordings, or refused it.
    case listFailed
    /// Wi‑Fi Fast Transfer ended without Bluetooth coming back to close the recorder's access point.
    case fastTransferInterrupted

    public var title: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothDenied: return "Daybook can’t use Bluetooth"
        case .bluetoothUnsupported: return "This Mac can’t connect to Soundcore"
        case .notFound: return "No Soundcore found nearby"
        case .connectTimeout: return "Soundcore didn’t finish connecting"
        case .rejected: return "This Soundcore didn’t accept the connection"
        case .notConnected: return "Soundcore isn’t connected"
        case .disconnectedDuringImport: return "Soundcore disconnected during import"
        case .stalled: return "Soundcore stopped sending audio"
        case .integrity: return "This recording couldn’t be imported"
        case .didNotConfirm: return "Soundcore didn’t confirm"
        case .notRecording: return "Soundcore isn’t recording"
        case .listFailed: return "Soundcore didn’t list its recordings"
        case .fastTransferInterrupted: return "Fast Transfer didn’t finish"
        }
    }

    public var message: String {
        switch self {
        case .bluetoothOff: return "Turn on Bluetooth to connect to your Soundcore."
        case .bluetoothDenied: return "Allow Daybook in Privacy & Security › Bluetooth."
        case .bluetoothUnsupported: return "Use the Soundcore app and an import folder instead."
        case .notFound: return "Take it out of its case, close the Soundcore app on your phone, and bring it close to this Mac."
        case .connectTimeout: return "Take it out of its case to wake it, and close the Soundcore app on your phone."
        case .rejected: return "Use the Soundcore app and an import folder instead."
        case .notConnected: return "Take your Soundcore out of its case to wake it, then connect."
        case .disconnectedDuringImport:
            return "The recording is still on your Soundcore. Importing continues when it reconnects."
        case .stalled: return "The recording is still on your Soundcore."
        case .integrity:
            return "Some audio didn’t arrive intact. The recording is still on your Soundcore."
        case .didNotConfirm: return "Check its light: solid orange means it’s recording."
        case .notRecording: return "Start recording on your Soundcore, then listen live."
        case .listFailed: return "Close the Soundcore app on your phone, then refresh."
        case .fastTransferInterrupted: return "The recording is still on your Soundcore. Connect to turn off its Wi‑Fi."
        }
    }

    public var actions: [DeviceProblemAction] {
        switch self {
        case .bluetoothOff: return [.openBluetoothSettings]
        case .bluetoothDenied: return [.openPrivacySettings]
        case .bluetoothUnsupported: return [.setUpFolder]
        case .notFound, .connectTimeout, .stalled: return [.tryAgain]
        case .rejected: return [.setUpFolder, .technicalDetails]
        case .notConnected, .fastTransferInterrupted: return [.connect]
        case .disconnectedDuringImport: return [.reconnect, .dismiss]
        case .integrity: return [.tryAgain, .technicalDetails]
        case .didNotConfirm: return [.refreshStatus]
        case .listFailed: return [.refreshStatus, .technicalDetails]
        case .notRecording: return []
        }
    }

    public var isTransferProblem: Bool { [.disconnectedDuringImport, .stalled, .integrity].contains(self) }

    public var problem: DeviceProblem {
        DeviceProblem(id: rawValue, title: title, message: message, actions: actions, isTransferProblem: isTransferProblem)
    }

    /// Maps a protocol error to the problem people see.
    public static func from(_ error: Error, transferring: Bool) -> SoundcoreIssue {
        guard let error = error as? SoundcoreError else { return transferring ? .stalled : .rejected }
        switch error {
        case .disconnected: return transferring ? .disconnectedDuringImport : .notConnected
        case .invalidPacket, .incompleteTransfer, .corruptAudio, .invalidEncryption, .codecUnavailable:
            return transferring ? .integrity : .rejected
        case .rejected, .unsupported: return .rejected
        case .liveFileUnavailable: return .notRecording
        case .timedOut, .stalled, .yielded: return transferring ? .stalled : .connectTimeout
        }
    }
}

extension DeviceTransferError {
    /// The transfer problem for a Soundcore import.
    public init(soundcore error: Error) {
        switch error as? SoundcoreError {
        case .disconnected?: self = .disconnected
        case .stalled?, .timedOut?: self = .stalled
        case .rejected?, .unsupported?, .liveFileUnavailable?: self = .rejected(error.localizedDescription)
        default: self = .integrity(error.localizedDescription)
        }
    }
}

/// The recorder this Mac connects to, with its last confirmed status and recording list, so stale
/// values can be shown with their time instead of disappearing.
public struct SoundcoreSnapshot: Codable, Equatable {
    public var deviceID: UUID
    public var name: String
    public var serial = ""
    public var info: SoundcoreDeviceInfo?
    public var statusUpdatedAt: Date?
    public var lastConnectedAt: Date?
    public var recordings: [SoundcoreRecording] = []
    public var recordingsUpdatedAt: Date?
    /// The recording the recorder named as in progress at the last listing, kept across
    /// disconnects so the remembered list never shows it as finished. Its time is
    /// `recordingsUpdatedAt`; whether it was recording is `info.isRecording` as of `statusUpdatedAt`.
    /// Optional, so earlier snapshots decode.
    public var activeRecordingID: UInt32?
    /// The recorder's clock, as last measured. Optional, so earlier snapshots decode.
    public var clock: SoundcoreClock?
    /// Wi‑Fi Fast Transfer asked the recorder to open its access point, with this name, and it hasn't
    /// been closed since: the next confirmed Bluetooth link closes it. Optional, so earlier snapshots decode.
    public var accessPointSSID: String?
    public var accessPointSince: Date?

    /// The name shown in Settings: "soundcore Work ··7F3A".
    public var displayName: String { serial.isEmpty ? name : "\(name) \(maskedSerial(serial))" }

    /// Keeps values a partial update (a battery push) doesn't carry.
    public mutating func apply(_ update: SoundcoreDeviceInfo, at date: Date) {
        var merged = info ?? SoundcoreDeviceInfo()
        merged.microphoneBattery = update.microphoneBattery ?? merged.microphoneBattery
        merged.caseBattery = update.caseBattery ?? merged.caseBattery
        merged.microphoneCharging = update.microphoneCharging
        merged.caseCharging = update.caseCharging
        if update.totalBytes > 0 { merged.freeBytes = update.freeBytes; merged.totalBytes = update.totalBytes }
        if !update.firmware.isEmpty { merged.firmware = update.firmware }
        if !update.caseFirmware.isEmpty { merged.caseFirmware = update.caseFirmware }
        if !update.serial.isEmpty { merged.serial = update.serial; serial = update.serial }
        merged.isRecording = update.isRecording
        info = merged
        statusUpdatedAt = date
    }

    public init(deviceID: UUID, name: String, serial: String = "", info: SoundcoreDeviceInfo? = nil, statusUpdatedAt: Date? = nil, lastConnectedAt: Date? = nil, recordings: [SoundcoreRecording] = [], recordingsUpdatedAt: Date? = nil, activeRecordingID: UInt32? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.serial = serial
        self.info = info
        self.statusUpdatedAt = statusUpdatedAt
        self.lastConnectedAt = lastConnectedAt
        self.recordings = recordings
        self.recordingsUpdatedAt = recordingsUpdatedAt
        self.activeRecordingID = activeRecordingID
    }
}

/// What a Soundcore is recording, as one device knows it: live while connected, otherwise as last
/// confirmed. `SoundcoreConnection.recordingState` publishes it (for the device page, the iPhone's
/// Live Activity, and multipoint).
public struct SoundcoreRecordingState: Equatable, Sendable {
    /// The recorder said it's recording.
    public var isRecording: Bool
    /// The recording it names as in progress: recording, or paused on firmware that keeps the file
    /// open. Nil when it names none.
    public var activeRecordingID: UInt32?
    /// When that recording started, by the recorder's clock corrected by its measured offset.
    public var startedAt: Date?
    /// When the recorder last confirmed this.
    public var asOf: Date
    /// Connected now: live. Otherwise remembered, and shown with its time.
    public var isLive: Bool
    /// This device asked the recorder to start this recording.
    public var startedHere: Bool

    public init(isRecording: Bool, activeRecordingID: UInt32? = nil, startedAt: Date? = nil, asOf: Date, isLive: Bool,
                startedHere: Bool = false) {
        self.isRecording = isRecording
        self.activeRecordingID = activeRecordingID
        self.startedAt = startedAt
        self.asOf = asOf
        self.isLive = isLive
        self.startedHere = startedHere
    }
}

extension SoundcoreDeviceInfo {
    /// The generic status the device page shows.
    public func status(at date: Date, activeRecordingStart: Date?) -> DeviceStatus {
        DeviceStatus(battery: .init(level: microphoneBattery, charging: microphoneCharging),
                     caseBattery: .init(level: caseBattery, charging: caseCharging),
                     storage: totalBytes > 0 ? .init(freeBytes: freeBytes, totalBytes: totalBytes,
                                                     bytesPerHour: SoundcoreRecording.bytesPerHour) : nil,
                     isRecording: isRecording, recordingStartedAt: isRecording ? activeRecordingStart : nil,
                     firmware: firmware.isEmpty ? nil : firmware, caseFirmware: caseFirmware.isEmpty ? nil : caseFirmware,
                     serial: serial.isEmpty ? nil : serial, updatedAt: date)
    }
}

extension SoundcoreRecording {
    /// The generic form; the ID is the start time as a decimal string. `clockCorrection` is the
    /// recorder's measured clock offset, taken off its start.
    public func deviceRecording(inProgress: Bool = false, clockCorrection: TimeInterval = 0) -> DeviceRecording {
        DeviceRecording(id: String(id), startedAt: start(correction: clockCorrection), length: length, byteCount: UInt64(size),
                        isInProgress: inProgress)
    }
}
