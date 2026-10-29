import AVFoundation
import Foundation

/// Timeouts and delays for the Soundcore connection, in one place. Tests shorten them.
public struct SoundcoreTiming {
    /// A command's reply.
    public var request: Duration = .seconds(10)
    /// No audio for this long ends a transfer.
    public var stall: Duration = .seconds(45)
    /// Quiet time after a stopped or failed transfer, so stray packets can't reach the next one.
    public var settle: Duration = .seconds(1)
    public var scan: Duration = .seconds(15)
    /// Connecting to a recorder chosen in setup.
    public var connect: Duration = .seconds(20)
    /// Connecting to the remembered recorder before falling back to a scan.
    public var reconnect: Duration = .seconds(10)
    /// The recorder confirming Start or Pause.
    public var recordConfirm: Duration = .seconds(10)
    /// Waits between reconnect attempts after an unexpected disconnect.
    public var backoff: [Duration] = [2, 5, 15, 30, 60].map { .seconds($0) }
    /// A connection the person made is let go after this long with nothing happening.
    public var idleRelease: Duration = .seconds(300)
    /// A connection made for automatic import is let go soon after its imports finish.
    public var automaticIdleRelease: Duration = .seconds(30)
    /// After letting the recorder go, automatic import waits this long before reaching for it again,
    /// so the phone app can have it.
    public var automaticCooldown: Duration = .seconds(900)
    /// After letting the recorder go, a recording it was making is shown as "Recording · as of 10:07"
    /// for this long, then as unknown: nobody can see it stop.
    public var lastKnownRecording: Duration = .seconds(1_200)
    /// After the recorder doesn't list its recordings (it didn't answer, or refused), the waits
    /// before each quiet try again while the link stays up.
    public var relist: [Duration] = [15, 60].map { .seconds($0) }
    /// Holding the link for the recorder's button (`SoundcoreConnection.staysConnected`): the wait
    /// before trying again when an attempt failed at once (the recorder isn't known to the system).
    public var holdRetry: Duration = .seconds(30)
    /// After the recorder says it stopped recording, how long live audio still being received may take
    /// to end on its own before what arrived is kept.
    public var liveTail: Duration = .seconds(2)
    /// A recording the recorder started this recently, found as the held link comes back, counts as its
    /// button pressed while the link was away.
    public var buttonCatchUp: Duration = .seconds(60)
    /// Audio Daybook didn't ask for (another app's transfer over a link iOS shares between apps) must
    /// have stopped for this long before Daybook starts a transfer or sends Start or Pause.
    public var otherAppQuiet: Duration = .seconds(3)
    /// Wi‑Fi Fast Transfer (iPhone): recordings at least this long go over Wi‑Fi when the device's
    /// preference is on.
    public var fastTransferMinimum: Duration = .seconds(600)
    /// After the recorder answers `1A 05` and Bluetooth is let go, the time its access point takes to start.
    public var accessPointStartup: Duration = .seconds(10)
    /// Opening the recorder's WebSocket: each attempt's limit, how many, and the wait between them.
    public var webSocketConnect: Duration = .seconds(10)
    public var webSocketAttempts = 3
    public var webSocketRetry: Duration = .seconds(2)
    /// The UDP keep-alive's interval while the WebSocket is open.
    public var keepAlive: Duration = .seconds(2)
    /// After a Wi‑Fi transfer with another recording queued, how long the Wi‑Fi link waits for it.
    public var fastTransferLinger: Duration = .seconds(30)
    /// After Fast Transfer fails (the join declined, the network didn't appear), how long transfers stay
    /// on Bluetooth.
    public var fastTransferPause: Duration = .seconds(1_800)

