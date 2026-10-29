import DaybookCore
import DaybookIntelligence
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
        let coordinator = SpeakerProfileCoordinator(library: library,
                                                    options: { [weak self] in self?.speakerProfileOptions ?? SpeakerProfileOptions(recognizes: false) },
                                                    skipping: { [weak self] in Set([self?.processingID, self?.recordingID, self?.voicingID].compactMap { $0 }) })
        coordinator.didRefresh = { [weak self] in self?.giveVoicesWhenIdle() }
        return coordinator
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

    // MARK: Voices for speakers found without them

    /// The model that gives speakers their voices (Settings › Models › Voice Profiles; Community-1
    /// unless another was chosen), when it's on this Mac. Nil otherwise: nothing is downloaded for it.
    var voiceProfileModel: ModelReference? {
        let selections = ModelRouting.withDefaultVoiceEmbedder(modelSelections, catalog: modelCatalog, engines: runtime.engines)
        guard let key = selections[.speakerEmbedding], let model = modelCatalog.model(key), model.serves(.speakerEmbedding),
              model.capabilities.voiceEmbeddings != nil, installedModels.contains(key) else { return nil }
        return ModelReference(key, revision: installedRevisions[key])
    }

    /// The next conversation with speakers found without voice embeddings (`Meeting.runsWithoutVoices`),
    /// newest first, that this Mac can give voices now: its audio is here, and it isn't being recorded,
    /// processed, or waiting to be.
    func nextConversationWithoutVoices() -> (id: UUID, runs: [(track: RecordingTrack, run: TrackTranscript)])? {
        let busy = Set([recordingID, processingID].compactMap { $0 } + queuedIDs)
        for meeting in meetings.sorted(by: { $0.date > $1.date }) where !busy.contains(meeting.id) {
            let runs = meeting.runsWithoutVoices.filter { !voicedRuns.contains($0.run.id) }
            if !runs.isEmpty { return (meeting.id, runs.map { ($0.track, $0.run) }) }
        }
        return nil
    }

    /// Speakers found without voice embeddings (Sortformer runs from before voice profiles, or a
    /// voice-profile model that couldn't run) can't be recognized. While the library has profiles and
    /// this Mac has nothing else to do, they get voices from their saved transcript's turns, one
    /// conversation at a time, newest first (`InferenceProcessingEngine.voices`): the voice step of
    /// Identify Speakers Again without finding the speakers again, so names, identities, the
    /// transcript, and the summary stay. Profiles then label and learn from them as from any other.
    /// Real work comes first: queuing a job stops it, and it starts again when the queue is idle.
    /// Audio that isn't on this Mac is left for later, and nothing is downloaded for it.
    func giveVoicesWhenIdle() {
        guard library.isLoaded, isReady, !library.isApplyingSync, voicingID == nil, processingTask == nil, processingQueue.isEmpty,
              downloadingID == nil, readingPhotoID == nil, recordingID == nil, !isStartingRecording, detectSpeakers,
              !library.speakerProfiles.isEmpty, let model = voiceProfileModel, let next = nextConversationWithoutVoices() else { return }
        let id = next.id
        let configuration = InferenceProcessingEngine.Configuration(
            transcriptionModel: "", summaryModel: "", detectSpeakers: true, speakerModel: "", voiceEmbeddingModel: model,
            speakerOptions: .init(), fingerprint: "voices", speakerMatchThreshold: 0, speakerMatchMargin: 0)
        let engine = InferenceProcessingEngine(inference: sources.inference ?? runtime, configuration: configuration)
        voicingID = id
        voicingTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            var again = true
            defer {
                self.voicingID = nil
                self.voicingTask = nil
                self.runQueue()
                self.startPendingDownload()
                self.readNextPhotosWhenIdle()
                if again { self.giveVoicesWhenIdle() }
            }
            for (track, run) in next.runs {
                guard !Task.isCancelled, let meeting = self.meetings.first(where: { $0.id == id }),
                      meeting.transcripts.contains(where: { $0.id == run.id }) else { return }
                let named = Set(meeting.speakers.filter { meeting.handRename(of: $0.id) != nil }.map(\.id))
                guard let url = try? await self.library.audioURL(for: track, in: id), FileManager.default.fileExists(atPath: url.path) else {
                    self.voicedRuns.insert(run.id)
                    continue
                }
                do {
                    let input = TrackProcessingInput(meetingID: id, track: track, audioURL: url, mode: .speakerRefresh, previousTranscript: run)
                    let analysis = try await engine.voices(input, run: run, protectedSpeakers: named, progress: { _ in })
                    self.voicedRuns.insert(run.id)
                    guard let analysis, let space = analysis.embeddingModelID, !Task.isCancelled else { continue }
                    self.update(id) { $0.giveVoices(analysis.embeddings, space: space, model: model.id) }
                } catch is CancellationError {
                    return
                } catch LocalIntelligenceError.busy {
                    // Another reading holds the models: tried again on the next look.
                    again = false
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.voicedRuns.insert(run.id)
                }
            }
        }
    }

    var speakerProfiles: [SpeakerProfile] { library.speakerProfiles }
    func confirmSpeakerProfile(_ speakerID: String, in id: UUID) { library.confirmSpeakerProfile(speakerID, in: id) }
    func rejectSpeakerProfile(_ speakerID: String, in id: UUID) { library.rejectSpeakerProfile(speakerID, in: id) }
}
