import Foundation

/// Where Wi‑Fi Fast Transfer is, for the recorder's page.
public enum FastTransferStage: Equatable, Sendable {
    /// Asking the recorder over Bluetooth to open its access point.
    case opening
    /// Bluetooth let go; the recorder's network is starting.
    case starting
    /// Joining its network (iOS asks the person).
    case joining
    /// Opening the WebSocket.
    case connecting
    /// Transferring, or waiting for the next recording queued.
    case transferring
    /// Ending: FINISH, leaving the network, back to Bluetooth, and the access point closed.
    case closing

    /// What the page says: "Starting Wi‑Fi…", "Over Wi‑Fi", "Back to Bluetooth…".
    public var label: String {
        switch self {
        case .opening, .starting, .joining, .connecting: return "Starting Wi‑Fi…"
        case .transferring: return "Over Wi‑Fi"
        case .closing: return "Back to Bluetooth…"
        }
    }
}

/// What Fast Transfer asks of the Soundcore connection that runs it.
@MainActor
protocol SoundcoreFastTransferHost: AnyObject {
    /// The confirmed Bluetooth session, while the link is up.
    var bluetoothSession: SoundcoreSession? { get }
    /// Another recording from this recorder is waiting in the import queue.
    var moreQueued: Bool { get }
    /// Lets the Bluetooth link go on purpose: the recorder is starting its access point.
    func leaveBluetoothForWiFi()
    /// Brings the Bluetooth link back. Once it's confirmed, the connection closes the access point.
    func returnToBluetooth()
    /// Remembers that the recorder's access point may be open (its name), or that it's closed (nil), so
    /// a run that ends before closing it closes it on the next connection.
    func accessPointMayBeOpen(_ ssid: String?)
    func fastTransferChanged()
    func fastTransferFailed(_ error: Error)
}

public enum SoundcoreFastTransferError: LocalizedError, Equatable {
    /// Daybook left the foreground, where iOS lets it use the recorder's network.
    case background
    /// Fast Transfer ended while it was starting (Daybook left the foreground, or it was stopped).
    case ended

    public var errorDescription: String? {
        switch self {
        case .background: return "Daybook left the foreground."
        case .ended: return "Fast Transfer ended before it started."
        }
    }
}

/// Wi‑Fi Fast Transfer (iPhone, in the foreground; docs/direct-soundcore.md, "Wi‑Fi Fast Transfer"):
///
/// 1. Over Bluetooth, after the usual key exchange (the Wi‑Fi transfer reuses that key), `1A 05` with an
///    access point name and password Daybook chooses; the recorder answers with its address and port.
/// 2. Bluetooth is let go on purpose, and the recorder gets `accessPointStartup` to start its network.
/// 3. The iPhone joins it (`SoundcoreHotspot`; iOS asks each time) and opens `wss://` to the recorder,
///    taking its self-signed certificate, with a UDP keep-alive every two seconds.
/// 4. Each recording is asked for as hex text (`1A 07` with an offset of 0), and arrives as the same
///    encrypted packets as over Bluetooth, through the same checks.
/// 5. FINISH, the network left, Bluetooth back, and `1A 02` closes the access point. Nothing deletes.
///
/// Any failure falls back to Bluetooth, and the access point is closed on the next confirmed Bluetooth
/// link whatever happened (`accessPointMayBeOpen` persists that it may be open).
@MainActor
final class SoundcoreFastTransfer {
    /// How the last attempt went, for Device Details.
    enum Outcome: Equatable {
        case transferred(Date)
        case fellBack(Date, String)
    }

    private(set) var stage: FastTransferStage? {
        didSet { if stage != oldValue { host?.fastTransferChanged() } }
    }
    private(set) var outcome: Outcome?
    var isActive: Bool { stage != nil }
    /// On the recorder's network now, with nothing ending it.
    var isLinked: Bool { link != nil && ending == nil }

    private weak var host: (any SoundcoreFastTransferHost)?
    private let hooks: SoundcoreWiFiHooks
    private let timing: SoundcoreTiming
    private var link: Link?
    private var joined: String?
    private var leftBluetooth = false
    private var downloading = false
    private var lingering: Task<Void, Never>?
    private var ending: Task<Void, Never>?

    private struct Link {
        let socket: SoundcoreWebSocket
        let keepAlive: SoundcoreKeepAlive
        let session: SoundcoreSession
    }

    init(host: any SoundcoreFastTransferHost, hooks: SoundcoreWiFiHooks, timing: SoundcoreTiming) {
        self.host = host
        self.hooks = hooks
        self.timing = timing
        hooks.observeForeground { [weak self] front in
            guard !front, let self, self.isActive else { return }
            self.outcome = .fellBack(Date(), SoundcoreFastTransferError.background.localizedDescription)
            self.end()
        }
    }

    /// Moves one recording over the recorder's Wi‑Fi, opening it first unless it's open. True when it's
    /// done; false when Fast Transfer gave up and the link is on its way back to Bluetooth, where the
    /// caller carries on. Cancelling (the person stopped the import) ends Fast Transfer.
    func transfer(_ recording: SoundcoreRecording, to url: URL,
                  progress: @escaping (TransferPhase, UInt64) -> Void) async throws -> Bool {
        lingering?.cancel()
        lingering = nil
        do {
            if link == nil { try await start() }
            guard let link, ending == nil else { throw SoundcoreFastTransferError.ended }
            stage = .transferring
            downloading = true
            defer { downloading = false }
            _ = try await link.session.download(recording, to: url, progress: progress)
            outcome = .transferred(Date())
            if host?.moreQueued == true { linger() } else { end() }
            return true
        } catch is CancellationError {
            end()
            throw CancellationError()
        } catch {
            // Unless it's ending already for its own reason (Daybook left the foreground).
            if ending == nil {
                outcome = .fellBack(Date(), error.localizedDescription)
                host?.fastTransferFailed(error)
            }
            end()
            return false
        }
    }

