import DaybookCaptions
import DaybookDesign
import DaybookKit
import SwiftUI

// Listen Live (docs/devices.md, "Listen Live captions"): what a recorder is recording now, heard live on this
// device. The same page on both: what it's recording and since when, Listen Live, then while listening how much
// has been saved with Stop Listening and the tentative captions; after Stop Listening, where it was saved. The Mac
// shows it for the list's Recording Now; the iPhone pushes it from the recorder's page.

/// A recorder's recording now, and Listen Live.
public struct ListenLiveView: View {
    private let session: DeviceSession

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        RecorderPageColumn {
            ListenLiveContent(session: session)
        }
    }
}

private struct ListenLiveContent: View {
    let session: DeviceSession
    @Environment(\.recorderServices) private var services
    @Environment(\.readingWidth) private var readingWidth
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let connection = session.direct as? any LiveListeningConnection
        let listening = connection?.live.isListening == true
        Group {
            title
            byline
            // Handed over mid-recording: the conversation it goes into once it's finished.
            if let id = session.split.inProgress?.id, let waiting = session.conversationWaiting(for: id),
               let meeting = services?.library.meeting(waiting) {
                Text("For \(meeting.title)").daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                    .padding(.top, DaybookSpacing.s2)
            }
            if let problem = RecorderProblemBox.shownProblem(session) {
                RecorderProblemBox(session: session, problem: problem).padding(.top, DaybookSpacing.s4)
            }
            if let connection {
                if listening {
                    ListeningRow(session: session, connection: connection)
                    ListenLiveCaptions(session: session, live: connection.live)
                    Text("Stopping here doesn’t stop your \(session.kind.shortName) recording.")
                        .daybookFont(.colophon)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DaybookSpacing.s5)
                } else {
                    let importing = session.queue.current != nil
                    Button { connection.startListening() } label: { Label("Listen Live", systemImage: "ear") }
                        .buttonStyle(.daybookProminent)
                        .disabled(session.status?.isRecording != true || importing || !session.isLinked)
                        .padding(.top, DaybookSpacing.s5)
                    if importing {
                        Text("Available when the import finishes.")
                            .daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary)
                            .padding(.top, DaybookSpacing.s2)
                    }
                    LiveSavedNotice(session: session)
                }
            }
        }
        .daybookMotion(DaybookMotion.fade, value: listening)
    }

    @ViewBuilder private var title: some View {
        let text = Text("Recording on \(session.kind.shortName)")
            .daybookFont(.docTitle)
            .foregroundStyle(DaybookPalette.Ink.title)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        let glyph = Image(systemName: "record.circle.fill")
            .font(.system(size: 22))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(DaybookPalette.Ink.record)
            .symbolEffect(.breathe, isActive: !reduceMotion)
            .accessibilityHidden(true)
        if readingWidth == .regular {
            text.overlay(alignment: .topLeading) {
                glyph.frame(width: ReadingGeometry.margin - ReadingGeometry.marginGap, height: 36, alignment: .trailing)
                    .offset(x: -ReadingGeometry.margin)
            }
        } else {
            text.padding(.top, density == .touch ? DaybookSpacing.s2 : 0)
        }
    }

    private var byline: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(DaybookPalette.Ink.record).accessibilityHidden(true)
            if let start = session.split.inProgress?.startedAt {
                Text("Started \(start.formatted(date: .omitted, time: .shortened)) · \(Text(timerInterval: start...Date.distantFuture, countsDown: false)) so far")
            } else {
                Text("Recording")
            }
        }
        .daybookFont(.byline)
        .foregroundStyle(DaybookPalette.Ink.secondary)
        .padding(.top, 6)
    }
}

/// Listening: the live glyph, how much has been saved so far, and Stop Listening.
private struct ListeningRow: View {
    let session: DeviceSession
    let connection: any LiveListeningConnection
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: DaybookSpacing.s3) {
            // Live, like the byline's playing waveform: mint, glowing and moving, in Dark Mode; steady link ink in Light.
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DaybookPalette.liveGlyph)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: !reduceMotion && scheme == .dark)
                .daybookGlow(DaybookPalette.neonMint, radius: 4)
                .frame(width: ListenLiveCaptions.glyphColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.live.isCatchingUp ? "Catching up…" : "Listening").daybookFont(.statusLead).foregroundStyle(DaybookPalette.Ink.body)
                Text("\(TimeLabel.short(connection.live.receivedSeconds)) saved")
                    .daybookFont(.status).foregroundStyle(DaybookPalette.Ink.secondary).monospacedDigit()
            }
            Spacer(minLength: DaybookSpacing.s3)
            Button("Stop Listening") { connection.stopListening() }
                .buttonStyle(.daybookTinted)
        }
        .padding(.top, DaybookSpacing.s5)
    }
}

/// Listen Live's tentative captions: the newest lines under "Live captions · tentative", or what the captioner is
/// doing. Nothing when captions are off or can't run.
struct ListenLiveCaptions: View {
    let session: DeviceSession
    let live: LiveCapture
    @Environment(\.recorderServices) private var services
    @Environment(\.daybookDensity) private var density

    /// The label's glyph column, which the Listening row above shares, so their words start together.
    static let glyphColumn: CGFloat = CaptionStripStyle.feed.glyphColumn ?? 24

    /// On the Mac, the strip's feed (six lines in the page's body type); under touch the page's caption column. The
    /// label is drawn above the strip, its glyph in the Listening row's column.
    static func style(_ density: DaybookDensity) -> CaptionStripStyle {
        var style = density == .touch ? CaptionStripStyle.page : CaptionStripStyle.feed
        style.showsLabel = false
        return style
    }

    var body: some View {
        let style = Self.style(density)
        // Whatever has been heard is shown while listening, whatever the captioner says of itself.
        let lines = session.liveCaptions.suffix(style.lines).map {
            CaptionLine(id: $0.id, text: $0.text, isTentative: $0.isTentative, speaker: $0.speaker?.name)
        }
        let status = lines.isEmpty ? services?.captionStatus(live.captionState) : nil
        if !lines.isEmpty || status != nil {
            VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                HStack(spacing: DaybookSpacing.s3) {
                    Image(systemName: "captions.bubble").frame(width: Self.glyphColumn)
                    Text("Live captions · tentative")
                }
                .font(density == .touch ? .caption.weight(.semibold) : .system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(DaybookPalette.Ink.meta)
                .lineLimit(1)
                .accessibilityHidden(true)
                LiveCaptionStrip(lines: Array(lines), status: status, style: style)
            }
            .padding(.top, DaybookSpacing.s5)
        }
    }
}

/// "Saved 12 min as a new conversation", after Stop Listening, with Show Conversation.
public struct LiveSavedNotice: View {
    private let session: DeviceSession
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession) { self.session = session }

    public var body: some View {
        if let live = (session.direct as? any LiveListeningConnection)?.live, let saved = live.saved, !live.isListening {
            let meetingID = session.links.partial[saved.recordingID] ?? session.links.imported[saved.recordingID]
            AttentionBox(kind: .info, title: "Saved \(DurationLabel.format(saved.seconds)) as a new conversation",
                         symbol: "checkmark.circle.fill", message: nil,
                         primary: meetingID.map { id in AttentionAction("Show Conversation") { services?.showConversation(id) } },
                         dismiss: { live.saved = nil })
                .padding(.top, DaybookSpacing.s4)
                .daybookTransition(.opacity)
        }
    }
}
