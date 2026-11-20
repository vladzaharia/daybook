# Daybook for Apple Watch

Daybook on the wrist records audio as one of the iPhone's recorders, part of multipoint recording
([multipoint.md](multipoint.md)). The iPhone manages the watch like its other recorders (`daybook.watch`,
DaybookDevices): it asks the watch to start and stop with its shared recording, and the watch's audio arrives as short
segments the iPhone joins and imports into that conversation as the watch's track. The watch keeps nothing it hasn't
handed over: a recording stays on it until the iPhone says it's in the library.

Nothing here has run on a real watch yet; see [Needs a real watch](#needs-a-real-watch).

## Code

| Piece | What it does | Where |
| --- | --- | --- |
| The protocol | Messages, replies, `PhoneContext`, `WatchState`, `WatchChange`, segments, the audio format, the clock | [WatchLink.swift](../Sources/DaybookWatchLink/WatchLink.swift) |
| The iPhone's ledger | Which segments of each watch recording have arrived, and when one is complete | [WatchSegmentLedger.swift](../Sources/DaybookWatchLink/WatchSegmentLedger.swift) |
| Following | When the watch joins, adopts, or stops for the iPhone's shared recording, and what a `.start` or `.stop` means (pure, tested on the Mac) | [WatchFollowing.swift](../Sources/DaybookWatchLink/WatchFollowing.swift) |
| The journal | A recording's segments, the one being written, what the iPhone has, and closing it after the app was ended (pure, tested on the Mac) | [WatchRecordingJournal.swift](../Sources/DaybookWatchLink/WatchRecordingJournal.swift) |
| The app | The model that ties it together, the recorder and its writer, the store, the WatchConnectivity link, the one screen | [Apps/iOS/DaybookWatch](../Apps/iOS/DaybookWatch) |

The package's `DaybookWatchLink` is Foundation only, so the watch app links nothing else from the package. The tests are
`WatchLinkTests`, `WatchFollowingTests`, and `WatchRecordingJournalTests` (`swift test --filter WatchLink`).

## How it starts

The iPhone can't open an app on the watch. Three ways in:

- **The Live Activity.** While the iPhone records, its Live Activity is in the watch's Smart Stack; tapping it opens
  Daybook on the watch. When Daybook opens or becomes active, it asks the iPhone what it records (`.context`) and, with
  the watch's Record Along on (`PhoneContext.recordsAlong`) and a shared recording going, joins it on its own
  (`WatchChange.joined`).
- **The iPhone's `.start`.** With Daybook open on the watch (active, or frontmost with the wrist down), it starts and
  answers with its state (`.startedByPhone`). Otherwise it answers `.refused("Open Daybook on your Apple Watch to record
  there too.")`, and the refusal's words if starting failed (the microphone not allowed, storage full). A `.start` with
  no conversation (Record on the watch's page on the iPhone, with nothing recording there) records the watch's own
  (`WatchRecordingJournal.isOwn`, kept in its journal): it can still adopt a shared recording that starts later (the
  iPhone records it along as already recording), but the iPhone's context never stops it, adopted or not.
- **The wrist.** The record button starts a recording (`.startedOnWatch`); with Record Along on, the iPhone records too,
  from the pushed state, and sends a fresh context once it has: the watch's recording adopts that shared recording
  then, never one from a context the watch had before it started (it may have ended), and stops when it ends. With
  Record Along off the iPhone ignores the button, and the recording adopts nothing.

While a recording starts (the first microphone prompt can take a while), nothing else starts, and the iPhone's `.start`
and `.stop` wait for it: once it has started, or failed to, they're handled as if they came after it (a `.stop` for it
stops it; a `.start` for its conversation is answered with the real state), and then the newest context, which may have
ended its shared recording meanwhile.

Stopping on the wrist (`.stoppedOnWatch`) stops the shared recording everywhere. The iPhone stops the watch with a
`.stop`, or by its context no longer sharing the recording (`.stoppedByPhone`). A recording that can't go on (storage,
the microphone) ends on its own (`.endedOnItsOwn`).

## Following the iPhone

`WatchFollowing` decides; the model does what it says.

- **Only a fresh context is joined or adopted**: the answer to `.context`, for a minute after it arrives, or an
  application context sent within a minute of the watch's now (`WatchFollowing.freshness`). The latest application
  context waits for the watch app, so after a while away (or a relaunch out of reach) it may name a recording that has
  ended; the watch joins nothing from it and asks again when the iPhone is in reach.
