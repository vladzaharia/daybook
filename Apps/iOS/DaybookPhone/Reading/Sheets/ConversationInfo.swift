import DaybookKit
import DaybookUI
import SwiftUI

/// Info: DaybookUI's `ConversationInfoForm`, the Mac's inspector, as a sheet (and on the open Duo a card on the
/// right page): where the conversation is filed, who spoke, its recordings and where their audio is, and how it was
/// processed, with this iPhone's player, placement, and requests.
struct ConversationInfo: View {
    let library: LibraryController
    let meetingID: UUID
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session
    @Environment(\.summaryPlacement) private var placement
    @Environment(\.audioProvider) private var provider
    @Environment(\.undoManager) private var undoManager
    @State private var detent: PresentationDetent = Self.launchDetent

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ConversationInfoForm(library: library, meetingID: meetingID, services: services) { _ in
                    EmptyView()
                } addRecording: { _ in
                    EmptyView()
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
                #if DEBUG
                .task {
                    // `--info-scroll people`, for screenshots.
                    guard let index = CommandLine.arguments.firstIndex(of: "--info-scroll"), CommandLine.arguments.indices.contains(index + 1),
                          let section = InfoSectionID(rawValue: CommandLine.arguments[index + 1]) else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    proxy.scrollTo(section, anchor: .top)
                }
                #endif
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// `--info-detent large` (debug), for screenshots.
    private static var launchDetent: PresentationDetent {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--info-detent"), CommandLine.arguments.indices.contains(index + 1),
           CommandLine.arguments[index + 1] == "large" { return .large }
        #endif
        return .medium
    }

    private var services: ConversationInfoServices {
        let library = library, provider = provider, placement = placement
        let words = DeviceWords.iPhone(id: library.thisDevice.id)
        return ConversationInfoServices(
            catalog: .builtIn, words: words,
            recordingName: { track, meeting in RecordingWords.name(track, in: meeting) },
            recordingLine: { track, meeting in
                RecordingWords.line(track, in: meeting, mac: "Your Mac", pending: "Lines up when your Mac processes it")
            },
            availability: { track, meeting in Self.reading(await provider.availability(of: track, in: meeting.id)) },
            actionContext: { meeting in Self.context(meeting) },
            now: { meeting, date in
                var inputs = ConversationStatusPresentation.Inputs(words: words, local: .iPhone())
                if let placement {
                    inputs.placement = .init(planner: placement.planners[meeting.id], run: placement.runs[meeting.id],
                                             cloudOffered: placement.cloudOffer != nil)
                }
                return InfoNow.make(ProcessingStatus.phone(meeting, now: date), meeting: meeting, inputs: inputs, now: date)
            },
            perform: { action, meeting in perform(action, in: meeting) })
    }

    static func context(_ meeting: Meeting) -> ConversationActions.Context {
        let status = ProcessingStatus.phone(meeting)
        var here = false
        if case .processing(let progress) = status, progress.device == nil { here = true }
        return ConversationActions.Context(platform: .iPhone, isProcessingHere: here, status: status)
    }

    static func reading(_ availability: AudioAvailability) -> ReadingAudio {
        switch availability {
        case .local: return .local
        case .downloadable(let bytes): return .downloadable(bytes: bytes)
        case .offline: return .offline
        case .missing: return .missing
        }
    }

    private func perform(_ action: ConversationInfoAction, in meeting: Meeting) {
        let id = meeting.id
        switch action {
        case .track(.play, let track):
            session.player.play(.source(track, 0), in: meeting, provider: provider)
        case .track(.removeRecording, let track):
            library.removeRecording(track.id, from: id, undoManager: undoManager, changed: processAgain)
        case .track(.moveToNewConversation, let track):
            let library = library, provider = provider, undoManager = undoManager, processAgain = processAgain
            Task {
                do {
                    _ = try await library.moveRecordingToNewConversation(track.id, from: id, audio: { track in
                        try await provider.localAudio(for: track, in: id, progress: { _ in })
                    }, undoManager: undoManager, changed: processAgain)
                } catch {
                    session.alert = ReadingAlert(title: "Couldn’t Move the Recording", error: error, fallback: "Try again.")
                }
            }
        case .track(.adjustTiming, let track):
            // The sheet becomes the transcript's tool, as Version History does.
            session.sheet = .adjustTiming(meetingID: id, trackID: track.id)
        case .track(.showOriginalTranscript, let track):
            session.sheet = .originalTranscript(meetingID: id, trackID: track.id)
        case .track:
            break
        case .putBack(let track):
            library.putBackRecording(track.id, in: id, undoManager: undoManager, changed: processAgain)
        case .process(let mode):
            if mode == .summaryOnly { library.summarize(id, placement: placement) } else { library.requestProcessing(id, mode: mode) }
        case .summarize(let template):
            library.summarize(id, templateID: template, placement: placement)
        case .versionHistory:
            // The sheet becomes Version History: the sheet presenting it swaps, and on the Duo's page the card does.
            session.sheet = .history(id)
        case .status(.placement(let choice)):
            placement?.perform(choice, for: id)
        case .status(.stopSummary):
            placement?.stop(id)
        case .status(.dontWait):
            library.stopWaitingForRecordings(in: id, undoManager: undoManager)
        case .status:
            break
        case .searchTag(let tag):
            // Info and the conversation step aside for the tag's conversations.
            session.sheet = nil
            session.closeConversation()
            session.searchText = ""
            session.searchTokens = [.tag(tag)]
            session.isSearchPresented = true
        }
    }

    /// A conversation whose recordings changed, with what the library says it needs: its new recording is
    /// transcribed where that happens, else the summary it had is written again from the transcript it has now.
    private var processAgain: @MainActor (UUID, ProcessingRequest.Mode) -> Void {
        let library = library, placement = placement
        return { id, mode in
            if mode == .summaryOnly { library.summarize(id, placement: placement) } else { library.requestProcessing(id, mode: mode) }
        }
    }
}
