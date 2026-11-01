import AppKit
import DaybookCore
import DaybookKit
import DaybookLink
import Foundation
import Observation
import os

/// This Mac's end of Daybook's local link to paired iPhones (docs/link.md): the `LinkService`, the
/// pairing window, which phones are connected, and what they last reported.
///
/// The service runs only while there's a reason to: pairing is open or a phone is paired. A Mac
/// nobody pairs with never listens on the network, and the service itself advertises over Bonjour
/// only under the same rule, so nothing is announced on every network this Mac joins.
@MainActor
@Observable
final class PhoneLink {
    /// What the pairing sheet shows.
    enum Pairing: Equatable {
        case closed
        /// Opening the listener.
        case starting
        /// The code to type on the phone.
        case showing(LinkPairingCode)
        /// A phone paired; the sheet says so until it closes.
        case paired(LinkPairedDevice)
        /// Pairing couldn't open, in words.
        case unavailable(String)
    }

    /// How the service is made: Bonjour and the keychain in the app; loopback and memory in tests.
    struct Environment {
        var makeService: @MainActor (LinkIdentity) -> LinkService

        static let app = Environment { identity in
            LinkService(identity: identity, keyStore: KeychainLinkKeyStore(), configuration: LinkConfiguration())
        }
    }

    private(set) var pairing: Pairing = .closed
    /// Why the last attempt didn't pair (a wrong code, too many tries), shown under the new code.
    private(set) var pairingProblem: String?
    /// Phones this Mac shares a key with, a pairing that can't be read among them (`LinkPairedDevice.isDamaged`).
    /// Valid once `pairingsLoaded`. A read that fails keeps the list it had.
    private(set) var paired: [LinkPairedDevice] = []
    private(set) var pairingsLoaded = false
    /// The last read of the pairings failed (the keychain didn't allow it yet, as just after login): they're read
    /// again after `pairingsRetryDelay` (doubling), at wake, and at the next start.
    private(set) var pairingsReadFailed = false
    /// How long after a failed read the pairings are read again, at first.
    @ObservationIgnored var pairingsRetryDelay: Duration = .seconds(5)
    @ObservationIgnored private var pairingsRetry: Task<Void, Never>?
    @ObservationIgnored private var pairingsRetries = 0
    /// Connected, authenticated phones, with their clock estimates.
    private(set) var peers: [UUID: LinkPeer] = [:]
    /// What each connected phone last said about its recorder.
    private(set) var recordingStates: [UUID: LinkRecordingState] = [:]
    /// What each phone last said about the recorders it manages, on this Mac's clock; kept after it
    /// disconnects, for as long as it can be trusted (`LinkRecorderState.lifetime`).
    private(set) var phoneRecorders: [UUID: [LinkRecorderState]] = [:]
    @ObservationIgnored private var lastSentRecorders: [LinkRecorderState]?
    private(set) var lastConnected: [UUID: Date] = [:]
    private(set) var isRunning = false

    @ObservationIgnored var environment: Environment
    private(set) var identity: LinkIdentity
    private(set) var service: LinkService?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Bool, Never>?

    /// A phone paired, or a pairing went away (from either side).
    @ObservationIgnored var onPaired: ((LinkPairedDevice) -> Void)?
    @ObservationIgnored var onUnpaired: ((UUID) -> Void)?
    @ObservationIgnored var onConnected: ((LinkPeer) -> Void)?
    /// An app message from a phone: recording state, bookmarks, processing nudges.
    @ObservationIgnored var onMessage: ((LinkMessage, UUID) -> Void)?
    /// The Mac woke from sleep: the app's wake work (`AppState.systemDidWake`, which wakes the link too). Without
    /// it the link does only its own (`systemDidWake()`).
    @ObservationIgnored var onWake: (@MainActor () async -> Void)?
    @ObservationIgnored private var wakeWatch: Task<Void, Never>?
    /// Answers a phone asking this Mac to start or stop recording.
    @ObservationIgnored var recordHandler: (@MainActor (LinkPeer, LinkRecordRequest) async -> LinkRecordReply.Outcome)?
    /// This Mac's own recorder as phones should see it (`recording.state`), read each time it's sent.
    @ObservationIgnored var localRecordingState: (() -> LinkRecordingState)?
    /// How often this Mac's state is sent again while it records, so a phone can tell it's still at it.
    var recordingStateInterval: Duration = .seconds(15)
    @ObservationIgnored private var stateBeat: Task<Void, Never>?
    @ObservationIgnored private var stateSend: Task<Void, Never>?

