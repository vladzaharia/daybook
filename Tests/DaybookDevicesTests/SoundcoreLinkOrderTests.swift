import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookDevices

/// Who gets the link next (`SoundcoreSession.exclusiveWhenQuiet`), without a recorder: sessions over a link that only
/// records what is sent, and the audio another app's transfer would send injected by hand.
@MainActor
final class SoundcoreLinkOrderTests: XCTestCase {
    /// One session, and the requests it sent (the type and command of each).
    @MainActor private final class Link {
        var sent: [UInt16] = []
        var session: SoundcoreSession!

        init(quiet: Duration) {
            var timing = SoundcoreTiming()
            timing.request = .seconds(60)
            timing.stall = .seconds(60)
            timing.otherAppQuiet = quiet
            timing.otherAppYields = 3
            session = SoundcoreSession(timing: timing) { [unowned self] data in
                let bytes = [UInt8](data)
                if bytes.count > 6 { self.sent.append(UInt16(bytes[5]) << 8 | UInt16(bytes[6])) }
            }
        }
    }

    private static let status: UInt16 = 0x0101
    /// A transfer's first request: the key exchange (Listen Live's is the recorder's list).
    private static let keyExchange: UInt16 = 0x2e01

    /// A transfer waiting for the link is handed it just as another app's audio arrives, and gives it back until the
    /// other app has been quiet. A request made meanwhile (Listen Live, as a shared recording's capture) mustn't go
    /// first when both wake: the transfer was asked for earlier, and it starts again right after the command that
    /// stopped it, ahead of anything asked for since (docs/devices.md, "Record commands come first"). Listen Live holds
    /// the link until its recording ends, so a transfer behind it waits for the whole shared recording.
    ///
    /// Which of two that wake at the same instant runs first isn't the code's to say, so sixteen links go through it at
    /// once: without the order kept, all sixteen going the right way is a matter of chance.
    func testATransferThatGaveTheLinkBackForAnotherAppKeepsItsPlaceAheadOfLaterRequests() async throws {
        let quiet = Duration.seconds(0.6 * TestTiming.scale)
        let links = (0..<16).map { _ in Link(quiet: quiet) }
        let folder = FileManager.default.temporaryDirectory

        // The link is held; a transfer waits for it.
        let holders = links.map { link in Task { try await link.session.readStatus() } }
        for link in links { try await waitUntil("the link held") { link.sent.contains(Self.status) } }
        let transfers = links.map { link in
            Task {
                try await link.session.download(SoundcoreRecording(id: 7, size: 1_600),
                                                to: folder.appendingPathComponent("link-order-\(UUID().uuidString).wav")) { _, _ in }
            }
        }
        for link in links { try await waitUntil("the transfer to wait for the link") { link.session.linkWaiters == 1 } }

        // Another app's audio arrives, and the link is let go: the transfer is handed it, finds the other app
        // transferring, and gives it back to wait.
        for link in links { link.session.receive(SoundcorePacket.frame(type: 0x1a, command: 0x08, payload: Data(count: 8))) }
        holders.forEach { $0.cancel() }
        for link in links {
            try await waitUntil("the transfer to wait for the other app") { link.session.isWaitingForOtherApp && link.session.linkWaiters == 0 }
        }

        // Listen Live is asked for now, with the link free, and waits for the other app to be quiet too.
        let lives = links.map { link in
            Task {
                try await link.session.listen(destination: { _ in folder.appendingPathComponent("link-order-live.wav") },
                                              onPCM: { _ in }, progress: { _, _ in })
            }
        }
        let before = links.map(\.sent.count)
        for (index, link) in links.enumerated() {
            try await waitUntil("a request to go out", timeout: 10) { link.sent.count > before[index] }
        }

        for (index, link) in links.enumerated() {
            let first = link.sent[before[index]]
            XCTAssertEqual(first, Self.keyExchange, "link \(index): the transfer's request first, not Listen Live's (\(String(first, radix: 16)))")
        }

        links.forEach { $0.session.close() }
        transfers.forEach { $0.cancel() }
        lives.forEach { $0.cancel() }
        for task in transfers { _ = await task.result }
        for task in lives { _ = await task.result }
        for task in holders { _ = await task.result }
    }
}
