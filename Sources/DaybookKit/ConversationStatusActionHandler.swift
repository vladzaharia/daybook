import DaybookCore
import Foundation

/// Carries out what a conversation's status offers (`ConversationStatusPresentation.Action`), from its page and from
/// Info's Now row alike. Each app implements it once (the Mac's `MacStatusActions`, the iPhone's `PhoneStatusActions`);
/// the library's half is here, the same on both: Transcribe, Summarize, and Try Again go through the app's own
/// processing (`process`, as its `ConversationActionPerformer` processes), Cancel takes back this device's request, Don’t
/// Wait and Wait Again register with Edit › Undo, and Dismiss clears the note. The rest are each app's own
/// (`performHere`): its queue, its models and Settings, where its summaries run, and upgrades.
@MainActor
public protocol ConversationStatusActionHandler {
    var library: LibraryController { get }
    /// What Don’t Wait and Wait Again register their undo with.
    var undoManager: UndoManager? { get }
    /// Processes a conversation in a mode, as the app's menus do.
    func process(_ id: UUID, _ mode: ProcessingRequest.Mode)
    /// An action only this app carries out: everything `perform` doesn't.
    func performHere(_ action: ConversationStatusPresentation.Action, on id: UUID)
}

extension ConversationStatusActionHandler {
    /// Carries out `action` on the conversation `id`.
    public func perform(_ action: ConversationStatusPresentation.Action, on id: UUID) {
        switch action {
        case .transcribe: process(id, .newAudio)
        case .summarize: process(id, .summaryOnly)
        case .tryAgain(let mode): process(id, mode)
        case .cancelRequest(let request):
            let device = library.thisDevice
            library.update(id) { $0.withdrawProcessingRequest(request, by: device, at: Date()) }
        case .dontWait: library.stopWaitingForRecordings(in: id, undoManager: undoManager)
        case .waitAgain: library.waitAgainForMissingRecordings(in: id, undoManager: undoManager)
        case .dismiss: library.update(id) { $0.errorMessage = nil }
        case .details, .pause, .resume, .cancel, .cancelDownload, .downloadModels, .downloadSummaryModel, .chooseModels,
             .cloudSettings, .summarizeHere, .useYourMac, .placement, .stopSummary, .upgrade, .dismissUpgrade:
            performHere(action, on: id)
        }
    }
}
