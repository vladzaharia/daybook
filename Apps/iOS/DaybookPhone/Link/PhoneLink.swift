import DaybookKit
import DaybookLink
import DaybookUI
import Foundation
import Observation
import os

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
        /// It joins and stops shared recordings on its own (`LinkCapabilities.cascadeFeature`) and takes
        /// notes and bookmarks over the link (`sharedNotesFeature`), from its capabilities.
        var cascades = false
        var sharesNotes = false
        /// It shows this iPhone's live captions of a shared recording beside its own (`liveCaptionsFeature`).
        var showsCaptions = false
        /// It draws this iPhone's input level during a shared recording beside its own meters (`liveLevelsFeature`).
        var showsLevels = false
        /// The synced library it has open, from its capabilities.
        var libraryID: UUID?
        /// What it does for other devices with its models, from its capabilities; nil from an earlier Daybook,
        /// which says only `canProcess`.
        var processing: ProcessingCapabilities?
        /// It shows its summary countdowns here and takes this iPhone's choice (`summaryPlacementFeature`).
        var placesSummaries = false
        /// It can take a summary this iPhone sends it.
        var summarizes: Bool { processing?.summarizes ?? canProcess }
        /// The recorders it manages, as it last said, on this iPhone's clock; kept after it disconnects,
        /// for as long as that can be trusted (`LinkRecorderState.lifetime`).
        var recorders: [LinkRecorderState] = []
        /// It stops what it records when this iPhone's page for it asks (`LinkCapabilities.pageStopFeature`).
        var stopsForPages = false
        /// Its pairing is here but can't be read: it can't connect until it's paired again.
        var isDamaged = false

        var isConnected: Bool { state == .connected }
        var isRecording: Bool { recording?.phase == .recording || recording?.phase == .paused || recording?.phase == .starting }

        /// What keeps it from connecting, for its page: a pairing to make again, or a Daybook to update.
        var problem: PeerPage.Problem? {
            if isDamaged { return .damaged }
            guard case .failed(let reason) = state else { return nil }
            switch reason {
            case .authenticationFailed, .notPaired: return .notRecognized
            case .incompatibleVersion(let versions): return .incompatible(peerVersions: versions)
            default: return nil
            }
        }

        /// "Connected", "Looking for it…", "Last seen today, 3:25 AM", "Needs pairing again".
        var stateLine: String { stateLine(now: Date()) }

        func stateLine(now: Date) -> String {
            if isDamaged { return PairingWords.needsPairingAgain }
            switch state {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .searching: return "Looking for it on this network…"
            case .waitingToRetry: return "Not reachable right now · trying again"
            case .waitingForNetwork: return "Waiting for Wi‑Fi"
            case .suspended, .idle:
                return lastConnectedAt.map { "Not connected · \(RecorderStatusWords.lastSeen($0, now: now))" } ?? "Not connected"
            case .failed(let reason):
                switch reason {
                case .authenticationFailed, .notPaired: return PairingWords.needsPairingAgain
                case .incompatibleVersion(let versions):
                    return PairingWords.update(name, here: PairingWords.here(.iPhone), peerVersions: versions)
                default: return "Couldn’t connect"
                }
            }
        }
    }

    private(set) var macs: [Mac] = []
    /// Macs on this network, while the pairing screen browses.
    private(set) var discovered: [LinkDiscoveredMac] = []
    /// Whether Macs can be found: browsing, not, or refused the Local Network permission.
    private(set) var discovery: LinkDiscoveryState = .idle
    @ObservationIgnored private var demoCandidates: [PairingCandidate]?

    /// A Mac the pairing screen lists.
    struct PairingCandidate: Identifiable, Equatable {
        var id: String
        var name: String
        var endpoint: LinkEndpoint
        /// It's showing a pairing code now.
        var isPairing: Bool
        var isPaired: Bool
        /// It has this iPhone's library open.
        var sharesLibrary: Bool?
        /// It has another library open (another Apple ID, or another library) and isn't paired here: listed,
        /// dimmed, so it can be told from no Mac at all, but not offered.
        var usesAnotherLibrary = false
        /// The paired Mac it is, by its link ID.
        var pairedMacID: UUID?

        /// What its row says.
        var line: String {
            if usesAnotherLibrary { return PairingWords.usesAnotherLibrary }
            if isPaired { return PairingWords.alreadyPaired }
            return isPairing ? PairingWords.showingACode : PairingWords.notShowingACode
        }
    }

    /// Macs to pair with, showing a code first; Macs of another library last.
    var candidates: [PairingCandidate] {
        if let demoCandidates { return demoCandidates }
        return discovered.map {
            PairingCandidate(id: $0.id, name: $0.serviceName, endpoint: $0.endpoint, isPairing: $0.isPairing,
                             isPaired: $0.pairedDeviceID != nil, sharesLibrary: $0.sharesLibrary,
                             usesAnotherLibrary: $0.usesAnotherLibrary, pairedMacID: $0.pairedDeviceID)
        }
        .sorted { (Self.rank($0), $0.name) < (Self.rank($1), $1.name) }
    }

    private static func rank(_ candidate: PairingCandidate) -> Int {
        candidate.usesAnotherLibrary ? 2 : candidate.isPairing ? 0 : 1
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
    /// An encrypted library's key asked for, or sent, by a Mac (the app model answers or keeps it).
    @ObservationIgnored var onLibraryKeyMessage: ((LinkMessage, UUID) -> Void)?
    /// A Mac connected or went away.
    @ObservationIgnored var onMacsChanged: (() -> Void)?
    /// A Mac connected (again): what's waiting for it (a stop) can go now.
    @ObservationIgnored var onMacConnected: ((UUID) -> Void)?
    /// A Mac said what it's recording, or that it's idle.
    @ObservationIgnored var onMacRecordingState: ((UUID, LinkRecordingState) -> Void)?
    /// A Mac wrote a note or made or changed a bookmark while it records a conversation with this iPhone.
    @ObservationIgnored var onSharedNotes: ((LinkMessage, UUID) -> Void)?
    /// A Mac's live progress on a conversation (its summary's countdown among them).
    @ObservationIgnored var onLiveProgress: ((LiveProgress) -> Void)?

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
                            features: [LinkCapabilities.recordControlFeature, LinkCapabilities.bookmarksFeature,
                                       LinkCapabilities.recorderHandoffFeature, LinkCapabilities.recorderControlFeature,
                                       LinkCapabilities.cascadeFeature, LinkCapabilities.sharedNotesFeature],
                            syncDeviceID: syncDeviceID)
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
        await connectPaired()
        pruning = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.pruneProgress()
                self?.pruneRecordingStates()
            }
        }
    }

    /// Keeps a connection to every paired Mac whose pairing can be read.
    private func connectPaired() async {
        for mac in macs where !mac.isDamaged { try? await client.connect(to: mac.id, via: endpoints[mac.id]) }
    }

    /// Scene phase and recording decide how hard the link works (docs/link.md, "Lifecycle"). Coming to the
    /// foreground reads the pairings again when the last read failed.
    func setActivity(_ activity: LinkActivity) async {
        await client.setActivity(activity)
        guard activity == .foreground else { return }
        if pairedReadFailed { await retryPaired() }
        await client.systemDidWake()
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

    /// Forgets a Mac on both sides (it hears it when it's connected). Throws when the keychain refuses: the
    /// pairing is still there.
    func unpair(_ macID: UUID) async throws {
        try await client.unpair(macID)
        endpoints[macID] = nil
        reloadPaired()
    }

    static func message(for error: Error) -> String {
        guard let error = error as? LinkPairingError else { return "Couldn’t pair with this Mac. Try again with the code it shows now." }
        switch error {
        case .invalidCode: return "Type the six digits shown on your Mac."
        case .codeAlreadyUsed: return "That code was already tried. Type the code your Mac shows now, or close and reopen pairing there for a new one."
        case .codeRejected: return "That code didn’t match. Your Mac now shows a new code; try that one."
        case .notPairing: return "The Mac isn’t showing a code. \(PairingWords.onTheMac)"
        case .busy: return "Another device is pairing with this Mac. Try again in a minute."
        case .timedOut: return "Pairing took too long. Try again with the code your Mac shows now."
        case .tooManyAttempts: return "Too many tries. On your Mac, close and reopen pairing for a new code."
        case .unsupportedVersion: return "Update Daybook on this iPhone or the Mac to pair."
        case .expired: return "That code expired. Type the new code your Mac shows."
        case .connectionFailed: return "Couldn’t reach the Mac. Make sure both are on the same Wi‑Fi."
        case .protocolViolation: return "Couldn’t pair with this Mac. Try again with the code it shows now."
        }
    }

    // MARK: Sending

    var connectedMacs: [Mac] { macs.filter(\.isConnected) }

    /// Asks a Mac to start or stop recording this conversation too. The answer, or why there isn't one.
    /// `id` names the request: sent again with the same ID (after a lost answer), the Mac answers once.
    func request(_ action: LinkRecordRequest.Action, id: UUID = UUID(), conversationID: UUID, timing: LinkTiming?, title: String? = nil,
                 date: Date? = nil, cascade: LinkCascade? = nil, from macID: UUID) async -> Result<LinkRecordAck, RecordRequestFailure> {
        do {
            let reply = try await client.request(LinkRecordRequest(id: id, action: action, conversationID: conversationID, timing: timing,
                                                                   title: title, date: date, cascade: cascade), from: macID)
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
            case .unreachable: return "\(mac) didn’t answer. Recording on this iPhone only."
            case .refused(let refusal):
                if let message = refusal.message { return message }
                switch refusal.reason {
                case .recordingSomethingElse: return "\(mac) is recording another conversation."
                case .microphoneUnavailable: return "\(mac) can’t use its microphone right now."
                case .permissionDenied: return "\(mac) isn’t allowed to record. Check its Privacy settings."
                case .storageFull: return "\(mac) is out of space."
                case .busy: return "\(mac) is busy. Try again in a moment."
                case .declined: return PairingWords.declined(mac, here: PairingWords.here(.iPhone))
                case .notRecording: return "\(mac) isn’t recording this conversation."
                default: return "\(mac) can’t record with this iPhone."
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
        enqueue(.nudges) { try? await $0.send(.processingNudge(nudge)) }
    }

    /// The person's choice here for a summary a Mac counts down to: Use the Cloud or Start Now, sent to that Mac.
    func sendSummaryChoice(_ choice: LinkSummaryChoice.Choice, for meetingID: UUID, to macID: UUID) {
        guard macs.contains(where: { $0.id == macID && $0.isConnected }) else { return }
        let message = LinkMessage.summaryChoice(LinkSummaryChoice(meetingID: meetingID, choice: choice))
        enqueue(.choices) { try? await $0.send(message, to: macID) }
    }

    /// What this iPhone is recording, to every connected Mac, in the order it changes (a stop's `.stopping`, then
    /// `.idle`, never the other way round).
    func sendRecordingState(_ state: LinkRecordingState) {
        guard !connectedMacs.isEmpty else { return }
        enqueue(.recordingState) { try? await $0.send(.recordingState(state)) }
    }

    /// Sends to one connected Mac (a recorder handoff's request, answer, or release).
    func send(_ message: LinkMessage, to macID: UUID) async throws {
        try await client.send(message, to: macID)
    }

    /// A bookmark made here, to every connected Mac, in order with the notes and bookmark changes after it.
    func sendBookmark(_ bookmark: LinkBookmark) {
        guard !connectedMacs.isEmpty else { return }
        enqueue(.notes) { try? await $0.send(.bookmark(bookmark)) }
    }

    /// Notes and bookmark changes for the Macs recording a conversation with this iPhone, in order.
    func sendShared(_ messages: [LinkMessage], to macIDs: [UUID]) {
        guard !messages.isEmpty, !macIDs.isEmpty else { return }
        enqueue(.notes) { client in
            for mac in macIDs {
                for message in messages { try? await client.send(message, to: mac) }
            }
        }
    }

    /// Messages that must arrive in the order they were made, one chain each.
    enum SendChannel: Hashable {
        case recordingState
        /// Bookmarks, notes, and bookmark changes: a change never overtakes the bookmark it changes.
        case notes
        case nudges
        case choices
    }

    @ObservationIgnored private var sends: [SendChannel: Task<Void, Never>] = [:]

    /// Runs `send` once the channel's earlier sends are done, so they go out in the order they were made.
    private func enqueue(_ channel: SendChannel, _ send: @escaping @Sendable (LinkClient) async -> Void) {
        let previous = sends[channel], client = client
        sends[channel] = Task {
            await previous?.value
            await send(client)
        }
    }

    /// Every send made so far has gone (tests).
    func sendsSettled() async {
        for task in sends.values { await task.value }
    }

    /// Sends this iPhone's input level to the Macs that draw it. Levels go on their own, never queued
    /// behind captions or notes: while one is still on its way, the next is dropped (the Mac's meter
    /// holds), so a slow link never delivers them late.
    func sendLevels(_ levels: LinkLevels, to macIDs: [UUID]) {
        guard levelSend == nil, !macIDs.isEmpty else { return }
        levelSend = Task { [weak self, client] in
            for mac in macIDs { try? await client.send(.levels(levels), to: mac) }
            self?.levelSend = nil
        }
    }

    @ObservationIgnored private var levelSend: Task<Void, Never>?

    /// What the Mac managing a recorder last said about it, and that Mac's name; nil once too old to say.
    func recorderReport(kind: String, serial: String?, now: Date = Date()) -> (mac: String, state: LinkRecorderState)? {
        macs.flatMap { mac in mac.recorders.filter { $0.describes(kind: kind, serial: serial) }.map { (mac.name, $0) } }
            .filter { $0.1.summary(now: now) != nil }
            .max { $0.1.asOf < $1.1.asOf }
    }

    /// Stop on <Mac>, from its page: asks it to stop what it's recording (a page's stop, which a Mac listing
    /// `pageStopFeature` takes when this iPhone can start recording on it). Nil when it stopped; otherwise why not.
    func stopRecording(on macID: UUID) async -> String? {
        guard let mac = macs.first(where: { $0.id == macID }), let conversation = mac.recording?.conversationID else { return nil }
        stopsInFlight.insert(macID)
        defer { stopsInFlight.remove(macID) }
        do {
            let reply = try await client.request(LinkRecordRequest(action: .stop, conversationID: conversation, standalone: true), from: macID)
            switch reply.outcome {
            case .accepted: return nil
            case .refused(let refusal) where refusal.reason == .notRecording: return nil
            case .refused(let refusal): return RecordRequestFailure.refused(refusal).message(mac: mac.name)
            }
        } catch {
            return RecordRequestFailure.unreachable.message(mac: mac.name)
        }
    }

    /// Macs a page's stop is on its way to.
    private(set) var stopsInFlight: Set<UUID> = []

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
    /// Debug demos: Macs and progress for screenshots, with nothing on the network. Macs to pair with come with
    /// one that has another library open, as a Mac signed in to another Apple ID shows.
    func applyDemo(macs: [Mac], candidates: [PairingCandidate] = [], progress: [LiveProgress] = []) {
        self.macs = macs
        demoCandidates = candidates.isEmpty ? [] : candidates + [
            PairingCandidate(id: "Home Mac mini", name: "Home Mac mini", endpoint: LinkEndpoint(host: "192.0.2.11", port: 7000),
                             isPairing: false, isPaired: false, sharesLibrary: false, usesAnotherLibrary: true)
        ]
        liveProgress = Dictionary(progress.map { ($0.meetingID, $0) }, uniquingKeysWith: { a, _ in a })
        discovery = .searching
        started = true
    }

    /// Debug demos: finding Macs in a state (Local Network refused).
    func applyDemo(discovery: LinkDiscoveryState) {
        self.discovery = discovery
        demoCandidates = []
    }
    #endif

    // MARK: Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .discovered(let found):
            discovered = found
        case .discovery(let state):
            guard demoCandidates == nil else { return }
            discovery = state
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
                mac.libraryID = peer.capabilities.libraryID
                mac.cascades = peer.capabilities.cascades
                mac.sharesNotes = peer.capabilities.sharesNotes
                mac.showsCaptions = peer.capabilities.showsCaptions
                mac.showsLevels = peer.capabilities.showsLevels
                mac.processing = peer.capabilities.processing.map(ProcessingCapabilities.init)
                mac.placesSummaries = peer.capabilities.placesSummaries
                mac.stopsForPages = peer.capabilities.stopsForPages
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
            let live = LiveProgress(progress, from: macID)
            if live.isFinished {
                liveProgress[progress.meetingID] = live.phase == .failed ? live : nil
                onProcessingFinished?(progress.meetingID)
            } else {
                liveProgress[progress.meetingID] = live
            }
            onLiveProgress?(live)
        case .recordingState(let state):
            var heard = state
            let clock = macs.first(where: { $0.id == macID })?.clock
            heard.sentAt = clock?.localDate(fromPeer: state.sentAt) ?? Date()
            update(macID) { mac in
                mac.recording = state.phase == .idle ? nil : heard
                if let recorders = state.recorders { mac.recorders = recorders.map { $0.moved { clock?.localDate(fromPeer: $0) ?? $0 } } }
            }
            onMacRecordingState?(macID, heard)
        case .bookmark, .note, .bookmarkChange:
            // While a Mac records a conversation with this iPhone, its notes and bookmarks show here too.
            onSharedNotes?(message, macID)
        case .processingNudge, .captions, .levels, .summaryChoice:
            // A Mac's captions stay on the Mac; this iPhone shows its own. Levels and choices go the other way.
            break
        case .recorderHandoffRequest, .recorderHandoffReply, .recorderRelease:
            onHandoffMessage?(message, macID)
        case .libraryKeyRequest, .libraryKeyGrant:
            onLibraryKeyMessage?(message, macID)
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

    /// Reads the paired Macs from the keychain, a pairing that can't be read among them. A read that fails keeps
    /// the Macs it had (and what they last said), and tries again later: after `pairedRetryDelay` (doubling),
    /// when the app comes to the foreground, and at the next start.
    private func reloadPaired() {
        let paired: [LinkPairedDevice]
        do {
            paired = try keyStore.pairedDevices()
        } catch {
            Self.log.error("Couldn’t read the paired Macs: \(String(describing: error), privacy: .public)")
            pairedReadFailed = true
            schedulePairedRetry()
            return
        }
        pairedReadFailed = false
        pairedRetries = 0
        pairedRetry?.cancel(); pairedRetry = nil
        let previous = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        macs = paired.sorted { $0.pairedAt < $1.pairedAt }.map { device in
            let name = device.name.isEmpty ? PairingWords.unnamed(.mac) : device.name
            var mac = previous[device.deviceID] ?? Mac(id: device.deviceID, name: name, pairedAt: device.pairedAt)
            mac.name = previous[device.deviceID]?.name ?? name
            mac.isDamaged = device.isDamaged
            return mac
        }
    }

    /// The last read of the paired Macs failed (the keychain didn't allow it).
    private(set) var pairedReadFailed = false
    /// How long after a failed read the paired Macs are read again, at first.
    @ObservationIgnored var pairedRetryDelay: Duration = .seconds(5)
    @ObservationIgnored private var pairedRetry: Task<Void, Never>?
    @ObservationIgnored private var pairedRetries = 0
    private static let log = Logger(subsystem: "local.daybook", category: "link")

    private func schedulePairedRetry() {
        guard pairedRetry == nil else { return }
        let delay = pairedRetryDelay * (1 << min(pairedRetries, 6))
        pairedRetries += 1
        pairedRetry = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            self.pairedRetry = nil
            await self.retryPaired()
        }
    }

    /// Reads the paired Macs again and, once they're read, connects to them.
    private func retryPaired() async {
        reloadPaired()
        guard !pairedReadFailed, started else { return }
        await connectPaired()
    }

    private func update(_ id: UUID, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        var mac = macs[index]
        change(&mac)
        if mac != macs[index] { macs[index] = mac }
    }
}