    public init(request: Duration = .seconds(10), stall: Duration = .seconds(45), settle: Duration = .seconds(1), scan: Duration = .seconds(15), connect: Duration = .seconds(20), reconnect: Duration = .seconds(10), recordConfirm: Duration = .seconds(10), backoff: [Duration] = [2, 5, 15, 30, 60].map { .seconds($0) }, idleRelease: Duration = .seconds(300), automaticIdleRelease: Duration = .seconds(30), automaticCooldown: Duration = .seconds(900), lastKnownRecording: Duration = .seconds(1_200), relist: [Duration] = [15, 60].map { .seconds($0) }) {
        self.request = request
        self.stall = stall
        self.settle = settle
        self.scan = scan
        self.connect = connect
        self.reconnect = reconnect
        self.recordConfirm = recordConfirm
        self.backoff = backoff
        self.idleRelease = idleRelease
        self.automaticIdleRelease = automaticIdleRelease
        self.automaticCooldown = automaticCooldown
        self.lastKnownRecording = lastKnownRecording
        self.relist = relist
    }
}

/// The Soundcore command protocol over any transport: one exchange at a time, each with a timeout,
/// and transfers that are accepted only when every slice arrives in order, decrypts, and decodes.
/// It never sends delete, reset, bind, or firmware commands.
@MainActor
public final class SoundcoreSession {
    public struct Listing: Equatable {
        public var recordings: [SoundcoreRecording]
        public var activeRecordingID: UInt32?
        /// Pages that held recordings not seen on an earlier page, the first always counted (Device Details).
        public var pages = 1
        /// Paging stopped at a page the recorder refused, rather than at one with nothing new.
        /// Whether firmware ends its list that way is unverified, so it's only reported.
        public var endedOnRefusal = false

        public init(recordings: [SoundcoreRecording], activeRecordingID: UInt32? = nil, pages: Int = 1, endedOnRefusal: Bool = false) {
            self.recordings = recordings
            self.activeRecordingID = activeRecordingID
            self.pages = pages
            self.endedOnRefusal = endedOnRefusal
        }
    }

    public struct Download: Equatable {
        public let url: URL
        public let seconds: TimeInterval
        public let bytes: UInt64

        public init(url: URL, seconds: TimeInterval, bytes: UInt64) {
            self.url = url
            self.seconds = seconds
            self.bytes = bytes
        }
    }

    /// Unsolicited updates from the recorder.
    public enum Push: Equatable {
        case battery(recorder: Int?, case: Int?)
        case charging(recorder: Bool, case: Bool)
        case recording(Bool)
    }

    public var onPush: ((Push) -> Void)?
    public private(set) var isClosed = false
    public var keyExchangeComplete: Bool { crypto.isReady }
    public var rejectedFrames: Int { buffer.rejectedFrames }
    public var isTransferring: Bool { transfer != nil }
    /// Audio packets (file heads, slices, ends) that arrived with no transfer of this session's
    /// running: a few stragglers after a stopped transfer, or many when another app on the same
    /// iPhone is transferring over the link iOS shares between apps (Device Details).
    public private(set) var unrequestedAudio = 0
    /// Replies that matched no request waiting here: late ones, or another app's.
    public private(set) var unrequestedReplies = 0
    /// Another app's audio arrived within `SoundcoreTiming.otherAppQuiet`: its transfer is under way.
    public var otherAppIsTransferring: Bool {
        otherAppAudioAt.map { ContinuousClock.now < $0.advanced(by: timing.otherAppQuiet) } ?? false
    }
    /// A transfer or a Start or Pause of this session's is waiting for another app's transfer to finish.
    public private(set) var isWaitingForOtherApp = false
    public var onWaitingForOtherApp: ((Bool) -> Void)?

    private let send: (Data) throws -> Void
    private let timing: SoundcoreTiming
    private var buffer = SoundcorePacketBuffer()
    private var crypto = SoundcoreCrypto()
    /// When another app's audio last arrived.
    private var otherAppAudioAt: ContinuousClock.Instant?
    private var waitingForOtherApp = 0
    /// The recording this session last asked the recorder for, so a late file head of its own isn't
    /// taken for another app's.
    private var lastRequestedID: UInt32?
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var reply: PendingReply?
    private var transfer: Transfer?
    private var quietUntil: ContinuousClock.Instant?