    init(identity: LinkIdentity, environment: Environment = .app) {
        self.identity = identity
        self.environment = environment
        watchWake()
    }

    private static let log = Logger(subsystem: "local.daybook", category: "link")

    var hasConnectedPhones: Bool { !peers.isEmpty }
    /// Paired, even when its pairing can't be read: Unpair removes it.
    func isPaired(_ phoneID: UUID) -> Bool { paired.contains { $0.deviceID == phoneID } }
    /// Its pairing is there but can't be read: it can't connect until it's paired again.
    func isDamaged(_ phoneID: UUID) -> Bool { paired.contains { $0.deviceID == phoneID && $0.isDamaged } }

    // MARK: Running

    /// Starts listening (once). False when the listener couldn't open.
    @discardableResult
    func start() async -> Bool {
        if service != nil {
            if pairingsReadFailed { await reloadPairings() }
            return true
        }
        if let starting { return await starting.value }
        let task = Task { await self.open() }
        starting = task
        let started = await task.value
        starting = nil
        return started
    }

    private func open() async -> Bool {
        let service = environment.makeService(identity)
        let events = service.events()
        listening = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        await service.setRecordControlHandler { [weak self] peer, request in
            guard let self else { return .refused(LinkRecordRefusal(reason: .unsupported)) }
            return await self.answer(peer, request)
        }
        do {
            try await service.start()
        } catch {
            listening?.cancel(); listening = nil
            return false
        }
        self.service = service
        isRunning = true
        await reloadPairings()
        return true
    }

    /// Stops when there's no reason to run: pairing is closed and no phone is paired. Never on a read that
    /// failed, which says nothing about what's paired.
    func stopIfIdle() async {
        guard let service, pairingsLoaded, !pairingsReadFailed, paired.isEmpty, pairing == .closed || isFinished(pairing) else { return }
        self.service = nil
        await service.stop()
        listening?.cancel(); listening = nil
        isRunning = false
        peers = [:]; recordingStates = [:]
    }

    /// Stops for good (tests, and quitting).
    func shutDown() async {
        stateBeat?.cancel(); stateBeat = nil
        wakeWatch?.cancel(); wakeWatch = nil
        pairingsRetry?.cancel(); pairingsRetry = nil
        startRetry?.cancel(); startRetry = nil; startedLate = nil
        guard let service else { return }
        self.service = nil
        await service.stop()
        listening?.cancel(); listening = nil
        isRunning = false
        peers = [:]
    }

    /// After sleep: probes every phone and reopens the listener if it failed, and reads the pairings again if the
    /// last read failed.
    func systemDidWake() async {
        if service == nil, startRetry != nil, await startLate() { return }
        await service?.systemDidWake()
        if pairingsReadFailed { await reloadPairings() }
    }

