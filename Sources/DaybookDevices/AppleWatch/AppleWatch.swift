@_exported import DaybookWatchLink
import Foundation
import Observation

/// Daybook on Apple Watch, as a recorder the iPhone manages (docs/devices.md, "Apple Watch"). The iPhone adds it by
/// itself once its paired watch has Daybook (never in Add Device), and it records along with the iPhone's shared
/// recordings like any recorder with record control: the cascade starts and stops it, the watch's own Record and Stop
/// are its button, and its audio arrives as segments over WatchConnectivity that are joined here and imported into
/// the conversation. WatchConnectivity sits in the app, so the app supplies the link through `DeviceEnvironment.watch`.
///
/// The Mac knows the kind, so a watch's tracks are named "Apple Watch" there, but never manages one: it reaches the
/// watch only through the iPhone (a Mac starting the iPhone starts the iPhone's recorders).
public struct AppleWatchIntegration: DeviceIntegration {
    /// Stored on every track the watch records (`DeviceRecordingIdentity.kind`). Never change it. Nonisolated, so what
    /// reads a track off the main actor (exports) can tell.
    public nonisolated static let id = "daybook.watch"

    public init() {}

    public let kind = DeviceKind(
        id: Self.id,
        name: "Apple Watch",
        shortName: "Watch",
        vendor: "Apple",
        systemImage: "applewatch",
        summary: "Record on your wrist, along with this iPhone.",
        methods: [
            ConnectionMethod(kind: .direct, title: "From Daybook on Apple Watch", summary: "Nothing to set up.",
                             systemImage: "applewatch", setupAction: "")
        ],
        // As Daybook on iPhone's own tracks: a microphone, on a device that names itself (`RecordingWords`).
        audioSource: .microphone,
        allowsMultiple: false,
        technicalNotes: [
            "Added on its own once Daybook is on the Apple Watch paired with this iPhone. Removed here, it comes back the next time Daybook opens while the watch has Daybook.",
            "Start and Stop travel as WatchConnectivity messages and need Daybook open on the watch. A stop the watch can’t hear yet is queued, and the watch also follows this iPhone’s recording when Daybook next runs there.",
            "The watch records AAC in two-minute segments and sends each as it closes. This iPhone joins them on the recording’s timeline without encoding them again, and imports only once every segment has arrived; the watch keeps its copies until then.",
            "Times on the watch are placed on this iPhone’s clock from round-trip clock samples taken while Daybook is open on both.",
            "Tested against a simulated watch. Nothing has run on a real Apple Watch yet."
        ],
        emptyHint: "Nothing waiting on Apple Watch.",
        isAddedByHand: false
    )

    public func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice,
                               environment: DeviceEnvironment) -> (any DeviceConnection)? {
        guard method == .direct, let transport = environment.watch.transport else { return nil }
        return WatchConnection(device: device, transport: transport, hooks: environment.watch,
                               storage: environment.storage(for: device, method: .direct),
                               staging: WatchStaging.folder(in: environment.stagingDirectory))
    }
}

/// What Apple Watch's connection needs from the iPhone app.
@MainActor
public final class AppleWatchHooks {
    /// The link to the watch: WatchConnectivity in the iPhone app, a `SimulatedWatch` in tests and demos. Nil makes no
    /// connection (the Mac).
    public var transport: (any WatchTransport)?
    /// The shared recording the iPhone records now, which a Start asks the watch to record along with, and the only
    /// one a watch that joined on its own records along with.
    public var sharedRecording: () -> WatchSharedRecording? = { nil }
    /// How the watch's `.context` is answered, stamped now: what the iPhone records, and whether the watch records along.
    public var phoneContext: () -> PhoneContext = { PhoneContext() }
    /// Joins a finished recording's segments, in order, into one M4A at the URL: each at its `startOffset`, the gaps
    /// silent. Without it, only a recording of one whole segment can be imported.
    public var join: (@MainActor ([WatchStagedSegment], URL) async throws -> Void)?
    /// How long a message waits for the watch's answer when nobody says otherwise.
    public var requestTimeout: Duration = .seconds(10)
    /// How long after activation the iPhone first asks the watch for a finished recording's missing segments:
    /// WatchConnectivity hands over what waited for Daybook (files whose transfer finished while it wasn't running) in its
    /// first moments, and an ask before they arrive would have the watch send them again.
    public var asksForMissingAfter: TimeInterval = 30
    /// Whether a recording made for this conversation waits before it imports by itself: the app says so while it may
    /// still file a recording of its own into the conversation, which isn't in the library yet (one its launch recovery
    /// hasn't filed). Filed first, the iPhone's recording makes the conversation (its title, date, and timeline), and the
    /// watch's joins it. Asked again after `importHoldChanged()`.
    public var holdsImport: (UUID) -> Bool = { _ in false }
    /// The watch's connection, looking at its recordings again.
    var onImportHoldChanged: (() -> Void)?

    public init() {}

    /// What `holdsImport` says may have changed: the watch's recordings it held import now.
    public func importHoldChanged() { onImportHoldChanged?() }
}

