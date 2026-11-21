import Foundation

// The person's own pause (docs/capture.md, "Pausing"): what this Mac captures until Resume is kept as silence. Only a
// recording nothing records along with can pause: an iPhone, a Watch, or a recorder recording with it wouldn't pause
// with it, so it would keep what this Mac left out.
extension AppState {
    /// The recording is paused by the person.
    var isRecordingPaused: Bool { recordingID != nil && (recorder.isPaused || PauseDemo.paused) }

    /// Seconds into the recording when it was paused, for a clock frozen there.
    var recordingPausedAt: TimeInterval? { recordingID != nil ? recorder.pausedAt ?? PauseDemo.pausedAt : nil }

    /// Pause is offered: recording here, not starting or stopping, not paused, and nothing records along with it.
    var canPauseRecording: Bool {
        guard let id = recordingID, !isStartingRecording, !isStoppingRecording, !isRecordingPaused else { return false }
        if PauseDemo.offered { return true }
        return recorder.isRecording && !sources.recorders.hasCompany(id)
    }

    /// Resume is offered: paused, and not stopping.
    var canResumeRecording: Bool { isRecordingPaused && !isStoppingRecording }

    func pauseRecording() {
        guard canPauseRecording else { return }
        recorder.pause()
    }

    func resumeRecording() {
        guard canResumeRecording else { return }
        recorder.resume()
    }

    /// Pause, or Resume while paused (the menus' one item).
    func togglePauseRecording() {
        if isRecordingPaused { resumeRecording() } else { pauseRecording() }
    }
}

/// `--pause-demo offered|paused` with `--simulate-recording` (debug builds): Pause offered, or the recording paused at
/// 12:41, for snapshots of a recording that isn't running. Nothing records.
enum PauseDemo {
    #if DEBUG
    static let value = LaunchOptions.value(after: "--pause-demo")
    #else
    static let value: String? = nil
    #endif
    static var offered: Bool { value == "offered" }
    static var paused: Bool { value == "paused" }
    static var pausedAt: TimeInterval? { paused ? 761 : nil }
}
