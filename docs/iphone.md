# Daybook for iPhone

A full Daybook app for iPhone. Everything the Mac app does, except running the models. Recording, notes, bookmarks, the library, reading, playback, editing, organizing, devices, templates, vocabulary, sync, and settings all work on the phone. Transcription, speaker identification, and summaries run on a Mac and sync back.

**Recorded but not processed is a normal, complete state.** A conversation recorded on the phone is immediately useful: you can play it, take timed notes, bookmark it, title it, file it, and search its notes. It says where it stands ("Not transcribed yet"), never that something is broken. The architecture keeps on-device processing possible later without restructuring.

Designed first for **iPhone Duo** (book-style foldable, iOS 27.1+): closed it's a pocket recorder, open it's a two-page notebook. Every other iPhone gets the closed layout, or the open one at regular width.

## Scope

Everything below is in v1:

- **Record.**
  - Microphone recording, background-safe, interruption-safe, compressed (AAC).
  - Notes with recording times and bookmarks, exactly as on the Mac (`TimedNotes`, highlights), in every posture.
  - Photos from the camera at their moment in the recording ([photos](photos.md)).
  - Start, stop, and bookmark from the Lock Screen, Dynamic Island / Live Activity, Control Center, the Action button, and Siri (App Intents).
  - **Live captions while recording.** Tentative, on-device captions from the Speech framework's `SpeechTranscriber` (volatile results), shown like closed captions. They prove the audio pipeline is working and give something to read until the Mac's transcript arrives, and they are never the transcript: phone-local (`<library>/LiveCaptions/<id>.json`, never synced), never fused, summarized, or used as evidence, and hidden once the official transcript exists. If the language isn't available, the app says so and recording is unaffected.
- **Library.** Places (All, Work, Personal), folders, tags, search (titles, notes, transcripts, summaries), Trash, and multi-select. New Note starts a conversation that's only your notes (and any photos), titled "Note at 10:15 AM", as on the Mac. Its page says "No recording yet" with Record, which records into it; the recording joins after the notes.
- **Reading.**
  - The summary page: lede, next steps, sections, your notes, bookmarks, colophon.
  - The transcript: speakers, times, tap to play.
  - Audio playback that downloads on demand.
  - Version History, with restore.
- **Editing that syncs.**
  - Notes, title, next steps, speaker names, and transcript passage corrections.
  - Folders, tags, Work/Personal placement, the template choice, and bookmarks during playback.
- **Processing requests.** Transcribe, Summarize Again, a template change, Identify Speakers Again, and Transcribe Everything Again are all available. On the phone they become requests a Mac carries out (see below).
- **Templates and vocabulary.** Browse and edit them; they sync as library metadata.
- **Devices.**
  - Soundcore Work over Bluetooth from the phone, which is usually the device in your pocket.
  - Other recorders through Files.
