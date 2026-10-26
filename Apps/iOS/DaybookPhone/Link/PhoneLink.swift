import DaybookKit
import DaybookLink
import Foundation
import Observation

/// The phone's end of DaybookLink (docs/link.md): pairing with a Mac by the code shown in its
/// Settings, keeping a connection to each paired Mac through the link's lifecycle, and what travels
/// over it: live processing progress, record control for multipoint, recording state, bookmarks,
/// clock samples, and processing-request nudges. Without the link everything still works through
/// sync, only later.
@MainActor
@Observable
final class PhoneLink {
    /// A paired Mac and how it's doing.
    struct Mac: Identifiable, Equatable {
        var id: UUID
        var name: String
        var pairedAt: Date
        var state: LinkConnectionState = .idle
        /// From its capabilities once connected.
        var canProcess = false
        var appVersion: String?
        /// Its recorder, from `recording.state`, with `sentAt` on this iPhone's clock. Nil when it said
        /// it's idle, or when it hasn't said for `recordingStateLifetime` (it repeats it while recording).
        var recording: LinkRecordingState?
        /// Its clock relative to this iPhone's, once samples are in (offset = Mac − iPhone).
        var clock: LinkClockEstimate?
        var lastConnectedAt: Date?
        /// Its sync replica ID (a Mac's equals its link ID) and whether it hands recorders over.
        var syncDeviceID: String?
        var handsOffRecorders = false

        var isConnected: Bool { state == .connected }
        var isRecording: Bool { recording?.phase == .recording || recording?.phase == .paused || recording?.phase == .starting }

        /// "Connected", "Looking for it…", "Not on this network", "Pair again on your Mac".
        var stateLine: String {
            switch state {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .searching: return "Looking for it on this network…"
            case .waitingToRetry: return "Not reachable right now · trying again"
            case .waitingForNetwork: return "Waiting for Wi-Fi"
            case .suspended, .idle: return lastConnectedAt.map { "Last connected \(MacPresence.age(Date().timeIntervalSince($0)))" } ?? "Not connected"
            case .failed(let reason):
                switch reason {
                case .authenticationFailed, .notPaired: return "This Mac doesn't recognise this iPhone any more. Pair again."
                case .incompatibleVersion: return "Update Daybook on this iPhone or the Mac to connect."
                default: return "Couldn't connect"
                }
            }
        }
    }

    private(set) var macs: [Mac] = []
    /// Macs on this network, while the pairing screen browses.
    private(set) var discovered: [LinkDiscoveredMac] = []
    @ObservationIgnored private var demoCandidates: [PairingCandidate]?

    /// A Mac the pairing screen offers.
    struct PairingCandidate: Identifiable, Equatable {
        var id: String
        var name: String
        var endpoint: LinkEndpoint
        /// It's showing a pairing code now.
        var isPairing: Bool
        var isPaired: Bool
        /// It has this iPhone's library open.
        var sharesLibrary: Bool?
    }

    /// Macs to pair with, showing a code first.
    var candidates: [PairingCandidate] {
        if let demoCandidates { return demoCandidates }
        return discovered.map {
            PairingCandidate(id: $0.id, name: $0.serviceName, endpoint: $0.endpoint, isPairing: $0.isPairing,
                             isPaired: $0.pairedDeviceID != nil, sharesLibrary: $0.sharesLibrary)
        }
        .sorted { ($0.isPairing ? 0 : 1, $0.name) < ($1.isPairing ? 0 : 1, $1.name) }
    }
    private(set) var isBrowsing = false
    /// Live processing progress from connected Macs, by conversation.
    private(set) var liveProgress: [UUID: LiveProgress] = [:]
    private(set) var started = false

    /// Answers a Mac's record request (start or stop recording here). Set by the app model.
    @ObservationIgnored var recordRequestHandler: (@MainActor (Mac, LinkRecordRequest) async -> LinkRecordReply.Outcome)?
    /// A Mac finished processing a conversation: sync to fetch the result.
    @ObservationIgnored var onProcessingFinished: ((UUID) -> Void)?
    /// A recorder handoff message from a Mac (the app model hands it to `RecorderHandoff`).
    @ObservationIgnored var onHandoffMessage: ((LinkMessage, UUID) -> Void)?
    /// A Mac connected or went away.
    @ObservationIgnored var onMacsChanged: (() -> Void)?
    /// A Mac connected (again): what's waiting for it (a stop) can go now.
    @ObservationIgnored var onMacConnected: ((UUID) -> Void)?
    /// A Mac said what it's recording, or that it's idle.
    @ObservationIgnored var onMacRecordingState: ((UUID, LinkRecordingState) -> Void)?

