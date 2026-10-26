# iPhone fixtures from shipped versions

Files exactly as a shipped Daybook wrote them, so `ShippedCaptureJournalTests` catches a field that
today's code renamed, retyped, or made required. The content is synthetic: no real recording,
transcript, or person. XcodeGen copies this folder into the test bundle as it is
(`Apps/iOS/project.yml`, `DaybookPhoneTests`).

## v0.2.2/phone-capture.json

The capture journal of an iPhone recording before photos existed (no `photos` key), as v0.2.2
(`b1ce900`) left it when Daybook was killed after an interruption: the first part (3 s) closed when a
call began at 0:03, recording resumed at 0:05, and the second part was never closed. The tests
supply the two segment files (synthetic tones), so the journal is the only thing taken from v0.2.2.

It was written by v0.2.2's own code, not by hand: a scratch Swift package holding the tag's
`Sources/DaybookCore` (`git archive v0.2.2 Sources/DaybookCore`), its
`Apps/iOS/DaybookPhone/Recording/CaptureJournal.swift`, and the `AudioInputRoute` and
`RecordingFormat` declarations from its `AudioSession.swift` and `AudioInput.swift`, plus this
`main.swift`, run with the output folder as its argument. `journal.write(to:)` is v0.2.2's, so the
encoder (pretty-printed, sorted keys, dates in milliseconds since 1970), the keys, and the absence of
a trailing newline are what that version wrote.

```swift
import DaybookCore
import Foundation

let created = Date(timeIntervalSince1970: 1_792_850_000)
var journal = PhoneCaptureJournal(id: UUID(uuidString: "6B1F2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!, title: "Synthetic standup",
                                  createdAt: created, format: .speech)
journal.startedAt = created.addingTimeInterval(0.25)
journal.hostTimeSeconds = 1_000
journal.continuousTimeSeconds = 1_005
journal.routes = [CaptureRouteEvent(time: 0, input: AudioInputRoute(name: "iPhone Microphone", portType: "MicrophoneBuiltIn"), reason: "start")]
journal.segments = [
    CaptureSegment(index: 0, fileName: "segment-000.m4a", startOffset: 0, frameCount: 144_000, closed: true, firstSampleHostTime: 1_000,
                   clockAnchors: [ClockAnchor(frame: 0, hostTime: 1_000), ClockAnchor(frame: 48_000, hostTime: 1_001),
                                  ClockAnchor(frame: 96_000, hostTime: 1_002)], notes: nil),
    CaptureSegment(index: 1, fileName: "segment-001.m4a", startOffset: 5, frameCount: 96_000, closed: false, firstSampleHostTime: 1_005,
                   clockAnchors: [ClockAnchor(frame: 0, hostTime: 1_005), ClockAnchor(frame: 48_000, hostTime: 1_006)], notes: nil)
]
journal.interruptions = [CaptureInterruption(began: 3, ended: 5, reason: "A call or another app interrupted the recording.", resumed: true)]
journal.state = .recording
journal.notes = "Agenda\nShip on Friday"
journal.timedNotes = [TimedNote(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, time: nil, text: "Agenda"),
                      TimedNote(id: UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!, time: 5.5, text: "Ship on Friday")]
journal.highlights = [Highlight(id: UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!, time: 2),
                      Highlight(id: UUID(uuidString: "12345678-9ABC-4DEF-8123-456789ABCDEF")!, time: 6, text: "Decision")]

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try journal.write(to: folder)
```

SHA-256 of the file: `48a867675f15c3843f99cf889f0069631a0153b6abb8d8f2c250bc05bd1c6261`.
