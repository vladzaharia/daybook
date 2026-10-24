import DaybookCore
import SwiftUI

/// Unstyled hooks for several recordings of one conversation, shown in the inspector's Audio
/// section: a recorder recording alongside this Mac, and a recording that may belong with another
/// conversation, to confirm or dismiss. The state and actions live in `AppState+Sources`; the
/// interface is to be designed.
struct SourceHooks: View {
    @ObservedObject var state: AppState
    let meeting: Meeting

    var body: some View {
        ForEach(meeting.companions ?? []) { link in
            if let line = Self.companionLine(link) { Text(line).font(.caption).foregroundStyle(.secondary) }
        }
        ForEach(meeting.sourceSuggestions ?? []) { suggestion in
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.suggestionLine(suggestion, titles: titles(suggestion))).font(.caption)
                HStack {
                    ForEach(suggestion.candidateMeetingIDs.filter { id in state.meetings.contains { $0.id == id } }, id: \.self) { target in
                        Button("Add to “\(title(target))”") {
                            Task { await state.confirmSourceSuggestion(suggestion.id, in: meeting.id, into: target) }
                        }
                        .disabled(state.processingID == meeting.id || state.processingID == target || state.recordingID == meeting.id)
                    }
                    Button("Keep Separate") { state.dismissSourceSuggestion(suggestion.id, in: meeting.id) }
                }
            }
        }
    }

    private func title(_ id: UUID) -> String { state.meetings.first { $0.id == id }?.title ?? "Conversation" }
    private func titles(_ suggestion: SourceSuggestion) -> [String] { suggestion.candidateMeetingIDs.map(title) }

    static func suggestionLine(_ suggestion: SourceSuggestion, titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.formatted(.list(type: .or))
        switch suggestion.reason {
        case .severalConversations: return "This recording overlaps \(names). Add it to one of them?"
        case .lowConfidence: return "This recording may be part of \(names)."
        case .checkingTranscript: return "Checking whether this recording is part of \(names)…"
        }
    }

    static func companionLine(_ link: CompanionRecording) -> String? {
        switch link.state {
        case .starting: return "Starting \(link.deviceName)…"
        case .recording, .alreadyRecording: return "Also recording on \(link.deviceName)."
        case .stopping: return "Stopping \(link.deviceName)…"
        case .stopped, .stopFailed: return "Waiting for the \(link.deviceName) recording."
        case .unavailable, .failed, .attached: return nil
        }
    }
}