- A recording with no conversation yet (started on the wrist, or by a `.start` for none) adopts the shared recording of
  a fresh context that arrived after it started, with Record Along on (`PhoneContext.recordsAlong`): the one the iPhone
  sends once it hears of the recording. With it off, nothing is adopted: the iPhone ignores the watch's button and
  records nothing along with it.
- A recording with a conversation stops once a newer context no longer shares it (none, or another one), fresh or not.
  A context sent before that shared recording started (both times on the iPhone's clock) can't know it yet and never
  stops it, so a context that arrives after the `.start` it preceded is harmless. A context older than the newest seen
  changes nothing. The watch's own recording (a `.start` for none) never stops for a context, even once it adopted a
  shared recording: the iPhone's cascade counts it as already recording, and never stops one of those.
- With nothing recording, a context (or Daybook becoming active) joins the shared recording when Record Along is on and
  Daybook is in the foreground. If the iPhone has moved on to another shared recording, the watch stops the old one and
  joins the new one when it can.
- A conversation the watch left (stopped on the wrist, stopped by the iPhone's `.stop`, or ended on its own) is never
  joined or adopted again on its own; only the iPhone's `.start` for it brings the watch back. The last 20 are kept, with
  the newest context, in the watch's preferences. A recording with no conversation that stops (say, stopped on the wrist
  before the iPhone's context arrived) leaves every shared recording that started before it stopped, allowing five
  seconds for the clocks (`clockSlack`): the context in flight for the one the iPhone started because of it doesn't
  start the watch again.
- A recording closed at launch (`.recovered`) leaves nothing: with Record Along on, the relaunched watch joins the
  shared recording again from the iPhone's answer as Daybook opens, if it's still going, and the iPhone imports both
  recordings into that conversation.
- `.stop` stops only the recording it names, and only one made for the conversation it names: a stop that arrives late
  never ends a newer recording, and one for a conversation never ends a recording started on the wrist for none.
- `.start` for the recording's own conversation changes nothing; for a recording with none, it's adopted; for another
  conversation, the watch stops and starts again if it's in the foreground, and refuses otherwise.

## The protocol, as the watch uses it

Every dictionary carries one value encoded with `WatchPayload` (JSON under `daybook`, the version under `v`). The
application contexts carry their value directly: the iPhone's is a `PhoneContext`, the watch's a `WatchState`.

| From the iPhone | The watch |
| --- | --- |
| `.start(WatchStart)` | Starts, adopts, or refuses (above); answers `.state` or `.refused` |
| `.stop(WatchStop)` | Stops if it matches; answers `.state` |
| `.status` | Answers `.state` |
| `.clock(phoneTime)` | Answers `.clock(WatchClockSample(phoneSent: phoneTime, watchTime: now))` |
| `.received(WatchReceipt)` | Marks the segments it names delivered; with `requestsMissing` (a finished recording), sends again every segment it leaves out, but for one on its way or whose transfer finished in the last two minutes (`WatchRecordingJournal.resendAfter`); with `imported`, deletes the finished recording and its segments. No answer |
| Application context (`PhoneContext`) | Follows it (above); fresh only if sent within a minute |
| A message it can't read | Answers `.refused("Update Daybook on your Apple Watch.")` |

What the watch sends:

- **Its state** whenever it changes, with the change: `.state(WatchState)` by `sendMessage` when the iPhone is reachable,
  and always as the application context, so the iPhone knows it after a relaunch. It also goes out when a segment closes
  or arrives, without a change. The state has the recording in progress (its duration up to now), whether the
  microphone captures, the finished recordings the iPhone hasn't imported, battery and charging, free and total storage,
  the model (`WKInterfaceDevice.model`, "Apple Watch": watchOS has no API for the marketing name), and the app's version.
- **`.context`** when Daybook becomes active (or WatchConnectivity activates, or the iPhone becomes reachable, while it
  is), unless the watch already records for a conversation. Unreachable, it reads the last application context instead
  (joined only if it's fresh).
- **Segments**, each once with `transferFile`, its `WatchSegment` as the metadata, as soon as it closes; at a stop, the
  last one and any that closed without going out. A finished transfer isn't delivery: a segment is delivered only once
  the iPhone's receipt names it (`WatchReceipt`), and the journal keeps both (`delivered`, and `transferred` with when
  each finished; a journal from before kept only which, read as long finished). A failed transfer is tried again up to
  five times while the app runs (10 s, 20 s, …). Once the activation is recorded and WatchConnectivity has handed over
  what waited at launch (the iPhone's receipts, transfers that finished while the app wasn't running), and whenever the
  iPhone becomes reachable, every segment with no receipt and no finished transfer that isn't on its way already
  (`outstandingFileTransfers`) goes. The receipt the iPhone sends as it stores segments asks for nothing (a later one
  may simply not have arrived). Only its ask (`requestsMissing`: a finished recording still missing segments, at most
  once a minute, and not in the first 30 seconds after its own activation) sends again what it leaves out, each once
  more unless it's on its way or its transfer finished in the last two minutes (the file may not have reached the
  iPhone's handler yet). A segment can arrive twice; the iPhone's ledger keeps one.

WatchConnectivity's background tasks (`WKWatchConnectivityRefreshBackgroundTask`) are held until the session is
activated and has nothing pending, after what arrived has been handled; if activation fails, at once. Settling waits for
the activation to be recorded (the state's observation can come before the delegate's callback), so what it sends goes.

## Recording

`WatchRecorder` records the microphone with `AVAudioEngine`'s input node. The tap delivers the hardware format; the
writer converts each buffer to 48 kHz mono float with `AVAudioConverter` when it differs, and encodes it with
`AVAudioFile` into an M4A: AAC-LC, mono, 48 kHz, 64 kbps with a constrained variable rate (`WatchAudioFormat.speech`),
the iPhone's own recording format (`RecordingFormat`), so the iPhone joins the segments by copying packets and never
encodes them again. watchOS has no `AVAssetWriter`, so there are no movie fragments: an M4A is readable once it's closed.

- The audio session is `.record` with the default mode: recording only, with no route picker (that's long-form
  playback's), and haptics still play (`setAllowHapticsAndSystemSoundsDuringRecording`). Starting and stopping tap the
  wrist.
- The microphone permission is asked the first time with `AVAudioApplication.requestRecordPermission`. Refused, the
  screen says "Allow Microphone in Settings". A start (or a resume) that fails lets the audio session go.
- The level meter is fed only while Daybook is active; with the wrist down the writer skips it, to spare the CPU
  watchOS allows a background recording.
- Nothing starts with less than 50 MB free, and a recording in progress ends on its own when a segment would open below
  that.

## Segments and recovery

A recording lives in `Application Support/Recordings/<id>/`: its segments, named `WatchSegment.fileName`
(`<id>-0003.m4a`), and `journal.json` (`WatchRecordingJournal`). The writer owns the journal while recording and saves it
whenever a segment opens or closes.

- **Segments** close every `WatchAudioFormat.segmentLength` (120 s), so the app being ended costs at most the one being
  written. Each carries the recording as it was when it closed; the last one carries the finished recording.
- **Runs.** Audio comes in runs, one per stretch the microphone captures. The first sample of the first run is the
  recording's start (`startedAt`, offset 0). A later run (after an interruption) starts where the wall clock says, from
  its first sample's host time, never before the audio already written; within a run, segments follow sample by sample.
  The gap stays a gap: the iPhone fills it with silence when it joins them.
- **Interruptions.** A call or Siri closes the open segment cleanly and reports `.interrupted`; the recording waits
  ("Paused"). When the interruption ends with Daybook active, or Daybook next becomes active, the next run starts
  (`.resumed`).
- **Route and format changes** stop the engine: the run ends there (its segment closes and goes out) and the next starts
  on the new format, so the restart's gap stays a gap. If it can't start again, it waits as for an interruption.
- **The audio system resetting** closes the run the same way, and the engine is made again (the old one can't start any
  more); the next run starts at once if Daybook is active, or when it next becomes active.
- **Recovery.** At launch, a recording whose journal isn't finished (the app was ended while it recorded) is closed as
  finished and reported with `.recovered`. The segment being written is kept, as not cleanly closed, if its file reads;
  otherwise it's deleted and left out of `segmentIndices`, so every index listed is one the iPhone will receive and its
  ledger completes. A recording ended while paused had no open segment and loses nothing. Its conversation isn't left,
  so the watch can join the shared recording again ("Following the iPhone").
- **A recording with no audio** (stopped at once) finishes with no segments; the iPhone acknowledges it like any other.
- **Deleting.** Only `.received` with `imported: true` deletes a recording. A finished transfer (not sent again unless
  asked) or a receipt without it (delivered) keeps the segments. A recording in progress is never deleted.

## Recording with the wrist down

The watch app declares the `audio` background mode in `UIBackgroundModes` (Info.plist, from `Apps/iOS/project.yml`).
With it, a recording started in the foreground goes on when the wrist drops or the screen turns off, and watchOS shows
the red microphone indicator at the top of the screen; tapping it opens Daybook. Evidence:

- Apple's [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
  lists the watchOS Audio mode as `audio` in `UIBackgroundModes` ("The app plays audible content in the background").
  `UIBackgroundModes` lists watchOS among its platforms.
- WatchKit's [Enabling Background Sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions):
  "The Audio, Location updates, and Workout processing modes let your app run the respective background sessions. Your
  app must start the session in the foreground, but the session continues to run when your app transitions to the
  background. … If the user presses the digital crown to navigate back to the watch face, the system displays an icon
  above the status bar, indicating that the session is still active."
- [`WKBackgroundModes`](https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes)
  takes only `workout-processing` and the extended runtime sessions (`self-care`, `mindfulness`, `physical-therapy`,
  `alarm`, underwater depth): not `audio`, and none of them fits a meeting recorder.
- WWDC17 "What's New in Audio" (session 501): from watchOS 4, `AVAudioRecorder` and `AVAudioEngine`'s input node record
  on the watch; "The recording can start only when the app is in foreground. But it is allowed to continue recording in
  the background, … the microphone icon will be displayed at the top", and "recording in background is CPU limited".
  WWDC17 "The Life of a watchOS App" (session 216): recording is "foreground initiated and background running, just like
  our workouts".
- An Apple Frameworks Engineer, on the Developer Forums
  ([thread 750432](https://developer.apple.com/forums/thread/750432), about an `AVAudioEngine` recorder interrupted by a
  call or Siri): "Recording cannot be resumed when the app is in the background on watchOS. It must be a user-initiated
  event while the app is in the foreground. (Recording can then continue once the app moves to the background.)" Hence
  `.interrupted` and resuming only in the foreground.

Not used: `WKExtendedRuntimeSession` (its session types are for health and alarms, and App Review holds background
modes to their purpose), and workout sessions.

## Building

`Apps/iOS/project.yml` has the `DaybookWatch` target: a single-target watchOS app (watchOS 26.0, device family 4,
`local.daybook.watchkitapp`), with `WKApplication`, `WKCompanionAppBundleIdentifier: local.daybook`, and
`WKRunsIndependentlyOfCompanionApp: false`. It links only the package's `DaybookWatchLink`. `DaybookPhone` embeds it in
an Embed Watch Content phase (`DaybookPhone.app/Watch/DaybookWatch.app`), so every `scripts/build-ios.sh` build includes
it: the simulator build for the watchOS Simulator, the device build and archive for the watch (arm64_32 and arm64). The
`DaybookWatch` scheme builds it alone. `scripts/ci/check-ios-archive.sh` fails an archive without it, with another
bundle ID, versions that differ from the app's, or another companion.

The icon is the Icon Composer document the other apps use (`Resources/Daybook.icon`); Xcode builds it for watchOS.

Signing is automatic. `local.daybook.watchkitapp` is registered on the developer account, with no capabilities
([release.md](release.md), "The owner's steps").

## Needs a real watch

None of this has run on a watch; the build compiles for the watchOS Simulator and for devices, and the pure parts are
tested on the Mac. To check on hardware:

- A long recording (an hour or more) with the wrist down: it keeps going with the `audio` background mode alone, the red
  microphone indicator shows, and the CPU limit for background recording holds with AAC encoding at 48 kHz (and the
  conversion, if the microphone isn't 48 kHz mono). The battery cost per hour.
- The input node's format on the watch, and that `AVAudioFile` encodes AAC-LC at 48 kHz mono 64 kbps there. On the
  iPhone, the segments join by packet copy (`RecordingAssembler.copiesPackets`), not by encoding again.
- `.record` activates with no route picker, with and without AirPods connected, and records the watch's microphone.
- Starting from the iPhone's `.start` with Daybook frontmost but inactive (wrist down, Always On): watchOS may count
  that as background and refuse the session.
- A call and Siri: the segment closes, `.interrupted` reaches the iPhone, and the recording resumes when Daybook is
  active again; with the wrist down it waits. AirPods connecting mid-recording (a configuration change): a new run
  starts with a gap of the restart's length. After a media services reset, the rebuilt engine
  resumes.
- At a relaunch, transfers that finished while the app wasn't running reach the delegate (or the iPhone's receipts
  arrive) before `hasContentPending` turns false, so nothing is sent twice.
- Ending the app from the Dock while recording: the open M4A is unreadable and deleted, and the recording comes back as
  `.recovered` with the earlier segments.
- WatchConnectivity while recording in the background: `transferFile` goes on, `sendMessage` reachability, background
  refresh tasks complete, and a reply to `.start` survives the first microphone prompt (or the pushed state carries it).
- The Live Activity in the Smart Stack opens Daybook on the watch (not the iPhone's mirrored activity) and it joins.
- Haptics play while recording; the app icon on the watch.
