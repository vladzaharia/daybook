import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

// Where the person chooses the Mac's microphone (`MicrophoneChoice`; docs/interface.md, "Floating Notes" and
// "Settings"): Floating Notes' phase while recording, "● RECORDING · MacBook Pro Microphone ▾", is a menu of
// Automatic and each input, and Settings › Recording has the same choice as a pop-up. A recording under way moves to
// the new input at once.

/// Automatic, then each input, the choice checked.
struct MicrophoneMenuItems: View {
    let inputs: MicrophoneInputs

    var body: some View {
        Picker(selection: Binding(get: { inputs.preference }, set: { inputs.choose($0) })) {
            Text(MicrophoneChoice.automaticTitle).tag(MicrophoneChoice.Preference.automatic)
            Divider()
            ForEach(inputs.menuDevices) { device in
                Text(device.name).tag(MicrophoneChoice.Preference.device(device))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The recording's phase as the input menu, in Floating Notes' title band.
struct MicrophoneMenu<Label: View>: View {
    let inputs: MicrophoneInputs
    let phase: RecorderPhase
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            MicrophoneMenuItems(inputs: inputs)
        } label: {
            label.daybookHitTarget()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(phase.detailIsWarning ? RecordingStatusWords.microphoneSilentHelp : RecordingStatusWords.inputControlName)
        .accessibilityLabel(phase.title)
        .accessibilityValue([phase.detailIsWarning ? "Microphone silent" : nil, phase.input].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Chooses the microphone")
    }
}

/// Settings › Recording's Microphone pop-up: Automatic, then each input.
struct MicrophoneSettingsRow: View {
    @State private var inputs = MicrophoneInputs()

    var body: some View {
        Picker(RecordingStatusWords.inputControlName, selection: Binding(get: { inputs.preference }, set: { inputs.choose($0) })) {
            Text(MicrophoneChoice.automaticTitle).tag(MicrophoneChoice.Preference.automatic)
            Divider()
            ForEach(inputs.menuDevices) { device in
                Text(device.name).tag(MicrophoneChoice.Preference.device(device))
            }
        }
        .onAppear { inputs.start() }
        .onDisappear { inputs.stop() }
    }
}
