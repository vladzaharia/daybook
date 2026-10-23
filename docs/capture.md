# Local audio capture and meeting detection

Daybook records the microphone with `AVAudioEngine` and Mac playback with `ScreenCaptureKit`. The two sources remain separate PCM CAF files so transcription and source fusion can distinguish local speech from remote participants. No video output is registered, and no screen images are written. ScreenCaptureKit still needs a display filter and macOS screen/system-audio permission. The system track includes playback from other apps, excluding Daybook itself.

## App integration

`RecordingController` is main-actor isolated and observable:

```swift
let recorder = RecordingController()
try await recorder.start(in: uniqueStagingDirectory, includeSystemAudio: true)
let result = await recorder.stop()
```

Observe `state`, `startedAt`, `lastError`, and `lastResult`. Keep a visible recording indicator whenever the state is `.starting`, `.recording`, or `.stopping`. Set `onUnexpectedStop` to import preserved partial audio after device changes, capture errors, or sleep. Manual `stop()` returns the finalized result directly. A failed start can still leave a partial result in `lastResult`; do not delete that staging folder. Stopping during startup cancels startup after the current permission/API await finishes.

The caller supplies a fresh directory for each recording. Files use owner-only permissions (`0700` directory, `0600` files). The directory contains:

| File | Purpose |
| --- | --- |
| `capture-session.json` | Session identifier and wall/host clock anchor, saved before recording |
| `microphone.caf`, `systemAudio.caf` | Independent native PCM audio tracks |
| `microphone.json`, `systemAudio.json` | Track timing, format and frame count; saved after first buffer and every ten seconds |
| `capture-result.json` | Final result and any warnings |

Capture JSON uses milliseconds since Unix epoch for dates, retaining fractional-second alignment. Use `CaptureRecovery.recover(in:)` to decode finalized results or recover inactive staging directories after a crash. Recovery reads the actual CAF length because periodic metadata may trail durable audio. It reports approximate timing when a sidecar is missing and preserves unreadable files for inspection. It must never run against a directory still being recorded.

Each `CapturedAudioTrack` has an `offsetSeconds` relative to the shared session anchor. Add it to a transcript segment's track-relative timestamp. The wall-clock `startedAt` and `firstSampleHostTimeSeconds` are retained for additional alignment. A microphone and system track can begin at different times. Gaps over 80 ms and at most five seconds are padded with silence; larger forward jumps or backward jumps over 100 ms stop capture and preserve the partial recording rather than allowing the timeline to drift. Device-clock drift below those bounds remains a limitation of this first implementation; long recordings and device changes need physical-device validation.

Audio is copied off input callbacks and written on serial queues. Each queue allows at most 256 pending buffers. A disk backlog triggers a visible failure and graceful stop instead of unbounded growth. Microphone format changes stop and preserve the current recording. On sleep, the controller attempts to finalize before suspension; crash recovery is still necessary if macOS terminates the process before finalization.

## Permissions and packaging

The application bundle must have `NSMicrophoneUsageDescription`, for example “Daybook records your voice for private, on-device meeting transcripts.” A signed hardened-runtime build needs `com.apple.security.device.audio-input`. The same entitlement is required for sandboxed microphone input. This implementation does not request Camera, Accessibility, Apple Events, or network permission to capture audio.

The first manual system recording requests Screen & System Audio Recording authorization through `SCShareableContent`. The monitor checks authorization without prompting. When the user explicitly enables automatic recording, the app should request authorization with `CGRequestScreenCaptureAccess()` and explain any restart macOS requests. Enabling automatic recording is an app-level opt-in independent of OS authorization. Polling must not enable recording by itself.

## Automatic meeting detection

`MeetingMonitor` exposes `startMonitoring()`, `stopMonitoring()`, `statusText`, `activeCandidate`, `isMeetingActive`, `onMeetingStarted`, and `onMeetingEnded`. Its mutable `rules: [MeetingAppRule]` is the configurable allowlist. Defaults cover Zoom, Teams, Slack huddles, and meeting pages in Chrome, Safari, Firefox, Edge, and Arc. Rules match bundle IDs (including matching helper prefixes) and meeting-specific window-title fragments. They are heuristics, not integrations with private vendor call APIs.

The monitor polls every two seconds. A start requires both a matching meeting window and that allowed app's actual CoreAudio activity, continuously for six seconds. Native apps can start with input or output activity. Browsers must have input activity: playback elsewhere in the same browser with a dormant Meet tab must not trigger recording. Merely running Zoom, playing audio without a meeting window, or opening microphone settings does not satisfy that rule. Playback activity allows a muted native meeting to start. A browser call joined while its microphone device is completely closed may need manual start. Window titles are only inspected locally and are not logged by this module.

A detected native meeting continues while its app has input/output activity or its dedicated meeting window remains present. Browsers require continuing audio-device activity: the title of a tab often remains after a call ends, so a title alone is insufficient to keep a browser recording alive. A 45-second grace period prevents brief mute/device interruptions from splitting a meeting. `suppressCurrentMeeting()` should be called after a manual stop or failed automatic start; it prevents automatic restart until the original app's call evidence has disappeared for 45 seconds. Revoked permission or a failed CoreAudio query ends the monitor's active meeting immediately so the caller can stop an automatic recording.

Known limits: localized/renamed meeting windows, browser helper-process attribution, custom meeting titles, browser calls that completely close audio devices while muted, and multiple calls in one app can defeat the heuristic. Native meeting windows deliberately left open after a call can also delay stopping. Keep manual start/stop readily available, expose the monitor's status, and retain the recording indicator. Live Zoom/Meet/Teams acceptance tests are required before claiming reliable automatic capture across those apps.

## Verification

`Tests/DaybookTests/CaptureTests.swift` checks start/end debounce, inactive apps, native mute, browser tabs after calls, manual suppression, native playback-only starts, prevention of browser playback-only starts, muted-browser continuation, PCM copying, readable audio files, source offsets, gap padding, format-change recovery, backward-clock errors, and crash-recovery frame counts/subsecond dates. These tests synthesize PCM and do not open a microphone, record another app, or grant permissions.

Physical-device acceptance should cover microphone-only and system-plus-microphone recording, headphones versus speakers, Zoom/Meet/Teams joining and leaving, muted joins, minimization, manual suppression, permission denial/revocation, device switching, sleep, forced termination/recovery, and long recordings. Speakers can cause microphone echo of the system track; the downstream fusion layer must account for duplicate speech.

## Apple references

- [ScreenCaptureKit audio configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [CoreAudio process input activity](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput)
- [CoreAudio process output activity](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunningoutput)
- [Window metadata](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))
- [Screen-capture authorization check](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess())
- [Apple's screen and window metadata privacy discussion](https://developer.apple.com/videos/play/wwdc2019/701/)
