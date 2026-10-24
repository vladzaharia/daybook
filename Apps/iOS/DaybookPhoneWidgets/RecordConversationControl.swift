import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen, and the Action button: one toggle that starts and stops
/// recording. Its action runs in the app (an `AudioRecordingIntent`), which starts the Live Activity.
struct RecordConversationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedRecordingState.controlKind, provider: RecordingStateProvider()) { isRecording in
            ControlWidgetToggle(isOn: isRecording, action: ToggleRecordingIntent()) {
                Label("Daybook", systemImage: "waveform")
            } valueLabel: { on in
                Label(on ? "Recording" : "Record", systemImage: on ? "stop.circle.fill" : "record.circle")
            }
            .tint(PhoneStyle.Ink.record)
        }
        .displayName("Record Conversation")
        .description("Start or stop a Daybook recording.")
    }
}

struct RecordingStateProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharedRecordingState.load().isActive
    }
}
