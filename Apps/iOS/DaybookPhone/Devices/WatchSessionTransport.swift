import DaybookKit
import Foundation
import Observation
import os
import WatchConnectivity

/// WatchConnectivity, as Apple Watch's connection speaks it (`WatchTransport`, DaybookDevices): `WCSession.default`,
/// activated at launch with the devices (`PhoneDevices.start`), before the first scene, so a message that launched
/// Daybook in the background is heard. Its delegate runs on WatchConnectivity's queue: a segment file is moved into
/// staging there, before the callback returns (the system deletes it after), and everything else is decoded there and
/// handed to the main actor. Messages that arrive before the watch's connection exists wait for it, and reach it on the
/// turn after it starts listening, once its session has wired its button. A segment that can't be staged is only
/// logged: the connection's receipts leave it out, and the watch sends it again.
@MainActor
@Observable
final class WatchSessionTransport: WatchTransport {
    private(set) var isActivated = false
    private(set) var activationError: String?
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var watchContext: WatchState?
    @ObservationIgnored var onMessage: ((WatchMessage, ((WatchReply) -> Void)?) -> Void)? { didSet { scheduleHeld() } }
    @ObservationIgnored var onSegment: ((WatchStagedSegment) -> Void)?
    @ObservationIgnored var onWatchContext: ((WatchState) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let session: WCSession
    @ObservationIgnored private let receiver: Receiver
    @ObservationIgnored private var activating = false
    /// What waits for activation: the latest context, and queued messages in order.
    @ObservationIgnored private var pendingContext: PhoneContext?
    @ObservationIgnored private var pendingQueue: [WatchMessage] = []
    /// Messages that came before anything listened, at most `heldLimit`.
    @ObservationIgnored private var held: [(WatchMessage, ((WatchReply) -> Void)?)] = []
    private static let heldLimit = 20
    nonisolated private static let log = Logger(subsystem: "local.daybook.phone", category: "Watch")

    /// WatchConnectivity's, staging segments in the devices' staging folder; nil where there's none.
    static func ifSupported(stagingDirectory: URL) -> WatchSessionTransport? {
        guard WCSession.isSupported() else { return nil }
        return WatchSessionTransport(session: .default, staging: WatchStaging.folder(in: stagingDirectory))
    }

    private init(session: WCSession, staging: URL) {
        self.session = session
        receiver = Receiver(staging: staging)
        receiver.deliver = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func activate() {
        guard !activating, !isActivated else { return }
        activating = true
        session.delegate = receiver
        session.activate()
    }

    func send(_ message: WatchMessage, timeout: Duration) async throws -> WatchReply {
        guard isActivated, session.isReachable else { throw WatchTransportError.unreachable }
        let payload = try WatchPayload.dictionary(message)
        return try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            session.sendMessage(payload, replyHandler: { reply in
                answer.resume(WatchPayload.decode(WatchReply.self, from: reply).map { .success($0) } ?? .failure(WatchTransportError.unreadable))
            }, errorHandler: { error in
                let unreachable = (error as? WCError)?.code == .notReachable
                answer.resume(.failure(unreachable ? WatchTransportError.unreachable : WatchTransportError.failed(error.localizedDescription)))
            })
            Task {
                try? await Task.sleep(for: timeout)
                answer.resume(.failure(WatchTransportError.timedOut))
            }
        }
    }

    func queue(_ message: WatchMessage) {
        guard isActivated else { return pendingQueue.append(message) }
        do { session.transferUserInfo(try WatchPayload.dictionary(message)) } catch { Self.log.error("Couldn't queue a message: \(error.localizedDescription, privacy: .public)") }
    }

    func tell(_ message: WatchMessage) {
        guard isActivated, session.isReachable, let payload = try? WatchPayload.dictionary(message) else { return queue(message) }
        session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.queue(message) }
        }
    }

    func updateContext(_ context: PhoneContext) {
        guard isActivated, isPaired, isWatchAppInstalled else {
            pendingContext = context
            return
        }
        pendingContext = nil
        // Stamped as it's sent: one that waited for activation is what this iPhone records now.
        var context = context
        context.sentAt = Date()
        do { try session.updateApplicationContext(try WatchPayload.dictionary(context)) } catch {
            Self.log.error("Couldn't publish the context: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: From WatchConnectivity

    private func handle(_ event: Event) {
        switch event {
        case .activated(let error):
            activating = false
            activationError = error
            readState()
            sendPending()
            onChange?()
        case .changed:
            readState()
            sendPending()
            onChange?()
        case .message(let message, let reply):
            let answer = reply.map { reply in { (answer: WatchReply) in reply.send(answer) } }
            if let onMessage { onMessage(message, answer) } else {
                held.append((message, answer))
                guard held.count > Self.heldLimit else { return }
                // The oldest go, and the watch, if it waits on one, hears so rather than waiting it out.
                for (_, reply) in held.prefix(held.count - Self.heldLimit) { reply?(.refused(Self.notListening)) }
                held.removeFirst(held.count - Self.heldLimit)
            }
        case .watchState(let state):
            watchContext = state
            onWatchContext?(state)
        case .segment(let staged):
            onSegment?(staged)
        }
    }

    private func readState() {
        let activated = session.activationState == .activated
        if activated != isActivated { isActivated = activated }
        if session.isPaired != isPaired { isPaired = session.isPaired }
        if session.isWatchAppInstalled != isWatchAppInstalled { isWatchAppInstalled = session.isWatchAppInstalled }
        if session.isReachable != isReachable { isReachable = session.isReachable }
    }

    private func sendPending() {
        guard isActivated else { return }
        let queued = pendingQueue
        pendingQueue = []
        queued.forEach(queue)
        if let pendingContext { updateContext(pendingContext) }
    }

    /// On the next turn: the connection that set `onMessage` is made before its session wires its button.
    private func scheduleHeld() {
        guard onMessage != nil, !held.isEmpty else { return }
        Task { [weak self] in self?.deliverHeld() }
    }

    private func deliverHeld() {
        guard let onMessage, !held.isEmpty else { return }
        let messages = held
        held = []
        for (message, reply) in messages { onMessage(message, reply) }
    }

    private static let notListening = "Daybook on this iPhone couldn’t answer yet."

    // MARK: WatchConnectivity's queue

    enum Event: Sendable {
        case activated(String?)
        case changed
        case message(WatchMessage, Reply?)
        case watchState(WatchState)
        case segment(WatchStagedSegment)
    }

    /// WatchConnectivity's reply handler, for an answer on the main actor.
    final class Reply: @unchecked Sendable {
        private let handler: ([String: Any]) -> Void
        init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
        func send(_ reply: WatchReply) { handler((try? WatchPayload.dictionary(reply)) ?? [:]) }
    }

    /// One answer to one message: the watch's reply, its error, or the timeout, whichever comes first.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WatchReply, Error>?
        init(_ continuation: CheckedContinuation<WatchReply, Error>) { self.continuation = continuation }
        func resume(_ result: Result<WatchReply, Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }
    }

    /// `WCSession`'s delegate.
    final class Receiver: NSObject, WCSessionDelegate, @unchecked Sendable {
        private let staging: URL
        /// Set once, before activation.
        var deliver: (@Sendable (Event) -> Void)?

        init(staging: URL) { self.staging = staging }

        func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
            if let state = WatchPayload.decode(WatchState.self, from: session.receivedApplicationContext) { deliver?(.watchState(state)) }
            deliver?(.activated(error?.localizedDescription))
        }

        func sessionDidBecomeInactive(_ session: WCSession) { deliver?(.changed) }

        /// Another watch was chosen: activated again, for it.
        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
            deliver?(.changed)
        }

        func sessionWatchStateDidChange(_ session: WCSession) { deliver?(.changed) }
        func sessionReachabilityDidChange(_ session: WCSession) { deliver?(.changed) }

        func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
            if let decoded = WatchPayload.decode(WatchMessage.self, from: message) { deliver?(.message(decoded, nil)) }
        }

        func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
            guard let decoded = WatchPayload.decode(WatchMessage.self, from: message) else {
                return replyHandler((try? WatchPayload.dictionary(WatchReply.refused("Daybook on this iPhone needs updating."))) ?? [:])
            }
            deliver?(.message(decoded, Reply(replyHandler)))
        }

        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            if let decoded = WatchPayload.decode(WatchMessage.self, from: userInfo) { deliver?(.message(decoded, nil)) }
        }

        func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
            if let state = WatchPayload.decode(WatchState.self, from: applicationContext) { deliver?(.watchState(state)) }
        }

        /// Moved into staging now: the file is deleted once this returns.
        func session(_ session: WCSession, didReceive file: WCSessionFile) {
            guard let metadata = file.metadata else { return }
            do {
                deliver?(.segment(try WatchStaging.stage(file.fileURL, metadata: metadata, in: staging)))
            } catch {
                WatchSessionTransport.log.error("A segment from the watch couldn't be staged: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
