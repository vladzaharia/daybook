import DaybookCore
import SwiftUI

/// Several recordings of one conversation, in the inspector's Audio section under its recordings:
/// a recorder's recording still to come, and a recording that may belong with another
/// conversation, to confirm or dismiss. Each is laid out like a recording row. The state and
/// actions live in `AppState+Sources`.
struct SourceHooks: View {
    @ObservedObject var state: AppState
    let meeting: Meeting

    var body: some View {
        ForEach(meeting.companions ?? []) { link in
            if let line = Self.companionLine(link, recordingNow: state.recordingID == meeting.id) {
                // Laid out like a recording row (glyph column, then words), since it is one to come.
                row(symbol: "clock") { Text(line).foregroundStyle(.secondary) }
            }
        }
        ForEach(meeting.sourceSuggestions ?? []) { suggestion in
            row(symbol: "questionmark.circle") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.suggestionLine(suggestion, titles: titles(suggestion)))
                        .fixedSize(horizontal: false, vertical: true)
                    // The buttons share a line when their titles fit, else each takes its own.
                    ViewThatFits(in: .horizontal) {
                        HStack { buttons(suggestion) }
                        VStack(alignment: .leading, spacing: 6) { buttons(suggestion) }
                    }
                }
            }
        }
    }

    private func row(symbol: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func buttons(_ suggestion: SourceSuggestion) -> some View {
        let targets = suggestion.candidateMeetingIDs.filter { id in state.meetings.contains { $0.id == id } }
        ForEach(targets, id: \.self) { target in
            // The sentence above names a single conversation, so its button needn't repeat (and truncate) it.
            Button(targets.count == 1 ? "Move There" : "Add to “\(title(target))”") {
                Task { await state.confirmSourceSuggestion(suggestion.id, in: meeting.id, into: target) }
            }
            .disabled(state.processingID == meeting.id || state.processingID == target || state.recordingID == meeting.id)
        }
        Button("Keep Separate") { state.dismissSourceSuggestion(suggestion.id, in: meeting.id) }
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

    /// A recording a link waits for that hasn't come in this long is let go (it may never arrive).
    static let waitingLineLifetime: TimeInterval = 2 * 86_400

    /// The link's line, while this Mac records the conversation (`recordingNow`) or after. A link an
    /// interrupted recording left open reads as waiting, and every waiting line goes after a while.
    static func companionLine(_ link: CompanionRecording, recordingNow: Bool, now: Date = Date()) -> String? {
        let live = recordingNow && link.macEndedAt == nil
        if !live, now.timeIntervalSince(link.macEndedAt ?? link.macStartedAt) > waitingLineLifetime { return nil }
        let waiting = "Waiting for audio from \(link.deviceName)."
        switch link.state {
        case .starting: return live ? "Starting \(link.deviceName)…" : nil
        case .recording, .alreadyRecording: return live ? "Also recording on \(link.deviceName)." : waiting
        case .stopping: return live ? "Stopping \(link.deviceName)…" : waiting
        case .stopped, .stopFailed: return waiting
        case .unavailable, .failed, .attached: return nil
        }
    }
}
