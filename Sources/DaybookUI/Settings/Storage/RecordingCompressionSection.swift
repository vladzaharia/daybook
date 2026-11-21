import DaybookCore
import DaybookKit
import SwiftUI

/// Settings › Storage › Compress Older Recordings, on both apps: the library's choice (every device shows the same; only
/// Macs act on it), when this Mac starts while it hasn't yet, and the one line on what can't be undone.
public struct RecordingCompressionSection: View {
    @Binding private var age: RecordingCompressionAge
    private let startsLine: String?

    public init(age: Binding<RecordingCompressionAge>, startsLine: String? = nil) {
        _age = age
        self.startsLine = startsLine
    }

    public var body: some View {
        Section {
            Picker(RecordingCompressionSchedule.label, selection: $age) {
                ForEach(RecordingCompressionSchedule.choices, id: \.self) { Text(RecordingCompressionSchedule.title($0)).tag($0) }
            }
            if let startsLine {
                Text(startsLine).foregroundStyle(.secondary)
            }
        } footer: {
            SettingsFooter(RecordingCompressionSchedule.footer)
        }
    }
}