    /// A Mac's word on its recorder lasts this long; it repeats it every 15 s while recording.
    static let recordingStateLifetime: TimeInterval = 45

    @ObservationIgnored let client: LinkClient
    @ObservationIgnored private var identity: LinkIdentity
    @ObservationIgnored private let keyStore: any LinkKeyStore
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var pruning: Task<Void, Never>?
    /// Fixed addresses for Macs (tests over loopback, which have no Bonjour).
    @ObservationIgnored private var endpoints: [UUID: LinkEndpoint] = [:]

    init(identity: LinkIdentity, keyStore: any LinkKeyStore, configuration: LinkConfiguration = LinkConfiguration()) {
        self.identity = identity
        self.keyStore = keyStore
        client = LinkClient(identity: identity, keyStore: keyStore, configuration: configuration)
    }

    /// This iPhone on the link: its stable installation ID, its name, and the library it has open.
    static func identity(installation: String, name: String, libraryID: UUID?, syncDeviceID: String? = nil) -> LinkIdentity {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return LinkIdentity(deviceID: UUID(uuidString: installation) ?? UUID(), name: name, deviceClass: .iPhone,
                            appVersion: version, libraryID: libraryID, canProcess: false,
                            features: ["recordControl", "bookmarks", LinkCapabilities.recorderHandoffFeature], syncDeviceID: syncDeviceID)
    }

    var deviceID: UUID { identity.deviceID }

    // MARK: Lifecycle

