import Foundation

/// Where Wi‑Fi Fast Transfer is, for the recorder's page.
public enum FastTransferStage: Equatable, Sendable {
    /// Asking the recorder over Bluetooth to open its access point.
    case opening
    /// Bluetooth let go; the recorder's network is starting.
    case starting
    /// Joining its network: iOS asks the person, so the page names whose network it is.
    case joining(recorder: String)
    /// Opening the WebSocket.
    case connecting
    /// Transferring, or waiting for the next recording queued.
    case transferring
    /// Ending: FINISH, leaving the network, back to Bluetooth, and the access point closed.
    case closing

    /// Short, for a figure's place beside a title and in a status line: "Starting Wi‑Fi…", "Joining Wi‑Fi…",
    /// "Over Wi‑Fi", "Back to Bluetooth…".
    public var label: String {
        switch self {
        case .opening, .starting, .connecting: return "Starting Wi‑Fi…"
        case .joining: return "Joining Wi‑Fi…"
        case .transferring: return "Over Wi‑Fi"
        case .closing: return "Back to Bluetooth…"
        }
    }

    /// A line of its own under the import's progress, while iOS asks to join a network called "WiFi-1730…", so the
    /// question has its context: "Joining Soundcore Work’s Wi‑Fi…". Nil at the other stages.
    public var sentence: String? {
        guard case .joining(let recorder) = self else { return nil }
        return "Joining \(recorder)’s Wi‑Fi…"
    }
}

/// What Fast Transfer asks of the Soundcore connection that runs it.
@MainActor
protocol SoundcoreFastTransferHost: AnyObject {
    /// The confirmed Bluetooth session, while the link is up.
    var bluetoothSession: SoundcoreSession? { get }
    /// Another recording from this recorder is waiting in the import queue.
    var moreQueued: Bool { get }
    /// The recorder's name as the person knows it, for "Joining Soundcore Work’s Wi‑Fi…".
    var recorderName: String { get }
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
///    access point name and password Daybook chooses; the recorder answers with its address and port. If
///    the iPhone couldn't tell the recorder's network from the one it's on (`SoundcoreHotspot.canCheckJoin`),
///    the access point is closed and the transfer stays on Bluetooth.
/// 2. Bluetooth is let go on purpose, and the recorder gets `accessPointStartup` to start its network.
/// 3. The iPhone joins it (`SoundcoreHotspot`; iOS asks each time) and, while it's on the recorder's network
///    (`SoundcoreHotspot.isJoined`), opens `wss://` to the recorder, taking its self-signed certificate, with a
///    UDP keep-alive every two seconds.
/// 4. Each recording is asked for as hex text (`1A 07` with an offset of 0), and arrives as the same
///    encrypted packets as over Bluetooth, through the same checks.
/// 5. FINISH, the network left, Bluetooth back, and `1A 02` closes the access point. Nothing deletes.
///
/// Any failure falls back to Bluetooth, and the access point is closed on the next confirmed Bluetooth
/// link whatever happened (`accessPointMayBeOpen` persists that it may be open). While it runs, the app
/// holds a short background task (`SoundcoreWiFiHooks.holdInBackground`): a moment outside Daybook doesn't
/// cost a transfer on the recorder's network, and a longer one ends Fast Transfer tidily.
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
    /// The app's background time is held (tests).
    var holdsBackgroundTime: Bool { releaseBackground != nil }

    private weak var host: (any SoundcoreFastTransferHost)?
    private let hooks: SoundcoreWiFiHooks
    private let timing: SoundcoreTiming
    private var link: Link?
    private var joined: String?
    private var leftBluetooth = false
    private var downloading = false
    private var lingering: Task<Void, Never>?
    private var ending: Task<Void, Never>?
    /// Ends the background task held while Fast Transfer runs.
    private var releaseBackground: (@MainActor () -> Void)?
    /// Out of the foreground on the recorder's network: Fast Transfer ends when this runs out.
    private var backgroundGrace: Task<Void, Never>?

    private struct Link {
        let socket: SoundcoreWebSocket
        let keepAlive: SoundcoreKeepAlive
        let session: SoundcoreSession
    }

