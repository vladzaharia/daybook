import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The library's saves, written in the background and coalesced: each conversation (and the
/// library's settings and vocabulary) has at most one save waiting, and the latest snapshot is the
/// one written. A save starts after a short pause (`delay`), so a burst of edits (typing notes)
/// writes once, and saves run one at a time, in the order things first changed.
///
/// A failed save is remembered under its key until a later save of the same thing succeeds or it
/// becomes moot (`forget`: the conversation went to the Trash).
@MainActor
final class LibrarySaveQueue {
    typealias Write = @MainActor () async throws -> Void

    /// What failed, by key: a conversation's UUID string, "library-settings", or "glossary".
    private(set) var failures: [String: String] = [:]
    var delay: Duration = .milliseconds(500)
    /// After each failed save, with its key.
    var onFailure: (String, Error) -> Void = { _, _ in }
    /// Each time the queue runs empty.
    var onIdle: () -> Void = {}
    /// Saves carried out, for tests.
    private(set) var completed = 0

    private var pending: [String: Write] = [:]
    private var order: [String] = []
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Queues `write` under `key`, replacing a save of the same thing that hasn't started.
    func enqueue(_ key: String, write: @escaping Write) {
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
    func forget(_ key: String) {
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

#if canImport(UIKit)
extension LibraryController {
    /// On iPhone, leaving the foreground writes waiting saves at once, in the time iOS grants for it.
    func flushWhenBackgrounded() -> AnyCancellable {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification))
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let assertion = UIApplication.shared.beginBackgroundTask(withName: "Saving the library")
                    Task {
                        await self.flush()
                        UIApplication.shared.endBackgroundTask(assertion)
                    }
                }
            }
    }
}
#endif
