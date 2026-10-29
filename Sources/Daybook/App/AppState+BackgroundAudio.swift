import DaybookCore
import DaybookKit
import Foundation

/// Background audio (a TV, radio, music) is left out of a conversation's transcript and summary
/// (`BackgroundAudio`); the person can keep it in. The transcript runs always hold every word, so
/// either way is only a new fusion.
extension AppState {
    /// Keeps the conversation's background audio in its transcript, or leaves it out again.
    func includeBackgroundAudio(_ include: Bool, in id: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == id }), (meeting.includesBackgroundAudio == true) != include else { return }
        update(id) { $0.includesBackgroundAudio = include ? true : nil }
        await realign(id)
    }
}