    init(host: any SoundcoreFastTransferHost, hooks: SoundcoreWiFiHooks, timing: SoundcoreTiming) {
        self.host = host
        self.hooks = hooks
        self.timing = timing
        hooks.observeForeground { [weak self] front in self?.foregroundChanged(front) }
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
        backgroundGrace?.cancel()
        backgroundGrace = nil
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
        letBackgroundGo()
    }

    // MARK: Starting

    private func start() async throws {
        guard let host, let hotspot = hooks.hotspot, let bluetooth = host.bluetoothSession else { throw SoundcoreError.disconnected }
        stage = .opening
        holdBackground()
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
        // A join this device couldn't tell from staying on its own network (`SoundcoreHotspot.canCheckJoin`) isn't
        // tried: the access point is closed while Bluetooth is still here, and the transfer stays on it.
        guard hotspot.canCheckJoin(recorder: accessPoint.host) else {
            try? await bluetooth.closeAccessPoint()
            throw SoundcoreHotspotError.notJoined
        }
        host.accessPointMayBeOpen(accessPoint.ssid)
        let key = bluetooth.handOverKey()
        leftBluetooth = true
        host.leaveBluetoothForWiFi()

        stage = .starting
        try await Task.sleep(for: timing.accessPointStartup)
        try stillStarting()
        guard hooks.isForeground else { throw SoundcoreFastTransferError.background }

        // Said before iOS asks to join a network named "WiFi-1730…", so the question has its context.
        stage = .joining(recorder: host.recorderName)
        joined = accessPoint.ssid
        try await hotspot.join(ssid: accessPoint.ssid, password: accessPoint.password, recorder: accessPoint.host)
        try stillStarting()

        stage = .connecting
        let socket = try await connect(accessPoint, hotspot: hotspot)
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

    /// The recorder's WebSocket, in a few attempts: its network may take a moment to route. Each attempt opens
    /// only while this device is on the recorder's network (`SoundcoreHotspot.isJoined`): once iOS has gone back
    /// to another, the recorder's address could reach a host there, and the socket takes any certificate.
    private func connect(_ accessPoint: SoundcoreAccessPoint, hotspot: any SoundcoreHotspot) async throws -> SoundcoreWebSocket {
        var last: Error = WebSocketError.timedOut
        for attempt in 0..<max(1, timing.webSocketAttempts) {
            if attempt > 0 { try await Task.sleep(for: timing.webSocketRetry) }
            try stillStarting()
            guard await hotspot.isJoined(to: accessPoint.ssid, recorder: accessPoint.host) else { throw SoundcoreHotspotError.notJoined }
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

    // MARK: The foreground

    /// iOS joins a network for an app in front and drops it about 15 seconds after the app leaves. Joining needs
    /// Daybook in front (iOS asks the person there), so leaving before it's on the recorder's network ends Fast
    /// Transfer at once. On it, a moment elsewhere doesn't cost the transfer: it carries on for
    /// `fastTransferBackgroundGrace`, and ends (back to Bluetooth) only if Daybook hasn't come back by then.
    private func foregroundChanged(_ front: Bool) {
        guard isActive, ending == nil else { return }
        backgroundGrace?.cancel()
        backgroundGrace = nil
        guard !front else { return }
        guard isLinked else { return leftForeground() }
        let grace = timing.fastTransferBackgroundGrace
        backgroundGrace = Task { [weak self] in
            guard (try? await Task.sleep(for: grace)) != nil, let self, !self.hooks.isForeground else { return }
            self.leftForeground()
        }
    }

    /// Out of the foreground for good, or out of background time: back to Bluetooth.
    private func leftForeground() {
        guard isActive, ending == nil else { return }
        outcome = .fellBack(Date(), SoundcoreFastTransferError.background.localizedDescription)
        end()
    }

    /// Asks the app for a short while in the background, held until Fast Transfer has ended. If the system
    /// ends that time first, Fast Transfer ends at once.
    private func holdBackground() {
        guard releaseBackground == nil, let hold = hooks.holdInBackground else { return }
        releaseBackground = hold { [weak self] in self?.leftForeground() }
    }

    private func letBackgroundGo() {
        backgroundGrace?.cancel()
        backgroundGrace = nil
        let release = releaseBackground
        releaseBackground = nil
        release?()
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
        letBackgroundGo()
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
