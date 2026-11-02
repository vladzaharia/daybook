import DaybookDesign
import DaybookKit
import SwiftUI

// The conversation's tools that read a conversation and edit it through `LibraryController`, the same on both apps:
// Review Earlier Corrections, Adjust Timing, and a recording's Original Transcript. A sheet on the Mac and on the
// iPhone in the hand; a card on the open Duo's right page.

// MARK: - Review Earlier Corrections

/// Corrections made before the audio was transcribed again, one at a time: apply each to a passage of the new
/// transcript, or keep it in Version History only. Later closes it with nothing decided; the transcript keeps offering
/// Review….
public struct ReviewCorrectionsSheet: View {
    private let library: LibraryController
    private let meetingID: UUID
    private let close = SheetDismiss()
    @State private var index = 0
    @State private var target: UUID?
    @Environment(\.daybookDensity) private var density

    public init(library: LibraryController, meetingID: UUID) {
        self.library = library
        self.meetingID = meetingID
    }

    private var meeting: Meeting? { library.meeting(meetingID) }
    private var issues: [CorrectionTransferIssue] { meeting?.correctionTransferIssues ?? [] }

    public var body: some View {
        NavigationStack {
            Group {
                if let meeting, !issues.isEmpty {
                    let position = min(index, issues.count - 1)
                    let issue = issues[position]
                    review(issue, position: position, in: meeting)
                } else {
                    ContentUnavailableView("All Corrections Reviewed", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Review Earlier Corrections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if issues.isEmpty {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } }
                } else {
                    // Closes it with nothing decided (Esc too); the transcript keeps offering Review….
                    ToolbarItem(placement: .cancellationAction) { Button("Later") { close() }.keyboardShortcut(.cancelAction) }
                }
            }
        }
        .onAppear { target = issues.first.flatMap { Self.candidates($0, in: meeting).first?.id } }
        #if os(macOS)
        .frame(width: 560, height: 460)
        #endif
    }

    private func review(_ issue: CorrectionTransferIssue, position: Int, in meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s3) {
            SheetTitle("Review Earlier Corrections", detail: issues.count > 1 ? "\(position + 1) of \(issues.count)" : nil)
            Text("You corrected this before the audio was transcribed again:")
                .font(DaybookFont.status.font(density)).foregroundStyle(DaybookPalette.Ink.secondary)
            Text("“\(issue.originalSegment.text)”")
                .font(DaybookFont.body.font(density))
                .foregroundStyle(DaybookPalette.Ink.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
            Text("Apply it to:").font(DaybookFont.status.font(density)).foregroundStyle(DaybookPalette.Ink.secondary)
            List(Self.candidates(issue, in: meeting), selection: $target) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DaybookSpacing.s2) {
                        Text(TimeLabel.short(segment.start)).font(DaybookFont.time.font(density)).foregroundStyle(DaybookPalette.Ink.meta)
                        if let name = meeting.speakerName(segment.speakerID) {
                            Text(name).font(DaybookFont.speaker.font(density))
                                .foregroundStyle(DaybookPalette.speakerInk(meeting.speakerIndex(segment.speakerID)))
                        }
                    }
                    Text(segment.text).lineLimit(3).foregroundStyle(DaybookPalette.Ink.body)
                }
                .tag(segment.id)
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .frame(minHeight: 160)
            ViewThatFits(in: .horizontal) {
                HStack {
                    keepButton(issue)
                    Spacer()
                    skipButton
                    applyButton(issue)
                }
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    applyButton(issue)
                    skipButton
                    keepButton(issue)
                }
            }
        }
        .padding(density == .touch ? 20 : DaybookSpacing.s5)
    }

    private func keepButton(_ issue: CorrectionTransferIssue) -> some View {
        Button("Keep in History Only") { resolve(issue, nil) }
    }

    @ViewBuilder private var skipButton: some View {
        if issues.count > 1 {
            Button("Skip") { index = (index + 1) % max(1, issues.count); target = nil }
        }
    }

    private func applyButton(_ issue: CorrectionTransferIssue) -> some View {
        Button("Apply") { resolve(issue, target) }
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil)
    }

    /// The passages the correction most likely belongs to, else the whole transcript.
    static func candidates(_ issue: CorrectionTransferIssue, in meeting: Meeting?) -> [TranscriptSegment] {
        guard let meeting else { return [] }
        let preferred = meeting.unifiedTranscript.filter { issue.candidateSegmentIDs.contains($0.id) }
        return preferred.isEmpty ? meeting.unifiedTranscript : preferred
    }

    private func resolve(_ issue: CorrectionTransferIssue, _ segment: UUID?) {
        library.resolveCorrectionTransfer(issue.id, targetSegmentID: segment, in: meetingID)
        target = nil
        if issues.isEmpty { close() } else {
            index = min(index, max(0, issues.count - 1))
            target = issues.first.flatMap { Self.candidates($0, in: meeting).first?.id }
        }
    }
}

