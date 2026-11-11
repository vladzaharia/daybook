import DaybookKit
import Foundation
import Observation

/// Apple Watch as a recorder this iPhone manages (docs/devices.md, "Apple Watch"): the iPhone's side of the link, which
/// `PhoneDevices` makes with the devices and starts with them at launch.
///
/// - **Added by itself** under one ID once WatchConnectivity says the paired watch has Daybook, at launch and whenever
///   that changes. Never removed by itself; one the person removes comes back at the next launch while the watch has
///   Daybook. Nothing about it syncs: a Mac reaches the watch only through this iPhone.
/// - **The shared recording** a Start carries, and what the watch is told (its context): the cascade's conversation, so
///   the watch records along with whatever this iPhone records, also when only its recorder does. Published whenever it, the
///   watch's Record Along, or activation changes, and the answer to the watch's `.context`, each stamped as it's sent
///   (the watch joins only from a fresh one).
/// - **Joining** a recording's segments as this iPhone joins its own (`RecordingAssembler`).
@MainActor
final class PhoneWatch {
    /// The ID the watch is added under: the one WatchConnectivity talks to.
    static let deviceID = "apple-watch"

    let transport: any WatchTransport
    private let hub: DeviceHub
    private let cascade: RecorderCascade
    private let phoneName: String
    private var watches: [ObservationWatch] = []
    private var started = false

    /// What the watch is told, without when.
    struct Context: Equatable {
        var sharedRecording: WatchSharedRecording?
        var recordsAlong: Bool
    }

    /// `hub` was made with `transport` as its watch link (`DeviceEnvironment.watch.transport`).
    /// `phoneName` is this iPhone's ("Alex’s iPhone"), by default.
    init(transport: any WatchTransport, hub: DeviceHub, cascade: RecorderCascade, phoneName: String? = nil) {
        self.transport = transport
        self.hub = hub
        self.cascade = cascade
        self.phoneName = phoneName ?? ProcessingRequest.Device.currentName
        let hooks = hub.environment.watch
        hooks.sharedRecording = { [weak cascade] in cascade.flatMap { Self.sharedRecording($0) } }
        hooks.phoneContext = { [weak self] in self?.phoneContext() ?? PhoneContext() }
        hooks.join = { segments, output in _ = try await Self.join(segments, into: output) }
    }

    /// Activates WatchConnectivity and follows it. Call once, at launch, after the hub starts.
    func start() {
        guard !started else { return }
        started = true
        transport.activate()
        let transport = self.transport
        watches.append(ObservationWatch.distinctValues(of: {
            transport.isActivated && transport.isPaired && transport.isWatchAppInstalled
        }) { [weak self] hasDaybook in
            if hasDaybook { self?.addWatch() }
        })
        // Published once WatchConnectivity is activated, and again whenever what it says changes.
        watches.append(ObservationWatch.distinctValues(of: { [weak self] in
            self.map { Published(context: $0.context, activated: transport.isActivated) }
        }) { [weak self] next in
            guard let next, next.activated else { return }
            self?.publish(next.context)
        })
    }

    private struct Published: Equatable {
        var context: Context
        var activated: Bool
    }

    /// The watch, as a device of this iPhone's: added once, under its ID.
    var session: DeviceSession? { hub.session(Self.deviceID) }

    private func addWatch() {
        guard session == nil else { return }
        hub.add(ConfiguredDevice(id: Self.deviceID, kind: AppleWatchIntegration().kind))
    }

    /// What the watch is told now.
    var context: Context {
        Context(sharedRecording: Self.sharedRecording(cascade), recordsAlong: session?.device.recordsAlongsideMac ?? true)
    }

    /// The answer to the watch's `.context`, stamped as it's given.
    func phoneContext() -> PhoneContext {
        let context = self.context
        return PhoneContext(sharedRecording: context.sharedRecording, recordsAlong: context.recordsAlong, phoneName: phoneName, sentAt: Date())
    }

    /// Stamped again by the transport as it's sent (`WatchTransport.updateContext`).
    private func publish(_ context: Context) {
        transport.updateContext(PhoneContext(sharedRecording: context.sharedRecording, recordsAlong: context.recordsAlong, phoneName: phoneName,
                                             sentAt: Date()))
    }

    /// The cascade's conversation: what this iPhone records now, or only its recorder does.
    static func sharedRecording(_ cascade: RecorderCascade) -> WatchSharedRecording? {
        cascade.conversation.map { WatchSharedRecording(conversationID: $0.id, title: $0.title, startedAt: $0.date ?? Date()) }
    }

    // MARK: Joining

    enum JoinError: LocalizedError {
        case partUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .partUnreadable(let words): return words
            }
        }
    }

    /// Joins the watch's segments as this iPhone joins its own recording's: their AAC packets copied in place, each at
    /// its offset, silence in the gaps (`RecordingAssembler`). Every part, or nothing: a part that can't be read fails
    /// the join, and the recording waits on the device page. The assembler moves a lone whole part into place, so it
    /// joins hard links to the staged parts, which stay until the import is done. The links' folder (`.join-…`) is one
    /// the app ended mid-join leaves behind: the connection clears it at its next activation.
    @discardableResult
    static func join(_ segments: [WatchStagedSegment], into output: URL) async throws -> RecordingAssembler.Result {
        let format = RecordingFormat(sampleRate: WatchAudioFormat.speech.sampleRate, bitRate: WatchAudioFormat.speech.bitRate)
        let manager = FileManager.default
        let links = output.deletingLastPathComponent().appendingPathComponent(".join-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: links, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: links) }
        var pieces: [RecordingAssembler.Piece] = []
        for staged in segments {
            let link = links.appendingPathComponent(staged.url.lastPathComponent)
            try manager.linkItem(at: staged.url, to: link)
            pieces.append(RecordingAssembler.Piece(url: link, startOffset: staged.segment.startOffset, cleanlyClosed: staged.segment.cleanlyClosed))
        }
        let result = try await RecordingAssembler.assemble(pieces, into: output, format: format)
        guard result.warnings.isEmpty else {
            try? manager.removeItem(at: output)
            throw JoinError.partUnreadable(result.warnings.joined(separator: " "))
        }
        return result
    }
}
