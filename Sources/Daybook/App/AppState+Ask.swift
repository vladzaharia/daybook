import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookUI
import Foundation

/// What asking across conversations needs of this Mac (AskController.swift): the search field's scope, the Personal
/// lock, the library, the summary model, and the processing queue.
extension AppState {
    /// - Parameter engine: another engine than the installed summary model's; the debug demo's scripted one.
    func makeAskController(engine override: ((LibraryPassageIndex) -> AskEngine?)? = nil) -> AskController {
        AskController(dependencies: AskController.Dependencies(
            engine: { [weak self] index in
                if let override { return override(index) }
                guard let self, self.installedModels.contains(self.summaryModel) else { return nil }
                return AskEngine(runtime: self.runtime, model: ModelReference(self.summaryModel), index: index)
            },
            meetings: { [weak self] in self?.meetings ?? [] },
            vocabulary: { [weak self] in self?.glossary ?? [] },
            people: { [weak self] in self?.speakerProfiles.map(\.name) ?? [] },
            scope: { [weak self] in
                guard let self else { return (AskScope(), "") }
                let scope = self.window.searchScope
                let name: String
                switch scope {
                case .all: name = AskPageWords.allConversations
                case .work: name = "Work"
                case .personal: name = "Personal"
                case .folder(let id): name = self.folders.first { $0.id == id }?.name ?? AskPageWords.allConversations
                }
                return (AskScope(search: scope, tokens: self.window.searchTokens, personal: .init(self.personalLock)), name)
            },
            personal: { [weak self] in self.map { .init($0.personalLock) } ?? .locked },
            isPersonal: { [weak self] id in self?.meetings.first { $0.id == id }?.effectivePlacement == .personal },
            isJobRunning: { [weak self] in self?.processor.queue.runningID != nil },
            jobName: { [weak self] in
                guard let self, let id = self.processor.queue.runningID, let meeting = self.meetings.first(where: { $0.id == id }),
                      !self.personalLock.hides(meeting) else { return nil }
                return meeting.title.isEmpty || meeting.title == "Untitled meeting" ? nil : meeting.title
            },
            holdQueue: { [weak self] in self?.processor.holdForAsk() },
            releaseQueue: { [weak self] in self?.processor.releaseAsk() },
            modelName: { [weak self] provenance in
                guard let self else { return nil }
                return provenance?.name ?? self.modelCatalog.name(for: self.summaryModel, provenance: provenance)
            }))
    }

    /// Plays a cited passage without leaving the answer, as a passage on the conversation's page plays.
    func playCitation(_ citation: AskCitation) {
        guard !isRecording, let time = citation.time, let meeting = meetings.first(where: { $0.id == citation.meetingID }),
              !personalLock.hides(meeting) else { return }
        let target: PlaybackTarget
        if let id = citation.segmentID, let segment = meeting.unifiedTranscript.first(where: { $0.id == id }) { target = .segment(segment) }
        else { target = .timeline(time) }
        guard let resolved = target.resolve(in: meeting) else { return }
        Task {
            guard let url = await audioURL(for: resolved.track, meetingID: meeting.id) else { return }
            playback.play(url: url, at: resolved.seconds, trackID: resolved.track.id, meetingID: meeting.id)
        }
    }

    /// Opens a citation's conversation at its passage (`MacSearch.open`'s way), leaving the question open behind it.
    func openCitation(_ citation: AskCitation) {
        window.selection = []
        window.openID = citation.meetingID
        ask.leavePage()
        if let segment = citation.segmentID {
            window.turnPage(to: .transcript)
            window.pageScrollTarget = segment
        } else {
            window.turnPage(to: .summary)
            window.pageScrollTarget = nil
            if citation.kind == .note { window.showOnSummary(SummaryBlockID.notes, in: citation.meetingID) }
        }
    }
}