    private struct PendingReply {
        public let token: UUID
        public let matches: (SoundcorePacket) -> Bool
        public let continuation: CheckedContinuation<SoundcorePacket, Error>
        public let timeout: Task<Void, Never>
    }

    private final class Transfer {
        public let token = UUID()
        public let recordingID: UInt32
        public let url: URL
        public let isLive: Bool
        public var decoder: SoundcoreOpusDecoder?
        public var key: SoundcoreFileKey?
        public var expectedBytes: UInt64
        public var receivedBytes: UInt64 = 0
        public var nextSequence: UInt32?
        public var lastSlice: SoundcoreAudioSlice?
        public let progress: (TransferPhase, UInt64) -> Void
        public var continuation: CheckedContinuation<Download, Error>?
        public var outcome: Result<Download, Error>?
        public var stallTimer: Task<Void, Never>?

        public init(recordingID: UInt32, url: URL, isLive: Bool, decoder: SoundcoreOpusDecoder, expectedBytes: UInt64,
             progress: @escaping (TransferPhase, UInt64) -> Void) {
            self.recordingID = recordingID; self.url = url; self.isLive = isLive; self.decoder = decoder
            self.expectedBytes = expectedBytes; self.progress = progress
        }
    }

    /// The link a session runs over. Over Wi‑Fi (Fast Transfer) it only transfers: its file request is
    /// the WebSocket's hex text, its audio key is the one exchanged over Bluetooth, and it never asks the
    /// recorder to stop sending (ending the WebSocket does).
    public enum Medium: Equatable { case bluetooth, wifi }

    public let medium: Medium

    public init(timing: SoundcoreTiming = SoundcoreTiming(), medium: Medium = .bluetooth, crypto: SoundcoreCrypto = SoundcoreCrypto(),
                send: @escaping (Data) throws -> Void) {
        self.timing = timing
        self.medium = medium
        self.crypto = crypto
        self.send = send
    }

    // MARK: Receiving

    /// Feeds bytes from the link. Frames are reassembled; malformed ones are dropped.
    public func receive(_ data: Data) {
        guard !isClosed else { return }
        for packet in buffer.append(data) { handle(packet) }
    }

    private func handle(_ packet: SoundcorePacket) {
        switch (packet.type, packet.command) {
        case (0x01, 0x03):
            let b = [UInt8](packet.payload)
            guard b.count >= 2 else { return }
            onPush?(.battery(recorder: SoundcoreDeviceInfo.battery(b[0]), case: SoundcoreDeviceInfo.battery(b[1])))
        case (0x01, 0x04):
            let b = [UInt8](packet.payload)
            guard b.count >= 2 else { return }
            onPush?(.charging(recorder: b[0] == 1, case: b[1] == 1))
        case (0x1a, 0x07), (0x1b, 0x07):
            if let transfer, transfer.key == nil, Self.head(packet, names: transfer.recordingID) { receiveFileKey(packet) } else { unrequested(packet) }
        case (0x1a, 0x08), (0x1a, 0x12), (0x1b, 0x08), (0x1b, 0x12):
            if transfer?.key != nil { receiveAudio(packet) } else { unrequested(packet) }
        case (0x1a, 0x0a), (0x1b, 0x0a):
            if transfer?.key != nil { receiveEnd() } else { unrequested(packet) }
        default:
            if let reply, reply.matches(packet) {
                self.reply = nil
                reply.timeout.cancel()
                reply.continuation.resume(returning: packet)
            } else if packet.type == 0x18, packet.command == 0x82, let status = packet.payload.first, status <= 2 {
                // Pressing the recorder's own button reports the new state.
                onPush?(.recording(status == 1))
            } else {
                unrequestedReplies += 1
                // Another app exchanged audio keys with the recorder, which keeps one session key: this
                // session's is stale, and its next transfer exchanges keys again.
                if packet.type == 0x2e, packet.command == 0x01, packet.succeeded { crypto.reset() }
            }
        }
    }

