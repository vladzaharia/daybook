import Combine
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation

/// Daybook on iPhone's *direct* method: Daybook's local link to one paired phone, as a device
/// connection. It gives the device page the phone's presence and recording state, and multipoint
/// its record control. The phone connects to this Mac, never the reverse, so Connect and Disconnect
/// do nothing; recordings arrive through sync (`SyncedPhoneRecordings`), never over the link.
@MainActor
final class PhoneLinkConnection: ObservableObject, AnsweringRecordControl {
    let method = ConnectionMethodKind.direct
    let capabilities: DeviceCapabilities = [.recordControl]
    let phoneID: UUID
    var onChange: (() -> Void)?
    @Published private(set) var recordCommandPending = false

    private let link: PhoneLink
    private var subscription: AnyCancellable?

    init(phoneID: UUID, link: PhoneLink) {
        self.phoneID = phoneID
        self.link = link
        subscription = link.changes.sink { [weak self] id in
            guard let self, id == nil || id == self.phoneID else { return }
            self.objectWillChange.send()
            self.onChange?()
        }
    }

    var peer: LinkPeer? { link.peers[phoneID] }
    /// Paired, or not known yet (the keychain is read once the link starts).
    var isSetUp: Bool { !link.pairingsLoaded || link.isPaired(phoneID) }

    var state: ConnectionState {
        guard isSetUp else { return .notSetUp }
        return peer == nil ? .notConnected : .connected
    }

    var recordings: [DeviceRecording] { [] }
    var inventoryUpdatedAt: Date? { nil }
    var isRefreshing: Bool { false }
    var problem: DeviceProblem? { nil }
    var lastConnectedAt: Date? { link.lastConnected[phoneID] }

    /// What the phone's recorder is doing, as it last said: recording, paused (a call interrupted it;
    /// still its recording, which Stop ends), or nil when idle or not connected.
    var recordingPhase: LinkRecordingState.Phase? {
        guard peer != nil, let phase = link.recordingStates[phoneID]?.phase, [.starting, .recording, .paused, .stopping].contains(phase) else { return nil }
        return phase
    }

    /// The phone's recorder as it last said, with its start on this Mac's clock. A paused recording is
    /// still recording (`recordingPhase` says which).
    var status: DeviceStatus? {
        guard let peer, let recording = link.recordingStates[phoneID] else { return nil }
        let start = recording.startedAt.map { peer.clock?.localDate(fromPeer: $0) ?? $0 }
        return DeviceStatus(isRecording: recordingPhase != nil, recordingStartedAt: start,
                            updatedAt: peer.clock?.localDate(fromPeer: recording.sentAt) ?? Date())
    }

    /// The recorders the phone manages, as it last said (on this Mac's clock), still within their lifetime.
    func recorders(now: Date = Date()) -> [LinkRecorderState] {
        (link.phoneRecorders[phoneID] ?? []).filter { $0.summary(now: now) != nil }
    }

    /// The conversation the phone is recording (or paused in), when it says it's recording one.
    var recordingConversationID: UUID? {
        guard recordingPhase != nil else { return nil }
        return link.recordingStates[phoneID]?.conversationID
    }

    var summary: String {
        switch state {
        case .connected: return "Connected"
        case .notSetUp: return "Not paired"
        default: return "Not connected"
        }
    }

    func activate() {}
    func connect() {}
    func disconnect() {}
    func refresh() {}
    func dismissProblem() {}

    /// Forgetting the method unpairs the phone, on both sides.
    func forget() {
        let link = self.link, phoneID = self.phoneID
        Task { await link.unpair(phoneID) }
    }

    func transfer(_ recording: DeviceRecording, progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        throw DeviceTransferError.rejected("Nothing to import from iPhone.")
    }

    func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] { [] }

    // MARK: Record control

    /// The device page's Start Recording on iPhone: the phone records a new conversation of its own.
    func startRecording() {
        Task { _ = await requestStart(CompanionStart(conversationID: UUID(), standalone: true)) }
    }

    /// The device page's Pause Recording on iPhone: stops what the phone is recording.
    func pauseRecording() {
        guard let conversation = recordingConversationID else { return }
        Task { _ = await requestStop(conversationID: conversation, macEndedAt: Date(), recorder: nil) }
    }

    /// Its clock against this Mac's, as the link measures it now.
    var clock: CompanionClock? { peer?.clock.map(CompanionClock.init) }

    func requestStart(_ start: CompanionStart) async -> CompanionAnswer {
        guard peer != nil else { return .unavailable }
        // A fresh sample now, so the estimate kept with the answer (and refreshed at Stop) rests on it;
        // the request carries the estimate as it stands, usually settled by the burst after connecting.
        await link.sampleClock(of: phoneID)
        let clock = peer?.clock
        // `elapsed` counts the conversation's timeline, which for one recorded into again began earlier.
        let timing = start.macStartedAt.map {
            LinkTiming(startedAt: $0, elapsed: start.timelineStart.map { max(0, Date().timeIntervalSince($0)) },
                       clockOffset: clock?.offset, clockUncertainty: clock?.uncertainty, timelineStart: start.timelineStart)
        }
        return await send(LinkRecordRequest(id: start.requestID, action: .start, conversationID: start.conversationID, timing: timing,
                                            title: start.title, date: start.date, standalone: start.standalone ? true : nil,
                                            recorder: start.recorder))
    }

    func requestStop(conversationID: UUID, macEndedAt: Date?, recorder: LinkRecorderTarget?) async -> CompanionAnswer {
        guard peer != nil else { return .unavailable }
        return await send(LinkRecordRequest(action: .stop, conversationID: conversationID, recorder: recorder))
    }

    /// It starts and stops the recorders it manages when asked (multipoint through their owner).
    var controlsRecorders: Bool { peer?.capabilities.controlsRecorders == true }

    private func send(_ request: LinkRecordRequest) async -> CompanionAnswer {
        recordCommandPending = true
        defer { recordCommandPending = false }
        do {
            let reply = try await link.request(request, from: phoneID)
            let clock = (link.peers[phoneID]?.clock ?? peer?.clock).map(CompanionClock.init)
            switch reply.outcome {
            case .accepted(let ack):
                if request.action == .stop { return .stopped(at: ack.stoppedAt) }
                return .recording(recordingID: ack.recordingID, startedAt: ack.startedAt, alreadyRecording: ack.wasAlreadyRecording, clock: clock)
            case .refused(let refusal):
                return refusal.reason == .notRecording && request.action == .stop ? .stopped(at: nil) : .refused(Self.words(for: refusal))
            }
        } catch LinkError.notConnected {
            return .unavailable
        } catch {
            return .noAnswer
        }
    }

    /// The phone's reason, in a sentence: its own words when it sent some.
    static func words(for refusal: LinkRecordRefusal) -> String {
        if let message = refusal.message, !message.isEmpty { return message }
        switch refusal.reason {
        case .recordingSomethingElse: return "It’s recording another conversation."
        case .microphoneUnavailable: return "Its microphone isn’t available."
        case .permissionDenied: return "Daybook isn’t allowed to use its microphone."
        case .storageFull: return "It’s out of storage."
        case .busy: return "It’s busy."
        case .declined: return "It’s set not to record along with this Mac."
        case .notRecording: return "It isn’t recording."
        default: return "It can’t record right now."
        }
    }
}
