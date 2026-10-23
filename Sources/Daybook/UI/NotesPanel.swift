import AppKit
import DaybookCore
import SwiftUI

/// A utility panel that can sit beside a full-screen call without bringing the
/// library window forward. Text input becomes key when the user clicks the notes.
@MainActor
final class NotesPanelController {
    private var panel: MeetingNotesPanel?
    private var displayedMeetingID: UUID?

    func show(state: AppState, meetingID: UUID) {
        let panel: MeetingNotesPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = MeetingNotesPanel(contentRect: .zero,
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 320, height: 360)
            panel.animationBehavior = .utilityWindow
            panel.title = "Daybook Notes"
            panel.titlebarAppearsTransparent = true
            self.panel = panel
        }

        if displayedMeetingID != meetingID || panel.contentViewController == nil {
            panel.contentViewController = NSHostingController(rootView: MeetingNotesView(state: state, meetingID: meetingID))
            displayedMeetingID = meetingID
        }
        if !panel.isVisible {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let width = min(CGFloat(370), frame.width - 32)
                let height = min(CGFloat(660), frame.height - 32)
                panel.setFrame(NSRect(x: frame.maxX - width - 16, y: frame.maxY - height - 16,
                                      width: width, height: height), display: true)
            }
        }
        // Automatic appearance must not steal typing focus from the meeting app.
        panel.orderFrontRegardless()
    }

    func close() { panel?.close() }
}

private final class MeetingNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MeetingNotesView: View {
    @ObservedObject var state: AppState
    let meetingID: UUID

    private var meeting: Meeting? { state.meetings.first(where: { $0.id == meetingID }) }
    private var isRecording: Bool { state.recordingID == meetingID }
    private var notes: Binding<String> {
        Binding(get: { meeting?.notes ?? "" }, set: { state.editNotes(meetingID, text: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("YOUR NOTES", systemImage: "square.and.pencil")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                    Spacer()
                    if isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack(spacing: 6) {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                Text(TimeLabel.format(state.recorder.elapsedTime))
                                    .monospacedDigit()
                            }.font(.caption.weight(.medium))
                        }.accessibilityLabel("Recording in progress")
                    } else {
                        Label("Local", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(meeting?.title ?? "Conversation unavailable")
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(3)
                Text(isRecording ? "Stay in the conversation. Capture what matters." : "Your notes are saved with this conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)

            Divider()
            ZStack(alignment: .topLeading) {
                TextEditor(text: notes)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .accessibilityLabel("Meeting notes")
                    .disabled(meeting == nil)
                if meeting?.notes.isEmpty != false {
                    Text("A thought, a question, a detail to remember…")
                        .font(.system(size: 15)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 20).padding(.top, 22)
                        .allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if isRecording {
                    HStack {
                        Button { state.addHighlight(meetingID) } label: {
                            Label("Mark moment", systemImage: "bookmark")
                        }.help("Add a timestamped highlight to this recording")
                        Spacer()
                        Button {
                            Task { await state.stopRecording() }
                        } label: {
                            Label(state.isStoppingRecording ? "Saving…" : "Stop", systemImage: "stop.fill")
                        }.disabled(state.isStoppingRecording)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                if let anchors = meeting?.timedNotes, !anchors.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(anchors.suffix(2))) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(note.time.map(TimeLabel.format) ?? "Untimed")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Text(note.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.accessibilityLabel("Recent note timestamps")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Included in your final summary").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let count = meeting?.highlights.count, count > 0 {
                        Label("\(count)", systemImage: "bookmark.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("\(count) marked moments")
                    }
                }
            }.padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0.22, green: 0.43, blue: 0.38))
        .frame(minWidth: 300, minHeight: 320)
    }
}