    /// A file head for `id`, or the recorder refusing the request (which names nothing).
    private static func head(_ packet: SoundcorePacket, names id: UInt32) -> Bool {
        let b = [UInt8](packet.payload)
        guard packet.succeeded, b.count >= 4 else { return true }
        return (try? b.le32(at: 0)) == id
    }

    /// Audio that isn't for a transfer of this session's: a straggler of one it just stopped, or another
    /// app's transfer over the link iOS shares between apps (Device Details counts both). Another app's
    /// audio ends this session's transfer, if one is waiting for its head, without a word to the recorder,
    /// so the other app's transfer carries on; Daybook's own waits until it has finished.
    private func unrequested(_ packet: SoundcorePacket) {
        unrequestedAudio += 1
        let isHead = packet.command == 0x07
        let names = isHead ? (try? [UInt8](packet.payload).le32(at: 0)) : nil
        if transfer == nil, let quietUntil, ContinuousClock.now < quietUntil, !isHead || names == lastRequestedID { return }
        otherAppAudioAt = .now
        guard let transfer, transfer.outcome == nil else { return }
        if transfer.isLive, transfer.receivedBytes > 0 { completeLive(transfer) } else { finish(transfer, .failure(SoundcoreError.yielded)) }
        quietUntil = nil
    }

    // MARK: Commands

    public func readStatus() async throws -> SoundcoreDeviceInfo {
        try await exclusive {
            let packet = try await request(0x01, 0x01) { $0.type == 0x01 && $0.command == 0x01 }
            guard packet.succeeded else { throw SoundcoreError.rejected }
            return try SoundcoreDeviceInfo.parse(packet.payload)
        }
    }

    /// Every page of the recording list. Firmware without the 12-byte layout gets the 8-byte one.
    public func listRecordings() async throws -> Listing {
        try await exclusive { try await listLocked() }
    }

    /// Asks the recorder to start (true) or pause (false). Returns the state its reply reports, if any.
    /// It waits while another app is transferring.
    public func setRecording(_ on: Bool) async throws -> Bool? {
        try await exclusiveWhenQuiet {
            let packet = try await request(0x18, 0x82, Data([on ? 1 : 2])) { $0.type == 0x18 && $0.command == 0x82 }
            if let status = packet.payload.first, status <= 2 { return status == 1 }
            guard packet.succeeded else { throw SoundcoreError.rejected }
            return nil
        }
    }

    /// Moves one recording to `url` as a 16 kHz WAV. Throws on any gap, mismatch, or decode error,
    /// after removing the partial file. Cancelling stops the transfer on the recorder too. It starts once
    /// no other app is transferring, and throws `yielded` when another app starts a transfer before this
    /// one's audio arrives.
    public func download(_ recording: SoundcoreRecording, to url: URL,
                  progress: @escaping (TransferPhase, UInt64) -> Void) async throws -> Download {
        try await exclusiveWhenQuiet {
            try await transferLocked(recordingID: recording.id, expectedBytes: UInt64(recording.size), live: false,
                                     url: url, onPCM: nil, progress: progress)
        }
    }

    /// Receives the recording in progress until `stopListening()`, saving it to the URL `destination`
    /// returns for its ID. Audio is decoded as it arrives and passed to `onPCM`. It starts once no other
    /// app is transferring.
    public func listen(destination: (UInt32) -> URL, onPCM: @escaping (AVAudioPCMBuffer) -> Void,
                progress: @escaping (TransferPhase, UInt64) -> Void) async throws -> (recordingID: UInt32, download: Download) {
        guard medium == .bluetooth else { throw SoundcoreError.unsupported }
        return try await exclusiveWhenQuiet {
            let listing = try await firstPageLocked()
            guard let active = listing.activeRecordingID else { throw SoundcoreError.liveFileUnavailable }
            let result = try await transferLocked(recordingID: active, expectedBytes: 0, live: true, url: destination(active),
                                                  onPCM: onPCM, progress: progress)
            return (active, result)
        }
    }