    /// Follows the Mac's wake for as long as the link lives: the one wake observer of the Mac app.
    private func watchWake() {
        let wakes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification).map { _ in () }
        wakeWatch = Task { [weak self] in
            for await _ in wakes {
                guard let self else { return }
                if let onWake = self.onWake { await onWake() } else { await self.systemDidWake() }
            }
        }
    }

    /// This Mac's name, library, or ability to process changed.
    func update(_ change: (inout LinkIdentity) -> Void) async {
        var updated = identity
        change(&updated)
        guard updated != identity else { return }
        identity = updated
        await service?.updateIdentity(updated)
    }

    /// The port the service listens on (loopback tests connect to it).
    var port: UInt16? { get async { await service?.port } }

    // MARK: Pairing

    /// Opens pairing and shows its code. Calling it again shows a new code.
    func beginPairing() async {
        pairingProblem = nil
        if service == nil { pairing = .starting }
        guard await start(), let service else {
            pairing = .unavailable("Couldn’t start pairing. Check this Mac’s network connection, then try again.")
            return
        }
        pairing = .showing(await service.beginPairing())
    }

    /// Closes pairing (the sheet closed). Stops the service if no phone is paired.
    func endPairing() async {
        pairing = .closed
        pairingProblem = nil
        await service?.endPairing()
        await stopIfIdle()
    }

    /// Forgets a phone on both sides (the phone hears it when it's connected). Throws when the link can't
    /// start or the keychain refuses: the pairing is still there.
    func unpair(_ phoneID: UUID) async throws {
        guard await start(), let service else { throw LinkError.listenerFailed("The link couldn’t start.") }
        guard isPaired(phoneID) || !pairingsLoaded || pairingsReadFailed else { return }
        try await service.unpair(phoneID)
        // Gone, whether or not the keychain lists the rest just now.
        paired.removeAll { $0.deviceID == phoneID }
        await reloadPairings()
    }

    /// Reads the pairings from the keychain. A read that fails keeps what was known (every phone stays as it
    /// was, rather than looking unpaired) and tries again later.
    private func reloadPairings() async {
        guard let service else { return }
        do {
            paired = try await service.pairedDevices().sorted { $0.pairedAt < $1.pairedAt }
            pairingsLoaded = true
            pairingsReadFailed = false
            pairingsRetries = 0
            pairingsRetry?.cancel(); pairingsRetry = nil
        } catch {
            Self.log.error("Couldn’t read the iPhone pairings: \(String(describing: error), privacy: .public)")
            pairingsReadFailed = true
            scheduleReloadPairings()
        }
    }

    /// The link couldn't start (a keychain that won't read yet keeps its listener from opening): tries again after
    /// `pairingsRetryDelay` (doubling, up to about five minutes) and at wake, until it starts, then runs `started`.
    func keepStarting(then started: @escaping @MainActor () async -> Void) {
        guard service == nil, startRetry == nil else { return }
        startedLate = started
        startRetry = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let delay = self.map({ $0.pairingsRetryDelay * (1 << min(attempt, 6)) }) else { return }
                guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
                attempt += 1
                if await self.startLate() { return }
            }
        }
    }

    @ObservationIgnored private var startRetry: Task<Void, Never>?
    @ObservationIgnored private var startedLate: (@MainActor () async -> Void)?

    /// One more try for `keepStarting(then:)`. True once started.
    private func startLate() async -> Bool {
        guard await start() else { return false }
        startRetry?.cancel(); startRetry = nil
        let started = startedLate
        startedLate = nil
        await started?()
        return true
    }

    /// Reads the pairings again after a failed read, waiting longer each time (up to about five minutes).
    private func scheduleReloadPairings() {
        guard pairingsRetry == nil else { return }
        let delay = pairingsRetryDelay * (1 << min(pairingsRetries, 6))
        pairingsRetries += 1
        pairingsRetry = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            self.pairingsRetry = nil
            await self.reloadPairings()
        }
    }

    private func isFinished(_ pairing: Pairing) -> Bool {
        if case .paired = pairing { return true }
        if case .unavailable = pairing { return true }
        return false
    }

    // MARK: Talking to phones

    /// Sends to every connected phone; nothing happens when none is connected.
    func broadcast(_ message: LinkMessage) async {
        guard let service, !peers.isEmpty else { return }
        try? await service.send(message, to: nil)
    }

    /// Sends to one connected phone (a recorder handoff's request, answer, or release).
    func send(_ message: LinkMessage, to phoneID: UUID) async throws {
        guard let service else { throw LinkError.notConnected }
        try await service.send(message, to: phoneID)
    }

    func request(_ request: LinkRecordRequest, from phoneID: UUID) async throws -> LinkRecordReply {
        guard let service else { throw LinkError.notConnected }
        return try await service.request(request, from: phoneID)
    }

    func sampleClock(of phoneID: UUID) async { await service?.sampleClock(of: phoneID) }

    /// Sends this Mac's recording state to every connected phone (or one that just connected), and
    /// again every `recordingStateInterval` while it records. Sends go out one after another, in order.
    func sendRecordingState(to phoneID: UUID? = nil, onlyIfRecordersChanged: Bool = false) {
        guard let state = localRecordingState?() else { return }
        if onlyIfRecordersChanged, state.recorders == lastSentRecorders { return }
        if phoneID == nil { lastSentRecorders = state.recorders }
        let recording = state.phase != .idle
        if !recording { stateBeat?.cancel(); stateBeat = nil }
        else if stateBeat == nil {
            stateBeat = Task { [weak self] in
                while let interval = self?.recordingStateInterval, (try? await Task.sleep(for: interval)) != nil {
                    guard let self, !Task.isCancelled else { return }
                    self.sendRecordingState()
                }
            }
        }
        guard service != nil, !peers.isEmpty else { return }
        let previous = stateSend
        stateSend = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let phoneID { try? await self.send(.recordingState(state), to: phoneID) } else { await self.broadcast(.recordingState(state)) }
        }
    }

    private func answer(_ peer: LinkPeer, _ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
        guard let recordHandler else { return .refused(LinkRecordRefusal(reason: .unsupported)) }
        return await recordHandler(peer, request)
    }

    // MARK: Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .pairingCode(let code):
            if let code { pairing = .showing(code) }
            else if case .showing = pairing { pairing = .closed }
        case .paired(let device):
            pairing = .paired(device)
            pairingProblem = nil
            // Pairing again replaces the pairing it had, one that couldn't be read among them.
            paired.removeAll { $0.deviceID == device.deviceID }
            paired.append(device)
            onPaired?(device)
        case .pairingFailed(let error):
            switch error {
            case .tooManyAttempts, .expired:
                // Pairing closed; the sheet offers to start again.
                pairingProblem = nil
                pairing = .unavailable(Self.words(for: error))
            default:
                pairingProblem = Self.words(for: error)
            }
        case .unpaired(let deviceID, _):
            paired.removeAll { $0.deviceID == deviceID }
            peers[deviceID] = nil
            recordingStates[deviceID] = nil
            onUnpaired?(deviceID)
        case .connected(let peer):
            peers[peer.deviceID] = peer
            lastConnected[peer.deviceID] = Date()
            // A phone that (re)connects hears at once whether this Mac is recording, and what.
            sendRecordingState(to: peer.deviceID)
            onConnected?(peer)
        case .peerUpdated(let peer):
            guard peers[peer.deviceID] != nil else { return }
            peers[peer.deviceID] = peer
        case .disconnected(let deviceID, _):
            peers[deviceID] = nil
            recordingStates[deviceID] = nil
            lastConnected[deviceID] = Date()
        case .received(let message, let from):
            if case .recordingState(let state) = message {
                recordingStates[from] = state
                if let recorders = state.recorders {
                    let clock = peers[from]?.clock
                    phoneRecorders[from] = recorders.map { $0.moved { clock?.localDate(fromPeer: $0) ?? $0 } }
                }
            }
            onMessage?(message, from)
        case .discovered, .discovery, .connectionState:
            break
        }
    }

    /// What went wrong with an attempt, for the pairing sheet.
    static func words(for error: LinkPairingError) -> String {
        switch error {
        case .codeRejected: return "That code didn’t match. Use the new code shown here."
        case .expired: return "The code expired. Show a new code to pair."
        case .tooManyAttempts: return "Too many tries. Start again when you’re ready."
        case .busy: return "Another iPhone is pairing. Try again in a moment."
        case .timedOut: return "The iPhone stopped responding. Use the new code shown here."
        default: return "Pairing didn’t finish. Use the new code shown here."
        }
    }
}

extension CompanionClock {
    /// A link clock estimate, as the multipoint record keeps it.
    init(_ estimate: LinkClockEstimate) {
        self.init(offset: estimate.offset, uncertainty: estimate.uncertainty, samples: estimate.sampleCount, measuredAt: estimate.measuredAt)
    }
}
