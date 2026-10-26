import Combine
import DaybookCore
import DaybookDevices
import DaybookLink
import Foundation

/// Moves a recorder (Soundcore Work) between this device and another in one tap: "Use on This
/// iPhone" and "Use on This Mac", from either side (docs/devices.md, "Handing a recorder over").
///
/// A recorder talks to one device at a time, and who manages it is a synced `RecorderOwnership`.
/// A handoff changes the owner safely:
///
/// - **Over the local link** (seconds): the requester sends `recorder.handoff.request`; the owner
///   answers (accepted, with what it finishes first, or refused with a reason), finishes what can't
///   move, lets go, records the new owner, and sends `recorder.release`. The new owner claims the
///   recorder and connects.
/// - **Through sync**, when the owner isn't on the link or doesn't answer: the same request as a
///   `RecorderHandoffRecord` in the library. The requester says honestly that it's waiting, and
///   offers Take Over Anyway.
///
/// Safety rules, whichever way it travels:
/// - A transfer in progress always finishes on the old owner: transfers can't resume on another
///   device (they would start again from the beginning). Nothing new starts meanwhile.
/// - What was waiting to import moves to the new owner, which imports it once connected. What the
///   old owner imported recently is named too, so the new owner doesn't import it again while it
///   travels through sync. The library's device identity (kind, serial, recording ID) does the rest.
/// - Listen Live stops and saves what arrived. A recorder that's recording keeps recording; record
///   control moves with ownership.
/// - Taking over without asking (Take Over Anyway, or setting the recorder up elsewhere) makes the
///   old owner do the same: finish, let go, and hand over its waiting imports.
@MainActor
public final class RecorderHandoff: ObservableObject {
    // MARK: Types

    /// Another device on the local link, as the handoff sees it.
    public struct Peer: Equatable, Sendable {
        public var linkID: UUID
        /// Its sync replica ID, from its capabilities (nil from older builds).
        public var syncID: String?
        public var name: String
        public var deviceClass: SyncDeviceClass
        /// It understands the handoff messages.
        public var handsOffRecorders: Bool

        public init(linkID: UUID, syncID: String?, name: String, deviceClass: SyncDeviceClass, handsOffRecorders: Bool) {
            self.linkID = linkID
            self.syncID = syncID
            self.name = name
            self.deviceClass = deviceClass
            self.handsOffRecorders = handsOffRecorders
        }
    }

    /// The app's end of the local link: who's connected, and sending to one of them.
    public struct Link {
        public var peers: @MainActor () -> [Peer]
        public var send: @MainActor (LinkMessage, UUID) async throws -> Void

        public init(peers: @escaping @MainActor () -> [Peer], send: @escaping @MainActor (LinkMessage, UUID) async throws -> Void) {
            self.peers = peers
            self.send = send
        }

        /// No link: every handoff travels through sync.
        public static var none: Link { Link(peers: { [] }, send: { _, _ in throw LinkError.notConnected }) }
    }

    public struct Timing: Sendable {
        /// How long the owner has to answer on the link before the request goes through sync.
        public var replyTimeout: Duration = .seconds(5)
        /// Waiting through sync longer than this, the page says the owner hasn't answered.
        public var patience: TimeInterval = 120
        /// How long "Now on this iPhone" stays.
        public var doneDisplay: Duration = .seconds(5)
        /// How long the new owner waits for the recorder before it stops saying "Connecting".
        public var connectPatience: Duration = .seconds(90)
        /// After the person chose this device, automatic hand-back leaves the recorder alone this long.
        public var handBackCooldown: TimeInterval = 600
        /// How often a release checks whether what can't move has finished.
        public var poll: Duration = .milliseconds(100)
        /// How often the owner updates the requester while it finishes.
        public var progressInterval: TimeInterval = 5

        public init() {}
    }

    /// What the other device finishes before it lets go.
    public enum Finishing: Equatable, Sendable {
        /// An import in progress: "Today, 10:02 AM", with time left when known.
        case importing(title: String?, secondsLeft: TimeInterval?)
        /// Listen Live, which stops and saves what arrived.
        case liveListening
    }

    /// Where one recorder's handoff is, on this device.
    public enum State: Equatable, Sendable {
        case idle
        /// Asking the owner over the local link.
        case asking(owner: String)
        /// The owner agreed; it lets go once what can't move has finished.
        case ownerFinishing(owner: String, finishing: Finishing?)
        /// The request travels through sync: the owner isn't on the link, or didn't answer.
        case waitingForSync(owner: String, since: Date)
        /// The other device said no (or didn't answer an offer).
        case refused(by: String, message: String)
        /// The recorder is free: connecting to it here.
        case connecting(from: String)
        /// It moved here.
        case done(at: Date)
        /// This device is letting go of it, after what can't move has finished.
        case handingOver(to: String, finishing: Finishing?)
        /// This device offered it to another (`Use on Studio Mac`), waiting for the answer.
        case offering(to: String)

        /// Something is under way (as opposed to idle, answered, or finished).
        public var isPending: Bool {
            switch self {
            case .asking, .ownerFinishing, .waitingForSync, .connecting, .handingOver, .offering: return true
            case .idle, .refused, .done: return false
            }
        }
    }

    // MARK: State

