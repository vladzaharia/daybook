# Call capture, echo removal, and meeting detection

Daybook records a call as two separate tracks on one clock: **You** (the microphone) and
**Them** (the call's audio as the Mac plays it). Keeping them separate is what lets transcripts
say who spoke. Through speakers, though, the microphone also hears the call. Left alone, the
other side's words show up twice, once in each track, and sometimes they're attributed to you.
Daybook fixes this after the recording ends. It uses the call track as the reference and removes
its echo from the microphone, so the microphone track contains only your voice.

```
 microphone ──► microphone.caf ─────────────┐
 (AVAudioEngine, raw, no voice processing)  │  after Stop:
                                            ├─► echo removal ─► microphone.echo-cancelled.caf
 call app ────► systemAudio.caf ────────────┘   (derived track, transcribed instead of the original)
 (process tap on the call app; ScreenCaptureKit as fallback)
```

Code: `Sources/Daybook/Capture/` (capture, devices, finalizing) and `Sources/DaybookCore/Echo/`
(pure DSP: echo canceller, delay estimation, resampling, clock fitting).

## Recording the call: process tap first, ScreenCaptureKit as fallback

`SystemAudioSelector` picks the path when recording starts:

1. **Process tap (preferred).** If the call app is known, Daybook creates a Core Audio process
   tap (`CATapDescription`, `AudioHardwareCreateProcessTap`). The tap covers the app's audio
   processes and helpers, and it runs through a private aggregate device clocked by the current
   output device. Daybook itself is never included. Notifications, music, and other apps aren't
   recorded. The call app comes from `MeetingMonitor.activeCandidate` when automatic detection
   found it. For a manual recording, `CallAppResolver` looks at Core Audio process activity and
   picks it in this order: a native meeting app using the microphone, then a native meeting app
   playing audio, then a browser using the microphone. A browser that's only playing audio
   isn't treated as a call.
   - Helper processes are matched by bundle-ID prefix and case-insensitively. For example,
     `com.google.Chrome.helper` matches Chrome and `company.thebrowser.browser.helper` matches
     Arc. Safari plays audio through `com.apple.WebKit.GPU` and Firefox through
     `org.mozilla.plugincontainer`, so those are included too. A browser tap records the whole
     browser, not just one tab.
   - During the call, the tap does three things:
     - It re-reads the process list every three seconds and adds any new audio helper.
     - It rebuilds its aggregate device when the default output device changes.
     - It runs a silence watchdog (see Permissions).
2. **ScreenCaptureKit (fallback).** This records everything the Mac plays except Daybook. The
   tap isn't used in these cases:
   - no call app is known;
   - process taps aren't available. They need macOS 14.2, and Daybook requires macOS 15, so this
     branch is defensive;
   - creating or starting the tap fails.

   The reason is kept in `SystemAudioCaptureInfo.fallbackReason`. A tap failure never costs
   the recording.
3. **The microphone alone.** When ScreenCaptureKit can't start either and no call app is known
   (a conversation in the room, or a call Daybook can't name), most often because Screen &
   System Audio Recording isn't allowed yet, the microphone records alone. The recording keeps
   one warning, "Computer audio isn’t included. Allow Screen & System Audio Recording in Settings
   › General." (`RecordingController.computerAudioLeftOut`), and Floating Notes says "No call
   audio" with its fix. When a call app *is* known and neither path works, the start fails and
   says why: half a call isn't recorded silently.

If the tap fails *during* a call, `RecordingController` switches the same `systemAudio.caf` to
ScreenCaptureKit and records `switchedAt`. The failure might be a rebuild that didn't work, the
device disappearing, a tap that stays silent through three restarts (When the world misbehaves,
below), or the watchdog (only when that switch needs no new prompt; see Permissions).
ScreenCaptureKit records through the main display (`CGMainDisplayID`), the one that stays when an
external display is unplugged, and a stream that stops on its own or stalls restarts once there. If
it fails again, only the call track stops; the microphone keeps recording and a warning is kept. A
recording ends only when someone stops it, the microphone fails for good, a writer stops moving for
a minute, or the Mac is put to sleep. In every case the audio captured so far is preserved.

The path used is saved in two places:

- `capture-result.json` → `systemAudio` (`process-tap` or `screen-capture-kit`, with
  `capturedApps`, `fallbackReason`, and `switchedAt`);
- each library track's `capture` details (`RecordingTrack.capture.method`, `capturedApps`, and
  `fallbackReason`).

## Permissions: what is asked, and when

| Permission | Asked when | Used for |
|---|---|---|
| Microphone (`NSMicrophoneUsageDescription`) | The first recording, through `AVCaptureDevice.requestAccess` | You |
| System Audio Recording Only (`NSAudioCaptureUsageDescription`) | The first time a process tap starts, so the first recording of a known call app. macOS shows the prompt itself. | The call app's audio |
| Calendars, full access (`NSCalendarsFullAccessUsageDescription`) | Turning on Settings › Recording › Use Calendar, through `EKEventStore.requestFullAccessToEvents` | Naming a call's recording after its meeting, and asking at a meeting's start (Calendar, below) |
| Screen & System Audio Recording (`NSScreenCaptureUsageDescription`) | The first recording that falls back to ScreenCaptureKit, through `SCShareableContent` | All Mac audio. Also needed by `MeetingMonitor` to read window titles for automatic detection. |

Call audio starts before the microphone, so any prompt comes before your voice is being recorded.
Screen & System Audio Recording can't be granted in its prompt: the person allows it in System
Settings, often with a relaunch. So the first recording without a call app goes on with the
microphone alone (above) rather than failing, and Welcome's Allow Recording page asks for both
permissions ahead of time, with the same Allow… buttons as Settings › Recording › Permissions
(`CapturePermissions`, which shares Settings' record that macOS has asked once). Coming back from
System Settings, the page reads both again.

macOS has no public API to check or request the System Audio Recording permission. When it's
denied, a tap still runs but delivers digital silence. So `ProcessTapSource` keeps a watchdog: if
the tap has produced nothing but exact zeros for 45 seconds while the app reports
`kAudioProcessPropertyIsRunningOutput`, it reports `.silent`.

- If Screen & System Audio Recording is already granted (`CGPreflightScreenCaptureAccess()`,
  which never prompts), the controller falls back to ScreenCaptureKit for the rest of the
  recording.
- Otherwise it keeps the tap, which resumes as soon as the app plays sound, and adds a warning
  pointing to the permission. Switching would show a prompt in the middle of a call.

A call that's genuinely silent for 45 seconds (a waiting room, or alone in the meeting) can trip
the watchdog too. That costs isolation, not audio.

Reading Core Audio device and process properties doesn't prompt, and neither does listening for
route changes. The signed app also needs `com.apple.security.device.audio-input`; in the App Sandbox the
microphone needs `com.apple.security.device.microphone` too, and process taps are expected to work with
`audio-input` but haven't been verified sandboxed (docs/sandbox.md). Daybook doesn't
request Camera, Accessibility, Apple Events, or network access to record.

## Staging folder

The caller supplies a fresh directory for each recording. Files are owner-only: the directory is
0700 and files are 0600.

| File | Purpose |
|---|---|
| `capture-session.json` | Session ID, wall-clock and host-clock anchor, and the target call app. Saved before recording starts. |
| `microphone.caf`, `systemAudio.caf` | The originals: independent native PCM tracks, never modified after capture. |
| `microphone.json`, `systemAudio.json` | Track timing, format, frame count, capture method, notes, **clock anchors**, and `gaps` (where the timeline holds no captured audio, and why). Saved after the first buffer, every ten seconds, and at the end. |
| `capture-result.json` | Final result: warnings, call-capture path, output-route events, and later the echo-removal report and derived tracks. |
| `microphone.echo-cancelled.caf` | The microphone with the call's echo removed: 16 kHz mono Float32, written after Stop. |

`CaptureRecovery.recover(in:)` decodes finalized results or salvages inactive staging folders after
a crash. It reads the actual CAF length, because sidecars can trail the audio. It must never run on
a directory that's still being recorded. Clock anchors live in the sidecars, so a recovered
recording still gets drift correction and echo removal.

## Timing, gaps, and clock drift

Every buffer arrives with the host time of its first frame. `CapturedAudioTrack.offsetSeconds`
places a track's first sample relative to the session anchor.

- **Anchors.** About once a second, `PCMTrackWriter` records `(frame, hostTime)` as a
  `ClockAnchor`.
- **Gaps.** Each buffer is compared with the time predicted from the latest anchor, which is at
  most about a second old. Slow drift therefore never looks like a gap. A track never stops for its
  clock (the iPhone's rule, `PhoneTrackWriter`):
  - A real gap of more than 80 ms and up to 5 minutes is padded with silence, and the next anchor is
    marked `resync`. The silence ramps over 5 ms from the last sample written and into the next
    buffer's first, so neither seam clicks; the captured samples themselves are untouched.
  - A gap longer than 5 minutes isn't padded: the next anchor is marked `resync` at the buffer's
    real host time, which starts a new clock segment.
  - A jump of more than 100 ms backward drops the audio that overlaps what's already written (buffer
    after buffer, until the stamps reach the timeline again) and resyncs where it continues.

  Each is kept in the track's `gaps` (`CaptureGap`: `padded`, `lost`, `skipped`, or `overlap`, with
  its frame and seconds), and the capture notes say the total ("3 gaps were filled with silence
  (8.2 s in all).").

  The earlier code compared against the time predicted from the *first* buffer, which caused two
  problems:
  - A device clock running fast against the host clock would hit the −100 ms limit and stop. At
    50 ppm that happens after about 33 minutes.
  - A slow clock got 80 ms of silence spliced in again and again. That also makes an echo path
    jump.
- **Measurement.** `ClockDriftEstimator.fit` fits a line from frames to host time for each run of
  anchors, splitting at resyncs. The second pass drops jittery stamps beyond 3σ, with a 2 ms
  minimum. The result is a `TrackClock`: frames per session second for each segment.
  - Runs shorter than 20 s keep the previous rate.
  - Rates beyond ±1000 ppm are treated as timestamp faults, not drift.
- **Correction.**
  - Echo removal resamples both tracks onto the session clock with their measured clocks. This
    makes the echo path stationary, so the adaptive filter isn't chasing drift.
  - The derived track is written on the session clock, so its `clockRate` is 1.
  - For the originals, the measured rate is recorded as `RecordingTrack.capture.clockRate`. It's
    session seconds per track second, with the same convention as `TrackAlignment.rate`:
    `meetingTime = offset + trackTime × clockRate`.

  Fusion applies it: a track this Mac recorded, and not otherwise placed, goes to `TranscriptFusion`
  as a placement with its measured rate (`SourceFusion`).

## Device and route changes

- **Microphone.** `MicrophoneSource` restarts its AVAudioEngine tap on the new input when
  `AVAudioEngineConfigurationChange` fires. That happens when AirPods connect, or when they switch
  to the hands-free profile because an app opened their microphone. `PCMTrackWriter` converts the
  new format to the file's original format with `AVAudioConverter`. It drains the converter's
  look-ahead at every switch and at the end, so no frames are lost. It also pads the switch gap
  and starts a new clock segment. Restarts are limited by rate, not count: more than 10 in a minute
  is a microphone that won't settle, and ends the recording, so AirPods coming and going all day
  never do. A start that fails (a new device reporting 0 Hz for a moment) is tried again after 0.25,
  0.5, 1, and 2 s, then on the Mac's built-in microphone (`AVMicrophoneEngine.builtInInput`), before
  the microphone counts as failed. Each start is a fresh `AVAudioEngine` (behind `MicrophoneEngine`,
  which tests replace).
- **Output route.** `AudioRouteMonitor` records the default output device: once at start, then at
  every device or data-source change. Data-source changes cover a headphone jack being plugged
  in. The events go in `capture-result.json` as `outputRoutes`.

  The route is one of these:
  - `speakers`: built-in speakers, HDMI, DisplayPort, or AirPlay;
  - `headphones`: the built-in jack's `hdpn` source, or a Bluetooth or USB device named like
    AirPods, earbuds, headphones, or a headset;
  - `bluetooth`: the form factor is unknown;
  - `external`;
  - `unknown`.

  Daybook doesn't use Bluetooth APIs to identify the form factor.
- **Call tap.** The tap rebuilds its aggregate device on the new output device. The writer pads
  the short gap and resyncs.

## When the world misbehaves

A recorder's first duty is to keep the audio, so recoverable trouble never ends a recording, and
trouble that loses sound is said where the person is looking. The controller's 15 Hz meter timer
(`updateLevels`) does the watching.

- **A busy disk.** Each writer holds up to 30 s of audio (`PCMTrackWriter.defaultBacklog`, counted
  in seconds, not buffers) while its queue waits on the disk. Past that a buffer is dropped and
  counted, and the gap code pads the hole once writing catches up, as a `lost` gap; the track's
  notes and the conversation say it: "2.4 s of call audio were lost while the disk was busy."
  (`RecordingWords.lostAudio`). Only a writer with audio waiting that hasn't finished any for 60 s
  (`CaptureWriting.stallLimit`) stops: the microphone's ends the recording ("The disk couldn't keep
  up…"), the call's stops only the call. A write that fails is the same: a call-track problem never
  stops the microphone.
- **A source that stops delivering.** No buffer for 3 s while recording restarts that source
  (`CaptureAudioSource.restart`): the microphone's engine, the tap rebuilt on the current output, or
  ScreenCaptureKit once on the main display. Each restart gets its own 3 s. A call source still
  silent after three restarts has failed: a tap falls back to ScreenCaptureKit (when that needs no new
  prompt; otherwise only the call stops), and ScreenCaptureKit's call track ends. The microphone is
  restarted for as long as it's silent, within its rate limit. Audio arriving starts the count over.
- **The audio system restarting.** A `kAudioHardwarePropertyServiceRestarted` listener
  (`AudioServiceRestartMonitor`) hears coreaudiod restart (a crash, `killall coreaudiod`); every
  device, tap, and aggregate is new afterwards, so both sources start again. The conversation says
  "The microphone stopped for a moment and was restarted, leaving a short gap." rather than that the
  microphone changed.
- **Hearing.** The microphone isn't hearing when no non-zero sample arrived in the last 5 s, or
  nothing above −90 dBFS for 20 s (`CaptureLevelMonitor.isNotHearing`). It's rolling, so a
  microphone that goes to digital zeros partway (a MacBook lid closed in clamshell mode, a mute
  switch, a dead interface) is said too, and it clears as soon as it hears again. Floating Notes says
  "Microphone silent" (the iPhone's words), and a notification goes out while Daybook isn't in front.
- **Space.** Every 30 s the free space (`volumeAvailableCapacityForImportantUsage`) is divided by the
  recording's byte rate (2.3 GB an hour for a typical call). Under 30 minutes, Floating Notes shows
  "Low on space" and a notification goes out while Daybook is behind; under 3 minutes, call audio
  stops (two thirds of the bytes) so the microphone has what's left, and the room is measured again
  at its rate.
- **Sleep.** While recording, Daybook holds an idle-sleep assertion (`SleepAssertion`,
  `.idleSystemSleepDisabled` with `.userInitiated`), so a long call on battery never idles the Mac to
  sleep. A forced sleep (the lid, the Apple menu) still stops this Mac's tracks
  (`RecordingController.stoppedForSleep`), but the recorders and iPhones recording along keep going
  (docs/multipoint.md). After wake, Floating Notes says "Soundcore Work and Alex's iPhone kept
  recording." with Stop.

## Echo removal

Echo removal runs in `CaptureFinalizer.finalize`. It's called from `AppState.ingestCapture` on a
detached task, after Stop and before import and transcription, and also during crash recovery. It
reads both originals with `AudioFileSampleSource` (read-only) and writes a temporary file. The
temporary file is renamed to `microphone.echo-cancelled.caf` only when processing succeeded. The
report goes into `capture-result.json`, so running finalize again reuses it.

`EchoRemover`, in DaybookCore, makes two passes at 16 kHz on the session timeline:

1. **Analysis.**
   - Both tracks are resampled with drift correction.
   - Channels are mixed to mono. For the microphone, channels more than 30 dB below the loudest
     are ignored.
   - Call activity is measured per 20 ms.
   - The echo delay is measured by GCC-PHAT between the call and the microphone. It uses
     1.024 s frames where the call is audible, a 200 Hz–4 kHz band, and a search range of −0.25 s
     to +0.8 s. It's measured globally and in 30 s windows.
   - Confidence is the peak's height above the correlation's background, in standard deviations.
     Echo-free pairs score about 4–5. The threshold is 9.
   - If confident windows disagree by more than 12 ms (for example, a Bluetooth speaker joining
     mid-call), the recording is split into segments with their own delay, each starting a fresh
     filter.
2. **Cancellation.**
   - For each segment, the reference is shifted by the delay minus a 32 ms margin.
   - `EchoCanceller` first converges on up to 30 s of the segment, then processes the segment
     from its start with that filter. Offline, the opening greetings are cleaned as well as the
     rest.

`EchoCanceller` is a partitioned-block frequency-domain adaptive filter: an MDF/PBFDAF, using
vDSP throughout.

- **Filter.** 256-sample blocks with a 512-point FFT and overlap-save, in 16 partitions. That
  gives a 256 ms echo tail after the bulk delay. The gradient is constrained on every partition.
- **Two filters.**
  - A *background* filter always adapts.
  - The *foreground* filter produces the output. It copies the background only when the
    background is significantly better, with a cross-fade.
  - If the background diverges, it's reset from the foreground.
- **Learning rate.**
  - The rate is set per frequency bin from the estimated residual-echo-to-error ratio (Valin's
    MDF). The leak estimate is a regression of error-power fluctuations on echo-estimate power
    fluctuations.
  - When you talk over the call, the error is dominated by your voice, so the rate collapses
    and the filter doesn't learn your voice.
  - When the room changes, leakage rises and the filter re-converges.
  - Proportionate per-partition rates speed up convergence for sparse room responses.
- **Double-talk detector.** A block is double talk when the call is active and the error is more
  than four times the predicted residual echo plus the noise floor. It's tracked with minimum
  statistics. Before convergence, the test is "the microphone is louder than the reference".
- **Residual echo suppressor.**
  - It works on the same frames, using sqrt-Hann analysis and synthesis with 16 ms latency, which
    is compensated.
  - The residual-echo estimate is leakage × the removed echo's spectrum, plus a decaying reverb
    tail (150 ms).
  - The gain is a decision-directed Wiener gain.
  - The floor is −40 dB on call-only stretches. During double talk the floor is −12 dB and
    there's no over-subtraction, so your speech survives.
- A high-pass at 80 Hz is applied first. Clipping (|x| ≥ 32 000 of 32 768) pauses adaptation for
  one filter length.

**When the work is skipped**

The skip is recorded as `EchoRemovalReport.skipReason`, with a readable `detail`:

| Reason | When |
|---|---|
| `noCallTrack` | No call audio was recorded. |
| `callSilent` | Less than 2 s of the call was above −55 dBFS. |
| `microphoneSilent` | The microphone was all zeros. |
| `noEchoDetected` | GCC-PHAT found no confident echo: headphones, a muted speaker, or very low volume. |
| `headphones` | The output route was headphones for the whole recording *and* no echo was measured. If headphones were reported but the call leaked into the microphone anyway (open-back headphones at volume), echo is removed and `detail` says so. |

A failure, such as an unreadable file, is reported as `outcome: failed`. The original
microphone is then transcribed, and the warning is shown.

**What the report contains.** `EchoRemovalReport` also records:

- the delay, its confidence, and the per-segment delays;
- microphone and call drift in ppm;
- ERLE on converged call-only blocks;
- the double-talk fraction;
- seconds of call activity.

It's stored on the microphone original and on its derived track as `capture.echoRemoval`.

### Derived track and transcription

`AppState.ingestCapture` imports the originals as before, then imports the cleaned file as a
second `.microphone` track with these fields:

- `derivedFrom` set to the original microphone track's ID;
- `processing = "echo-cancelled"`;
- `offset` equal to the microphone's drift-corrected first-sample time;
- `capture.method = "echo-cancelled"`.

The original stays in the library byte for byte, with the same SHA-256. `Meeting.transcribableTracks`
(DaybookCore) leaves out any track that another track was derived from. `AppState.process`, `enqueue`,
`defaultProcessingMode`, and sync's "new audio" check use it, so the cleaned microphone is
transcribed *instead of* the original. `Meeting.hasUntranscribedTranscribableAudio` is the
matching predicate.

### Why not Apple voice processing

Daybook never calls `setVoiceProcessingEnabled` on the capture engine:

- **Ducking.** Voice processing ducks other audio by default, which lowers the call the person is
  listening to. `voiceProcessingOtherAudioDuckingConfiguration` can reduce this but not remove it.
- **Wrong echo reference.** Its canceller uses the engine's own output path as the reference. That
  path isn't the call track Daybook records, so neither Daybook nor a test can inspect it or
  replay it.
- **Changes the original.** It applies automatic gain control and noise suppression to the only
  copy of the microphone. That would break the rule that originals are kept as captured.
- **Conflicts with the call app.** It can interfere with the call app's own voice processing on
  the same device. It also changes the input format and channel count.

The offline canceller works from exactly the audio that was recorded. It's deterministic and
repeatable, and if processing improves, the original can be cleaned again. If a future live
preview wants voice processing, it should run on a separate engine. That engine should set the
ducking configuration to `.min` with advanced ducking off, and it must never feed the recorded
original.

## App integration

`RecordingController` is main-actor isolated and `@Observable`:

```swift
let recorder = RecordingController()                      // CaptureEnvironment.live
try await recorder.start(in: uniqueStagingDirectory, includeSystemAudio: true,
                         callApp: CallAppTarget(candidate))  // nil → all Mac audio
let result = await recorder.stop()                        // capture only; finalize separately
let finalized = CaptureFinalizer.finalize(result!)        // off the main actor
```

Observe these:

- `state`, `startedAt`, `lastError`, and `lastResult`;
- `systemAudioCapture`: how the call is being recorded, and why;
- `outputRoute`;
- `isCallAudioDetected`.

Keep a visible recording indicator whenever the state is `.starting`, `.recording`, or
`.stopping`.

Set `onUnexpectedStop` to import partial audio after a microphone failure, a writer that stopped
moving for a minute, or sleep. A failed start can still leave a partial result in `lastResult`; don't delete that staging
folder. With nothing recorded, `AppState` takes back a conversation it made for the recording (to the
Trash, the library's only way out) and leaves one it recorded into as it was; the alert says why, with
Open System Settings when a permission is the reason. The hook gets the partial result and one sentence saying why it stopped (the recorder's
own when the cause is one of Daybook's, else `unexpectedStopSentence`). `lastError` keeps that
sentence even when the recording's details then can't be saved, as on a full disk, where the
track and `capture-result.json` fail together. `AppState` keeps the sentence for the conversation
(`unexpectedStops`) until the person has seen it (`dismissUnexpectedStop`).

Quitting while recording asks first, as QuickTime does: "Stop recording and quit?" with Stop and Quit
or Cancel. Logging out, restarting, or shutting down stops it without asking; the quit event says which
(its `kAEQuitReason`, read for each request, so a logout another app called off leaves nothing behind).
Quit then stops the recording, waits up to 5 s for recorders and iPhones that recorded along, saves, and
only then quits (`DaybookDelegate`, `QuitDecision`):

- An ordinary quit (the menu, ⌘Q, the Dock) is turned down (`.terminateCancel`) while that work runs, and
  asked again from the run loop once it's done, when it goes ahead. A second ⌘Q or the Dock's Quit
  meanwhile reaches the delegate and is turned down too. AppKit doesn't ask the delegate again while an
  answer is pending (`.terminateLater`): it quits at once, so a pending answer would let a second quit cut
  the stop and save short.
- A logout, restart, or shutdown is answered later (`.terminateLater`), since turning it down would stop
  it; one that comes during an ordinary quit's work waits for that work.
- Code that quits from a main-actor task calls `NSApp.terminateFromRunLoop()`. A task runs as a main-queue
  job, and `terminate(_:)` called there holds the main queue while the quit's work waits to run on it.

`CaptureEnvironment` injects the following:

- microphone permission;
- the microphone source;
- the system-audio provider;
- the current route and route observation;
- the host clock;
- free space, the idle-sleep assertion, and the audio system's restarts;
- how writers buffer (`CaptureWriting`: the backlog, the stall limit, and a hook before each write).

Tests drive the controller with fakes, so no device, tap, or stream is opened. `AppState` takes
the same fakes (`capture:`).

### Live levels, for the recording UI

| API | Type | Meaning |
|---|---|---|
| `recorder.levels.microphone` | `CaptureLevelMonitor.Level` | "You": `rms` (smoothed over 300 ms) and `peak` (held for a second) in dBFS, so a tap's 10 ms buffers and the microphone's 85 ms ones move alike. `meterValue` maps −60…0 dBFS to 0…1. |
| `recorder.levels.call` | same | "Call", with the same fields. |
| `recorder.levels.isCallAudioDetected` | `Bool` | The call track was above −50 dBFS within the last 4 s. |
| `recorder.isCallAudioDetected` | `Bool` | The same signal on the controller. It changes rarely, so any view may read it. |
| `recorder.levels.isMicrophoneSilent` | `Bool` | The microphone isn't hearing: no non-zero sample in the last 5 s, or nothing above −90 dBFS for 20 s. Rolling: it clears when it hears again. |
| `recorder.levels.isCapturingCall` | `Bool` | Call audio is part of this recording. It's false after the call track stops. |
| `recorder.spaceLeft` | `TimeInterval?` | Seconds of recording the disk has room for at the current rate, once that's under 30 minutes. |
| `recorder.callStoppedForSpace` | `Bool` | Call audio stopped to leave the disk's last minutes to the microphone. |

Floating Notes meters every source a recording has, not only these two (docs/interface.md, "Meters"): a
recorder recording along from the live audio it saves into the recording (`LiveCapture.level(at:)`, the
latest buffer's level, current for a second after it arrived, through `DeviceSession.liveLevel(into:)`),
and a paired iPhone from the levels it sends over the link (`LinkLevels`; docs/link.md).

`CaptureLevelMonitor` updates 15 times a second and changes its levels only by at least 0.5 dB. Only a
meter reads `microphone` and `call`: a view that read them would redraw 15 times a second, so Floating Notes
samples them on its own timer (DaybookUI's `RecorderLevels`) and its status bar reads only the flags, which change rarely.

## Live captions

While the Mac records, tentative captions show that both sources are being heard and give
something to read until the transcript exists. They come from the same engine as every other live
caption in Daybook, `DaybookCaptions` (`SpeechAnalyzer` with `SpeechTranscriber`, volatile and fast
results; docs/iphone.md, "One live-caption engine"), or, when the live models are downloaded
(Settings › Models › Live transcription and Live speakers), from local models: streaming
transcription on any macOS, speakers, and names for voices that match the library's voice profiles
(`MacLiveModels`; docs/model-runtime.md, "Live"). They are never the transcript: they stay on this
Mac, aren't synced, fused, summarized, or used as evidence, and the transcript replaces them.

Code: `Sources/Daybook/Captions/` (the Mac's controller, echo rule, and settings), DaybookCaptions'
`LiveCaptionSession` and `LiveCaptionStore` (what a recording's captions do on both apps), DaybookUI's
`Captions/` (the strip's lines, saved captions, Settings' section), and `Capture/CaptureCaptionTap.swift`.

```
 microphone ──► microphone writer ──► microphone.caf
            └─► tap ──► You captioner ──┐
 call app ────► call writer ──► systemAudio.caf      ├─► echo rule ─► Floating Notes, the conversation page,
            └─► tap ──► Call captioner ─┘                           <library>/LiveCaptions/<meeting id>.json
```

- **Two captioners.** `LiveCaptionsController.prepare(meetingID:includesCall:)` makes one captioner
  for You (the microphone) and, when computer audio is on, one for Call, and returns a
  `CaptureCaptionTap`. `RecordingController.captionTap` hands each source's buffers to its
  captioner beside its writer, the same copied buffers, with seconds since the recording started
  (`onSessionTimeline`), so both share the recording's timeline. The captioners count from the
  recording's start (`SpeechCaptioner(timelineOrigin: 0)`), so audio dropped while the recognizer
  starts never shifts later captions. The ScreenCaptureKit switch mid-call keeps feeding Call.
- **Never in the recording's way.** A tap handler only appends (cheap, callable on the audio
  thread). Each captioner runs on its own tasks with a bounded backlog (about ten seconds: 128 of
  the microphone's ~85 ms buffers, 1,024 of the call's ~10 ms IO cycles) and drops the oldest audio
  when it falls behind. A captioner that can't start or fails changes only its own state; the other
  source keeps captioning and the recording is untouched. Captions start after the recorder is
  running and finish after Stop on their own task; nothing in starting, stopping, or importing waits
  for them.
- **Echo.** Through the speakers the microphone hears the call too, and echo removal runs only
  after Stop, so the You captioner also captions the other side a moment after Call does.
  `CaptionEcho` leaves out a You line when at least 60% of its words appear, in order, in the Call
  lines within 2 seconds of it (words folded for case, accents, and apostrophes). It applies wherever
  the output route at that moment isn't `headphones` (`AudioRouteMonitor`; Bluetooth of unknown form
  factor counts as speakers, which costs nothing when there's no echo). With headphones both
  sources show in full, so a line you repeat is kept. Route changes mid-recording apply from their
  time on. Verdicts are recomputed while lines are fresh and kept once they're 30 seconds old.
- **Every source.** Live captions cover every source a recording has, not only this Mac's:
  - **You and Call** with the live models, each its own captioner over models loaded once
    (`LiveModelHost`): checked with the real models on this Mac, both captioning at once
    (docs/validation.md). With computer audio off ("Include computer audio" in Settings › Recording)
    there's no Call track and no Call captions; that's the setting, not the captions.
  - **A recorder recording along** (Soundcore Work through `DeviceSession.captureLive`): its live
    audio is captioned as Listen Live is, and `LiveCaptureCaptions` hands each recorder's lines to the
    recording's captions with when its recording began (its live audio starts there), so they move onto
    this Mac's timeline (lines from before this Mac started are left out).
  - **A paired iPhone recording the same conversation**: the phone sends the captions it makes (its
    microphone's, and its recorder's) over the local link, a second at a time, only the lines that
    changed (`LinkCaptions`, to a Mac listing `liveCaptions`; docs/link.md). Its recording's start,
    mapped through the link's clock estimate, places them. The Mac never receives the phone's audio
    while it records, so it can't caption it itself.

  Other devices' lines join by time (`LiveCaptionMix`), each tagged with its source
  (`LiveCaptionSource.device`). Several devices in one room hear the same speech: a line another
  device captioned that repeats, in order, at least 60% of the words of one already shown within 4
  seconds is left out, so the room reads once; this Mac's own lines come first. Labels: You and Call
  keep the time lane in Floating Notes; another device's line names the person live speakers
  recognized before its words, else the device ("Soundcore", "iPhone"); the conversation page reads
  them as turns labelled the same way. The devices' names are saved with the captions
  (`LiveCaptions.sourceNames`).
- **Storage.** `LiveCaptionStore` (DaybookCaptions, the iPhone's too) keeps
  `<library>/LiveCaptions/<meeting id>.json` (directory 0700, file 0600, protected until first
  unlock): one `LiveCaptions` with You and Call as segments tagged `source` (`.microphone`, `.call`),
  saved every 10 seconds while listening and at Stop (what stood then is kept as heard), on the
  store's own queue, never the main thread, with a save still on its way never putting back what a
  later one replaced. It's outside `Meetings/`, so sync never reads it. One rule on both apps:
  captions are replaced by any transcript made after they began (`LiveCaptionStore.isReplaced`), and
  then deleted, as are captions of conversations moved to the Trash (`prune`, off the main thread, a
  second after a transcript or the set of conversations changes; typing notes never prunes). A Mac
  conversation exists from the moment it's recorded, so captions of one the library doesn't have are
  gone; an iPhone recording joins the library only once it's filed, so the iPhone passes its Trash
  (`trashed`) and keeps captions of a recording stopped a moment ago or left by a crash for recovery.
- **Where they show.** Every live caption on both apps is one renderer, `LiveCaptionStrip`
  (DaybookDesign), in a style per surface: "LIVE CAPTIONS · TENTATIVE" on top, the newest line in
  Body ink, earlier ones in Secondary, still-revised words in Meta, and "Listening…" before anything
  is heard. Floating Notes, while recording: a fixed-height strip above Bookmark and Stop (`.panel`)
  with the newest two lines, the newest larger and keeping its latest words; the source (You or
  Call) sits in the time lane, so arriving words never move the notes. Compact, it shows the newest
  line only, without the label (`.panelCompact`). The conversation page, after your notes: the newest
  eight lines while this Mac records it, You or Call before the words. A recorder's Listen Live page:
  six lines in the page's body type (`.feed`). Each surface observes the captions directly, so a
  revised word redraws only it.
- **Saved captions.** Once the recording stops, both apps show saved captions by one rule
  (`SavedCaptions.shown`, DaybookUI): a conversation's own, with words to read, until a transcript
  made after they began replaces them. They read on the transcript's page: in the transcript's place
  while there's none, with the Transcript switch (⌘2) on, else after the transcript (one from an
  earlier recording of the conversation, which doesn't cover them; `SavedCaptions.standsIn`). Both
  draw them with DaybookUI's `SavedCaptionsView`: each caption with its time, which plays the
  recording it was heard from and marks the caption under the playhead, the person or device before
  its words, in lighter ink than a transcript, with no editing. Search finds them in conversations
  nothing else matched, labelled "Live captions · tentative" with the caption's time, and opens the
  transcript's page at the caption. The Mac reads them off the main actor once they're saved and
  after pruning (`LiveCaptionsController.readSaved`), and not while it records the conversation,
  when the conversation page shows them live.
- **Settings › Recording › Live Captions.** DaybookUI's `LiveCaptionSettingsSection`, the iPhone's
  too: "Show while recording" (on by default, as on the iPhone) and the language ("Same as This Mac",
  any `SpeechTranscriber` locale, and those only the downloaded live recognizers cover,
  `LiveModelSet.languages`: the Latin model's six, the multilingual model's 35; on macOS 15 only
  those), with a footer, only while captions are on, that says whether the language downloads the
  first time (never asking triggers a download), or, on macOS 15, that live transcription doesn't
  cover the chosen language; none when a downloaded recognizer covers it. A language chosen before
  its model was removed stays chosen and listed, so the choice still reads, and captions return when
  a model covers it again (`LiveCaptionLanguages`, DaybookCaptions). It's in General, beside the other recording choices, rather than Models: captions use
  the system's speech assets, which Daybook doesn't download or manage, and they never feed the
  transcript that the Models pane is about. The same setting and language apply to a recorder's
  Listen Live.
- **Availability.** The Speech framework's captions need macOS 26. On macOS 15 captions run only
  from downloaded live models, in the languages they cover; without them (or in another language) no
  captioner is made, no tap is installed, nothing is shown, and Settings says why.
  `--captions-as-macos-15` (debug) acts as macOS 15 for screenshots. A real recording may download the language from Apple
  (system-managed `AssetInventory`) and, if the analyzer fails before any result while
  speech-recognition authorization is undetermined, ask once (`NSSpeechRecognitionUsageDescription`).
  Tests, demos, and the device simulator never do either.
- **Checking without a microphone.** `--simulate-recording "<title>" --demo-captions` scripts You
  and Call talking over one another on speakers (the microphone's echo of the call is left out);
  add `--snapshot <dir>` to capture Floating Notes and the page.

## Calls

**When a call starts** (Settings › Recording, and the menu bar extra) is Off, **Ask** (a new
installation's), or Record Automatically (`CallRecordingPolicy`). The old Record calls automatically
switch becomes Record Automatically when it was on and Ask when it was off, and Daybook still writes
it, on only for Record Automatically, for an older version to read (`CallPolicy.stored`, `save`). An
app can have an answer of its own ahead of it (`CallAppChoice`: Ask, Always Record, Never), chosen in
the call prompt's menu and changed or removed under Settings › Recording › Apps. Off is off whatever
an app's answer. `CallPolicy.decision` is the whole rule, and nothing is decided while a recording is
being made or started.

**The call prompt** (`CallPromptWindow`, `CallPrompt.swift`), for Ask: a small panel in the
top-trailing corner of where Floating Notes opens, non-activating, floating over a full-screen call
on every Space and kept out of screen shares, as Floating Notes is. It shows the app's icon, the call
("Zoom call") and its meeting window's title, Record and Not Now, and in its menu Always Record Zoom
Calls and Never for Zoom. VoiceOver announces it. A hairline along its foot drains over 15 seconds and
holds while the pointer is over it; no answer by then is Not Now. **Record** starts the recording, as
one started for the call (it stops when the call ends), and the panel grows into Floating Notes'
frame as Floating Notes takes its place (a fade under Reduce Motion, or when Floating Notes doesn't
show while recording). Not Now, Never, and a call that ends before an answer leave the call alone
until it ends (`suppressCurrentMeeting`).

**Ending a recording the person started.** A call ending during a recording someone started
themselves never stops it: the prompt asks "The Zoom call ended · Stop recording?", with Keep
Recording and Stop, and after 30 seconds without an answer the recording goes on. The question goes if the recording stops
some other way first, and its Stop only ever stops the recording it asked about. A recording the
call started (Record Automatically, Always Record, or Record in the prompt) stops 45 seconds after the
call ends, as before.

**Under test** the app's own monitor never starts (`MacCaptioners.isRunningTests`): an `AppState` in
a test must not read this Mac's audio server or ask about a call the developer is on. The monitor's
tests drive it with scripted looks.

## Calendar

**Use Calendar** (Settings › Recording, under When a call starts; off by default, and unavailable while
When a call starts is Off) reads the calendars on this Mac through EventKit (`MeetingCalendar.swift`).
Turning it on asks for full access to events; without it, the switch stays off and the page says so,
with Open System Settings… (Privacy & Security › Calendars). Events are read on this Mac and never
leave it. Only a meeting's title is kept, as its conversation's title, as a typed one would be.

- **A call takes its meeting's name.** When a call starts, `CalendarMeetings.current` picks the
  meeting it belongs to: one going on, or starting within 10 minutes, that the person hasn't declined,
  that isn't all day, and that has a title. One whose link (from its URL, location, or notes) is on the call's service
  comes first (a Zoom call and the event with a zoom.us link), then the one that started closest to
  now. The prompt shows "Weekly product sync · 4 people" under "Zoom call", and the recording, by
  whichever answer, is named after the meeting.
- **A meeting with other people asks as it starts.** A meeting with two or more people invited,
  starting from 30 seconds ahead to two minutes late, asks "Weekly product sync · Starting now ·
  4 people" with the calendar's icon, once per occurrence (`CalendarMeetings.startingNow`). That
  catches a meeting in a room, which no call announces. It's only asked while nothing is recording,
  no call is under way (nor one the person said not to record), and the prompt isn't asking something
  else, and never about a meeting whose call was already asked about or answered by its app's choice. A meeting is always asked about,
  never recorded on its own, and Record Automatically doesn't change that. Unanswered is Not Now.
- **Once it's over** (its end time, while the recording it started still goes on), the prompt asks
  "Weekly product sync ended · Stop recording?" once, and keeps recording without an answer.

`AppState.checkCalendar(at:)` is the whole of it, called every 30 seconds while Use Calendar is on
and never under XCTest. Tests stand in their own calendar (`MeetingCalendarReading`). The calendars
entitlement (`com.apple.security.personal-information.calendars`) is in all three entitlements files,
since the hardened runtime needs it as much as the App Sandbox does.

## Automatic meeting detection

`MeetingMonitor` exposes:

- `startMonitoring()` and `stopMonitoring()`;
- `statusText`, `activeCandidate`, and `isMeetingActive`;
- `onMeetingStarted`, which answers what became of the call (`CallResponse`: being recorded, being
  asked about, or not recorded, which pauses the monitor until the call ends), and `onMeetingEnded`,
  which hears which call ended; `callRecordingStarted()` when a call asked about starts recording.

Its mutable `rules: [MeetingAppRule]` property is the configurable allowlist. The defaults cover
Zoom, Teams (and classic Teams), Slack huddles, Webex, GoTo Meeting, Chime, FaceTime, Discord,
WhatsApp, Signal, and meeting pages in Safari, Chrome, Firefox, Edge, Arc, Dia, Brave, Vivaldi,
Opera, and Orion. Rules match bundle IDs and meeting-specific window-title fragments. An app's audio
is the processes its call would be tapped from (`CallAppTarget.owns`: helpers by prefix,
case-insensitively, Teams' `com.microsoft.vcxpc`, and WebKit's audio processes for Safari and
Orion), so detection and the tap agree on which app is in a call. Orion shares WebKit's GPU process
with Safari, so it's a candidate only with a meeting window of its own (`sharesAudioProcess`). They're
heuristics, not integrations with private vendor call APIs.

**Looking.** Every two seconds the monitor looks at the Mac off the main actor
(`MeetingActivityReader.read`, through `detachedWork`), and only the answer comes back to the
main actor's state machine, so a Mac with hundreds of windows never stalls Daybook's window. One
look reads the audio server's process list once (`AudioProcessCatalog`, the list the tap uses, with
`isRunningInput` and `isRunningOutput`) and, when Screen & System Audio Recording lets titles be
read, the window list once: titled windows in the normal layer, on every Space, each app's bundle
ID looked up once however many windows it has. The loop is a task that `stopMonitoring()` cancels;
a look that finishes after that is dropped.

**Starting.** A start needs two things, continuously for six seconds: a matching meeting window,
and Core Audio activity from that allowed app. FaceTime, Discord, WhatsApp, and Signal have their
window open all along, so a window can't say a call there: they start on the app's microphone alone,
and continue only on its audio (`MeetingAppRule.needsMeetingWindow`).

- Native apps can start with input or output activity. Playback activity lets a muted native
  meeting start.
- Browsers must have input activity. Playback elsewhere in the browser beside a dormant Meet tab
  mustn't start a recording.
- These don't satisfy the rule: merely running Zoom, playing audio without a meeting window, or
  opening microphone settings.
- A browser call joined while its microphone device is completely closed may need a manual start.

Window titles are only inspected locally, and this module doesn't log them. The detected
candidate becomes the process-tap target.

**Continuing.**

- A detected native meeting continues while its app has input or output activity, or while its
  meeting window remains open.
- Browsers need continuing audio-device activity: a tab's title often stays after a call ends.
- A 45-second grace period keeps brief mute or device interruptions from splitting a meeting.

**Stopping.**

- `suppressCurrentMeeting()` should be called after a manual stop or a failed automatic start. It
  prevents an automatic restart until the original app's call evidence has been gone for
  45 seconds.
- A look that can't be made (the audio server didn't answer) is unknown, never the end of a call:
  ending and then seeing the same call again would split it into two conversations. Unknown counts
  as missing evidence, so a call ends only once nothing has confirmed it for the full 45 seconds,
  and one confirming look starts the grace over. A pending start waits, and a suppressed call stays
  suppressed. After three failed looks in a row the status line says "Can’t check for calls right
  now."
- Without Screen & System Audio Recording no title can be read: nothing new starts and the line
  says the permission is needed, but a call already being recorded continues on its app's audio
  and ends when that does.
- `onMeetingEnded` returns whether it stopped a recording (only an automatic one is). The line then
  says "The call ended, so recording stopped." or, for a recording someone started themselves,
  "The call ended.", until another call shows up.

## Notifications

While Daybook isn't in front, `RecordingNotifications` (Sources/Daybook/App/MacNotifications.swift)
says what a person would otherwise miss, by the same background-only rule as a recorder's
notifications (`DeviceNotifications`):

- **Recording stopped**, when a recording ends without Stop (`AppState.unexpectedStops`: a
  microphone that went, sleep, a disk that couldn't keep up). It names the conversation, unless
  it's Personal, as the menu bar extra never does, says the recorder's one sentence for why, and
  offers Record Again. A click opens the conversation. It goes once the stop has been seen in the
  app (`dismissUnexpectedStop`) or the next recording starts.
- **Recording**, when a call starts recording on its own while Floating Notes isn't showing,
  naming the call ("Zoom call"). A click shows Floating Notes. It goes when that recording ends.
- **Microphone silent**, when the microphone stops hearing while recording, and **Low on space**,
  once the disk has room for under half an hour (Floating Notes' chip's sentence, kept up to date in
  steps of five minutes). Each names the conversation unless it's Personal, a click shows Floating
  Notes, and each goes when it's over or the recording ends.

Permission is asked the first time someone records or chooses Record Automatically, for
alerts and sound, as a recorder's first import asks (`DeviceNotifications.authorizationOptions`):
the system asks once, so whichever comes first, Recording stopped can be heard. Only a
bundled app posts (`UNUserNotificationCenter` crashes an unbundled binary); tests drive the same
logic with snapshots and a fake center. The app starts it with its other system entry points
(`SystemEntryPoints`, docs/sandbox.md).

## Known limits

- **Browser calls.** A browser tap records every tab of that browser. Safari's WebKit GPU process
  is shared with other WebKit apps.
- **New apps.** A call app outside the rules, or a FaceTime call, isn't tapped and falls back to
  ScreenCaptureKit. FaceTime audio runs in system daemons.
- **Permission.** The System Audio Recording permission can't be checked. A denied tap is only
  detected after 45 s of silence while the app's output runs, and it falls back only if Screen
  Recording is already allowed. Otherwise the call track stays silent and a warning explains
  why.
- **What the canceller can't remove.**
  - It's linear, with suppression. Heavy speaker distortion at high volume leaves some residual,
    which the suppressor handles at the cost of a few dB of your voice in those moments.
  - Echo beyond about 220 ms of room reverb after the direct path is left to the suppressor.
  - Delay changes within a 30 s window are tracked by adaptation, not re-segmentation.
- **Output format.** The derived track is 16 kHz, which suits speech recognition and diarization.
  Listen to the original for full bandwidth.
- **Clock correction.** Drift correction depends on host-time stamps. ScreenCaptureKit's
  presentation stamps are assumed to be host time. Fusion applies `clockRate` from the longest clock
  piece only. A gap longer than 5 minutes isn't padded (its audio starts a new clock segment), and
  neither the library's one offset and rate nor echo removal's resampler (`SessionTimelineReader`,
  which reads on across a gap between clock pieces) honours it: audio after one reads early by the
  gap. With the stall watch restarting a silent source after 3 s, such a gap needs a source dead for
  five minutes that then comes back.
- **Detection heuristics.** Automatic detection is defeated by:
  - localized or renamed meeting windows;
  - browser helper-process attribution and custom meeting titles;
  - browser calls that close audio devices while muted;
  - multiple calls in one app.

  Native meeting windows deliberately left open can also delay stopping.

## Verification

All tests use synthetic audio. None opens a microphone, records another app, creates a tap or
aggregate device, or asks for permission.

**`Tests/DaybookCoreTests/EchoCancellerTests.swift` and `EchoRemoverTests.swift`** use speech-like
syllables with formants. The echo path is a delay, early reflections, and an exponentially
decaying tail, with added noise. They cover:

- FFT scaling;
- ERLE of at least 20 dB on call-only stretches;
- near-end correlation of at least 0.9 and level within 3 dB during double talk;
- GCC-PHAT delay within 1 ms through reverb;
- no echo reported when the call never reaches the microphone;
- 44.1 kHz mono against 48 kHz stereo with different start times, including the opening seconds;
- a call clock 250 ppm fast, measured within 3 ppm, where the correction beats no correction;
- clock fits split at resyncs, with jitter outliers rejected;
- silent-call and no-echo skips;
- a delay change mid-call becoming two segments.

**`Tests/DaybookCoreTests/TrackDerivationTests.swift`** covers the transcription skip rule and
`Codable` compatibility.

**`Tests/DaybookTests/CaptureTests.swift`** covers:

- the detection state machine;
- the monitor with scripted looks: one failed look keeps a call, failed looks end it only after
  the grace, a call continues on its audio without window titles and nothing new starts, the ended
  line by whether a recording stopped, and looks made off the main thread that stop with
  `stopMonitoring()`;
- candidates from one process list and the titled windows (titles in any case, Safari's WebKit
  audio, a browser only playing audio), and a process list that can't be read as unknown;
- PCM writing, offsets, and gap padding with resync;
- format changes converted without frame loss;
- 900 ppm drift in both directions over two minutes, with no stop and no inserted silence;
- recovery;
- a +8 s jump padded with 5 ms ramps, a 400 s one skipped onto a new clock segment, and a −0.5 s
  jump whose overlap is dropped, none stopping the track.

**`Tests/DaybookTests/CaptureResilienceTests.swift`** covers, with fake sources, a fake disk, a fake
clock, and a fake free-space reading:

- a 5 s disk stall keeping both tracks, padding the hole, and saying what was lost;
- a call writer stuck for a minute stopping only the call, and the microphone's ending the
  recording;
- sources that stop delivering restarted every 3 s, and a tap silent through three rebuilds falling
  back to ScreenCaptureKit;
- the audio system restarting both sources, and sleep held off only while recording;
- a microphone that goes to zeros after speech (and one under −90 dBFS for 20 s) said, and heard
  again;
- meters that move alike for 10 ms and 85 ms buffers, with the peak held a second;
- low space warning under 30 minutes and stopping the call under 3;
- sleep stopping this Mac's tracks and saying it was for sleep;
- `MicrophoneRestartTests`: 30 device changes in 10 minutes all followed, 11 in a minute failing, a
  restart that fails twice then succeeds, and one that falls back to the built-in microphone.

**`Tests/DaybookTests/CallCaptureTests.swift`** covers:

- tap versus ScreenCaptureKit selection with fakes: known app, unknown app, creation or start
  failure, an old OS, and both paths failing;
- helper and own-process filtering, and the manual call-app choice;
- route classification;
- the controller end to end with fake sources:
  - levels and the call-detected signal;
  - a route change;
  - a tap failure falling back mid-call;
  - a microphone device change;
  - a call-track failure that keeps the microphone running;
  - computer audio that can't start without a call app, recording the microphone alone with its
    one warning, and a known call app whose audio can't be recorded failing the start;
  - sleep stopping the recording, from a watch that ends with the controller (the devices recording
    along keep going: `PhoneLinkTests`);
  - microphone denial before any call capture;
- `CaptureFinalizer`:
  - originals byte-identical;
  - delay;
  - ERLE of at least 20 dB;
  - double-talk retention;
  - idempotence;
  - headphone, leak, and no-call cases;
- `AppState` importing a staged call into originals plus a derived track, with provenance,
  transcription choice, and restart persistence.

**`Tests/DaybookTests/LiveCaptionsTests.swift`** covers live captions with scripted captioners and
the same fake sources:

- You and Call fed from their own sources on the recording's timeline, tagged and interleaved;
- the speakers' echo left out, kept from a mid-call switch to headphones on, and both sources in
  full with headphones; the word-and-time rule itself;
- a failing Call captioner that leaves the recording and You untouched;
- the Mac-local store, kept until a later transcript replaces it, and pruned with the Trash;
- no captioner, tap, file, or warning when the system can't make captions (macOS 15).

**`Tests/DaybookTests/SystemEntryPointsTests.swift`** covers, with a fake notification center and
Spotlight index:

- a recording that stops on its own said once while Daybook is behind, its conversation named
  unless Personal, nothing while it's in front, and taken back once seen;
- a microphone that stops hearing and a disk running low said while Daybook is behind, kept up to
  date, and taken back when over or when the recording ends;
- an automatic start said only while Floating Notes is hidden, taken back when it ends, and an
  earlier stop taken back by the next recording; permission asked once, at the first recording or
  When a call starts (Record Automatically);
- a click opening the conversation, and Record Again recording with a fake microphone;
- the intents waiting for the app and its library, and Start, Bookmark, Stop, New Note, and Open
  Conversation on the app's state;
- Spotlight and Shortcuts' suggestions without Personal conversations, following renames, moves to
  Personal, and the Trash.

**`Tests/DaybookTests/WelcomeTests.swift`** covers Welcome's Record waiting for the library (and
stopping for a library move or a library that can't open), the free-space check, and the Allow
page's permissions against a scripted system.

Live checks still needed are listed in `docs/validation.md` under "Call capture and echo
removal".

## Apple references

- Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- `CATapDescription`: https://developer.apple.com/documentation/coreaudio/catapdescription
- `AudioHardwareCreateProcessTap`: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- ScreenCaptureKit audio configuration: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- CoreAudio process input/output activity: https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput
- `AVAudioEngine` configuration changes: https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification
- Voice processing and ducking: https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
- Screen-capture authorization check: https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()
