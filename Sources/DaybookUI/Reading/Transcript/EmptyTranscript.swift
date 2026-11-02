import DaybookDesign
import DaybookKit
import SwiftUI

/// The transcript's page before there's a transcript: a calm, complete state, not an error. Its title says what's
/// there ("No recording yet", "Not transcribed yet", "No transcript"); a failure's reason is said once, in the words
/// the summary page's box uses (`FailureWords`), and not at all where that box is beside it on two pages. Then what can
/// be done: play the recording, or record into a conversation that's only notes.
public struct EmptyTranscript<Record: View>: View {
    private let meeting: Meeting
    private let status: ProcessingStatus
    private let words: DeviceWords
    private let showsReason: Bool
    private let play: () -> Void
    private let transcribe: (() -> Void)?
    private let record: Record
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - showsReason: Say why a failure happened. Off where the summary's own box says it beside this page.
    ///   - transcribe: Offered while the audio isn't transcribed and nothing has asked for it, where the summary's
    ///     page leaves that to this one.
    ///   - record: Record, into a conversation that's only notes so far.
    public init(meeting: Meeting, status: ProcessingStatus, words: DeviceWords, showsReason: Bool, play: @escaping () -> Void,
                transcribe: (() -> Void)? = nil, @ViewBuilder record: () -> Record) {
        self.meeting = meeting
        self.status = status
        self.words = words
        self.showsReason = showsReason
        self.play = play
        self.transcribe = transcribe
        self.record = record()
    }

    public var body: some View {
        let words = Self.words(meeting: meeting, status: status, device: self.words, showsReason: showsReason)
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            Image(systemName: meeting.tracks.isEmpty ? "note.text" : "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DaybookPalette.Ink.meta)
                .accessibilityHidden(true)
            Text(words.title)
                .font(DaybookFont.rowTitle.font(density))
                .foregroundStyle(DaybookPalette.Ink.title)
                .accessibilityAddTraits(.isHeader)
            if let message = words.message {
                Text(message)
                    .font(DaybookFont.status.font(density))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if meeting.tracks.isEmpty {
                record.padding(.top, DaybookSpacing.s1)
            } else {
                HStack(spacing: DaybookSpacing.s2) {
                    Button(action: play) { Label("Play Recording", systemImage: "play.fill") }
                        .buttonStyle(.daybookTinted)
                    if let transcribe, case .recorded = status {
                        Button(action: transcribe) { Label("Transcribe", systemImage: "waveform") }
                            .buttonStyle(.daybookTinted)
                    }
                }
                .padding(.top, DaybookSpacing.s1)
            }
        }
        .padding(.top, DaybookSpacing.s7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The title and, when there's a reason to give, the sentence under it.
    public static func words(meeting: Meeting, status: ProcessingStatus, device: DeviceWords,
                             showsReason: Bool) -> (title: String, message: String?) {
        if meeting.tracks.isEmpty { return ("No recording yet", nil) }
        guard case .failed(let failure) = status else { return ("Not transcribed yet", nil) }
        guard showsReason else { return ("No transcript", nil) }
        let failed = FailureWords(failure, words: device)
        // No speech says so; every other failure's sentence already ends "The recording is saved."
        return ("No transcript", failure.isNoSpeech ? "\(failed.title). \(failed.message)" : failed.message)
    }
}

extension EmptyTranscript where Record == EmptyView {
    public init(meeting: Meeting, status: ProcessingStatus, words: DeviceWords, showsReason: Bool, play: @escaping () -> Void,
                transcribe: (() -> Void)? = nil) {
        self.init(meeting: meeting, status: status, words: words, showsReason: showsReason, play: play, transcribe: transcribe) { EmptyView() }
    }
}