    /// Each recorder's handoff, by `RecorderOwnership.id`. Absent means idle.
    @Published public private(set) var states: [String: State] = [:]
    /// The local link. The app sets it once its link is running.
    public var link: Link
    /// iPhone, off by default: "Hand back to my Mac when it's nearby". When the Mac this iPhone took
    /// the recorder from connects over the link, and the recorder is idle here, it goes back.
    public var handsBackAutomatically = false

    public let library: LibraryController
    public let devices: DeviceHub
    public let deviceClass: SyncDeviceClass
    public let timing: Timing
    private let defaults: UserDefaults
    /// This device's name in ownership records and handoffs; nil uses the system's.
    private let deviceName: String?

    private struct Outgoing {
        var request: LinkRecorderHandoffRequest
        /// The other device's name.
        var counterpart: String
        var counterpartClass: SyncDeviceClass
    }

    /// Requests this device sent (take or give), by ID.
    private var outgoing: [UUID: Outgoing] = [:]
    /// Answers this device gave, so a repeated request gets the same one.
    private var answered: [UUID: LinkRecorderHandoffReply] = [:]
    /// Recorders this device is letting go of, with the request (by recorder ID).
    private var releasing: [String: (request: UUID, to: LinkHandoffDevice, linkID: UUID?)] = [:]
    private var releaseTasks: [String: Task<Void, Never>] = [:]
    private var watchTasks: [String: Task<Void, Never>] = [:]
    /// Releases this device already took over from.
    private var completed: Set<UUID> = []
    /// Each recorder's owner as last seen, to notice when another device took it over.
    private var lastOwners: [String: String] = [:]
    /// Peers on the link that hand recorders over, by sync ID, to notice one arriving.
    private var presentPeers: Set<String> = []
    private var subscriptions: Set<AnyCancellable> = []
    private var metadataCheckScheduled = false
    private var sending: Task<Void, Never>?

    public init(library: LibraryController, devices: DeviceHub, deviceClass: SyncDeviceClass, defaults: UserDefaults = .standard,
                link: Link = .none, timing: Timing = Timing(), deviceName: String? = nil) {
        self.library = library
        self.devices = devices
        self.deviceClass = deviceClass
        self.defaults = defaults
        self.deviceName = deviceName
        self.link = link
        self.timing = timing
        for owner in library.recorderOwners { lastOwners[owner.id] = owner.ownerID }
        // `@Published` announces before the value changes: look once it has.
        library.$metadata.dropFirst().sink { [weak self] _ in self?.scheduleMetadataCheck() }.store(in: &subscriptions)
        scheduleMetadataCheck()
    }

    /// This device, as handoffs and ownership name it.
    public var thisDevice: ProcessingRequest.Device {
        let device = library.thisDevice
        return ProcessingRequest.Device(id: device.id, name: deviceName ?? device.name)
    }

    private var me: LinkHandoffDevice {
        LinkHandoffDevice(syncID: thisDevice.id, name: thisDevice.name, deviceClass: Self.linkClass(deviceClass))
    }

    // MARK: Reading

    public func recorderID(of session: DeviceSession) -> String? {
        session.recorderSerial.map { RecorderOwnership.id(kind: session.kind.id, serial: $0) }
    }

    public func state(of session: DeviceSession) -> State {
        recorderID(of: session).flatMap { states[$0] } ?? .idle
    }

    /// Who manages the recorder, when a device has claimed it.
    public func owner(of session: DeviceSession) -> RecorderOwnership? {
        session.recorderSerial.flatMap { library.recorderOwner(kind: session.kind.id, serial: $0) }
    }

    /// This device manages the recorder (it claimed it, or nobody has).
    public func isManagedHere(_ session: DeviceSession) -> Bool {
        guard session.direct is any ManagedConnection else { return false }
        return owner(of: session).map { $0.ownerID == thisDevice.id } ?? true
    }

    /// Devices on the link this one could hand the recorder to ("Use on Studio Mac").
    public func peersToGive(_ session: DeviceSession) -> [Peer] {
        guard isManagedHere(session), session.recorderSerial != nil else { return [] }
        return link.peers().filter { $0.handsOffRecorders && $0.syncID != nil && $0.syncID != thisDevice.id }
    }

    /// The owner is on the local link and understands handoffs, so asking takes seconds.
    public func ownerIsOnLink(_ session: DeviceSession) -> Bool {
        guard let owner = owner(of: session), owner.ownerID != thisDevice.id else { return false }
        return peer(syncID: owner.ownerID) != nil
    }

    /// Waiting through sync for longer than `Timing.patience`.
    public func isOverdue(_ state: State, now: Date = Date()) -> Bool {
        if case .waitingForSync(_, let since) = state { return now.timeIntervalSince(since) > timing.patience }
        return false
    }

    // MARK: Asking for the recorder

