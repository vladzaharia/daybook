import DaybookCore
import Foundation
import Observation

/// The courier beside iCloud Drive (docs/icloud-sync.md, "Courier (CloudKit)"), as `LibrarySyncController` drives it:
/// started once per connection, handed the files each pass wrote, asked to fetch when a push arrives or to try again
/// when the app comes to the front, and its status kept for the sync status. The controller owns one and forwards
/// `courier`, `courierRole`, and `courierStatus`.
@MainActor
@Observable
final class SyncCourierBridge {
    @ObservationIgnored var courier: (any SyncCourier)?
    var role: CourierRole = []
    /// The courier's state for the sync status: how many files wait to send, and whether a send is stuck.
    private(set) var status = CourierStatus()
    /// Called once the courier is available. The apps register for remote notifications, which CKSyncEngine needs.
    @ObservationIgnored var onAvailable: (() -> Void)?
    /// Told after each status is applied (the controller's settled status follows storage full).
    @ObservationIgnored var onStatus: (() -> Void)?
    @ObservationIgnored private var started: Task<Void, Never>?
    @ObservationIgnored private var sends: Task<Void, Never>?
    @ObservationIgnored private var expiryCheck: Date?
    /// Numbers the running courier's statuses (`apply`).
    @ObservationIgnored private var numbering = StatusNumbering()
    /// The libraries whose plaintext courier files were dropped once they were found encrypted.
    @ObservationIgnored private var sealedLibraries = Set<UUID>()

    /// Starts the courier in `role`, once per connection; files from other devices go to `receiver`.
    func start(receiver: CourierReceiver?) {
        guard let courier, !role.isEmpty, started == nil else { return }
        let role = role
        weak let weakSelf = self
        // Statuses hop to the main actor one task each, which may run out of order: each is numbered as it's reported,
        // and an older one never covers a newer, nor one from a courier started before this one.
        let numbering = StatusNumbering()
        self.numbering = numbering
        let onStatus: @Sendable (CourierStatus) -> Void = { [weak self] status in
            let number = numbering.issue()
            guard let self else { return }
            Task { @MainActor in self.apply(status, number: number, from: numbering) }
        }
        started = Task {
            let availability = await courier.start(role: role, receiver: receiver, onStatus: onStatus)
            guard availability == .available else { return }
            weakSelf?.onAvailable?()
            if role.contains(.receive) { await courier.fetch() }
        }
    }

    func stop() {
        guard let courier, let start = started else { return }
        started = nil
        Task { await start.value; await courier.stop() }
    }

    /// Hands the files a pass wrote to the courier and asks it to send them now. Each file is sent once, however often a
    /// pass reports it. Expired courier files are cleared at most hourly, after a pass.
    func hand(_ files: [SyncJournalFile], engine: LibrarySyncEngine, deviceID: String) {
        guard let courier, let start = started else { return }
        let now = Date()
        if expiryCheck.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true {
            expiryCheck = now
            Task { await start.value; await courier.removeExpired() }
        }
        guard role.contains(.send), !files.isEmpty else { return }
        let previous = sends
        sends = Task {
            await start.value
            await previous?.value
            guard let libraryID = await engine.libraryID else { return }
            let outgoing = files.map { file in
                CourierOutgoingFile(libraryID: libraryID, journal: file, deviceID: deviceID) { try engine.copyJournalFile(file, to: $0) }
            }
            await courier.send(outgoing)
            await courier.flush()
        }
    }

    /// Waits until the courier has taken what the latest passes wrote and tried sending it, or the calling task is
    /// cancelled.
    func finishSends() async {
        guard let sends else { return }
        await TaskWaiter.wait(for: sends)
    }

    /// Tries again a courier that's off for a reason that may have passed (the app came to the front).
    func resume() {
        guard let courier, let start = started else { return }
        Task { await start.value; await courier.reconnect() }
    }

    /// Asks the courier for what other devices sent (a push arrived).
    func fetch() {
        guard let courier, let start = started else { return }
        Task { await start.value; await courier.fetch() }
    }

    /// `libraryID` turned out encrypted: the plaintext files the courier still holds are dropped, once (and those it sent,
    /// deleted).
    func forgetPlaintext(of libraryID: UUID) {
        guard let courier, sealedLibraries.insert(libraryID).inserted else { return }
        Task { await courier.forgetPlaintext() }
    }

    private func apply(_ next: CourierStatus, number: Int, from numbering: StatusNumbering) {
        guard numbering === self.numbering, numbering.apply(number) else { return }
        status = next
        onStatus?()
    }
}

extension LibrarySyncController {
    // MARK: Courier

    /// The fast path beside iCloud Drive (docs/icloud-sync.md, "Courier (CloudKit)"): the iPhone sends the files its
    /// passes write, a Mac receives them into the engine's inbox. Set it and `courierRole` before connecting. Nil, or
    /// unavailable: iCloud Drive carries everything, exactly as without a courier.
    public var courier: (any SyncCourier)? {
        get { courierBridge.courier }
        set { courierBridge.courier = newValue }
    }
    public var courierRole: CourierRole {
        get { courierBridge.role }
        set { courierBridge.role = newValue }
    }
    /// The courier's state for the sync status: how many files wait to send, and whether a send is stuck.
    public var courierStatus: CourierStatus { courierBridge.status }
    /// Called once the courier is available. The apps register for remote notifications, which CKSyncEngine needs.
    public var onCourierAvailable: (() -> Void)? {
        get { courierBridge.onAvailable }
        set { courierBridge.onAvailable = newValue }
    }

    func startCourier() {
        weak let weakSelf = self
        courierBridge.onStatus = { weakSelf?.courierStatusChanged() }
        var receiver: CourierReceiver?
        if courierRole.contains(.receive) {
            receiver = { files in await weakSelf?.receiveCourierFiles(files) ?? [] }
        }
        courierBridge.start(receiver: receiver)
    }

    func stopCourier() { courierBridge.stop() }

    /// Hands the files a pass wrote to the courier and asks it to send them now. Each file is sent once, however
    /// often a pass reports it. Expired courier files are cleared at most hourly, after a pass.
    func handToCourier(_ files: [SyncJournalFile], engine: LibrarySyncEngine) {
        courierBridge.hand(files, engine: engine, deviceID: deviceID)
    }

    /// Waits until the courier has taken what the latest passes wrote and tried sending it. The iPhone waits under its
    /// background-task assertion. Returns at once if the calling task is cancelled; the courier carries on as the
    /// system allows, and iCloud Drive carries everything regardless.
    public func finishCourierSends() async { await courierBridge.finishSends() }

    /// The app came to the front: a courier that's off because the account couldn't be checked when it started (an
    /// iPhone woken in the background soon after it started) tries again now.
    public func resumeCourier() { courierBridge.resume() }

    /// Asks the courier for what other devices sent (a push arrived).
    public func fetchCourier() { courierBridge.fetch() }

    /// Files a courier brought. Each is verified and kept in the engine's inbox, never written into the sync folder;
    /// a pass then applies them. Returns those the courier may delete: stored, already here, or rejected.
    func receiveCourierFiles(_ files: [CourierIncomingFile]) async -> Set<String> {
        guard let engine else { return [] }
        var settled = Set<String>()
        var stored = false
        for incoming in files {
            guard let delivery = try? await engine.receiveCourierFile(incoming.file.journal, libraryID: incoming.file.libraryID,
                                                                      contents: incoming.contents) else { continue }
            if delivery == .stored { stored = true }
            if delivery.isSettled { settled.insert(incoming.file.id) }
        }
        if stored { requestSync() }
        return settled
    }
}