// MARK: - Adjust Timing

/// Places a recording on the conversation's timeline: lined up automatically, or starting at a time the person types.
/// Play Recording plays it from its start, to hear where it begins.
public struct AdjustTimingSheet: View {
    private let library: LibraryController
    private let meetingID: UUID
    private let trackID: UUID?
    private let recordingName: @MainActor (RecordingTrack, Meeting) -> String
    private let play: @MainActor (PlaybackTarget) -> Void
    private let close = SheetDismiss()
    @State private var automatic = true
    @State private var draft = ""
    @Environment(\.daybookDensity) private var density

    public init(library: LibraryController, meetingID: UUID, trackID: UUID?,
                recordingName: @escaping @MainActor (RecordingTrack, Meeting) -> String = { RecordingWords.name($0, in: $1) },
                play: @escaping @MainActor (PlaybackTarget) -> Void) {
        self.library = library
        self.meetingID = meetingID
        self.trackID = trackID
        self.recordingName = recordingName
        self.play = play
    }

    /// The recording to adjust: the one asked for, else the one that couldn't be lined up, else the second.
    public static func defaultTrack(in meeting: Meeting) -> UUID? {
        meeting.alignmentReports.first { $0.method == .unaligned }?.trackID ?? meeting.tracks.dropFirst().first?.id
    }

    private var meeting: Meeting? { library.meeting(meetingID) }
    private var resolvedTrackID: UUID? { trackID ?? meeting.flatMap(Self.defaultTrack) }
    private var track: RecordingTrack? { meeting?.tracks.first { $0.id == resolvedTrackID } }
    private var parsed: Double? { TimeField.parse(draft) }

    public var body: some View {
        NavigationStack {
            Form {
                if let meeting, let track {
                    Section {
                        Picker("Timing", selection: $automatic) {
                            Text("Automatically").tag(true)
                            Text("Starts at a time").tag(false)
                        }
                        #if os(macOS)
                        .pickerStyle(.radioGroup)
                        #else
                        .pickerStyle(.inline)
                        #endif
                        .labelsHidden()
                        if !automatic {
                            LabeledContent("Starts at") {
                                TextField("0:00", text: $draft)
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                    .keyboardType(.numbersAndPunctuation)
                                    #endif
                                    .frame(maxWidth: 96)
                                    .monospacedDigit()
                                    .accessibilityLabel("Starts at, into the conversation")
                            }
                        }
                    } header: {
                        Text(recordingName(track, meeting))
                    } footer: {
                        if meeting.alignmentReports.first(where: { $0.trackID == track.id })?.method == .unaligned {
                            Label("Couldn’t line up automatically.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(DaybookPalette.Ink.warning)
                        }
                    }
                    Section {
                        Button("Play Recording", systemImage: "play.fill") { play(.source(track, 0)) }
                            .buttonStyle(.daybookLink)
                    }
                } else {
                    Text("This recording isn’t in the conversation anymore.").foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .top, spacing: 0) {
                if SheetTitle.needsTitle {
                    SheetTitle("Adjust Timing").padding(.horizontal, DaybookSpacing.s5).padding(.top, DaybookSpacing.s4)
                }
            }
            .navigationTitle("Adjust Timing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if let id = track?.id { library.setOffset(meetingID, trackID: id, seconds: automatic ? nil : parsed) }
                        close()
                    }
                    .disabled(track == nil || (!automatic && parsed == nil))
                }
            }
        }
        .onAppear {
            automatic = track?.offset == nil
            draft = track?.offset.map(TimeLabel.short) ?? ""
        }
        #if os(macOS)
        .frame(width: 440, height: 340)
        #endif
    }
}