    /// "Use on This Mac" / "Use on This iPhone". Nobody manages it, or this device does: connect.
    /// Another device does: ask it to let go, over the link when it's there, else through sync.
    public func useHere(_ session: DeviceSession) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session) else { return }
        let kind = session.kind.id
        noteChosenHere(id)
        if isBusy(id, session) { return }
        guard let owner = library.recorderOwner(kind: kind, serial: serial), owner.ownerID != thisDevice.id else {
            claim(kind: kind, serial: serial)
            states[id] = nil
            session.connect()
            return
        }
        let request = LinkRecorderHandoffRequest(intent: .take, kind: kind, serial: serial, recorderName: session.device.name,
                                                 addressedTo: owner.ownerID, requester: me)
        outgoing[request.id] = Outgoing(request: request, counterpart: owner.ownerName, counterpartClass: owner.ownerClass)
        guard library.sync != nil else {
            // Without sync the devices don't share a library, so there's nobody to ask.
            takeOverAnyway(session)
            return
        }
        if let peer = peer(syncID: owner.ownerID) {
            states[id] = .asking(owner: owner.ownerName)
            send(.recorderHandoffRequest(request), to: peer.linkID)
            Task { [weak self, timing] in
                try? await Task.sleep(for: timing.replyTimeout)
                guard let self, case .asking? = self.states[id], self.outgoing[request.id] != nil else { return }
                self.waitThroughSync(request, ownerName: owner.ownerName)
            }
        } else {
            waitThroughSync(request, ownerName: owner.ownerName)
        }
    }

    /// Take Over Anyway: this device manages the recorder now. The old owner lets go when it hears
    /// (finishing an import first) and hands over what it had waiting. If it's still connected, the
    /// recorder may not answer here until then; this device keeps trying with no deadline.
    public func takeOverAnyway(_ session: DeviceSession) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session) else { return }
        let previous = owner(of: session)
        let ownerName = previous.flatMap { $0.ownerID == thisDevice.id ? nil : $0.ownerName }
        let record = library.recorderHandoff(kind: session.kind.id, serial: serial)
        if let record, record.requesterID == thisDevice.id { library.clearRecorderHandoff(kind: session.kind.id, serial: serial) }
        outgoing = outgoing.filter { $0.value.request.serial != serial || $0.value.request.kind != session.kind.id }
        noteChosenHere(id)
        claim(kind: session.kind.id, serial: serial)
        if ownerName != nil { rememberHome(id, from: previous) }
        connectAfterHandoff(session, id: id, from: ownerName ?? "the other device")
    }

    /// Stops waiting for the other device (a request through sync, or an answer to clear).
    public func cancel(_ session: DeviceSession) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session) else { return }
        let kind = session.kind.id
        if var record = library.recorderHandoff(kind: kind, serial: serial), record.requesterID == thisDevice.id,
           record.phase == .requested || record.phase == .releasing {
            record.phase = .cancelled
            library.saveRecorderHandoff(record)
        }
        outgoing = outgoing.filter { $0.value.request.serial != serial || $0.value.request.kind != kind }
        states[id] = nil
    }

    /// Clears an answer the page has shown (a refusal, or "Now on this iPhone").
    public func dismiss(_ session: DeviceSession) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session) else { return }
        if let state = states[id], !state.isPending { states[id] = nil }
        if let record = library.recorderHandoff(kind: session.kind.id, serial: serial), record.requesterID == thisDevice.id,
           record.phase == .refused {
            library.clearRecorderHandoff(kind: session.kind.id, serial: serial, onlyID: record.id)
        }
    }

    // MARK: Offering the recorder

    /// "Use on Studio Mac": offers the recorder to a device on the link. If it accepts (it has the
    /// recorder set up), this device finishes what can't move, lets go, and the other connects.
    public func give(_ session: DeviceSession, to peer: Peer) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session), let syncID = peer.syncID,
              peer.handsOffRecorders, isManagedHere(session) else { return }
        if isBusy(id, session) { return }
        let request = LinkRecorderHandoffRequest(intent: .give, kind: session.kind.id, serial: serial, recorderName: session.device.name,
                                                 addressedTo: syncID, requester: me)
        outgoing[request.id] = Outgoing(request: request, counterpart: peer.name, counterpartClass: peer.deviceClass)
        states[id] = .offering(to: peer.name)
        send(.recorderHandoffRequest(request), to: peer.linkID)
        Task { [weak self, timing] in
            try? await Task.sleep(for: timing.replyTimeout)
            guard let self, case .offering? = self.states[id], self.outgoing.removeValue(forKey: request.id) != nil else { return }
            self.states[id] = .refused(by: peer.name, message: "\(peer.name) didn’t answer. \(session.device.name) stays on \(self.thisDevice.name).")
        }
    }

    // MARK: The link

    /// A handoff message from the link. The app forwards every `recorder.*` message here.
    public func receive(_ message: LinkMessage, from linkID: UUID) {
        switch message {
        case .recorderHandoffRequest(let request): handle(request, replyTo: linkID)
        case .recorderHandoffReply(let reply): handle(reply)
        case .recorderRelease(let release):
            guard release.newOwner.syncID == thisDevice.id else { return }
            takeOver(kind: release.kind, serial: release.serial, from: peerName(linkID),
                     requestID: release.requestID,
                     pending: release.pendingImports.map { DeviceHandedOffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
                     imported: release.importedRecordingIDs,
                     inProgress: release.recordingInProgress.map { DeviceHandedOffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) })
        default:
            break
        }
    }

    /// Who's on the link changed. With hand-back on, a recorder taken from a Mac goes back to it when
    /// that Mac arrives and the recorder is idle here.
    public func peersChanged() {
        let present = Set(link.peers().filter(\.handsOffRecorders).compactMap(\.syncID))
        let arrived = present.subtracting(presentPeers)
        presentPeers = present
        guard handsBackAutomatically, !arrived.isEmpty else { return }
        let now = Date()
        for session in devices.sessions {
            guard let id = recorderID(of: session), let home = defaults.string(forKey: Self.homeKey(id)), arrived.contains(home),
                  isManagedHere(session), owner(of: session) != nil, !isBusy(id, session),
                  session.canLetGo, !session.queue.isActive,
                  now.timeIntervalSince(chosenHereAt(id) ?? .distantPast) > timing.handBackCooldown,
                  let peer = peer(syncID: home) else { continue }
            give(session, to: peer)
        }
    }

    private func handle(_ request: LinkRecorderHandoffRequest, replyTo linkID: UUID?) {
        if let reply = answered[request.id] {
            if let linkID { send(.recorderHandoffReply(reply), to: linkID) }
            return
        }
        let outcome = decide(request)
        let reply = LinkRecorderHandoffReply(requestID: request.id, outcome: outcome, from: me)
        answered[request.id] = reply
        let id = RecorderOwnership.id(kind: request.kind, serial: request.serial)
        if let linkID {
            send(.recorderHandoffReply(reply), to: linkID)
        } else if var record = library.recorderHandoff(kind: request.kind, serial: request.serial), record.id == request.id {
            // Through sync: the answer goes in the record.
            switch outcome {
            case .accepted: record.phase = .releasing
            case .refused(let refusal):
                record.phase = .refused
                record.message = Words.refusal(refusal, by: thisDevice.name, recorder: request.recorderName)
            }
            library.saveRecorderHandoff(record)
        }
        guard case .accepted = outcome, let session = session(kind: request.kind, serial: request.serial) else { return }
        switch request.intent {
        case .give:
            // The other device lets go and sends its release; this one then takes over.
            states[id] = .ownerFinishing(owner: request.requester.name, finishing: nil)
        default:
            beginRelease(session, to: request.requester, requestID: request.id, linkID: linkID)
        }
    }

    private func decide(_ request: LinkRecorderHandoffRequest) -> LinkRecorderHandoffReply.Outcome {
        let id = RecorderOwnership.id(kind: request.kind, serial: request.serial)
        let owner = library.recorderOwner(kind: request.kind, serial: request.serial)
        guard request.addressedTo == thisDevice.id else {
            return .refused(LinkRecorderHandoffRefusal(reason: .notOwner, ownerName: owner?.ownerName))
        }
        guard let session = session(kind: request.kind, serial: request.serial), session.direct?.isSetUp == true else {
            return .refused(LinkRecorderHandoffRefusal(reason: .notSetUp))
        }
        switch request.intent {
        case .take:
            if let owner, owner.ownerID != thisDevice.id {
                return .refused(LinkRecorderHandoffRefusal(reason: .notOwner, ownerName: owner.ownerName))
            }
            if let current = releasing[id], current.request != request.id {
                return .refused(LinkRecorderHandoffRefusal(reason: .busy))
            }
            return .accepted(ack(for: session))
        case .give:
            // It has the recorder set up, so it can take it.
            return .accepted(LinkRecorderHandoffAck())
        default:
            return .refused(LinkRecorderHandoffRefusal(reason: .unsupported))
        }
    }

    private func handle(_ reply: LinkRecorderHandoffReply) {
        guard let sent = outgoing[reply.requestID] else { return }
        let request = sent.request
        let id = RecorderOwnership.id(kind: request.kind, serial: request.serial)
        switch (request.intent, reply.outcome) {
        case (.give, .accepted):
            outgoing[reply.requestID] = nil
            guard let session = session(kind: request.kind, serial: request.serial) else { return }
            let syncID = reply.from?.syncID ?? request.addressedTo
            let receiver = LinkHandoffDevice(syncID: syncID, name: reply.from?.name ?? sent.counterpart,
                                             deviceClass: reply.from?.deviceClass ?? Self.linkClass(sent.counterpartClass))
            beginRelease(session, to: receiver, requestID: request.id, linkID: peer(syncID: syncID)?.linkID)
        case (_, .accepted(let ack)):
            // Updates may follow while the owner finishes; the release (or sync) ends it.
            switch states[id] {
            case .asking?, .ownerFinishing?, .waitingForSync?:
                states[id] = .ownerFinishing(owner: reply.from?.name ?? sent.counterpart, finishing: Self.finishing(ack))
            default: break
            }
        case (_, .refused(let refusal)):
            outgoing[reply.requestID] = nil
            states[id] = .refused(by: reply.from?.name ?? sent.counterpart,
                                  message: Words.refusal(refusal, by: reply.from?.name ?? sent.counterpart, recorder: request.recorderName))
        }
    }

    // MARK: Letting go

    /// Finishes what can't move (the transfer in progress; Listen Live stops and saves), then lets go.
    private func beginRelease(_ session: DeviceSession, to newOwner: LinkHandoffDevice, requestID: UUID, linkID: UUID?) {
        guard let serial = session.recorderSerial, let id = recorderID(of: session) else { return }
        let kind = session.kind.id
        releasing[id] = (requestID, newOwner, linkID)
        session.holdForHandoff()
        if let live = session.direct as? any LiveListeningConnection, live.live.isListening { live.stopListening() }
        states[id] = .handingOver(to: newOwner.name, finishing: Self.finishing(session))
        releaseTasks[id]?.cancel()
        releaseTasks[id] = Task { [weak self, timing] in
            var lastUpdate = Date()
            while let self, !Task.isCancelled, !session.canLetGo {
                let finishing = Self.finishing(session)
                if self.states[id] != .handingOver(to: newOwner.name, finishing: finishing) {
                    self.states[id] = .handingOver(to: newOwner.name, finishing: finishing)
                }
                if let linkID, Date().timeIntervalSince(lastUpdate) >= timing.progressInterval {
                    // Tell the requester how it's going: the same answer, with fresher numbers.
                    lastUpdate = Date()
                    let reply = LinkRecorderHandoffReply(requestID: requestID, outcome: .accepted(self.ack(for: session)), from: self.me)
                    self.answered[requestID] = reply
                    self.send(.recorderHandoffReply(reply), to: linkID)
                }
                try? await Task.sleep(for: timing.poll)
            }
            guard let self, !Task.isCancelled else { return }
            self.letGo(session, kind: kind, serial: serial, to: newOwner, requestID: requestID)
        }
    }

    private func letGo(_ session: DeviceSession, kind: String, serial: String, to newOwner: LinkHandoffDevice, requestID: UUID) {
        let id = RecorderOwnership.id(kind: kind, serial: serial)
        let pending = session.takeWaitingImports()
        let imported = Self.recentImports(session)
        let recording = session.isLinked ? session.status?.isRecording : nil
        let inProgress = recordingInProgress(session, kind: kind, serial: serial)
        // Recording the new owner first means this device's connection won't reach for it again.
        library.claimRecorder(kind: kind, serial: serial, deviceClass: Self.syncClass(newOwner.deviceClass),
                              by: ProcessingRequest.Device(id: newOwner.syncID, name: newOwner.name))
        lastOwners[id] = newOwner.syncID
        applyOwnership()
        session.disconnect(.direct)
        session.endHandoffHold()
        let existing = library.recorderHandoff(kind: kind, serial: serial)
        var record = RecorderHandoffRecord(
            id: requestID, kind: kind, serial: serial, ownerID: thisDevice.id, ownerName: thisDevice.name,
            requesterID: newOwner.syncID, requesterName: newOwner.name, requesterClass: Self.syncClass(newOwner.deviceClass),
            phase: .released,
            pendingImports: pending.map { RecorderHandoffRecord.PendingImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
            importedRecordingIDs: imported, recorderIsRecording: recording,
            requestedAt: existing?.id == requestID ? existing?.requestedAt ?? Date() : Date())
        record.recordingInProgress = inProgress.map { RecorderHandoffRecord.PendingImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) }
        library.saveRecorderHandoff(record)
        releasing[id] = nil
        releaseTasks[id] = nil
        states[id] = nil
        if let peer = peer(syncID: newOwner.syncID) {
            let release = LinkRecorderRelease(
                requestID: requestID, kind: kind, serial: serial, newOwner: newOwner,
                pendingImports: pending.map { LinkHandoffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
                importedRecordingIDs: imported, recorderIsRecording: recording,
                recordingInProgress: inProgress.map { LinkHandoffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) })
            send(.recorderRelease(release), to: peer.linkID)
        }
    }

    /// Another device took the recorder without asking (Take Over Anyway, or it was set up there):
    /// finish the transfer in progress, let go, and hand over what was waiting.
    private func wasTakenOver(_ session: DeviceSession, by owner: RecorderOwnership) {
        guard let id = recorderID(of: session), releasing[id] == nil else { return }
        let newOwner = LinkHandoffDevice(syncID: owner.ownerID, name: owner.ownerName, deviceClass: Self.linkClass(owner.ownerClass))
        let requestID = UUID()
        releasing[id] = (requestID, newOwner, nil)
        session.holdForHandoff()
        if let live = session.direct as? any LiveListeningConnection, live.live.isListening { live.stopListening() }
        releaseTasks[id] = Task { [weak self, timing] in
            while self != nil, !Task.isCancelled, !session.canLetGo { try? await Task.sleep(for: timing.poll) }
            guard let self, !Task.isCancelled, let serial = session.recorderSerial else { return }
            let pending = session.takeWaitingImports()
            let imported = Self.recentImports(session)
            let kind = session.kind.id
            let inProgress = self.recordingInProgress(session, kind: kind, serial: serial)
            session.disconnect(.direct)
            session.endHandoffHold()
            self.releasing[id] = nil
            self.releaseTasks[id] = nil
            if self.states[id]?.isPending == true { self.states[id] = nil }
            guard !pending.isEmpty || !imported.isEmpty || inProgress != nil else { return }
            var record = RecorderHandoffRecord(
                id: requestID, kind: kind, serial: serial, ownerID: self.thisDevice.id, ownerName: self.thisDevice.name,
                requesterID: owner.ownerID, requesterName: owner.ownerName, requesterClass: owner.ownerClass, phase: .released,
                pendingImports: pending.map { RecorderHandoffRecord.PendingImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
                importedRecordingIDs: imported)
            record.recordingInProgress = inProgress.map { RecorderHandoffRecord.PendingImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) }
            self.library.saveRecorderHandoff(record)
            if let peer = self.peer(syncID: owner.ownerID) {
                self.send(.recorderRelease(LinkRecorderRelease(
                    requestID: requestID, kind: kind, serial: serial, newOwner: newOwner,
                    pendingImports: pending.map { LinkHandoffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
                    importedRecordingIDs: imported,
                    recordingInProgress: inProgress.map { LinkHandoffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) })),
                          to: peer.linkID)
            }
        }
    }

    // MARK: Taking over

    /// The old owner let go (over the link or through sync): claim the recorder, import what it had
    /// waiting, and connect.
    private func takeOver(kind: String, serial: String, from ownerName: String?, requestID: UUID?,
                          pending: [DeviceHandedOffImport], imported: [String], inProgress: DeviceHandedOffImport? = nil,
                          previousOwner: RecorderOwnership? = nil) {
        if let requestID {
            // The record is done with either way (it may arrive through sync after the link's release).
            library.clearRecorderHandoff(kind: kind, serial: serial, onlyID: requestID)
            guard !completed.contains(requestID) else { return }
            completed.insert(requestID)
        }
        let id = RecorderOwnership.id(kind: kind, serial: serial)
        let before = previousOwner ?? library.recorderOwner(kind: kind, serial: serial)
        let name = ownerName ?? outgoing.values.first { $0.request.kind == kind && $0.request.serial == serial }?.counterpart
            ?? before.flatMap { $0.ownerID == thisDevice.id ? nil : $0.ownerName } ?? "the other device"
        outgoing = outgoing.filter { $0.value.request.serial != serial || $0.value.request.kind != kind }
        guard let session = session(kind: kind, serial: serial) else { return }
        if library.recorderOwner(kind: kind, serial: serial)?.ownerID != thisDevice.id { claim(kind: kind, serial: serial) } else { applyOwnership() }
        if let before, before.ownerID != thisDevice.id { rememberHome(id, from: before) }
        // The recording it's making waits here too, for the conversation that asked for it.
        session.adoptHandedOffImports(pending + (inProgress.map { [$0] } ?? []), alreadyImported: imported)
        if session.isLinked {
            if states[id]?.isPending == true { states[id] = .done(at: Date()); clearLater(id) }
        } else {
            connectAfterHandoff(session, id: id, from: name)
        }
    }

    private func connectAfterHandoff(_ session: DeviceSession, id: String, from name: String) {
        states[id] = .connecting(from: name)
        session.connectWhenAvailable()
        watchTasks[id]?.cancel()
        watchTasks[id] = Task { [weak self, timing] in
            let deadline = ContinuousClock.now.advanced(by: timing.connectPatience)
            while !Task.isCancelled, !session.isLinked, ContinuousClock.now < deadline { try? await Task.sleep(for: timing.poll) }
            guard let self, !Task.isCancelled, case .connecting? = self.states[id] else { return }
            // Linked: say so for a moment. Not yet: the device page's own status takes it from here.
            if session.isLinked { self.states[id] = .done(at: Date()); self.clearLater(id) } else { self.states[id] = nil }
        }
    }

    private func clearLater(_ id: String) {
        Task { [weak self, timing] in
            try? await Task.sleep(for: timing.doneDisplay)
            guard let self, case .done? = self.states[id] else { return }
            self.states[id] = nil
        }
    }

    // MARK: Sync

    private func scheduleMetadataCheck() {
        guard !metadataCheckScheduled else { return }
        metadataCheckScheduled = true
        Task { @MainActor [weak self] in
            self?.metadataCheckScheduled = false
            self?.metadataChanged()
        }
    }

    /// The library's ownership or handoff records changed (here, or through sync).
    private func metadataChanged() {
        let me = thisDevice.id
        // Ownership: notice a recorder this device managed going to another without a handoff.
        var owners: [String: RecorderOwnership] = [:]
        for owner in library.recorderOwners { owners[owner.id] = owner }
        for session in devices.sessions {
            guard let id = recorderID(of: session) else { continue }
            let now = owners[id]
            let before = lastOwners[id]
            lastOwners[id] = now?.ownerID
            if before == me, let now, now.ownerID != me, releasing[id] == nil { wasTakenOver(session, by: now) }
        }
        for (id, owner) in owners where lastOwners[id] == nil { lastOwners[id] = owner.ownerID }

        for record in library.recorderHandoffs {
            let id = record.recorderID
            if record.ownerID == me {
                switch record.phase {
                case .requested:
                    guard answered[record.id] == nil else { continue }
                    handle(LinkRecorderHandoffRequest(id: record.id, intent: .take, kind: record.kind, serial: record.serial,
                                                      recorderName: session(kind: record.kind, serial: record.serial)?.device.name ?? "Recorder",
                                                      addressedTo: me,
                                                      requester: LinkHandoffDevice(syncID: record.requesterID, name: record.requesterName,
                                                                                   deviceClass: Self.linkClass(record.requesterClass)),
                                                      sentAt: record.requestedAt),
                           replyTo: nil)
                case .cancelled:
                    if let current = releasing[id], current.request == record.id, let session = session(kind: record.kind, serial: record.serial) {
                        releaseTasks[id]?.cancel()
                        releaseTasks[id] = nil
                        releasing[id] = nil
                        session.endHandoffHold()
                        states[id] = nil
                    }
                default:
                    break
                }
            }
            if record.requesterID == me {
                switch record.phase {
                case .requested:
                    if states[id] == nil || states[id] == .idle {
                        states[id] = .waitingForSync(owner: record.ownerName, since: record.requestedAt)
                    }
                case .releasing:
                    switch states[id] {
                    case .asking?, .waitingForSync?, nil: states[id] = .ownerFinishing(owner: record.ownerName, finishing: nil)
                    default: break
                    }
                case .released:
                    takeOver(kind: record.kind, serial: record.serial, from: record.ownerName, requestID: record.id,
                             pending: (record.pendingImports ?? []).map { DeviceHandedOffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: $0.isAutomatic) },
                             imported: record.importedRecordingIDs ?? [],
                             inProgress: record.recordingInProgress.map { DeviceHandedOffImport(recordingID: $0.recordingID, attachTo: $0.attachTo, isAutomatic: true) },
                             previousOwner: RecorderOwnership(kind: record.kind, serial: record.serial, ownerID: record.ownerID,
                                                              ownerName: record.ownerName, ownerClass: deviceClass == .mac ? .phone : .mac))
                case .refused:
                    if states[id]?.isPending ?? true, states[id] != .refused(by: record.ownerName, message: record.message ?? "") {
                        outgoing = outgoing.filter { $0.value.request.id != record.id }
                        states[id] = .refused(by: record.ownerName, message: record.message ?? "\(record.ownerName) didn’t hand it over.")
                    }
                case .cancelled:
                    break
                }
            }
        }
    }

    private func waitThroughSync(_ request: LinkRecorderHandoffRequest, ownerName: String) {
        let id = RecorderOwnership.id(kind: request.kind, serial: request.serial)
        let record = RecorderHandoffRecord(id: request.id, kind: request.kind, serial: request.serial, ownerID: request.addressedTo,
                                           ownerName: ownerName, requesterID: thisDevice.id, requesterName: thisDevice.name,
                                           requesterClass: deviceClass, phase: .requested, requestedAt: Date())
        library.saveRecorderHandoff(record)
        states[id] = .waitingForSync(owner: ownerName, since: record.requestedAt)
    }

    // MARK: Helpers

    /// A handoff of this recorder is under way. "Connecting" ends once the recorder answers, even
    /// before the page has said "Now on this iPhone".
    private func isBusy(_ id: String, _ session: DeviceSession) -> Bool {
        guard let state = states[id], state.isPending else { return false }
        if case .connecting = state, session.isLinked { return false }
        return true
    }

    private func claim(kind: String, serial: String) {
        library.claimRecorder(kind: kind, serial: serial, deviceClass: deviceClass, by: thisDevice)
        lastOwners[RecorderOwnership.id(kind: kind, serial: serial)] = thisDevice.id
        applyOwnership()
    }

    /// Ownership reaches the sessions at once, rather than at the app's next look.
    private func applyOwnership() {
        devices.recorderOwnersChanged(library.recorderOwners, thisDevice: thisDevice.id)
    }

    private func session(kind: String, serial: String) -> DeviceSession? {
        devices.sessions.first { $0.kind.id == kind && $0.recorderSerial == serial }
    }

    private func peer(syncID: String) -> Peer? {
        link.peers().first { $0.syncID == syncID && $0.handsOffRecorders }
    }

    private func peerName(_ linkID: UUID) -> String? { link.peers().first { $0.linkID == linkID }?.name }

    /// In order: a release never overtakes the answer before it.
    private func send(_ message: LinkMessage, to linkID: UUID) {
        let link = self.link, previous = sending
        sending = Task { @MainActor in
            await previous?.value
            try? await link.send(message, linkID)
        }
    }

    private func ack(for session: DeviceSession) -> LinkRecorderHandoffAck {
        var ack = LinkRecorderHandoffAck(recorderIsRecording: session.isLinked ? session.status?.isRecording : nil)
        switch Self.finishing(session) {
        case .importing(let title, let secondsLeft)?:
            ack.finishing = .import
            ack.finishingTitle = title
            ack.secondsLeft = secondsLeft
        case .liveListening?:
            ack.finishing = .liveListening
        case nil:
            break
        }
        return ack
    }

    private static func finishing(_ session: DeviceSession) -> Finishing? {
        if let transfer = session.transferToFinish { return .importing(title: transfer.recording.title, secondsLeft: transfer.secondsLeft) }
        if (session.direct as? any LiveListeningConnection)?.live.isListening == true { return .liveListening }
        return nil
    }

    private static func finishing(_ ack: LinkRecorderHandoffAck) -> Finishing? {
        switch ack.finishing {
        case .import?: return .importing(title: ack.finishingTitle, secondsLeft: ack.secondsLeft)
        case .liveListening?: return .liveListening
        default: return nil
        }
    }

    /// The recording the recorder is making as it's let go (live, or as last seen), and the
    /// conversation waiting for it: one whose recording asked the recorder to record too and hasn't
    /// got its recording yet. The new owner imports it there once it's finished.
    private func recordingInProgress(_ session: DeviceSession, kind: String, serial: String) -> DeviceHandedOffImport? {
        guard let id = session.split.inProgress?.id else { return nil }
        let waiting = library.meetings.first { meeting in
            meeting.companions?.contains { link in
                link.deviceKind == kind && (link.deviceSerial ?? serial) == serial && link.recordingID == id
                    && link.trackID == nil && link.expectsRecording
            } == true
        }
        return DeviceHandedOffImport(recordingID: id, attachTo: waiting?.id, isAutomatic: true)
    }

    /// Recordings imported here in the last day: they may not have reached the new owner yet.
    private static func recentImports(_ session: DeviceSession) -> [String] {
        let since = Date().addingTimeInterval(-86_400)
        return session.links.recent.filter { $0.importedAt > since && !$0.recordingID.hasSuffix(DeviceLibraryLinks.partialSuffix) }
            .map(\.recordingID)
    }

    static func linkClass(_ deviceClass: SyncDeviceClass) -> LinkDeviceClass {
        switch deviceClass {
        case .mac: return .mac
        case .phone: return .iPhone
        case .other: return "other"
        }
    }

    static func syncClass(_ deviceClass: LinkDeviceClass) -> SyncDeviceClass {
        switch deviceClass {
        case .mac: return .mac
        case .iPhone: return .phone
        default: return .other
        }
    }

    // MARK: Hand-back memory

    private static func homeKey(_ id: String) -> String { "recorderHandoff.home.\(id)" }
    private static func chosenKey(_ id: String) -> String { "recorderHandoff.chosenHere.\(id)" }

    /// The Mac this device took the recorder from, for hand-back.
    private func rememberHome(_ id: String, from owner: RecorderOwnership?) {
        guard let owner, owner.ownerClass == .mac, deviceClass == .phone else { return }
        defaults.set(owner.ownerID, forKey: Self.homeKey(id))
    }

    /// The person chose this device for the recorder (hand-back leaves it alone for a while).
    public func noteChosenHere(_ session: DeviceSession) {
        if let id = recorderID(of: session) { noteChosenHere(id) }
    }

    private func noteChosenHere(_ id: String) { defaults.set(Date(), forKey: Self.chosenKey(id)) }
    private func chosenHereAt(_ id: String) -> Date? { defaults.object(forKey: Self.chosenKey(id)) as? Date }
}