    // MARK: Wi‑Fi Fast Transfer (docs/direct-soundcore.md)

    /// Asks the recorder to open its access point with these credentials (`1A 05`), after the audio key
    /// exchange its Wi‑Fi transfers reuse, and returns where its WebSocket listens. Waits while another
    /// app is transferring.
    public func openAccessPoint(ssid: String, password: String) async throws -> SoundcoreAccessPoint {
        guard medium == .bluetooth else { throw SoundcoreError.unsupported }
        let payload = try SoundcoreWiFi.accessPointRequest(ssid: ssid, password: password)
        return try await exclusiveWhenQuiet {
            try await ensureKey()
            let packet = try await request(0x1a, 0x05, payload) { $0.type == 0x1a && $0.command == 0x05 }
            guard packet.succeeded else { throw SoundcoreError.rejected }
            let endpoint = try SoundcoreWiFi.endpoint(from: packet)
            return SoundcoreAccessPoint(ssid: ssid, password: password, host: endpoint.host, port: endpoint.port)
        }
    }

    /// Asks the recorder to close its access point (`1A 02`). What it answers, if anything, is
    /// unverified, so a reply that doesn't come isn't an error.
    public func closeAccessPoint() async throws {
        guard medium == .bluetooth else { throw SoundcoreError.unsupported }
        try await exclusive {
            do { _ = try await request(0x1a, 0x02) { $0.type == 0x1a && $0.command == 0x02 } } catch SoundcoreError.timedOut {}
        }
    }

    /// The audio key exchanged on this link, for a session over the recorder's Wi‑Fi; this one gets a
    /// fresh one (and exchanges again if it transfers).
    public func handOverKey() -> SoundcoreCrypto {
        let key = crypto
        crypto = SoundcoreCrypto()
        return key
    }

    /// Ends Listen Live, keeping what arrived. The recorder keeps recording.
    public func stopListening() {
        guard let transfer, transfer.isLive else { return }
        stopTransport()
        completeLive(transfer)
    }

