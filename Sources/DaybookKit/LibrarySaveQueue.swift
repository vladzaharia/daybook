import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What one save writes. The queue keeps at most one save of each waiting.
enum SaveKey: Hashable, Sendable {
    /// A conversation (`meeting.json`).
    case meeting(UUID)
    /// The library's settings (`library.json`).
    case settings
    /// The vocabulary's own file.
    case glossary
    /// This device's record of the work it's doing (`local-work.json`, never synced).
    case localWork
}

/// The library's saves, written in the background and coalesced: each conversation (and the
/// library's settings, vocabulary, and record of this device's work) has at most one save waiting,
/// and the latest snapshot is the one written. A save starts after a short pause (`delay`), so a
/// burst of edits (typing notes) writes once, and saves run one at a time, in the order things
/// first changed.
///
/// A failed save is remembered under its key until a later save of the same thing succeeds or it
/// becomes moot (`forget`: the conversation went to the Trash).
@MainActor
final class LibrarySaveQueue {
    typealias Write = @MainActor () async throws -> Void

    /// What failed, by key, in the system's words.
    private(set) var failures: [SaveKey: String] = [:]
    var delay: Duration = .milliseconds(500)
    /// After each failed save, with its key.
    var onFailure: (SaveKey, Error) -> Void = { _, _ in }
    /// Each time the queue runs empty.
    var onIdle: () -> Void = {}
    /// Saves carried out, for tests.
    private(set) var completed = 0

    private var pending: [SaveKey: Write] = [:]
    private var order: [SaveKey] = []
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Queues `write` under `key`, replacing a save of the same thing that hasn't started.
    func enqueue(_ key: SaveKey, write: @escaping Write) {
        if pending.updateValue(write, forKey: key) == nil { order.append(key) }
        guard worker == nil, timer == nil else { return }
        timer = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.timer = nil
            self?.start()
        }
    }

    /// Writes everything waiting now, and returns once nothing is waiting or being written,
    /// including saves queued while it waited.
    func drain() async {
        while true {
            timer?.cancel(); timer = nil
            if worker == nil { start() }
            guard let worker else { return }
            await worker.value
        }
    }

    /// Drops a waiting save and a remembered failure: there's nothing left to save.
    func forget(_ key: SaveKey) {
        pending[key] = nil
        order.removeAll { $0 == key }
        failures[key] = nil
    }

    private func start() {
        guard worker == nil, !order.isEmpty else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !order.isEmpty {
            let key = order.removeFirst()
            guard let write = pending.removeValue(forKey: key) else { continue }
            do {
                try await write()
                failures[key] = nil
            } catch {
                failures[key] = error.localizedDescription
                onFailure(key, error)
            }
            completed += 1
        }
        worker = nil
        onIdle()
    }
}

/// Time the system grants to finish work once the app leaves the foreground: UIKit's background tasks on iPhone, a
/// fake in tests.
@MainActor
protocol BackgroundTime {
    /// Starts an assertion, or nil when there's no time to grant. `expired` runs when the time is up; an assertion
    /// still held then gets the app ended instead of suspended.
    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int?
    func end(_ assertion: Int)
}

extension LibraryController {
    /// Leaving the foreground: writes waiting saves now, inside the time the system grants. The assertion ends once
    /// they're written or, when the time runs out first, right then, and never twice; what's left is written when
    /// the app comes back. Returns the flush, for tests.
    @discardableResult
    func flushInBackground(_ time: any BackgroundTime) -> Task<Void, Never> {
        let assertion = BackgroundAssertion(time)
        assertion.begin("Saving the library")
        return Task {
            await self.flush()
            assertion.end()
        }
    }
}

/// One background-time assertion, ended once: by whichever of the work and the time finishes first.
@MainActor
private final class BackgroundAssertion {
    private let time: any BackgroundTime
    private var id: Int?

    init(_ time: any BackgroundTime) { self.time = time }

    func begin(_ name: String) { id = time.begin(name) { [weak self] in self?.end() } }

    func end() {
        guard let id else { return }
        self.id = nil
        time.end(id)
    }
}

#if canImport(UIKit)
/// UIKit's background tasks.
struct SystemBackgroundTime: BackgroundTime {
    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expired)
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ assertion: Int) { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: assertion)) }
}

extension LibraryController {
    /// On iPhone, leaving the foreground writes waiting saves at once (`flushInBackground`). Termination isn't
    /// watched: the app always leaves the foreground first, and work started as it ends never runs.
    func flushWhenBackgrounded() -> AnyCancellable {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.flushInBackground(SystemBackgroundTime()) }
            }
    }
}
#endif