    /// Listens for events, answers record requests, and keeps a connection to every paired Mac.
    func start() async {
        guard !started else { return }
        started = true
        let stream = client.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        await client.setRecordControlHandler { [weak self] peer, request in
            await self?.answer(peer, request) ?? .refused(LinkRecordRefusal(reason: .unsupported))
        }
        reloadPaired()
        for mac in macs { try? await client.connect(to: mac.id, via: endpoints[mac.id]) }
        pruning = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.pruneProgress()
                self?.pruneRecordingStates()
            }
        }
    }

    /// Scene phase and recording decide how hard the link works (docs/link.md, "Lifecycle").
    func setActivity(_ activity: LinkActivity) async {
        await client.setActivity(activity)
        if activity == .foreground { await client.systemDidWake() }
    }

    /// The library's identity changed (first sync): Bonjour tags and the Mac's view follow it.
    func updateLibrary(_ libraryID: UUID?) async {
        guard identity.libraryID != libraryID else { return }
        identity.libraryID = libraryID
        await client.updateIdentity(identity)
    }

    // MARK: Pairing

    func startBrowsing() async {
        isBrowsing = true
        guard demoCandidates == nil else { return }
        await client.startBrowsing()
        discovered = await client.discoveredMacs
    }

    func stopBrowsing() async {
        isBrowsing = false
        guard demoCandidates == nil else { return }
        await client.stopBrowsing()
    }

    /// Pairs with the code shown in the Mac's Settings › Devices › Add iPhone, then connects. Throws
    /// `LinkPairingError` (wrong code, expired, busy …); `message(for:)` puts it in words.
    @discardableResult
    func pair(with endpoint: LinkEndpoint, code: String) async throws -> LinkPairedDevice {
        let paired = try await client.pair(with: endpoint, code: code)
        endpoints[paired.deviceID] = endpointIsFixed(endpoint) ? endpoint : nil
        reloadPaired()
        try? await client.connect(to: paired.deviceID, via: endpoints[paired.deviceID])
        return paired
    }

    /// Loopback addresses (tests) are kept; Bonjour results are looked up again each time.
    private func endpointIsFixed(_ endpoint: LinkEndpoint) -> Bool { endpoint.description.hasPrefix("127.0.0.1") }

    func unpair(_ macID: UUID) async {
        try? await client.unpair(macID)
        endpoints[macID] = nil
        reloadPaired()
    }

    static func message(for error: Error) -> String {
        guard let error = error as? LinkPairingError else { return "Couldn't pair: \(error.localizedDescription)" }
        switch error {
        case .invalidCode: return "Type the six digits shown on your Mac."
        case .codeAlreadyUsed: return "That code was already tried. Your Mac shows a new one; type that."
        case .codeRejected: return "That code didn't match. Your Mac now shows a new code; try that one."
        case .notPairing: return "The Mac isn't showing a code. On your Mac, open Daybook › Settings › Devices and add your iPhone."
        case .busy: return "Another device is pairing with this Mac. Try again in a minute."
        case .timedOut: return "Pairing took too long. Try again with the code your Mac shows now."
        case .tooManyAttempts: return "Too many tries. On your Mac, close and reopen pairing for a new code."
        case .unsupportedVersion: return "Update Daybook on this iPhone or the Mac to pair."
        case .expired: return "That code expired. Type the new code your Mac shows."
        case .connectionFailed: return "Couldn't reach the Mac. Make sure both are on the same Wi-Fi."
        case .protocolViolation: return "Couldn't pair with this Mac. Try again with the code it shows now."
        }
    }

    // MARK: Sending

    var connectedMacs: [Mac] { macs.filter(\.isConnected) }

    /// Asks a Mac to start or stop recording this conversation too. The answer, or why there isn't one.
    func request(_ action: LinkRecordRequest.Action, conversationID: UUID, timing: LinkTiming?, title: String? = nil, date: Date? = nil,
                 from macID: UUID) async -> Result<LinkRecordAck, RecordRequestFailure> {
        do {
            let reply = try await client.request(LinkRecordRequest(action: action, conversationID: conversationID, timing: timing,
                                                                   title: title, date: date), from: macID)
            switch reply.outcome {
            case .accepted(let ack): return .success(ack)
            case .refused(let refusal): return .failure(.refused(refusal))
            }
        } catch {
            return .failure(.unreachable)
        }
    }

    enum RecordRequestFailure: Error, Equatable {
        case refused(LinkRecordRefusal)
        case unreachable

        func message(mac: String) -> String {
            switch self {
            case .unreachable: return "\(mac) didn't answer. Recording on this iPhone only."
            case .refused(let refusal):
                if let message = refusal.message { return message }
                switch refusal.reason {
                case .recordingSomethingElse: return "\(mac) is recording another conversation."
                case .microphoneUnavailable: return "\(mac) can't use its microphone right now."
                case .permissionDenied: return "\(mac) isn't allowed to record. Check its Privacy settings."
                case .storageFull: return "\(mac) is out of space."
                case .busy: return "\(mac) is busy. Try again in a moment."
                case .declined: return "\(mac) declined to record."
                case .notRecording: return "\(mac) isn't recording this conversation."
                default: return "\(mac) can't record with this iPhone."
                }
            }
        }
    }

    /// "I just wrote this request": a connected Mac looks now instead of at its next sync.
    func nudge(_ request: ProcessingRequest) {
        let mode: LinkProcessingNudge.Mode
        switch request.mode {
        case .newAudio: mode = .transcribe
        case .summaryOnly: mode = request.templateID == nil ? .summarizeAgain : .changeTemplate
        case .speakerRefresh: mode = .identifySpeakersAgain
        case .fullRetranscription: mode = .transcribeEverythingAgain
        }
        let nudge = LinkProcessingNudge(requestID: request.id, meetingID: request.meetingID, mode: mode, requestedAt: request.createdAt)
        guard !connectedMacs.isEmpty else { return }
        Task { try? await client.send(.processingNudge(nudge)) }
    }

    func sendRecordingState(_ state: LinkRecordingState) {
        guard !connectedMacs.isEmpty else { return }
        Task { try? await client.send(.recordingState(state)) }
    }

    /// Sends to one connected Mac (a recorder handoff's request, answer, or release).
    func send(_ message: LinkMessage, to macID: UUID) async throws {
        try await client.send(message, to: macID)
    }

    func sendBookmark(_ bookmark: LinkBookmark) {
        guard !connectedMacs.isEmpty else { return }
        Task { try? await client.send(.bookmark(bookmark)) }
    }

    /// Fresh clock samples from every connected Mac (at the start of a recording).
    func sampleClocks() {
        for mac in connectedMacs { Task { await client.sampleClock(of: mac.id) } }
    }

    /// The latest clock comparison with each Mac that has one, for the recording's metadata.
    func peerClocks(peerRecordingStart: (Mac) -> Date? = { _ in nil }) -> [CapturePeerClock] {
        macs.compactMap { mac in
            guard let clock = mac.clock else { return nil }
            return CapturePeerClock(deviceID: mac.id.uuidString, name: mac.name, deviceClass: LinkDeviceClass.mac.rawValue,
                                    offset: clock.offset, uncertainty: clock.uncertainty, sampleCount: clock.sampleCount,
                                    measuredAt: clock.measuredAt, peerRecordingStartedAt: peerRecordingStart(mac))
        }
    }

    // MARK: Tests and diagnostics

    /// Connects to a Mac at a fixed address (loopback tests have no Bonjour).
    func use(_ endpoint: LinkEndpoint, for macID: UUID) { endpoints[macID] = endpoint }

    #if DEBUG
    /// Debug demos: Macs and progress for screenshots, with nothing on the network.
    func applyDemo(macs: [Mac], candidates: [PairingCandidate] = [], progress: [LiveProgress] = []) {
        self.macs = macs
        demoCandidates = candidates
        liveProgress = Dictionary(progress.map { ($0.meetingID, $0) }, uniquingKeysWith: { a, _ in a })
        started = true
    }
    #endif

    // MARK: Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .discovered(let found):
            discovered = found
        case .paired, .unpaired:
            reloadPaired()
        case .connectionState(let id, let state):
            update(id) { $0.state = state }
            onMacsChanged?()
        case .connected(let peer), .peerUpdated(let peer):
            update(peer.deviceID) { mac in
                mac.state = .connected
                mac.name = peer.name
                mac.canProcess = peer.capabilities.canProcess
                mac.appVersion = peer.capabilities.appVersion
                mac.clock = peer.clock ?? mac.clock
                mac.lastConnectedAt = Date()
                mac.syncDeviceID = peer.capabilities.syncDeviceID ?? peer.deviceID.uuidString
                mac.handsOffRecorders = peer.capabilities.handsOffRecorders
            }
            onMacsChanged?()
            if case .connected = event { onMacConnected?(peer.deviceID) }
        case .disconnected(let id, _):
            update(id) { mac in
                mac.lastConnectedAt = Date()
                mac.recording = nil
            }
            liveProgress = liveProgress.filter { $0.value.macName != macs.first(where: { $0.id == id })?.name }
            onMacsChanged?()
        case .received(let message, let from):
            receive(message, from: from)
        case .pairingCode, .pairingFailed:
            break
        }
    }

    private func receive(_ message: LinkMessage, from macID: UUID) {
        switch message {
        case .processingProgress(let progress):
            let live = LiveProgress(progress)
            if live.isFinished {
                liveProgress[progress.meetingID] = live.phase == .failed ? live : nil
                onProcessingFinished?(progress.meetingID)
            } else {
                liveProgress[progress.meetingID] = live
            }
        case .recordingState(let state):
            var heard = state
            heard.sentAt = macs.first(where: { $0.id == macID })?.clock?.localDate(fromPeer: state.sentAt) ?? Date()
            update(macID) { $0.recording = state.phase == .idle ? nil : heard }
            onMacRecordingState?(macID, heard)
        case .bookmark, .processingNudge:
            // A Mac's bookmarks are on its own recording and arrive with it through sync.
            break
        case .recorderHandoffRequest, .recorderHandoffReply, .recorderRelease:
            onHandoffMessage?(message, macID)
        }
    }

    private func answer(_ peer: LinkPeer, _ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
        guard let handler = recordRequestHandler else { return .refused(LinkRecordRefusal(reason: .unsupported)) }
        let mac = macs.first(where: { $0.id == peer.deviceID })
            ?? Mac(id: peer.deviceID, name: peer.name, pairedAt: Date(), state: .connected, canProcess: peer.capabilities.canProcess, clock: peer.clock)
        var current = mac
        current.clock = peer.clock ?? mac.clock
        return await handler(current, request)
    }

    private func pruneProgress(now: Date = Date()) {
        let fresh = liveProgress.filter { now.timeIntervalSince($0.value.receivedAt) < LiveProgress.staleAfter }
        if fresh.count != liveProgress.count { liveProgress = fresh }
    }

    /// A Mac that stopped saying it's recording may have stopped (or gone): what it said no longer counts.
    func pruneRecordingStates(now: Date = Date()) {
        for mac in macs {
            guard let state = mac.recording, now.timeIntervalSince(state.sentAt) > Self.recordingStateLifetime else { continue }
            update(mac.id) { $0.recording = nil }
        }
    }

    private func reloadPaired() {
        let paired = (try? keyStore.records().map(\.device)) ?? []
        let previous = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        macs = paired.sorted { $0.pairedAt < $1.pairedAt }.map { device in
            var mac = previous[device.deviceID] ?? Mac(id: device.deviceID, name: device.name, pairedAt: device.pairedAt)
            mac.name = previous[device.deviceID]?.name ?? device.name
            return mac
        }
    }

    private func update(_ id: UUID, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        var mac = macs[index]
        change(&mac)
        if mac != macs[index] { macs[index] = mac }
    }
}
