import DaybookWatchLink
import Foundation
import WatchConnectivity
import WatchKit

/// The watch's side of WatchConnectivity (docs/watch.md, "The protocol, as the watch uses it"): what the iPhone asks and
/// tells, the state the watch pushes, and the segments it sends. Thin on purpose: what the messages mean is
/// `WatchModel`'s and `WatchFollowing`'s.
///
/// The state goes by `sendMessage` when the iPhone is reachable, and always as the application context, so the iPhone
/// knows it after a relaunch. Each closed segment goes once with `transferFile`, its `WatchSegment` as the metadata; a
/// transfer that fails is tried again. A finished transfer isn't delivery: only the iPhone's receipt is (`WatchReceipt`).
@MainActor
final class PhoneLink: NSObject {
    /// Answers a message that asked for one.
    struct Reply: @unchecked Sendable {
        let send: ([String: Any]) -> Void

        func callAsFunction(_ reply: WatchReply) {
            if let dictionary = try? WatchPayload.dictionary(reply) { send(dictionary) }
        }
    }

    var onActivated: () -> Void = {}
    /// Once after activation, when what waited for the app (the iPhone's receipts, transfers that finished while it
    /// wasn't running) has been handled: the time to send what the iPhone still needs.
    var onSettled: () -> Void = {}
    var onMessage: (WatchMessage, Reply?) -> Void = { _, _ in }
    /// A context, and whether it's the answer to `.context` (rather than the application context).
    var onContext: (PhoneContext, Bool) -> Void = { _, _ in }
    var onReachability: (Bool) -> Void = { _ in }
    /// A segment's transfer finished: it isn't sent again unless the iPhone asks. Delivered only once a receipt names it.
    var onTransferred: (WatchSegment) -> Void = { _ in }

    private(set) var isActivated = false
    private(set) var isReachable = false
    private(set) var isSettled = false

    private let store: WatchStore
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var pendingTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    /// Activation finished, successfully or not.
    private var activationEnded = false
    private var observations: [NSKeyValueObservation] = []
    private var retries: [String: Int] = [:]
    /// Tries a failed transfer again this many times while the app runs; the next launch starts over.
    private static let attempts = 5