#if DEBUG
extension RecorderHandoff {
    /// Demos and screenshots only: shows a handoff state for a recorder without doing anything.
    public func applyDemo(_ state: State, for session: DeviceSession) {
        guard let id = recorderID(of: session) else { return }
        states[id] = state == .idle ? nil : state
    }
}
#endif

// MARK: Words

extension RecorderHandoff {
    /// The handoff's words, the same on both devices. `here` is "this Mac" or "this iPhone".
    public enum Words {
        /// One line for the device page, the status sheet, or the menu bar.
        public static func headline(_ state: State, recorder: String, here: String) -> String? {
            switch state {
            case .idle: return nil
            case .asking(let owner): return "Asking \(owner) to let go of \(recorder)…"
            case .ownerFinishing(let owner, let finishing):
                switch finishing {
                case .importing?: return "\(owner) is finishing an import, then lets go"
                case .liveListening?: return "\(owner) is saving what it heard live, then lets go"
                case nil: return "\(owner) is letting go of \(recorder)…"
                }
            case .waitingForSync(let owner, _): return "Waiting for \(owner) to let go…"
            case .refused(let by, _): return "\(by) didn’t hand over \(recorder)"
            case .connecting: return "Connecting to \(recorder)…"
            case .done: return "\(recorder) is on \(here) now"
            case .handingOver(let to, let finishing):
                switch finishing {
                case .importing?: return "Handing \(recorder) to \(to) after this import"
                case .liveListening?: return "Handing \(recorder) to \(to) after saving Listen Live"
                case nil: return "Handing \(recorder) to \(to)…"
                }
            case .offering(let to): return "Asking \(to) to take \(recorder)…"
            }
        }