- **Multipoint.** When the Mac records, the phone can record too, and the reverse. Recordings join one conversation through the existing multipoint pipeline.
- **Settings.** iCloud (sync, the library's devices, encryption), Macs and pairing, recorders, recording, storage, templates, vocabulary, and About. Every row has its symbol on a neutral tile in one column (teal while a Mac or recorder is connected), and each device page opens with the same header: tile, name, status. In the hand it's a sheet. Open on the iPhone Duo, where a sheet would be a card centred across the crease, it takes the display as two pages, as pairing does (`settingsSheet`): the list on the left, the chosen screen (iCloud at first, Add Recorder too) on the right. Folded shut while shown it's one column; shown in the hand and then opened, the sheet splits into the same two pages at the crease (`SheetCreaseSplit`), as Add Recorder over the status panel does.
- **File protection.** Recording segments, the capture journal, photos taken while recording, and live captions are `completeUntilFirstUserAuthentication`, like the library. `completeUnlessOpen` was weighed and kept out: it lets a locked phone create files and keep writing ones already open, but not reopen a closed one, and Daybook reopens its own closed files while locked in everyday use. Stop from the Lock Screen, Siri, or a Mac reads every segment back to assemble the recording (`RecordingAssembler` opens even a single clean segment to check it) and copies the result into the library; an interruption closes one segment and opens another, so both are read at Stop; filing reads the photos taken while recording, and recovering after a quit reads the journal; and live captions reread their file to keep its track. Under `completeUnlessOpen` each of those fails until the phone is unlocked. Finished library items stay at the same class because background sync reads them while locked.
- **Backups.** iPhone backups (iCloud and computer) never hold copies Daybook can rebuild: the courier's inbox and outbox (`Sync/Inbox`, `Sync/Courier`; iCloud Drive carries the same files), audio downloaded for playback, imports being copied in, and `Documents/Inbox` (`BackupExclusion`, applied at launch and after each download). The library itself goes in unless Settings › Storage › Include in iPhone Backups is off (default on), which keeps the whole library folder out, for someone who doesn't want recordings in a backup, with or without sync.
  - **An encrypted library** (this iPhone syncs it encrypted, waits for its key, or synced it so before; docs/icloud-sync.md, "Encryption") keeps its conversations, Trash, sync state, and saved captions (`Meetings/`, `Trash/`, `Sync/`, `LiveCaptions/`) out of backups by itself: the sealed journal in iCloud is their backup, and an iPhone backup isn't encrypted end to end unless Advanced Data Protection is on. Recordings in progress (`Staging/`) and recorder state stay in. The same toggle, Include in iPhone Backups, then shows a choice of its own, off by default (`includesEncryptedLibraryInBackups`); turning it on includes the library again. How the two combine: a plaintext library follows the first choice as before; an encrypted one is included only when its own choice is on; otherwise, if the first choice is off, the whole library folder stays out as before, and if it's on, only those four folders do. A choice made for the plaintext library never carries over as on, so turning encryption on doesn't leave plaintext in backups because of an old setting; someone who wants an encrypted library in their backups turns it on again. Applied at launch, when either choice or the library's encryption changes, and after each sync pass.
- **Export.** Markdown and audio through the share sheet. Copy (a passage, a summary line, Copy Summary) stays on the device that copied it, on the Mac too: never Universal Clipboard (`LocalPasteboard`). Exports wait in `tmp/Daybook Export/` only until the share sheet is done with them, and anything left there is cleared at launch. A file another app opens in Daybook (iOS copies it to `Documents/Inbox/`) is removed once it's imported; a failed import keeps it.

**Not possible on iOS, by design**
- Recording another app's call audio. iOS has no per-app or system audio capture, so on a call the phone records its own microphone only. The Mac records the call.
- Recording cellular calls. Third-party apps can't. Importing iOS call recordings (saved to Notes) through the share sheet is a later addition.

## Processing on the Mac

A conversation's processing state comes from its data and is shown the same way on both platforms (`ProcessingStatus` in DaybookKit):

| State | Meaning | Phone shows |
|---|---|---|
| **Recorded** | Audio with no transcript yet; no request yet | "Not transcribed yet". Everything except transcript and summary works |
| **Requested** | A `ProcessingRequest` is in the library, waiting | "Waiting for your Mac" (with "Last seen 2 h ago" when no Mac has checked in recently) |
| **Processing** | A Mac claimed it | "Transcribing on <Mac name> · 40%" (live over the local link; coarse over sync) |
| **Waiting for a recording** | A Mac's audio is transcribed and summarized; a recorder that recorded along hasn't been added yet ([multipoint](multipoint.md#mac-first)) | "Waiting for audio from Soundcore Work" on the page; "Waiting for Soundcore Work audio" in the list |
| **Done** | Transcript and summary present | Normal page |
| **Couldn't finish** | The Mac reported a failure | What it means in plain words, Try Again (which writes a new request), and the Mac's own reason behind Details |

- **Requests travel in the library.** A `ProcessingRequest` (meeting, mode, template, requested by, when) is synced metadata, like an edit. Recording on the phone requests **Transcribe** automatically.
- **Requests run on a Mac.**
  - A Mac with models claims a request, records the claim (so two Macs don't both run it), runs it through its normal queue (pause, cancel, missing models), and writes the result and its status back.
  - Stale claims expire, and the claim survives the Mac going to sleep.
- **On a Mac nothing changes.** New audio that arrives through sync is processed as it is today; requests only make the phone's intent explicit and visible.
- **The phone never fakes progress.** If no Mac is paired or has been seen, the state says so plainly.

### On the Mac

The queue is `AppState`'s (`AppState+Requests.swift`); each change to a request is one of `ProcessingRequest`'s pure functions, saved like an edit.

- **Pick up.** After every sync pass, every finished job, a model download, a phone's nudge, and at launch, the Mac queues each open request it may take (unclaimed, its own, or with an expired claim), when **Transcribe synced recordings on this Mac** is on and it has the models that request needs. Otherwise the request stays unclaimed. One job per conversation: a job already queued or running for it (new audio that arrived with it, say) carries the request, and finishes it.
- **Claim when it starts.** The claim (10-minute lease) is taken when the job starts, not while it waits, so the phone reads "Waiting for your Mac" until work begins and a Mac busy with a long job leaves the request to another. A request another device holds is never run; its job is dropped.
- **Heartbeat.** While the job runs, the claim is renewed with its stage and fraction at every change of stage and every minute. Sync passes keep running while a request runs (they wait for local work, as before), so the heartbeat and coarse progress reach the phone; the conversation being processed is protected from a remote deletion or status, as a recording is.
- **Finish.** The request is completed, or failed with the Mac's reason, which `ProcessingStatus` shows on both devices. Any other open request the work satisfied is completed too, so statuses agree everywhere.
- **Pause, Cancel, models.** Pause and Cancel give the claim back (the lease ends now) and keep the conversation paused on this Mac, so it isn't claimed again at the next pass; Resume claims it again. Missing models leave it unclaimed.
- **Two Macs.** If both claim before either has synced, the merge keeps the newest claim on both. The Mac that sees it lost stops its job at that pass, without pausing it or touching the request, and the other finishes it. Until then both work, for at most one sync round.
- **Stale claims.** A claim whose lease ran out (a Mac that vanished) is claimable, and claiming it starts a strictly newer claim that wins every merge. Claims are never cleared outright (`expireStaleClaims` isn't used): the merge keeps the newest claim, so a cleared one would come back from the other copies at every pass.
- **Sleep and quitting.** A Mac that sleeps keeps its claim and renews it on waking, unless another Mac took it over meanwhile (then it stops). Quitting cancels processing, which gives claims back; they're published at the next launch's first pass, or simply expire if the Mac never returns. A Mac that crashes mid-claim runs its own claims again at launch.
- **No requests for its own work.** The Mac's own captures, imports, and menu commands write no requests: its queue is live on the Mac, phones see it over the link, and a request per job would double every job's sync traffic. It only completes requests its work satisfied.
- **Presence.** The sync controller publishes `SyncReplicaConfiguration.mac(displayName:canProcess:)`. `canProcess` is true when the models automatic processing needs are installed and the Mac transcribes synced recordings; it's updated whenever models are installed or removed, or those choices change, and the link's capabilities follow.
- **Status lines.** The list and conversation page read `ProcessingStatus`; while the Mac carries out another device's request they add "Requested from Alex's iPhone".
- **Live progress.** While any conversation is processed, connected phones get `processing.progress` at every change of phase (queued, aligning, transcribing, identifying speakers, summarizing, then finished, paused, failed, or waiting for models) and as the fraction moves. A `processing.nudge` makes the Mac sync at once.

## Architecture

```text
DaybookCore         (macOS + iOS)  models, storage, sync journal, fusion, alignment, echo DSP
DaybookKit          (macOS + iOS)  LibraryController: library state, edits + revisions, search,
                                   sync controller, recording ingest, ProcessingStatus,
                                   ProcessingRequest queue, ProcessingEngine seam
DaybookDevices      (macOS + iOS)  device framework, Soundcore (BLE, protocol, crypto, Opus)
DaybookLink         (macOS + iOS)  Mac <-> iPhone local-network channel: pairing, control, status
DaybookCaptions     (macOS + iOS)  the one live-caption engine (Speech framework's SpeechTranscriber):
                                   iPhone recordings, the Mac's You/Call capture, and hardware live
                                   audio (Soundcore live listening). Depends on Apple frameworks only.
DaybookIntelligence (macOS now)    WhisperKit, FluidAudio, MLX: the Mac's ProcessingEngine.
                                   Kept free of AppKit so an iOS build can link it later.
Daybook             (macOS app)    AppKit/SwiftUI app, capture, Mac UI
Apps/iOS            (Xcode, via XcodeGen)
  DaybookPhone          iPhone app (SwiftUI)
  DaybookPhoneWidgets   Live Activity, Control Center controls, widgets
```

- **Processing seam.**
  - `ProcessingEngine` (in DaybookKit) takes a meeting and its transcribable tracks and returns transcripts, speakers, and a summary. The Mac's pipeline implements it with DaybookIntelligence.
  - The phone registers none, so its requests wait for a Mac.
  - Turning on on-device processing later means linking DaybookIntelligence into the iOS app and registering an engine; the request queue and statuses already describe local work. Smaller models, memory limits, and iOS 26 background continued-processing tasks are tuning, not restructuring.
- **Sync through Daybook's iCloud container.**
  - Both apps use one ubiquity container, `iCloud.local.daybook` (configurable through `DAYBOOK_ICLOUD_CONTAINER`). The journal lives at `<container>/Documents/Daybook`, read through `DaybookICloudContainerIdentifier`. There's no folder to pick: signing into iCloud is all it takes.
  - The container is hidden from the Files app.
  - The journal format is unchanged (`docs/icloud-sync.md`).
  - Macs that synced through a chosen folder move to the container once. The journal is content-addressed, so the copy is safe and idempotent. The old folder is left untouched.
  - The phone uses an **on-demand audio** policy: meetings, transcripts, and summaries apply immediately; audio blobs download only for playback, and can be evicted.
  - Phone recordings upload as blobs like any other source.
  - Requires signed builds with the iCloud capability on both apps (same team, same container). Unsigned development builds and tests keep the folder transport, which is never offered as the product setup.
- **Courier (CloudKit).**
  - The iPhone also sends every file a pass writes (the recording, its events, library metadata) through CloudKit, in the same container's private database. It does so right after a recording is filed, under the same background-task assertion as that pass.
  - The Mac stores them in its courier inbox, applies them in a pass, and deletes them from CloudKit, usually seconds after the recording is filed, on any network.
  - iCloud Drive still carries everything, and the courier never writes into the container. The courier is off in builds without CloudKit, without an account, or when CloudKit refuses; sync then works as before.
  - A send that's stuck for 15 minutes shows in the sync line ("Waiting to send 2 items to your Mac", "iCloud storage is full"). See `docs/icloud-sync.md`, "Courier (CloudKit)".
- **Local link.**
  - When both are on the same network, DaybookLink (Network.framework, Bonjour, TLS with a pre-shared key from pairing) carries what iCloud is too slow for: start and stop for multipoint, live recording state, bookmarks, and live processing progress.
  - Without it, everything still works through sync, just later.
  - A Mac paired from now on can't start this iPhone's microphone until the person allows it. Right after pairing, the phone asks once: "Let <Mac> start recording on this iPhone?" (Allow / Not Now). The answer belongs to that pairing (pairing again asks again), and the Mac's row in Settings › Macs changes it later (Can Start Recording). Macs paired before the phone started asking keep the behavior they had. A start request from a Mac without permission is refused as `declined` with a sentence the Mac shows. Stop requests are unaffected.
- **What goes where.**

  | What | iCloud Drive (`<container>/Documents/Daybook`) | CloudKit courier (private database, zone `Courier`) | Local link |
  |---|---|---|---|
  | A phone recording (its audio object) | Always | From the iPhone, up to 50 MB, until a Mac stores it (at most 7 days) | No |
  | Conversations, edits, requests, library settings (events and metadata) | Always | From the iPhone | No |
  | Transcripts, speakers, summaries from the Mac | Always | No | Live progress only |
  | The manifest and presence (`daybook-sync.json`, `Devices/`) | Always | Never | Capabilities |
  | Recording control, live state, bookmarks during multipoint | No | No | Yes |
  | Courier bookkeeping (`Sync/Courier/`, `Sync/Inbox/`) | Never (local only) | No | No |

- **One live-caption engine.** Every live caption, whatever the source, goes through `DaybookCaptions`:
  - the phone's microphone;
  - the Mac's microphone and call audio, captioned separately as You and Call, with lines the microphone only heard from the speakers suppressed;
  - any recorder that streams live audio: Soundcore live listening, which replaced chunked WhisperKit previews (docs/devices.md, "Listen Live captions").
  Captions are always tentative feedback, never the transcript. Final transcription stays with the Mac's models.
- **The phone is a device to the Mac.** "Daybook on iPhone" is a `DeviceKind` with two methods: *direct* (DaybookLink, with record control) and *files* (sync). The existing multipoint coordinator, matcher, aligner, and fusion treat its recordings like any other source.
- **One Bluetooth owner per recorder.** A Soundcore is managed by the phone or by a Mac, never both at once. Ownership is a synced device setting; the other side shows "Managed by iPhone" and gets the recordings through sync. **Use on This iPhone** / **Use on This Mac** move it in one tap, in seconds over the local link and through sync otherwise ([devices.md](devices.md), "Handing a recorder over").

## iPhone Duo

Confirmed in the iOS 27.1 SDK: SwiftUI `onHingeChange { old, new in }` gives `DeviceHinge` (status `.closed`, `.partiallyOpen`, `.fullyOpen`, and `angle`). UIKit has `UIHingeInteraction`. Measure both displays in the iPhone Duo simulator before fixing layout constants.

| Posture | What the app becomes |
|---|---|
| **Closed** (outer 5.4") | *Pocket recorder.* One-handed. A large Record control at the thumb, the recorder's status, and recent conversations. Reading is one column. |
| **Open flat** (inner 7.6") | *Notebook.* Two pages split at the crease, never across it. Library, then conversation. In a conversation, the summary is on the left and the transcript on the right, linked: tapping a next step or bookmark scrolls the transcript to its evidence, and playback follows on the right. While recording: notes on the left; levels, bookmarks, and the live timeline on the right. |
| **Partly open on a table** while recording | *Table mode*, in landscape (flex mode): the phone is turned a quarter, hinge horizontal, the bottom half flat and the top half standing. The top half shows live captions in large type with the elapsed time and level, readable from across the table. The bottom half has large Bookmark and Stop targets, Write Notes, and the camera. Writing, the notes take the standing half and the keyboard the flat one; it doesn't dim until Done. Dimmed between interactions to save battery. |
| **Folding or unfolding** | Context carries over: unfold while reading a summary and the transcript opens beside it; fold mid-recording and the pocket recorder takes over without interrupting anything. |

Accessibility: Dynamic Type, VoiceOver order across both pages, Reduce Motion for posture transitions, and everything reachable with one hand when closed.

### Measured

Measured in the iPhone Duo simulator (iOS 27.1, 24A94425; model iPhone19,4) with the phone app's `--log-geometry` probe, which records the window, safe area, screen, and hinge on every change. Both displays are @3x and 460 ppi.

| Posture | Display | Points (window) | Pixels | Safe area (top, left, bottom, right) | Size classes |
|---|---|---|---|---|---|
| **Closed** | Cover, 5.4" (screen ID 1) | 466 × 678, portrait | 1398 × 2034 | 0, 0, 34, 84 | compact width, regular height |
| **Partly open** (about 99°) | Inner, 7.6" (screen ID 3) | 951 × 669, landscape | 2853 × 2007 as shown (a 2007 × 2853 panel mounted at 270°) | 0, 0, 34, 84 | regular, regular |
| **Open flat** (180°) | Inner | 951 × 669, landscape | the same | 0, 0, 34, 84 | regular, regular |

- **The status bar is a column on the right edge** in both displays, beside the sensor bar. That's the 84 pt right inset; there is no top inset. The home indicator takes the bottom 34 pt.
- **The crease** runs down the inner display's middle, at x = 475.5 pt of the 951 pt window, *not* at the middle of the safe area (433.5 pt). Two pages split at the crease are 475.5 pt (left) and 475.5 − 84 = 391.5 pt of safe area (right). The system adds no inset for the fold, so the app has to keep content off it.
- **Corners:** the cover's spine side (left) is nearly square (8 pt radius) and its outer side round (59 pt); the inner display is 55 pt all round.
- **Partly open and open flat have identical geometry.** Only the hinge status and angle differ, so layouts key off the posture, not the window size.
- **The app moves between displays live**, without relaunching: the window becomes 951 × 669 or 466 × 678 and the scene's screen changes. For a moment during the move the safe area reads top 82, right 0 before it settles, and `UIHingeInteraction` reports no hinge (`hinge == nil`); `DevicePosture` keeps the last posture through that gap.
- **Hinge reports:** angle 0–180° (`UIHinge.angle` in radians, π when flat), about 20 reports per fold. `.fullyOpen` from about 175°. The switch between `closed` and `partiallyOpen` (and between displays) happens partway through a fold and isn't at a fixed angle: one sweep from closed went `partiallyOpen` at 23° and closed again at 49° on the way back; others held `closed` past 100° when opened in steps, or `partiallyOpen` down to about 70° when closed from flat. Key layouts off the status, not the angle. SwiftUI's `onHingeChange` reports every change but not the posture at launch; `UIHingeInteraction` reports both, so `HingeObserver` uses the two together.
- **The simulator boots closed:** the cover is lit and the inner display is black. With the device open, the cover is black.

**Folding the simulator.** This Xcode (27.1, 27A9275) has no Simulator.app and `simctl` has no hinge command. Xcode's DeviceHub app has a hinge slider for this device, unverified with CoreSimulator devices. What works from the command line is SpringBoard's private display tool service, through `Apps/iOS/Tools/duo-fold/duo-fold.sh <udid> closed|book|open|<0.0–1.0>`, which spawns a small entitled helper inside the simulator. It's private SPI, simulator-only, and may break with any runtime update. Screenshots: `xcrun simctl io <udid> screenshot --display=1` (cover) or `--display=3` (inner); the display not in use is black, and images follow the interface orientation.

## Status sheet

A persistent status surface on the library screens, like Maps or Find My: the recorder, your Mac,
and sync at a glance, expanding to manage them (`DaybookPhone/Status/`). The words come from
`StatusSheetModel`, plain values from plain inputs, so tests read what each state says.

| Detent | What it shows |
|---|---|
| **Compact** | Record, Import, and Search at the thumb; then one line each: the recorder ("Connected · 80% · 2 new", "Recording · 80%", "Importing 1 of 3", "Managed by Studio Mac", a handoff under way), your Mac ("Transcribing · 40%" with the gradient line, "Connected · 2 waiting", "Last seen 2 h ago", or "Recording" with the red dot when its synced presence says so and the link has no word), and iCloud ("Up to date", "Syncing 3 changes"). Tapping a line goes to medium |
| **Medium** | Live listening captions while a recorder streams, first (`DeviceSession.liveCaptions`, tentative). Then at most three groups, each a generic heading and one full-width card, with each device in one card only. **Recorders**: a card per recorder, its tile, name, and status opening its page, then its handoff as a row (Use on This iPhone / Use on Studio Mac, progress, Take Over Anyway); Add Recorder… when there's none. **Macs**: every paired Mac as a row opening its details, the queue as rows under the Mac doing it (running with progress, waiting oldest first with "Requested from this iPhone", failures with the page's plain sentence and the Mac's words behind Details; the Mac isn't named again), and Pair with Your Mac… last. An empty queue shows nothing |
| **Large** | Each recorder's card adds its storage to its status ("About 2,170 hours left"), its actions as one row of equal-width buttons (Connect, Record or Pause on Soundcore, Import N New, Listen Live or Stop Listening: only what can be done now, never a disabled button), and the recordings waiting on it with Import, then All Recordings. A third group, **This iPhone**, is the audio kept on it ("1.2 GB of audio", as Settings says it), opening Storage. Links open the full screens (the device page, a Mac, Storage) inside the sheet rather than copies of them |

**Per posture, and why:**

- **Closed, and every other iPhone (18 Pro): a system sheet.** `.sheet` with `.presentationDetents([compact, .medium, .large])` (compact is a `CustomPresentationDetent` that grows with Dynamic Type, measured from the fonts: at most 55% of the screen, 70% at the accessibility sizes, so nothing is cut off), `.presentationBackgroundInteraction(.enabled(upThrough: .medium))` so the list stays usable, `.interactiveDismissDisabled()`, and the system's Liquid Glass sheet with nothing painted over it.
- **Record moves into the sheet.** The compact sheet sits exactly where `RecordStartButton` was; two stacked bottom layers would hide one or push Record up out of reach. One thumb surface holds what records and what it's doing, and Record stays one tap away, as before. The library's foot then keeps only the mini player, just above the sheet (`\.statusSheetInset`).
- **The sheet steps aside** for a conversation (pushed), search (the keyboard), selection (its bar), and the Trash, and comes back compact. Other sheets and alerts (Settings, Move, Tags) open above it.
- **Open (notebook): a panel on the right page.** A system sheet at regular width becomes a centred card across both pages and the crease, and can't be anchored to one page. So the status is a glass panel at the foot of the right page (crease at 475.5 pt: it starts `creaseClearance` past it and ends at the 84 pt status column), where the right thumb is. Compact, the conversation preview scrolls clear of it; medium covers the lower half of the preview; large takes the page as an inspector column, the preview hidden until it collapses. Record stays at the foot of the left page, so the panel doesn't repeat it. While a conversation is open across both pages (the reading spread), the panel isn't shown at all.
- **Partly open, in the library:** the same as open. The geometry is identical (docs: Measured) and the phone is held like a book; table mode is for recording only.
- **While recording: hidden.** `RecordingSurface` replaces the library and already shows the recorder's essentials (clock, level, bookmarks, captions); during a call there's one thing on screen (docs/interface.md, principle 1), and table mode needs the whole display. The sheet returns, compact, when the recording is filed.

Every card has the same quiet fill, 16 pt radius, and 12 pt padding, with inset dividers; symbols sit in a fixed-width column so text in sibling rows lines up. Record sits pinned under the grabber with room above it, outside the scroll view.

Accessibility: each line is one element ("Soundcore Work, Connected · 80%") with "Shows more"; the
sheet's grabber cycles detents for VoiceOver, and the panel's handle and container have Expand and
Collapse actions; the compact detent grows with Dynamic Type and its content scrolls at medium and
large; Reduce Motion drops the content and panel animations.

## Lock Screen, widgets, and the control

What they show comes from the app, which can stop at any moment (a crash, the system ending it, a
background relaunch that never reaches `launch`), so each says what it can still vouch for:

- **The recording's Live Activity** has a rolling stale date (90 s while recording, two hours while
  paused) that the app refreshes at least once a minute while it records. Stale, it says "Not
  confirmed", with no running clock and only Stop.
- **Widgets and the Control Center control** read `SharedRecordingState`, which carries `asOf`; the
  app writes it at least once a minute while recording (`SharedStatePublisher`). The timeline adds an
  entry where an unconfirmed recording turns into "Not confirmed", and the control is on only while
  it's confirmed. Paused, the clock is frozen ("Paused · 12:03").
- **Every launch** clears a recording state and activities an earlier run left (`App.init`).
- **Privacy.** Conversation titles are `privacySensitive`: hidden on the Lock Screen while locked.
- **Soundcore Work** gets its own Live Activity (`RecorderLiveActivity`) for Listen Live (with Stop
  Listening) and for a recording this iPhone started on it: live while connected, "Recording · as
  of 10:07 AM" after it lets the recorder go, and "Not confirmed" once that's 20 minutes old.
- Tests (`RecordingSurfacesTests`, `RecorderActivityTests`) cover the state and timeline logic, the
  Live Activity buttons' contrast (4.5:1 in light, dark, and Increase Contrast), and the recorder
  activity against the simulated recorder, not pixels.

## Design language

Same system as the Mac (`docs/interface.md`): paper, the Ink scale, Electric Teal, neon used sparingly (mint means playing, the gradient is brand and progress only, amber means bookmarks, red means recording). Use Liquid Glass for controls (iOS 26) and native navigation. Use New York for titles and SF for everything else.

## Phases and ownership

1. **Foundations, in parallel.**
   - *Kits*: DaybookKit (including `ProcessingStatus`, `ProcessingRequest`, and the engine seam), DaybookDevices, and the Mac adopting them.
   - *Sync*: the on-demand audio replica.
   - *Link*: DaybookLink.
   - *iOS shell*: the XcodeGen project, the recorder, Live Activity, controls, and App Intents.
2. **Features, in parallel.**
   - *iPhone library and reading*: the library, the page, the transcript, playback, editing, search, Version History, and Duo two-page layouts.
   - *iPhone recording, devices, and settings*: the recording screens (pocket, notebook, and table postures), Soundcore on iPhone (background BLE, state restoration), the sync folder, pairing, templates, and vocabulary.
   - *Mac integration*: the request queue and claims, iPhone as a device, pairing UI, multipoint with the phone, status to the phone, and Bluetooth ownership.
   - *Signing and iCloud container*: both apps get the iCloud capability. The Mac app moves to Xcode-managed signing (an XcodeGen project alongside the iPhone app, with a Developer ID provisioning profile), and Macs on folder sync migrate to the container once. Registering identifiers and the container on the Apple Developer account is done only with the owner's approval.
3. **Integration and design review** on iPhone Duo and iPhone 18 Pro simulators, plus the Mac.

## Verification

- `swift test` stays green for the Mac and core, with tests for the kits, the request queue and claims, the sync replica policy, and the link (loopback).
- iOS: `xcodebuild test` on the iPhone Duo simulator for kit and app logic. Screenshots with `xcrun simctl io <device> screenshot` in both postures and appearances.
- Still needs a real iPhone Duo and Mac: hinge transitions, background recording across calls and interruptions, Live Activity, Bluetooth with a real Soundcore in the background, local-network pairing, iCloud on-demand downloads, the CloudKit courier (pushes, background sends, cellular), battery and thermals.

Signing: set `DAYBOOK_TEAM_ID` for device builds. Bundle IDs are `local.daybook.app` (Mac), `local.daybook.phone`, and `local.daybook.phone.widgets`, with app group `group.local.daybook.phone` and iCloud container `iCloud.local.daybook` (iCloud Documents and CloudKit). Both app IDs also need Push Notifications, for the courier (`docs/release.md`, "One-time setup").
