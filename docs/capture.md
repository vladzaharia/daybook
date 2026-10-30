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

If the tap fails *during* a call, `RecordingController` switches the same `systemAudio.caf` to
ScreenCaptureKit and records `switchedAt`. The failure might be a rebuild that didn't work, the
device disappearing, or the watchdog (only when that switch needs no new prompt; see
Permissions). If ScreenCaptureKit also fails, or fails later, only the
call track stops; the microphone keeps recording and a warning is kept. Only a microphone failure,
a disk that can't keep up, or sleep ends a recording. In every case the audio captured so far is
preserved.

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
| Screen & System Audio Recording (`NSScreenCaptureUsageDescription`) | The first recording that falls back to ScreenCaptureKit, through `SCShareableContent` | All Mac audio. Also needed by `MeetingMonitor` to read window titles for automatic detection. |

Call audio starts before the microphone. That way any prompt is answered before your voice is
being recorded, and a dialog can't leave a microphone-only recording behind.

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
| `microphone.json`, `systemAudio.json` | Track timing, format, frame count, capture method, notes, and **clock anchors**. Saved after the first buffer, every ten seconds, and at the end. |
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
  most about a second old. Slow drift therefore never looks like a gap.
  - A real gap of more than 80 ms and up to 5 s is padded with silence, and the next anchor is
    marked `resync`.
  - A jump of more than 5 s forward or more than 100 ms backward stops that track and preserves
    it.

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

  `TranscriptFusion` doesn't read `clockRate` yet. That's the alignment owner's call.

## Device and route changes

- **Microphone.** `MicrophoneSource` restarts its AVAudioEngine tap on the new input when
  `AVAudioEngineConfigurationChange` fires. That happens when AirPods connect, or when they switch
  to the hands-free profile because an app opened their microphone. `PCMTrackWriter` converts the
  new format to the file's original format with `AVAudioConverter`. It drains the converter's
  look-ahead at every switch and at the end, so no frames are lost. It also pads the switch gap
  and starts a new clock segment. Recording stops only after 20 restarts, or if a restart fails.
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

`RecordingController` is main-actor isolated and observable:

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

Set `onUnexpectedStop` to import partial audio after a microphone failure, a disk backlog, or
sleep. A failed start can still leave a partial result in `lastResult`; don't delete that staging
folder.

`CaptureEnvironment` injects the following:

- microphone permission;
- the microphone source;
- the system-audio provider;
- the current route and route observation;
- the host clock.

Tests drive the controller with fakes, so no device, tap, or stream is opened.

### Live levels, for the recording UI

| API | Type | Meaning |
|---|---|---|
| `recorder.levels.microphone` | `CaptureLevelMonitor.Level` | "You": `rms` and `peak` in dBFS. `meterValue` maps −60…0 dBFS to 0…1. |
| `recorder.levels.call` | same | "Call", with the same fields. |
| `recorder.levels.isCallAudioDetected` | `Bool` | The call track was above −50 dBFS within the last 4 s. |
| `recorder.isCallAudioDetected` | `@Published Bool` | The same signal on the controller. It changes rarely, so it's fine to observe through `AppState`. |
| `recorder.levels.isMicrophoneSilent` | `Bool` | After 3 s, not one non-zero microphone sample has arrived. The input is muted in hardware, unplugged, or denied. |
| `recorder.levels.isCapturingCall` | `Bool` | Call audio is part of this recording. It's false after the call track stops. |

`CaptureLevelMonitor` updates 15 times a second and publishes only changes of at least 0.5 dB.
Observe `recorder.levels` directly as an `@ObservedObject`. `AppState` forwards
`recorder.objectWillChange`, and doing the same for meters would redraw the whole app 15 times a
second.

## Live captions

