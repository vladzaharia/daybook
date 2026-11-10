import DaybookCaptions
import Foundation

/// Live captions' echo rule. Through the speakers the microphone hears the call too, and echo
/// removal runs only after Stop (docs/capture.md), so the You captioner also captions the other
/// side, a moment after the Call captioner does. Where the output can echo, a You line and a Call line
/// within `LiveCaptionMix.ownWindow` of each other that share most of the shorter one's words are one
/// utterance, which reads from Call (the remote speaker's): the You line shows only words the call
/// didn't have (`LiveCaptionMixer`). With headphones they're kept apart: a You line that repeats the
/// call is then something you said.
enum CaptionEcho {
    /// Whether the microphone can hear the call through `kind`: anything but headphones (Bluetooth of
    /// unknown form factor counts as speakers, which costs nothing when there's no echo).
    static func canEcho(_ kind: AudioOutputRoute.Kind) -> Bool { kind != .headphones }
}