/// The link to Daybook on Apple Watch (WatchConnectivity's `WCSession` in the app). Observable, so the app can follow
/// whether a watch is paired and has Daybook. Its callbacks belong to the watch's connection.
@MainActor
public protocol WatchTransport: AnyObject, Observable {
    /// WatchConnectivity is activated: whether a watch is paired, has Daybook, and can be reached are known.
    var isActivated: Bool { get }
    /// Activation failed, in its own words (Technical Details). Nil otherwise.
    var activationError: String? { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    /// Daybook on the watch can answer now. Not needed for segments, which arrive while it's in the background.
    var isReachable: Bool { get }
    /// The watch's state as it last published it (its application context), kept across relaunches.
    var watchContext: WatchState? { get }

    /// Starts WatchConnectivity. Calling it again does nothing.
    func activate()
    /// Sends a message now and waits at most `timeout` for the answer. Throws `WatchTransportError` when the watch
    /// can't be reached or doesn't answer.
    func send(_ message: WatchMessage, timeout: Duration) async throws -> WatchReply
    /// Queues a message for whenever Daybook next runs on the watch (`transferUserInfo`): it arrives, in order.
    func queue(_ message: WatchMessage)
    /// Sends a message that has no answer (a receipt): now when the watch is reachable (`sendMessage`), queued when it
    /// isn't or sending fails.
    func tell(_ message: WatchMessage)
    /// Publishes the iPhone's context (`updateApplicationContext`), stamped as it's sent (`PhoneContext.sentAt`): only
    /// the latest reaches the watch.
    func updateContext(_ context: PhoneContext)

    /// A message from the watch (`.state`, `.context`), with how to answer it when the watch waits for an answer.
    var onMessage: ((WatchMessage, ((WatchReply) -> Void)?) -> Void)? { get set }
    /// A segment arrived and is staged (`WatchStaging`).
    var onSegment: ((WatchStagedSegment) -> Void)? { get set }
    /// The watch published its state (its application context).
    var onWatchContext: ((WatchState) -> Void)? { get set }
    /// Activation, pairing, Daybook on the watch, or reachability changed.
    var onChange: (() -> Void)? { get set }
}

/// Why a message to the watch didn't get its answer.
public enum WatchTransportError: Error, Equatable, LocalizedError {
    /// Daybook isn't open on the watch, or WatchConnectivity isn't activated.
    case unreachable
    /// No answer in time.
    case timedOut
    /// An answer this build can't read.
    case unreadable
    /// WatchConnectivity's own error.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Apple Watch can’t be reached."
        case .timedOut: return "Apple Watch didn’t answer in time."
        case .unreadable: return "Apple Watch’s answer couldn’t be read."
        case .failed(let message): return message
        }
    }
}

/// A segment staged on this iPhone, and what the watch said of it.
public struct WatchStagedSegment: Equatable, Sendable {
    public var url: URL
    public var segment: WatchSegment

    public init(url: URL, segment: WatchSegment) {
        self.url = url
        self.segment = segment
    }
}

/// Where the watch's segments wait on this iPhone until their recording is imported: `<staging>/Watch/<recordingID>/`,
/// each segment beside its metadata (`<fileName>.json`), so a segment staged before a relaunch is still known.
public enum WatchStaging {
    public enum Failure: Error, Equatable {
        /// The transfer's metadata isn't a segment this build can read.
        case unreadableMetadata
        /// A recording ID that can't name a folder.
        case badRecordingID
    }

    public static func folder(in staging: URL) -> URL { staging.appendingPathComponent("Watch", isDirectory: true) }

    /// One recording's folder in `folder` (`folder(in:)`); nil for an ID that isn't a plain name.
    public static func recordingFolder(_ recordingID: String, in folder: URL) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !recordingID.isEmpty, recordingID.count <= 128, recordingID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return folder.appendingPathComponent(recordingID, isDirectory: true)
    }

    /// Moves a received segment into place, with its metadata beside it, before returning: WatchConnectivity deletes
    /// the file it delivered once its delegate method returns. Called on WatchConnectivity's queue. `folder` is
    /// `folder(in:)`; `metadata` the transfer's (`WatchPayload`).
    public static func stage(_ file: URL, metadata: [String: Any], in folder: URL) throws -> WatchStagedSegment {
        guard let segment = WatchPayload.decode(WatchSegment.self, from: metadata) else { throw Failure.unreadableMetadata }
        guard segment.recording.id == segment.recordingID, let recording = recordingFolder(segment.recordingID, in: folder) else {
            throw Failure.badRecordingID
        }
        let manager = FileManager.default
        try manager.createDirectory(at: recording, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = recording.appendingPathComponent(segment.fileName)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: file, to: destination)
        try JSONEncoder().encode(segment).write(to: sidecar(of: destination), options: .atomic)
        return WatchStagedSegment(url: destination, segment: segment)
    }

    /// Every segment staged in `folder`, in no particular order: what a relaunch finds.
    public static func staged(in folder: URL) -> [WatchStagedSegment] {
        let manager = FileManager.default
        var found: [WatchStagedSegment] = []
        for recording in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: recording, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension.lowercased() == "m4a" {
                guard let data = try? Data(contentsOf: sidecar(of: file)),
                      let segment = try? JSONDecoder().decode(WatchSegment.self, from: data), segment.fileName == file.lastPathComponent else { continue }
                found.append(WatchStagedSegment(url: file, segment: segment))
            }
        }
        return found
    }

    static func sidecar(of file: URL) -> URL { file.appendingPathExtension("json") }
}