While the Mac records, tentative captions show that both sources are being heard and give
something to read until the transcript exists. They come from the same engine as every other live
caption in Daybook, `DaybookCaptions` (`SpeechAnalyzer` with `SpeechTranscriber`, volatile and fast
results; docs/iphone.md, "One live-caption engine"), or, when the live models are downloaded
(Settings › Models › Live transcription and Live speakers), from local models: streaming
transcription on any macOS, speakers, and names for voices that match the library's voice profiles
(`MacLiveModels`; docs/model-runtime.md, "Live"). They are never the transcript: they stay on this
Mac, aren't synced, fused, summarized, or used as evidence, and the transcript replaces them.

Code: `Sources/Daybook/Captions/` (controller, echo rule, store, views, settings) and
`Capture/CaptureCaptionTap.swift`.

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
    (docs/validation.md). With computer audio off ("Include computer audio" in Settings › General)
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
- **Storage.** `LiveCaptionStore` keeps `<library>/LiveCaptions/<meeting id>.json` (directory 0700,
  file 0600), laid out as on the iPhone: one `LiveCaptions` with You and Call as segments tagged
  `source` (`.microphone`, `.call`), saved every 10 seconds while listening and at Stop (what stood
  then is kept as heard). It's outside `Meetings/`, so sync never reads it. Captions are replaced by
  any transcript made after they began (`LiveCaptionStore.isReplaced`): they disappear from the page
  and are deleted, as are captions of conversations moved to the Trash (`prune`, a second after the
  library changes).
- **Where they show.** Floating Notes, while recording: a fixed-height strip above Bookmark and
  Stop (`LiveCaptionStrip`, `.panel` style, shared with the iPhone through `DaybookDesign`) with
  "Live captions · tentative" and the newest two lines: the newest larger, in body ink, keeping its
  latest words; the one before smaller, in Secondary; still-revised words lighter. The source (You
  or Call) sits in the time lane, so arriving words never move the notes. Compact, it shows the
  newest line only, without the label. The conversation page, after your notes: the newest eight lines while recording,
  then everything captioned until the transcript exists, as "Live captions · tentative" turns
  labelled You and Call, in lighter ink than a transcript, with no editing. Both observe the captions
  directly, so a revised word redraws only them.
- **Settings › General › Live Captions.** "Show while recording" (on by default, as on the
  iPhone) and the language ("Same as This Mac" or any `SpeechTranscriber` locale; on macOS 15, the
  languages the downloaded live recognizers cover, `LiveModelSet.languages`: the Latin model's six,
  the multilingual model's 35), with a footer that says whether the language is ready or downloads
  the first time (never asking triggers a download), or, on macOS 15, that live transcription doesn't
  cover the chosen language. A language chosen before its model was removed stays chosen and listed,
  so the choice still reads, and captions return when a model covers it again (`LiveCaptionLanguages`). It's in General, beside the other recording choices, rather than Models: captions use
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

## Automatic meeting detection

`MeetingMonitor` exposes:

- `startMonitoring()` and `stopMonitoring()`;
- `statusText`, `activeCandidate`, and `isMeetingActive`;
- `onMeetingStarted` and `onMeetingEnded`.

Its mutable `rules: [MeetingAppRule]` property is the configurable allowlist. The defaults cover
Zoom, Teams, Slack huddles, and meeting pages in Chrome, Safari, Firefox, Edge, and Arc. Rules
match bundle IDs, including helper prefixes, and meeting-specific window-title fragments. They're
heuristics, not integrations with private vendor call APIs.

**Starting.** The monitor polls every two seconds. A start needs two things, continuously for six
seconds: a matching meeting window, and Core Audio activity from that allowed app.

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
- A revoked permission or a failed Core Audio query ends the monitor's active meeting
  immediately, so the caller can stop an automatic recording.

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
  presentation stamps are assumed to be host time. Fusion doesn't apply `clockRate` yet.
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
- PCM writing, offsets, and gap padding with resync;
- format changes converted without frame loss;
- 900 ppm drift in both directions over two minutes, with no stop and no inserted silence;
- recovery and backward clock jumps.

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