        /// The sentence under the headline, when there's more to say.
        public static func detail(_ state: State, recorder: String, here: String, overdue: Bool = false, now: Date = Date()) -> String? {
            switch state {
            case .ownerFinishing(_, let finishing?):
                switch finishing {
                case .importing(let title, let secondsLeft):
                    return importing(title, secondsLeft)
                case .liveListening:
                    return "\(recorder) keeps recording."
                }
            case .waitingForSync(let owner, let since):
                return overdue ? "\(owner) hasn’t answered since \(since.formatted(date: .omitted, time: .shortened))." : nil
            case .refused(_, let message): return message
            case .connecting:
                return "Keep \(recorder) nearby."
            case .handingOver(_, .importing(let title, let secondsLeft)?):
                return importing(title, secondsLeft)
            default:
                return nil
            }
        }

        /// "Today, 10:02 AM · about 2 min left", for an import that finishes before the move.
        private static func importing(_ title: String?, _ secondsLeft: Double?) -> String? {
            let parts = [title, secondsLeft.map { TransferRateEstimator.label(secondsLeft: $0) }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// What Take Over Anyway risks, for its confirmation.
        public static func takeOverRisk(owner: String, recorder: String, here: String) -> String {
            "\(recorder) may not answer \(here) until \(owner) lets go. Nothing on \(recorder) is lost."
        }

        /// Why the other device said no.
        public static func refusal(_ refusal: LinkRecorderHandoffRefusal, by device: String, recorder: String) -> String {
            if let message = refusal.message { return message }
            switch refusal.reason {
            case .notOwner:
                return refusal.ownerName.map { "\(device) doesn’t manage \(recorder); \($0) does." } ?? "\(device) doesn’t manage \(recorder) any more."
            case .notSetUp: return "\(recorder) isn’t set up on \(device). Add it there first."
            case .busy: return "\(device) is already handing \(recorder) to another device."
            case .declined: return "\(device) declined."
            default: return "\(device) can’t hand over \(recorder)."
            }
        }
    }
}
