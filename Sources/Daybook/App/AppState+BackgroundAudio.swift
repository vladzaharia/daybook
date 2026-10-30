import DaybookCore
import DaybookKit
import Foundation

/// Background audio (a TV, radio, music) is left out of a conversation's transcript and summary
/// (`BackgroundAudio`); the person can keep it in. The transcript runs always hold every word, so
/// either way is only a new fusion.
extension AppState {
    /// Keeps the conversation's background audio in its transcript, or leaves it out again.
    func includeBackgroundAudio(_ include: Bool, in id: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == id }), (meeting.includesBackgroundAudio == true) != include else { return }
        update(id) { $0.includesBackgroundAudio = include ? true : nil }
        await realign(id)
    }

    // MARK: Recordings transcribed before Daybook listened

    /// Nothing else is running: no job, nothing queued, no download, photo reading, or speakers being
    /// given voices, no sync being applied, and nothing being recorded.
    var mayListenToEarlierRecordings: Bool {
        library.isLoaded && !library.isApplyingSync && processingTask == nil && processingQueue.isEmpty && downloadingID == nil
            && readingPhotoID == nil && voicingID == nil && recordingID == nil && !isStartingRecording && !isStoppingRecording
    }

    /// Recordings transcribed before Daybook listened for music and TV are listened to after other
    /// work: `backgroundListeningDelay` after the last of it, at low priority, one recording at a
    /// time, once each. What the classifier hears is kept on the recording and the conversation is
    /// fused again (`LibraryController.addBackgroundAudio`); nothing is transcribed. The pass stops
    /// when anything else starts, and the next idle moment picks it up.
    func listenToEarlierRecordingsWhenIdle() {
        guard !isListeningToEarlierRecordings, mayListenToEarlierRecordings else { return }
        // Each idle moment starts the wait again.
        backgroundListening?.cancel()
        backgroundListening = Task(priority: .utility) { [weak self, delay = backgroundListeningDelay] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.listenToEarlierRecordings()
        }
    }

    private func listenToEarlierRecordings() async {
        isListeningToEarlierRecordings = true
        defer { isListeningToEarlierRecordings = false; backgroundListening = nil }
        while !Task.isCancelled, mayListenToEarlierRecordings, let next = nextRecordingToListenTo() {
            await listen(to: next.track, in: next.meetingID)
        }
    }

    /// The newest conversation's recording that has no analysis and wasn't tried since Daybook opened.
    /// Paused conversations wait for the person.
    func nextRecordingToListenTo() -> (meetingID: UUID, track: RecordingTrack)? {
        for meeting in meetings.sorted(by: { $0.date > $1.date }) where !pausedIDs.contains(meeting.id) {
            if let track = meeting.recordingsAwaitingBackgroundAudio.first(where: { !listenedRecordings.contains($0.id) }) {
                return (meeting.id, track)
            }
        }
        return nil
    }

    /// One recording. If its conversation was taken meanwhile (a job, a recording, sync), it's tried
    /// at the next idle moment. One that can't be read or classified isn't tried again until Daybook
    /// opens again, and nothing is left out of it.
    private func listen(to track: RecordingTrack, in id: UUID) async {
        let analysis: BackgroundAudioAnalysis?
        do {
            let url = try await library.audioURL(for: track, in: id)
            analysis = try await (sources.inference ?? runtime).classifySound(url: url, progress: { _ in })
        } catch is CancellationError { return }
        catch { analysis = nil }
        guard !Task.isCancelled else { return }
        guard let analysis else { listenedRecordings.insert(track.id); return }
        guard !library.isApplyingSync, processingID != id, !queuedIDs.contains(id), recordingID != id else { return }
        listenedRecordings.insert(track.id)
        await library.addBackgroundAudio(analysis, toTrack: track.id, in: id)
    }
}