    /// Waits for Fast Transfer that's ending to finish ending.
    func settled() async {
        await ending?.value
    }

    /// Ends Fast Transfer: FINISH, the WebSocket and keep-alive closed, the network left, and the link
    /// back on Bluetooth.
    func end() {
        guard stage != nil, ending == nil else { return }
        stage = .closing
        lingering?.cancel()
        lingering = nil
        let socket = link?.socket
        ending = Task { [weak self] in
            if let socket, socket.isOpen {
                try? socket.send(text: SoundcoreWiFi.finish)
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.ended()
        }
    }

    /// The connection is going away (Disconnect, quitting): the Wi‑Fi side ends where it is, and
    /// Bluetooth isn't reached for. The access point stays marked as possibly open, for the next
    /// connection to close.
    func abandon() {
        lingering?.cancel()
        lingering = nil
        ending?.cancel()
        ending = nil
        tearDown()
        leftBluetooth = false
        stage = nil
    }

    // MARK: Starting

    private func start() async throws {
        guard let host, let hotspot = hooks.hotspot, let bluetooth = host.bluetoothSession else { throw SoundcoreError.disconnected }
        stage = .opening
        let credentials = SoundcoreWiFi.credentials()
        let accessPoint: SoundcoreAccessPoint
        do {
            accessPoint = try await bluetooth.openAccessPoint(ssid: credentials.ssid, password: credentials.password)
        } catch SoundcoreError.timedOut {
            // It may have opened without its answer arriving: closing it is harmless either way.
            try? await bluetooth.closeAccessPoint()
            throw SoundcoreError.timedOut
        }
        try stillStarting()
        host.accessPointMayBeOpen(accessPoint.ssid)
        let key = bluetooth.handOverKey()
        leftBluetooth = true
        host.leaveBluetoothForWiFi()

        stage = .starting
        try await Task.sleep(for: timing.accessPointStartup)
        try stillStarting()
        guard hooks.isForeground else { throw SoundcoreFastTransferError.background }

        stage = .joining
        joined = accessPoint.ssid
        try await hotspot.join(ssid: accessPoint.ssid, password: accessPoint.password, recorder: accessPoint.host)
        try stillStarting()

        stage = .connecting
        let socket = try await connect(accessPoint)
        try stillStarting()
        let keepAlive = SoundcoreKeepAlive(host: accessPoint.host, port: hooks.keepAlivePort(accessPoint.host),
                                           requiresWiFi: hooks.requiresWiFi, interval: timing.keepAlive)
        let session = SoundcoreSession(timing: timing, medium: .wifi, crypto: key) { [weak socket] data in
            guard let socket else { throw SoundcoreError.disconnected }
            try socket.send(text: String(decoding: data, as: UTF8.self))
        }
        socket.onMessage = { [weak session] message in
            switch message {
            case .binary(let data): session?.receive(data)
            // Hex text is the same frames; short texts ("OK") answer FINISH.
            case .text(let text): if text.count >= 20, let data = SoundcoreWiFi.bytes(hex: text) { session?.receive(data) }
            }
        }
        socket.onClose = { [weak self, weak session] _ in
            session?.close()
            self?.linkLost()
        }
        link = Link(socket: socket, keepAlive: keepAlive, session: session)
    }

    /// Something ended Fast Transfer while it was starting.
    private func stillStarting() throws {
        if ending != nil || stage == nil { throw SoundcoreFastTransferError.ended }
        try Task.checkCancellation()
    }

    /// The recorder's WebSocket, in a few attempts: its network may take a moment to route.
    private func connect(_ accessPoint: SoundcoreAccessPoint) async throws -> SoundcoreWebSocket {
        var last: Error = WebSocketError.timedOut
        for attempt in 0..<max(1, timing.webSocketAttempts) {
            if attempt > 0 { try await Task.sleep(for: timing.webSocketRetry) }
            try stillStarting()
            let socket = SoundcoreWebSocket(host: accessPoint.host, port: accessPoint.port, requiresWiFi: hooks.requiresWiFi)
            do {
                try await socket.open(timeout: timing.webSocketConnect)
                return socket
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = error
            }
        }
        throw last
    }

    // MARK: Ending

    /// Another recording is queued: the Wi‑Fi link waits a while for it, then ends.
    private func linger() {
        let wait = timing.fastTransferLinger
        lingering = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    /// The recorder closed the WebSocket. A transfer under way fails and falls back on its own;
    /// between transfers, Fast Transfer ends.
    private func linkLost() {
        guard ending == nil, !downloading, link != nil else { return }
        outcome = .fellBack(Date(), WebSocketError.closed.localizedDescription)
        end()
    }

    private func ended() {
        guard ending != nil else { return }
        tearDown()
        if leftBluetooth {
            leftBluetooth = false
            host?.returnToBluetooth()
        }
        ending = nil
        stage = nil
    }

    private func tearDown() {
        if let link {
            link.keepAlive.stop()
            link.socket.onClose = nil
            link.socket.close()
            link.session.close()
        }
        link = nil
        if let joined { hooks.hotspot?.leave(ssid: joined) }
        joined = nil
    }
}
