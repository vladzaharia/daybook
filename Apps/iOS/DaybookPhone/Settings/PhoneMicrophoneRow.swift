import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// Settings › Recording › Microphone, named as the Mac's pop-up is: the input recordings use (Automatic, or the one the
/// person chose in the recorder's input picker), and, when the system has refused Daybook the microphone, the way to
/// the system's Settings where it's given.
struct PhoneMicrophoneRow: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: MicrophonePermission = .notAsked
    @State private var preference: MicrophoneChoice.Preference = .automatic

    var body: some View {
        Section {
            LabeledContent(RecordingStatusWords.inputControlName, value: permission == .denied ? "Not Allowed" : SettingsWords.microphoneValue(preference))
            if permission == .denied {
                ProblemLine(text: SettingsWords.microphoneRefused) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        // Allowed or taken away in the system's Settings while Daybook was in the background.
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        permission = model.recorder.microphonePermission
        preference = PhoneMicrophonePreference(defaults: .standard).load()
    }
}
