import DaybookCore
import DaybookDesign
import DaybookIntelligence
import DaybookKit
import DaybookUI
import SwiftUI

/// Properties of the selected conversation, kept out of the page: DaybookUI's `ConversationInfoForm`, the iPhone's
/// Info, with this Mac's names, its queue, and what only the Mac adds to Audio (recordings to come and suggested
/// matches, background audio, Add Recording from a file, a recorder, or this Mac).
struct MeetingInspector: View {
    let state: AppState
    let meetingID: UUID
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.meetings.contains(where: { $0.id == meetingID }) {
            ConversationInfoForm(library: state.library, meetingID: meetingID, services: services) { meeting in
                SourceHooks(state: state, meeting: meeting)
                BackgroundAudioHook(state: state, meeting: meeting)
            } addRecording: { meeting in
                Menu("Add Recording") {
                    Button("From a File…") { state.chooseImport(attachTo: meeting.id) }
                    AddRecordingFromDeviceItems(state: state)
                    Button("Record on This Mac") { Task { await state.startRecording(into: meeting.id) } }
                        .disabled(state.isRecording || !state.canRecordInto(meeting.id))
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .disabled(state.processor.queue.runningID == meeting.id || state.recordingID == meeting.id)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
        }
    }

    private var services: ConversationInfoServices {
        let state = state
        return ConversationInfoServices(
            catalog: state.modelCatalog, words: .mac(id: state.library.thisDevice.id),
            recordingName: { track, meeting in state.recordingName(track, in: meeting) },
            recordingLine: { track, meeting in state.sourceLine(track, in: meeting) },
            actionContext: { meeting in Self.context(state, meeting) },
            now: { meeting, date in
                InfoNow.make(state.processingStatus(for: meeting), meeting: meeting, inputs: Self.inputs(state, meeting), now: date)
            },
            perform: { action, meeting in perform(action, in: meeting) })
    }

    static func context(_ state: AppState, _ meeting: Meeting) -> ConversationActions.Context {
        ConversationActions.Context(platform: .mac, isRecording: state.recordingID == meeting.id,
                                    isProcessingHere: state.processor.queue.runningID == meeting.id || state.processor.queue.queuedIDs.contains(meeting.id),
                                    status: state.processingStatus(for: meeting), isDeviceRecording: state.isRecording)
    }

    static func inputs(_ state: AppState, _ meeting: Meeting) -> ConversationStatusPresentation.Inputs {
        ConversationStatusPresentation.Inputs(words: .mac(id: state.library.thisDevice.id), local: .mac(),
                                              isRecording: state.recordingID == meeting.id,
                                              placement: .init(planner: state.placements[meeting.id]),
                                              arrivals: state.arrivals(for: meeting))
    }

    /// A conversation whose recordings changed is processed again here, as the library says it needs: its new
    /// recording transcribed, else the summary it had written again from the transcript it has now. One the person
    /// paused stays paused until Resume, and a recording moved out of it (`source`) waits in its new conversation
    /// until asked for too.
    static func processAgain(_ state: AppState, source: UUID? = nil) -> @MainActor (UUID, ProcessingRequest.Mode) -> Void {
        { [weak state] id, mode in
            guard let state, state.processor.queue.runningID != id, !state.processor.queue.paused.contains(id),
                  !(source.map(state.processor.queue.paused.contains) ?? false) else { return }
            state.cancelQueued(id)
            state.processor.enqueue(id, mode: mode)
        }
    }

    private func perform(_ action: ConversationInfoAction, in meeting: Meeting) {
        let id = meeting.id
        switch action {
        case .track(let action, let track):
            perform(action, track: track, in: meeting)
        case .putBack(let track):
            state.library.putBackRecording(track.id, in: id, phoneName: state.phoneName(track), undoManager: undoManager,
                                           changed: Self.processAgain(state))
        case .process(let mode):
            state.processor.enqueue(id, mode: mode)
        case .summarize:
            // Choosing a different template summarizes again right away; the earlier summary stays in Version History.
            guard state.processor.queue.runningID != id else { return }
            state.cancelQueued(id)
            state.processor.enqueue(id, mode: .summaryOnly)
        case .versionHistory:
            state.window.sheet = .versionHistory
        case .status(let action):
            MacStatusActions(state: state, undoManager: undoManager) { $0.open(with: openWindow, activating: false) }
                .perform(action, on: id)
        case .searchTag(let tag):
            state.window.searchTokens = [.tag(tag)]
        }
    }

    private func perform(_ action: ConversationAction.ID, track: RecordingTrack, in meeting: Meeting) {
        let id = meeting.id
        switch action {
        case .play:
            guard !state.isRecording else { return }
            Task {
                guard let url = await state.audioURL(for: track, meetingID: id) else { return }
                withAnimation(DaybookMotion.state) { state.playback.play(url: url, at: 0, trackID: track.id, meetingID: id) }
            }
        case .adjustTiming:
            state.window.sheet = .adjustTiming(track.id)
        case .showOriginalTranscript:
            state.window.sheet = .originalTranscript(track.id)
        case .showInFinder:
            state.showInFinder(id)
        case .removeRecording:
            // Its words leave the transcript at once; the summary is written again without them.
            state.library.removeRecording(track.id, from: id, phoneName: state.phoneName(track), undoManager: undoManager,
                                          changed: Self.processAgain(state))
        case .moveToNewConversation:
            let state = state, undoManager = undoManager
            Task {
                do {
                    _ = try await state.library.moveRecordingToNewConversation(track.id, from: id, phoneName: state.phoneName(track), audio: { track in
                        try await state.library.audioURL(for: track, in: id)
                    }, undoManager: undoManager, changed: Self.processAgain(state, source: id))
                } catch {
                    state.report("Couldn’t Move the Recording", "Try again.", error)
                }
            }
        default:
            break
        }
    }
}

/// The inspector reads the library itself, so the window redrawing it for the same conversation doesn't
/// draw it again (`MeetingDetailView` does the same).
extension MeetingInspector: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.meetingID == rhs.meetingID }
}
