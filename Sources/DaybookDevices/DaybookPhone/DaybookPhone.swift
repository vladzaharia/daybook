import Combine
import DaybookCore
import Foundation

/// Daybook on iPhone, as a device of this Mac (docs/iphone.md, "The phone is a device to the Mac").
/// Its recordings are Daybook conversations already: they arrive with the library's sync, which is
/// this kind's *files* method. Pairing over Daybook's local link adds the *direct* method: record
/// control, live recording state, and processing progress. The link (DaybookLink) sits above this
/// library, so the app supplies that connection through `DeviceEnvironment.phone`.
///
/// A paired phone is a configured device whose ID is the phone's link device ID. The phone tags
/// its tracks with its installation ID as the serial; the two are expected to be the same UUID.
public struct DaybookPhoneIntegration: DeviceIntegration {
    /// Stored on every track the phone records (`DeviceRecordingIdentity.kind`). Never change it.
    public static let id = "daybook.iphone"

    public init() {}

    public let kind = DeviceKind(
        id: Self.id,
        name: "Daybook on iPhone",
        shortName: "iPhone",
        vendor: nil,
        systemImage: "iphone",
        summary: "Record on your iPhone, on its own or along with this Mac.",
        methods: [
            ConnectionMethod(kind: .files, title: "Through iCloud",
                             summary: "Nothing to set up.",
                             systemImage: "icloud", setupAction: "Sync Settings…"),
            ConnectionMethod(kind: .direct, transport: .localNetwork, title: "Over Wi‑Fi",
                             summary: "Pair the iPhone to record together.",
                             systemImage: "wifi", setupAction: "Pair iPhone…",
                             note: "macOS asks to allow Daybook to find devices on your local network.")
        ],
        // The phone labels its own tracks; nothing is imported as this kind's audio.
        audioSource: .microphone,
        allowsMultiple: true,
        technicalNotes: [
            "Recordings travel with your library’s iCloud sync, never over the local link. The link carries record control, recording status, clock samples, and transcription progress.",
            "Pairing uses a six-digit code shown on this Mac. The link is encrypted with a key only this Mac and the iPhone hold, kept in each one’s keychain.",
            "This Mac announces itself on the local network only while pairing is open or an iPhone is paired.",
            "Pairing and record control are tested on this Mac over loopback. A real iPhone on a real network is still to be checked."
        ]
    )

    public func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice,
                               environment: DeviceEnvironment) -> (any DeviceConnection)? {
        switch method {
        case .files: return SyncedPhoneRecordings(device: device, hooks: environment.phone)
        case .direct: return environment.phone.makeLinkConnection?(device)
        case .account: return nil
        }
    }
}

/// What Daybook on iPhone's connections need from the app.
@MainActor
public final class DaybookPhoneHooks {
    /// The direct method: the app's adapter over Daybook's local link. Nil makes none (tests, demos).
    public var makeLinkConnection: ((ConfiguredDevice) -> (any DeviceConnection)?)?
    /// Whether the library syncs, which is how the phone's recordings arrive.
    public var syncIsOn: () -> Bool = { false }
    /// The phones this Mac is paired with (their device IDs), so each one lists only its own recordings.
    public var pairedPhoneIDs: () -> Set<String> = { [] }

    public init() {}
}

/// Daybook on iPhone's *files* method: the phone's recordings, which are in the library already
/// because they arrive through sync. Nothing transfers, so the device's list shows each of them as
/// already in Daybook.
@MainActor
public final class SyncedPhoneRecordings: ObservableObject, LibraryBackedConnection {
    public let method = ConnectionMethodKind.files
    public let capabilities: DeviceCapabilities = []
    @Published public private(set) var recordings: [DeviceRecording] = []
    @Published public private(set) var inventoryUpdatedAt: Date?
    public var isRefreshing: Bool { false }
    public var status: DeviceStatus? { nil }
    @Published public private(set) var problem: DeviceProblem?
    public var lastConnectedAt: Date? { nil }
    /// The library syncs, so recordings can arrive.
    @Published public private(set) var syncs = false
    public var isSetUp: Bool { true }
    public var state: ConnectionState { syncs ? .connected : .unavailable }
    public var onChange: (() -> Void)?
    /// The phone's device ID, which its tracks carry as their serial.
    public let phoneID: String

    public var summary: String {
        syncs ? "On" : "Sync is off"
    }

    private let hooks: DaybookPhoneHooks

    public init(device: ConfiguredDevice, hooks: DaybookPhoneHooks) {
        phoneID = device.id
        self.hooks = hooks
    }

    public func activate() { refresh() }
    public func connect() { refresh() }
    public func disconnect() {}

    /// Re-reads whether the library syncs.
    public func refresh() {
        let on = hooks.syncIsOn()
        if on != syncs { syncs = on }
        let issue = on ? nil : DeviceProblem(id: "syncOff", title: "Sync is off",
                                             message: "Turn on sync to get your iPhone’s recordings.",
                                             actions: [])
        if issue != problem { problem = issue }
        onChange?()
    }

    public func dismissProblem() {}
    public func forget() {}

    public func transfer(_ recording: DeviceRecording,
                         progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        throw DeviceTransferError.rejected("Nothing to import from iPhone.")
    }

    public func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] { [] }

    /// The phone's recordings in the library. A track whose serial is another paired phone's is
    /// that phone's; any other phone track counts as this one's, so a single phone lists its
    /// recordings even if its tracks carry another ID.
    public func libraryChanged(_ meetings: [Meeting]) {
        let others = hooks.pairedPhoneIDs().subtracting([phoneID])
        var found: [String: DeviceRecording] = [:]
        for meeting in meetings {
            for track in meeting.tracks {
                guard let device = track.device, device.kind == DaybookPhoneIntegration.id, found[device.recordingID] == nil else { continue }
                if let serial = device.serial, serial != phoneID, others.contains(serial) { continue }
                found[device.recordingID] = DeviceRecording(id: device.recordingID, startedAt: track.startedAt ?? track.createdAt,
                                                            length: track.duration.map(RecordingLength.exact), addedAt: track.createdAt)
            }
        }
        let sorted = found.values.sorted { ($0.sortDate ?? .distantPast, $0.id) > ($1.sortDate ?? .distantPast, $1.id) }
        if sorted != recordings { recordings = sorted }
        if inventoryUpdatedAt == nil { inventoryUpdatedAt = Date() }
        onChange?()
    }
}