    /// The link went away: everything waiting fails, and a live capture keeps what arrived.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let reply {
            self.reply = nil
            reply.timeout.cancel()
            reply.continuation.resume(throwing: SoundcoreError.disconnected)
        }
        if let transfer {
            if transfer.isLive && transfer.receivedBytes > 0 { completeLive(transfer) }
            else { finish(transfer, .failure(SoundcoreError.disconnected)) }
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.continuation.resume(throwing: SoundcoreError.disconnected) }
        crypto.reset()
        buffer.reset()
    }

    // MARK: Exclusive use

    /// One exchange or transfer at a time: the recorder answers commands in order.
    private func exclusive<T>(_ operation: () async throws -> T) async throws -> T {
        if isClosed { throw SoundcoreError.disconnected }
        try Task.checkCancellation()
        if busy {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id, continuation))
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        } else { busy = true }
        defer { handOff() }
        if isClosed { throw SoundcoreError.disconnected }
        try Task.checkCancellation()
        return try await operation()
    }

    private func handOff() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }

    /// `exclusive`, once no other app's audio has arrived for `SoundcoreTiming.otherAppQuiet`: a transfer
    /// or a Start or Pause sent over another app's transfer would cut it off. Listing and status don't
    /// wait, and don't hold up meanwhile.
    private func exclusiveWhenQuiet<T>(_ operation: () async throws -> T) async throws -> T {
        var waiting = false
        defer { if waiting { waitedForOtherApp() } }
        while true {
            if otherAppIsTransferring {
                if !waiting { waiting = true; waitForOtherApp() }
                try await quietSpell()
                continue
            }
            let result: T? = try await exclusive { () async throws -> T? in
                guard !otherAppIsTransferring else { return nil }
                if waiting { waiting = false; waitedForOtherApp() }
                return try await operation()
            }
            if let result { return result }
        }
    }

    /// Sleeps until another app's audio has been quiet for `otherAppQuiet`, a little at a time so a
    /// link that goes away ends the wait.
    private func quietSpell() async throws {
        while let since = otherAppAudioAt, ContinuousClock.now < since.advanced(by: timing.otherAppQuiet) {
            if isClosed { throw SoundcoreError.disconnected }
            try await Task.sleep(until: min(since.advanced(by: timing.otherAppQuiet), .now.advanced(by: .milliseconds(200))), clock: .continuous)
        }
        if isClosed { throw SoundcoreError.disconnected }
    }

    private func waitForOtherApp() {
        waitingForOtherApp += 1
        guard waitingForOtherApp == 1 else { return }
        isWaitingForOtherApp = true
        onWaitingForOtherApp?(true)
    }

    private func waitedForOtherApp() {
        waitingForOtherApp = max(0, waitingForOtherApp - 1)
        guard waitingForOtherApp == 0, isWaitingForOtherApp else { return }
        isWaitingForOtherApp = false
        onWaitingForOtherApp?(false)
    }

    private func request(_ type: UInt8, _ command: UInt8, _ payload: Data = Data(), timeout: Duration? = nil,
                         matching: @escaping (SoundcorePacket) -> Bool) async throws -> SoundcorePacket {
        try Task.checkCancellation()
        let token = UUID()
        let wait = timeout ?? timing.request
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SoundcorePacket, Error>) in
                do { try send(SoundcorePacket.command(type: type, id: command, payload: payload)) } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.failReply(token, SoundcoreError.timedOut)
                }
                reply = PendingReply(token: token, matches: matching, continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.failReply(token, CancellationError()) }
        }
    }

    private func failReply(_ token: UUID, _ error: Error) {
        guard let reply, reply.token == token else { return }
        self.reply = nil
        reply.timeout.cancel()
        reply.continuation.resume(throwing: error)
    }

    private static func isListing(_ packet: SoundcorePacket) -> Bool {
        (packet.type == 0x1a || packet.type == 0x1b) && packet.command == 0x0e
    }

    private static func page(_ number: UInt16) -> Data { Data([UInt8(number & 255), UInt8(number >> 8)]) }

    private var listingType: UInt8 = 0x1b

    private func firstPageLocked() async throws -> Listing {
        var first = try await request(listingType, 0x0e, Self.page(0), matching: Self.isListing)
        if !first.succeeded, listingType == 0x1b {
            first = try await request(0x1a, 0x0e, Self.page(0), matching: Self.isListing)
            // Firmware without the 12-byte layout. A recorder refusing both (busy) says nothing
            // about which it has, so the next listing asks for the 12-byte one again.
            if first.succeeded { listingType = 0x1a }
        }
        guard first.succeeded else { throw SoundcoreError.rejected }
        let page = try SoundcoreRecording.page(first)
        return Listing(recordings: page.recordings, activeRecordingID: page.active)
    }

    private func listLocked() async throws -> Listing {
        var listing = try await firstPageLocked()
        var seen = Set<UInt32>()
        listing.recordings = listing.recordings.filter { seen.insert($0.id).inserted }
        var fresh = listing.recordings
        var number: UInt16 = 0
        while !fresh.isEmpty, number < 100 {
            number += 1
            let packet = try await request(listingType, 0x0e, Self.page(number), matching: Self.isListing)
            guard packet.succeeded else { listing.endedOnRefusal = true; break }
            fresh = try SoundcoreRecording.page(packet).recordings.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty { listing.pages += 1 }
            listing.recordings += fresh
        }
        return listing
    }

    private func ensureKey() async throws {
        guard !crypto.isReady else { return }
        let packet = try await request(0x2e, 0x01, crypto.publicKey) { $0.type == 0x2e && $0.command == 0x01 }
        guard packet.succeeded else { throw SoundcoreError.rejected }
        try crypto.completeHandshake(packet.payload)
    }

    // MARK: Transfers

    private func transferLocked(recordingID: UInt32, expectedBytes: UInt64, live: Bool, url: URL,
                                onPCM: ((AVAudioPCMBuffer) -> Void)?,
                                progress: @escaping (TransferPhase, UInt64) -> Void) async throws -> Download {
        if let quietUntil, ContinuousClock.now < quietUntil { try await Task.sleep(until: quietUntil, clock: .continuous) }
        quietUntil = nil
        progress(.preparing, 0)
        if medium == .wifi {
            // Over Wi‑Fi the key is the one exchanged over Bluetooth; nothing else could be sent here.
            guard crypto.isReady else { throw SoundcoreError.invalidEncryption }
        } else {
            try await ensureKey()
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let decoder = try SoundcoreOpusDecoder(outputURL: url)
        decoder.onPCM = onPCM
        let transfer = Transfer(recordingID: recordingID, url: url, isLive: live, decoder: decoder,
                                expectedBytes: expectedBytes, progress: progress)
        self.transfer = transfer
        lastRequestedID = recordingID
        var payload = littleEndian32(0)
        payload.append(littleEndian32(recordingID))
        payload.append(live ? 1 : 0)
        do {
            if medium == .wifi { try send(Data(SoundcoreWiFi.fileRequest(recordingID: recordingID).utf8)) }
            else { try send(SoundcorePacket.command(type: 0x1a, id: 0x07, payload: payload)) }
        } catch {
            finish(transfer, .failure(error))
        }
        armStall(transfer)
        let token = transfer.token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Download, Error>) in
                if let outcome = transfer.outcome { continuation.resume(with: outcome) } else { transfer.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abort(token, CancellationError()) }
        }
    }

    private func receiveFileKey(_ packet: SoundcorePacket) {
        guard let transfer, transfer.key == nil, transfer.outcome == nil else { return }
        guard packet.succeeded else { abort(transfer, SoundcoreError.rejected); return }
        do {
            let key = try crypto.fileKey(from: packet.payload, expectedID: transfer.recordingID)
            transfer.key = key
            if key.expectedBytes > 0 { transfer.expectedBytes = UInt64(key.expectedBytes) }
            armStall(transfer)
            transfer.progress(.receiving(fraction: transfer.isLive || transfer.expectedBytes == 0 ? nil : 0), 0)
        } catch { abort(transfer, error) }
    }

    private func receiveAudio(_ packet: SoundcorePacket) {
        // Audio with no transfer waiting for it is a stray from one that was stopped.
        guard let transfer, transfer.outcome == nil, let key = transfer.key, let decoder = transfer.decoder else { return }
        do {
            for slice in try SoundcoreAudioSlice.parse(packet.payload) {
                if slice == transfer.lastSlice { continue }
                if let expected = transfer.nextSequence {
                    guard slice.sequence == expected else { throw SoundcoreError.incompleteTransfer }
                } else {
                    guard slice.sequence <= 1 else { throw SoundcoreError.incompleteTransfer }
                }
                guard slice.sequence < UInt32.max else { throw SoundcoreError.incompleteTransfer }
                try decoder.append(key.decrypt(slice))
                transfer.receivedBytes += 160
                transfer.nextSequence = slice.sequence + 1
                transfer.lastSlice = slice
                guard transfer.isLive || transfer.expectedBytes == 0 || transfer.receivedBytes <= transfer.expectedBytes else {
                    throw SoundcoreError.incompleteTransfer
                }
            }
            armStall(transfer)
            let fraction = transfer.isLive || transfer.expectedBytes == 0 ? nil
                : Double(transfer.receivedBytes) / Double(transfer.expectedBytes)
            transfer.progress(.receiving(fraction: fraction), transfer.receivedBytes)
        } catch { abort(transfer, error) }
    }

    private func receiveEnd() {
        guard let transfer, transfer.outcome == nil else { return }
        if transfer.isLive { completeLive(transfer); return }
        transfer.progress(.finishing, transfer.receivedBytes)
        do {
            guard transfer.key != nil, transfer.receivedBytes > 0, transfer.expectedBytes > 0,
                  transfer.receivedBytes == transfer.expectedBytes, let decoder = transfer.decoder else {
                throw SoundcoreError.incompleteTransfer
            }
            try decoder.finish()
            guard decoder.sampleCount > 0 else { throw SoundcoreError.corruptAudio }
            transfer.decoder = nil
            finish(transfer, .success(Download(url: transfer.url, seconds: Double(decoder.sampleCount) / 16_000,
                                               bytes: transfer.receivedBytes)))
        } catch { abort(transfer, error) }
    }

    private func completeLive(_ transfer: Transfer) {
        do {
            guard transfer.receivedBytes > 0, let decoder = transfer.decoder else { throw SoundcoreError.liveFileUnavailable }
            try decoder.finish()
            guard decoder.sampleCount > 0 else { throw SoundcoreError.corruptAudio }
            transfer.decoder = nil
            quietUntil = ContinuousClock.now.advanced(by: timing.settle)
            finish(transfer, .success(Download(url: transfer.url, seconds: Double(decoder.sampleCount) / 16_000,
                                               bytes: transfer.receivedBytes)))
        } catch { abort(transfer, error) }
    }

    private func armStall(_ transfer: Transfer) {
        transfer.stallTimer?.cancel()
        let token = transfer.token
        let wait = timing.stall
        transfer.stallTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.stalled(token)
        }
    }

    /// No audio for the stall timeout. A transfer fails; live audio keeps what arrived (the recording
    /// it follows ended, or the stream went quiet), as a disconnect does.
    private func stalled(_ token: UUID) {
        guard let transfer, transfer.token == token, transfer.outcome == nil else { return }
        if transfer.isLive, transfer.receivedBytes > 0 {
            stopTransport()
            completeLive(transfer)
        } else {
            abort(transfer, SoundcoreError.stalled)
        }
    }

    private func abort(_ token: UUID, _ error: Error) {
        guard let transfer, transfer.token == token else { return }
        abort(transfer, error)
    }

    /// Ends a transfer that failed or was stopped: the recorder stops sending, the partial file is
    /// removed, and the next transfer waits a moment for stray packets to pass.
    private func abort(_ transfer: Transfer, _ error: Error) {
        guard transfer.outcome == nil else { return }
        if !isClosed { stopTransport() }
        quietUntil = ContinuousClock.now.advanced(by: timing.settle)
        finish(transfer, .failure(error))
    }

    private func finish(_ transfer: Transfer, _ result: Result<Download, Error>) {
        guard transfer.outcome == nil else { return }
        transfer.stallTimer?.cancel()
        if self.transfer === transfer { self.transfer = nil }
        if case .failure = result {
            transfer.decoder = nil
            try? FileManager.default.removeItem(at: transfer.url)
        }
        transfer.outcome = result
        transfer.continuation?.resume(with: result)
        transfer.continuation = nil
    }

    /// Asks the recorder to stop sending. It stops transport only; it doesn't stop or delete a recording.
    /// Never while another app's transfer is arriving: the recorder would stop that one.
    private func stopTransport() {
        guard medium == .bluetooth, !otherAppIsTransferring else { return }
        try? send(SoundcorePacket.command(type: 0x1a, id: 0x11, payload: Data([1])))
    }
}
