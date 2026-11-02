import DaybookCore
import Foundation

/// Any recorder that saves audio files: a handheld recorder, a phone's voice memo export, a
/// wearable whose app exports audio. Its only method is a watched folder, which every kind shares,
/// so this integration builds no connections of its own.
public struct OtherRecorderIntegration: DeviceIntegration {
    public static let id = "recorder.files"

    public init() {}

    public let kind = DeviceKind(
        id: Self.id,
        name: "Other Recorder",
        shortName: "recorder",
        vendor: nil,
        // Its own glyph, so it isn't taken for Soundcore Work's tape beside it.
        systemImage: "waveform.and.mic",
        summary: "Any recorder that saves audio files.",
        methods: [
            ConnectionMethod(kind: .files, title: "From a folder",
                             summary: "Save or export recordings to a folder, such as one in iCloud Drive.",
                             systemImage: "folder.badge.gearshape", setupAction: "Choose Folder…")
        ],
        audioSource: .imported,
        allowsMultiple: true,
        emptyHint: "Save a recording to the folder and it appears here."
    )

    public func makeConnection(_ method: ConnectionMethodKind, for device: ConfiguredDevice,
                        environment: DeviceEnvironment) -> (any DeviceConnection)? { nil }
}
