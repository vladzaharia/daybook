import DaybookCore
import DaybookKit
import Foundation

/// Speaker profiles on the Mac (docs/architecture.md, "Speakers and profiles"): names given on any
/// device teach profiles, and profiles label speakers in every conversation, with the voice-matching
/// thresholds from Settings › Models.
extension AppState {
    /// Labels and suggestions use Voice Matching's thresholds, when Match Voices Across Recordings is on.
    var speakerProfileOptions: SpeakerProfileOptions {
        let preferences = processingPreferences
        return SpeakerProfileOptions(matching: SpeakerProfileMatching(labelSimilarity: preferences.speakerMatchThreshold,
                                                                      margin: preferences.speakerMatchMargin),
                                     recognizes: preferences.matchSpeakersAcrossSources)
    }

    /// Conversations being recorded or processed are reconciled when that's done.
    func makeSpeakerProfileCoordinator() -> SpeakerProfileCoordinator {
        SpeakerProfileCoordinator(library: library,
                                  options: { [weak self] in self?.speakerProfileOptions ?? SpeakerProfileOptions(recognizes: false) },
                                  skipping: { [weak self] in Set([self?.processingID, self?.recordingID].compactMap { $0 }) })
    }

    /// Before a conversation is summarized, its speakers are labelled, so the summary has their names.
    func labelSpeakers(before id: UUID) async {
        await library.reconcileSpeakerProfiles(options: speakerProfileOptions, skipping: Set([recordingID].compactMap { $0 }).subtracting([id]))
    }

    /// Whether the speaker model gives voice profiles, itself or through the voice-profile model.
    var makesVoiceProfiles: Bool {
        ModelRouting.makesVoiceProfiles(diarizer: processingPreferences.speakerModelID, selections: modelSelections,
                                        catalog: modelCatalog, engines: runtime.engines)
    }

    var speakerProfiles: [SpeakerProfile] { library.speakerProfiles }
    func confirmSpeakerProfile(_ speakerID: String, in id: UUID) { library.confirmSpeakerProfile(speakerID, in: id) }
    func rejectSpeakerProfile(_ speakerID: String, in id: UUID) { library.rejectSpeakerProfile(speakerID, in: id) }
}
