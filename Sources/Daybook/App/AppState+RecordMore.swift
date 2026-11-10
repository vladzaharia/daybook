import DaybookUI
import Foundation
import Observation

// Where a recording lands, and recording more once it has ended (docs/interface.md, "After Stop" and "Behaviour worth
// knowing"). Only the library window's own Record files a new conversation into the place it shows and selects it;
// a recording that starts anywhere else lands in All Conversations and leaves the window as it was. After a Stop,
// Keep Recording records into the same conversation for two minutes, unless the call's meeting ends, the next meeting
// starts, or another recording starts first (`RecordMore`, the iPhone's rule too).

/// Where a recording was started.
enum RecordingOrigin: Equatable, Sendable {
    /// The library window's own Record: a new conversation goes into the place the window shows, and is selected.
    case window
    /// Anywhere else (a call, the call prompt, the menu bar, the Dock, Floating Notes, a notification, a recorder or an
    /// iPhone, Shortcuts): a new conversation is unfiled, in All Conversations, and the selection stays where it was.
    case elsewhere
}

/// After a Stop on this Mac: the conversation Keep Recording records into, and when it stopped. It ends on its own
/// once `RecordMore.window` has passed, so what reads it redraws then.
@MainActor
@Observable
final class AfterStopMoment {
    private(set) var conversationID: UUID?
    private(set) var stoppedAt: Date?
    @ObservationIgnored private var ending: Task<Void, Never>?

    /// A Stop: Keep Recording records into `id` until the window passes or something ends it sooner.
    func began(_ id: UUID, at date: Date = Date()) {
        conversationID = id
        stoppedAt = date
        ending?.cancel()
        let left = max(0, RecordMore.windowEnds(after: date).timeIntervalSinceNow)
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    /// Something ended the moment: another recording started, the call's meeting ended, the next meeting started.
    func end() {
        ending?.cancel()
        ending = nil
        conversationID = nil
        stoppedAt = nil
    }

    /// When `id` was stopped, while Keep Recording still records into it.
    func stoppedAt(_ id: UUID) -> Date? { conversationID == id ? stoppedAt : nil }
}

extension AppState {
    /// What the control after Stop does for `id` now: Keep Recording, Record Again, or Record (`RecordMore`).
    func recordMore(after id: UUID, now: Date = Date()) -> RecordMore {
        let stoppedShort = meetings.first { $0.id == id }.map { FloatingStatusInputs.stoppedShort($0, state: self) } ?? false
        return RecordMore(stoppedShort: stoppedShort, stoppedAt: afterStop.stoppedAt(id), now: now)
    }

    /// The control after Stop, pressed as it read: into the same conversation (`recordAgain(into:)`), or a new one.
    func record(_ more: RecordMore, after id: UUID) async {
        if more.recordsIntoSameConversation {
            await recordAgain(into: id)
        } else {
            await startRecording(from: .elsewhere)
        }
    }

    /// Keep Recording or Record Again, from the panel or a notification: into the same conversation, after what was
    /// saved. The processing its first part queued waits for the whole.
    func recordAgain(into id: UUID) async {
        if processor.queue.runningID == id { pauseProcessing(id) } else if processor.queue.queuedIDs.contains(id) { cancelQueued(id) }
        // A job that was running lets go of the conversation once its work notices.
        for _ in 0..<40 where processor.queue.runningID == id { try? await Task.sleep(for: .milliseconds(50)) }
        // The first part is still being added: its capture holds the conversation's folder until it's in the library.
        let session = storageURL.appendingPathComponent("Staging").appendingPathComponent(id.uuidString)
            .appendingPathComponent("capture-session.json").path
        for _ in 0..<60 where FileManager.default.fileExists(atPath: session) { try? await Task.sleep(for: .milliseconds(50)) }
        // One that couldn't be added is kept there for recovery: record anew rather than fail.
        let held = FileManager.default.fileExists(atPath: session)
        dismissUnexpectedStop(id)
        await startRecording(into: held ? nil : id, from: .elsewhere)
    }
}