    init(store: WatchStore) {
        self.store = store
    }

    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        // Background tasks wait for what's pending to arrive (WKWatchConnectivityRefreshBackgroundTask).
        observations = Self.observe(session) { [weak self] in self?.settle() }
        session.activate()
    }

    /// The newest application context the iPhone sent, if any.
    var receivedContext: PhoneContext? {
        guard let session, isActivated else { return nil }
        return WatchPayload.decode(PhoneContext.self, from: session.receivedApplicationContext)
    }

    /// Holds a background task until what WatchConnectivity has pending has been handled.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        pendingTasks.append(task)
        settle()
    }

    /// Tells the iPhone the watch's state: a message now when it's reachable, and the application context always.
    /// Before activation there's no session to tell; the model pushes again once it's activated.
    func push(_ state: WatchState) {
        guard let session, isActivated, let dictionary = try? WatchPayload.dictionary(state) else { return }
        try? session.updateApplicationContext(dictionary)
        if session.isReachable, let message = try? WatchPayload.dictionary(WatchMessage.state(state)) {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    /// Asks the iPhone what it's recording; the answer comes to `onContext`. Unreachable, or with no answer, the
    /// application context it last sent stands in (not as an answer).
    func askContext() {
        guard let session, isActivated else { return }
        let answered: @MainActor @Sendable (PhoneContext?) -> Void = { [weak self] context in
            guard let self else { return }
            if let context {
                self.onContext(context, true)
            } else if let context = self.receivedContext {
                self.onContext(context, false)
            }
        }
        guard session.isReachable, let message = try? WatchPayload.dictionary(WatchMessage.context) else {
            answered(nil)
            return
        }
        let handlers = Self.contextHandlers(answered)
        session.sendMessage(message, replyHandler: handlers.reply, errorHandler: handlers.error)
    }

    /// Sends the segments the iPhone doesn't have and isn't already being sent.
    func send(_ segments: [WatchSegment]) {
        guard let session, isActivated else { return }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { transfer in
            WatchPayload.decode(WatchSegment.self, from: transfer.file.metadata ?? [:]).map(Self.key)
        })
        for segment in segments where !inFlight.contains(Self.key(segment)) {
            let url = store.url(of: segment)
            guard FileManager.default.fileExists(atPath: url.path),
                  let metadata = try? WatchPayload.dictionary(segment) else { continue }
            session.transferFile(url, metadata: metadata)
        }
    }

    private static func key(_ segment: WatchSegment) -> String { "\(segment.recordingID)/\(segment.index)" }

    /// Once activated with nothing pending, settles (the first time) and completes the background tasks held. Delivered
    /// content was handed to the main queue ahead of this, so it's been handled. With no session, or activation failed,
    /// nothing will arrive: the tasks complete at once. Only once `activated()` has recorded the activation (the state's
    /// observation can come first): until then nothing can be sent, so `activated()` settles again.
    private func settle() {
        guard let session, isActivated, session.activationState == .activated else {
            if session == nil || activationEnded { completeTasks() }
            return
        }
        guard !session.hasContentPending else { return }
        if !isSettled {
            isSettled = true
            onSettled()
        }
        completeTasks()
    }

    private func completeTasks() {
        pendingTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        pendingTasks.removeAll()
    }

    private func activated() {
        activationEnded = true
        isActivated = session?.activationState == .activated
        isReachable = session?.isReachable ?? false
        if isActivated { onActivated() }
        settle()
    }

    private func reachabilityChanged(_ reachable: Bool) {
        isReachable = reachable
        onReachability(reachable)
    }

    private func transferFinished(_ segment: WatchSegment?, url: URL, failed: Bool) {
        guard let segment else { return }
        let key = Self.key(segment)
        guard failed else {
            retries[key] = nil
            onTransferred(segment)
            return
        }
        let attempt = (retries[key] ?? 0) + 1
        retries[key] = attempt
        guard attempt <= Self.attempts, FileManager.default.fileExists(atPath: url.path) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10 * attempt))
            // Unless another transfer of it finished meanwhile.
            guard let self, self.retries[key] == attempt else { return }
            self.send([segment])
        }
    }

    private func deliver(_ message: WatchMessage?, reply: Reply?) {
        guard let message else {
            reply?.callAsFunction(.refused("Update Daybook on your Apple Watch."))
            return
        }
        onMessage(message, reply)
    }

    // MARK: Off the main actor

    // WatchConnectivity and KVO call these on their own queues. They're made here, outside the main actor, and hop to it.

    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    nonisolated private static func observe(_ session: WCSession,
                                            changed: @escaping @MainActor @Sendable () -> Void) -> [NSKeyValueObservation] {
        [session.observe(\.activationState) { _, _ in onMain(changed) },
         session.observe(\.hasContentPending) { _, _ in onMain(changed) }]
    }

    nonisolated private static func contextHandlers(_ answered: @escaping @MainActor @Sendable (PhoneContext?) -> Void)
        -> (reply: ([String: Any]) -> Void, error: (Error) -> Void) {
        let reply: ([String: Any]) -> Void = { dictionary in
            var context: PhoneContext?
            if case .context(let answer) = WatchPayload.decode(WatchReply.self, from: dictionary) { context = answer }
            let answer = context
            onMain { answered(answer) }
        }
        return (reply, { _ in onMain { answered(nil) } })
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Self.onMain { self.activated() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Self.onMain { self.reachabilityChanged(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let decoded = WatchPayload.decode(WatchMessage.self, from: message)
        Self.onMain { self.deliver(decoded, reply: nil) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let decoded = WatchPayload.decode(WatchMessage.self, from: message)
        let reply = Reply(send: replyHandler)
        Self.onMain { self.deliver(decoded, reply: reply) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let decoded = WatchPayload.decode(WatchMessage.self, from: userInfo) else { return }
        Self.onMain { self.deliver(decoded, reply: nil) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let decoded = WatchPayload.decode(PhoneContext.self, from: applicationContext) else { return }
        Self.onMain { self.onContext(decoded, false) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let segment = WatchPayload.decode(WatchSegment.self, from: fileTransfer.file.metadata ?? [:])
        let url = fileTransfer.file.fileURL
        let failed = error != nil
        Self.onMain { self.transferFinished(segment, url: url, failed: failed) }
    }
}