/// A time typed into a field: "42", "0:42", "1:02:03", and a leading minus for a recording that began earlier.
public enum TimeField {
    public static func parse(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        let negative = value.hasPrefix("-")
        if negative { value.removeFirst() }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return negative ? -seconds : seconds
    }
}

// MARK: - Original Transcript

/// One recording's own transcript, as it was made, before the recordings were put together. Read only; Copy takes it
/// for this device only.
public struct OriginalTranscriptSheet: View {
    private let library: LibraryController
    private let meetingID: UUID
    private let trackID: UUID
    private let recordingName: @MainActor (RecordingTrack, Meeting) -> String
    private let close = SheetDismiss()
    @Environment(\.daybookDensity) private var density

    public init(library: LibraryController, meetingID: UUID, trackID: UUID,
                recordingName: @escaping @MainActor (RecordingTrack, Meeting) -> String = { RecordingWords.name($0, in: $1) }) {
        self.library = library
        self.meetingID = meetingID
        self.trackID = trackID
        self.recordingName = recordingName
    }

    /// The recording's latest transcript.
    public static func run(of trackID: UUID, in meeting: Meeting) -> TrackTranscript? {
        meeting.transcripts.filter { $0.trackID == trackID }.max { $0.createdAt < $1.createdAt }
    }

    /// The transcript as text: each passage after its time.
    public static func text(_ run: TrackTranscript?) -> String {
        (run?.segments ?? []).map { "[\(TimeLabel.short($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    public var body: some View {
        let meeting = library.meeting(meetingID)
        let track = meeting?.tracks.first { $0.id == trackID }
        let run = meeting.flatMap { Self.run(of: trackID, in: $0) }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    SheetTitle("Original Transcript", detail: track.flatMap { track in meeting.map { recordingName(track, $0) } })
                        .padding(.bottom, DaybookSpacing.s2)
                    ForEach(run?.segments ?? []) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(TimeLabel.short(segment.start))
                                .font(DaybookFont.marginTime.font(density))
                                .foregroundStyle(DaybookPalette.Ink.meta)
                                .frame(width: 44, alignment: .trailing)
                            Text(segment.text)
                                .font(DaybookFont.body.font(density))
                                .foregroundStyle(DaybookPalette.Ink.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if run?.segments.isEmpty ?? true {
                        Text("No words in this recording.").foregroundStyle(DaybookPalette.Ink.secondary)
                    }
                }
                .padding(density == .touch ? 20 : DaybookSpacing.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DaybookPalette.paper.ignoresSafeArea())
            .navigationTitle("Original Transcript")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") { LocalCopy.copy(Self.text(run)) }.disabled(run?.segments.isEmpty ?? true)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } }
            }
        }
        .dismissesOnEscape { close() }
        #if os(macOS)
        .frame(width: 640, height: 560)
        #endif
    }
}

/// A sheet's title where the system shows none. A navigation bar carries it on the iPhone, and a sheet's toolbar on
/// macOS 26; before that a sheet on the Mac has no title bar, so its title is in its content. A detail under it ("2 of
/// 3", the recording) shows everywhere.
struct SheetTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    /// The system draws no title over the sheet.
    static var needsTitle: Bool {
        #if os(macOS)
        if #available(macOS 26, *) { return false }
        return true
        #else
        return false
        #endif
    }

    @Environment(\.daybookDensity) private var density

    var body: some View {
        if Self.needsTitle || detail != nil {
            VStack(alignment: .leading, spacing: 2) {
                if Self.needsTitle {
                    Text(title).font(.headline).foregroundStyle(DaybookPalette.Ink.title).accessibilityAddTraits(.isHeader)
                }
                if let detail {
                    Text(detail).font(DaybookFont.status.font(density)).foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
