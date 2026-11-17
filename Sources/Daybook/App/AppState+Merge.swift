import DaybookCore
import DaybookKit
import Foundation

/// Merge… on the Mac (docs/architecture.md, "Merging conversations"): the library merges, with this Mac's files, its
/// knowledge of when a recording started (`trackStart`), and what it's recording and processing, and the merged
/// conversation is transcribed again in full here, through the queue.
extension AppState {
    /// Merges the conversations `ids`, once the person confirmed. The merged one is selected; the others leave the queue
    /// as they go to the Trash. Something that stops it is said in the window's alert.
    func mergeConversations(_ ids: [UUID]) {
        // One merge of a conversation at a time: asked again while it runs, nothing more happens.
        guard library.mergingIDs.isDisjoint(with: ids) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let survivor = try await library.mergeConversations(
                    ids,
                    audio: { [library] track, id in try await library.audioURL(for: track, in: id) },
                    photo: { [library] photo, id in try await library.photoURL(for: photo, in: id) },
                    context: { MeetingInspector.context(self, $0) }, policy: sources.policy, startOf: { self.trackStart($0) },
                    process: { id, mode in
                        // Asked for by the person: one they paused before is transcribed again too.
                        self.processor.queue.paused.remove(id)
                        self.processor.enqueue(id, mode: mode)
                    })
                for id in ids where id != survivor {
                    processor.queue.removeJobs(for: id)
                    processor.queue.paused.remove(id)
                    processor.queue.settle(id)
                }
                window.selection = []
                selectQuietly(survivor)
            } catch {
                report("Couldn’t Merge", "Try again.", error)
            }
        }
    }
}
