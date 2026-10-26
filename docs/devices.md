# Devices

Daybook brings recordings in from recorders: Soundcore Work today, Daybook on iPhone, a generic
"Other Recorder" that saves audio files, and in future other hardware such as Plaud NotePin. This document
describes the hardware-agnostic device framework and how to add a new kind of recorder.

The framework and kinds are the `DaybookDevices` library (`Sources/DaybookDevices/`, macOS and iOS); the Mac's device interface stays in the app (`Sources/Daybook/Devices/`):

| Folder | What's there |
| --- | --- |
| `DaybookDevices/Framework/` | Kinds and methods, the connection interface, the per-device session and import queue, the hub, library links, formatting, notifications |
| `DaybookDevices/Files/` | The files method (`ImportFolderWatcher`), shared by every kind |
| `DaybookDevices/Soundcore/` | Soundcore Work: protocol, crypto, Opus decoder, transport, protocol session, connection, simulator |
| `DaybookDevices/OtherRecorder/` | A kind with only the files method |
| `DaybookDevices/DaybookPhone/` | Daybook on iPhone: the kind, its synced recordings (`SyncedPhoneRecordings`), and the hooks the app fills in (`DaybookPhoneHooks`) |
| `Daybook/App/PhoneLink*.swift` | The phone's direct method over DaybookLink (`PhoneLinkConnection`) and the Mac's end of the link (`PhoneLink`) |
| `Daybook/Devices/UI/` | Sidebar section, list column, device page, Add Device, Device Details, Settings › Devices, menus |
| `Daybook/Devices/Demo/` | Debug-only demo states for screenshots, installed into the hub through `DeviceHub.demo` |

## Concepts

```text
DeviceCatalog ── DeviceIntegration ── DeviceKind (id, name, symbol, vendor, methods in preference order)
                                          │
DeviceHub (@MainActor ObservableObject)   │  configured devices, persisted as [ConfiguredDevice]
  └─ DeviceSession (one per device) ──────┘
       ├─ connections: [any DeviceConnection]   one per implemented method
       │    ├─ SoundcoreConnection (direct, Bluetooth LE) ── SoundcoreSession ── SoundcoreTransport
       │    └─ ImportFolderWatcher (files)
       ├─ DeviceImportQueue   one transfer at a time, waiting, stop current / stop all, resume after reconnect
       ├─ DeviceLibraryLinks  what the library already holds, derived from tracks' device identity
       └─ DeviceBrowser       selection and presentation state for the device's views
```

- **Device kind** (`DeviceKind`): identity (`id` such as `soundcore.work`, name, short name,
  vendor, SF Symbol), the connection methods it supports in order of preference, the audio
  source label, whether more than one can be added, and its copy (discovery tips, technical
  notes).
- **Connection method** (`ConnectionMethodKind`):
  - `direct`: Daybook talks to the recorder (`DirectTransport`: Bluetooth LE, USB, local network).
  - `files`: a watched folder of exports. Implemented once, in `ImportFolderWatcher`, and given
    to every kind that declares it.
  - `account`: a vendor app or account. Declared so the architecture has a place for it; no kind
    implements it, because Daybook never sends audio off the Mac to be processed. Methods with
    `isImplemented: false` never appear in the interface.
- **Configured device** (`ConfiguredDevice`): one the person added: kind, name, which methods
  are turned off, and the automatic-import preference. Each method stores its own
  configuration (the remembered recorder, the folder bookmark) under
  `device.<id>.<method>.` in preferences.
- **Connection** (`DeviceConnection`): the common interface for one method of one device.
  - State: `ConnectionState` (`notSetUp`, `notConnected`, `searching`, `connecting`,
    `reconnecting`, `connected`, `unavailable`), `problem`, `lastConnectedAt`, `summary`.
  - Inventory: `recordings: [DeviceRecording]` with stable string IDs, start time, exact or
    estimated length, size, and whether it's still being recorded; `inventoryUpdatedAt`,
    `isRefreshing`, and `isInventoryCurrent` (listed since it connected and not being listed again;
    nothing imports from a list that isn't).
  - Status: `DeviceStatus` (battery, case battery, storage as hours, recording state,
    firmware, serial), live while connected and otherwise the last confirmed values with
    their time.
  - Capabilities: `DeviceCapabilities` (battery, case battery, storage, live listening,
    remote record control, details, wireless transfer). The device page shows only what's
    declared.
  - Operations: `activate`, `connect`, `disconnect`, `refresh`, `transfer(_:progress:)`
    (cancellable; throws `DeviceTransferError`; never returns partial audio),
    `automaticImports(links:since:excluding:)`, `didImport`, `forget`, `shutDown`.
  - Optional abilities as protocols: `DiscoveringConnection` (setup's search and connect),
    `RecordControlConnection`, `LiveListeningConnection`, `DetailedConnection`.
- **Session** (`DeviceSession`): runs the device's import queue. Import with an optional
  conversation to attach to; Stop current; Stop all; Remove from queue; Try Again. A
  disconnect puts the interrupted recording back at the front and suspends the queue; it
  resumes when that method reconnects. A stall or integrity failure gets one quiet retry
  (`DeviceRetryPolicy`), then a failure with Try Again. It holds an idle-sleep assertion while
  transferring, posts one notification per batch and one a day for low storage (bundled app
  only, and only while Daybook is in the background), and imports automatically where the
  method and preference allow.
- **Hub** (`DeviceHub`): owns the sessions, persists configured devices, runs setup (a device
  joins the sidebar only once one of its methods is set up), migrates the single folder and
  recorder of earlier versions, and follows the library to recompute each device's links.
  `add(_:)` adds a device set up elsewhere under its own ID (a phone paired over the link).
- **Kind-provided files method**: a kind may return its own connection for `.files` from
  `makeConnection`; otherwise it gets the shared `ImportFolderWatcher`. A connection that is
  `LibraryBackedConnection` gets the library's conversations whenever they change and lists its
  recordings from them (they're imported already, so nothing transfers).

## Library identity

`RecordingTrack` stores where a recording came from, all optional so existing libraries decode:

| Field | Example |
| --- | --- |
| `deviceKind` | `soundcore.work`, `recorder.files` |
| `deviceSerial` | the recorder's serial number, when it reports one |
| `deviceRecordingID` | `1729000000` (a Soundcore start time), `file:ZOOM0009.WAV|58200000` |

`MeetingStore.importAudio(..., device:)` writes it (and adds it to an existing track with the
same bytes). `AppState.importAudio(..., device:)` is the background import path: it dates the
new conversation at the recording's start, doesn't take the place being viewed or change the
selection, and joins a conversation that already holds the same bytes.

"Already in Daybook", "Recently imported", "Show Conversation", and live-to-full linking come
from `DeviceLibraryLinks`, so they survive sync and work on another Mac. The hub indexes the
library's recorder tracks by kind once per change (`DeviceLibraryIndex`), and a device rebuilds its
links only when its own tracks (or its recorder's serial) change, so editing notes costs no device
anything. A Listen Live portion is stored with the recording ID plus `~live`; a later full import of
that recording joins the same conversation.

- **Checked again at ingest.** Another device's import of the same recording can arrive through
  sync while this one transfers, and two decodes of one recording needn't be byte-identical. So the
  session, the Mac's device importer (`importFromDevice`), and the iPhone's (under its library lock)
  look the identity up once more right before ingesting (`DeviceLibraryLinks.meeting(holding:in:)`:
  kind and recording ID, the same recorder when both name a serial, never a Listen Live portion) and
  keep the conversation that has it. Moving a recording between conversations isn't an import and
  isn't checked. Two devices that both finish before either syncs still make two; ownership (below) is what
  keeps them from both importing.
- **Start dates.** `DeviceRecordingStart.date(of:)` reads a recording's start from its identity, for
  the new conversation's date and title and the device page's labels: Soundcore IDs are start times
  by the recorder's clock, less its measured offset ([direct Soundcore](direct-soundcore.md), "The
  recorder's clock").

## Automatic import (the default, and why)

- **Files**: everything that appears in the watched folder and is unchanged across two scans
  imports on its own, once. A file whose conversation is later deleted is offered again but
  not re-imported automatically.
- **Direct (Soundcore)**: "Import new recordings automatically" is **on by default**, because
  recordings that arrive without effort is what people want most from a wearable. It imports
  only recordings that **started after the recorder was added to Daybook**
  (`automaticImportsSince`), so adding a recorder that already holds months of audio, or
  recordings already brought in through the Soundcore app, doesn't start a long transfer the
  person didn't ask for. Older recordings are listed under New on Soundcore for one click.
- Nothing imports automatically until the library has loaded, because without it every
  recording would look new.
- Nothing imports from a remembered list either: only once the recorder has been listed on this
  connection (`isInventoryCurrent`). The remembered list can show a recording that was in progress
  as finished, and importing it early, under its final ID, would block the full one for good. A
  recording the recorder names as active is in progress whether or not it says it's recording
  (firmware may list the growing file, or keep a paused one open), so it waits, and a queued one the
  current list shows in progress leaves the queue.
- An automatic connection is let go 30 seconds after its imports finish, and the next attempt
  waits 15 minutes, so the phone app can reach the recorder. A connection the person made is
  let go after 5 idle minutes. The person can turn automatic import off in Settings › Devices.
- On iPhone that wait is a timer, and a suspended app runs none: the app-refresh task (registered
  with sync's, in `DaybookPhoneApp`) calls `DeviceHub.resumeAutomaticImportsIfDue()`, which starts
  the quiet connection once `automaticDueAt` has passed; iOS keeps it pending and wakes the app when
  the recorder answers.
- Audio a killed run left staged is removed when the hub starts (only `Soundcore-*.wav` older than
  the hub, so no transfer under way loses its file). The recorder still has all of it.

## What the recorder is recording

`SoundcoreConnection.recordingState` (`SoundcoreRecordingState`) is what this device knows:
`isRecording` (the recorder's flag), `activeRecordingID` (the file it names as in progress, also
when paused on firmware that keeps it open), `startedAt` (its start on this device's clock),
`asOf`, `isLive` (connected now), and `startedHere` (this device asked it to start). While
connected it's live. After the link goes (the idle release lets go even of a recording Daybook just
started), it's the last confirmed state for 20 minutes (`SoundcoreTiming.lastKnownRecording`): the
device's status says recording, pages read "Recording · as of 10:07 AM", the recording stays
Recording now, and then it's unknown again, because nobody can see it stop. The snapshot keeps
`activeRecordingID`, `info.isRecording`, and `statusUpdatedAt` (the as-of), so a relaunch knows too.
On iPhone, a recording it started and Listen Live get a Live Activity (docs/iphone.md).

## One owner per recorder

A recorder talks to one device at a time, so the iPhone and a Mac never both reach for it. Ownership is a `RecorderOwnership` (kind, serial number, owner's sync device ID, name, and class) in `LibraryMetadata.recorders`, keyed by kind and serial; the serial is the only identity every device sees the same way. It lives in the library's settings because they already sync with per-item last-writer-wins times and deletion markers (like folders and templates): the later claim wins, a release is a deletion marker that an older claim can't undo, and the field is optional, so earlier library files and journal versions decode and older Daybook versions ignore it.

- **Claiming.** `LibraryController.claimRecorder` when the person sets a recorder up on a device, or when a handoff (below) moves it there; `releaseRecorder(onlyIfOwnedBy:)` when it's removed there. No record means nobody claimed it, and every device behaves as before.
- **Honouring.** `DeviceHub.recorderOwnersChanged` (or `observeOwnership`) hands the records to each session, which applies them once its recorder's serial is known. While `managedElsewhere` is set, `SoundcoreConnection` never connects on its own (automatic import, reconnecting, multipoint) and `connect()` does nothing; a link already up is let go once idle, never mid-transfer, and the session starts no further transfer for it (what was waiting moves to the new owner). The page reads "Managed by Alex’s iPhone · Its recordings arrive through sync", and multipoint says "Soundcore Work is managed by Alex’s iPhone. Recording on this Mac only."

## Handing a recorder over

**Use on This Mac** and **Use on This iPhone**, from either device, move a recorder in one tap; the
device that manages it can also offer it (**Use on Studio Mac**, **Use on Alex’s iPhone**). It's
DaybookKit's `RecorderHandoff`, one per app (`AppState.recorderHandoff`, `PhoneDevices.handoff`),
with the app's link plugged in.

**Over the local link** (seconds), when the owner is connected and advertises the
`recorderHandoff` capability (docs/link.md, "Recorder handoff"):

1. The requester sends `recorder.handoff.request` (take, or give from the owner), addressed by the
   owner's sync ID, which capabilities now carry (`syncDeviceID`).
2. The owner answers `recorder.handoff.reply`: accepted, with what it finishes first (an import in
   progress with its time left, or Listen Live), or refused with a reason (`notOwner` with who does,
   `notSetUp`, `busy`, `declined`, `unsupported`). Updates follow every 5 s while it finishes.
3. The owner holds the session (`DeviceSession.holdForHandoff`: nothing new starts), lets the
   transfer in progress finish and Listen Live stop and save, takes what was waiting
   (`takeWaitingImports`), records the new owner, disconnects, writes the release into the synced
   record, and sends `recorder.release` with the waiting imports and the recordings it imported in
   the last day.
4. The new owner claims the recorder, adopts the imports (`adoptHandedOffImports`), and connects
   with no deadline (`connectWhenAvailable`), so a recorder still letting go is waited for rather than
   reported missing. The page says "Soundcore Work is on this iPhone now".

No answer within 5 s (an older build, or the link dropped) falls back to sync.

**Through sync**, when the owner isn't on the link: the request is a `RecorderHandoffRecord` in
`LibraryMetadata.handoffs` (one per recorder, last writer wins, cleared with a deletion marker).
The requester says honestly that it's waiting ("Waiting for Studio Mac to let go…", and after two
minutes "Studio Mac hasn't answered since 10:02 AM. It may be asleep, closed, or offline."). The
owner answers in the record at its next pass (`releasing`, `released` with the waiting imports, or
`refused` with words), then the requester takes over as above. **Stop Waiting** cancels it.
**Take Over Anyway** claims the recorder at once after a confirmation that says the risk: if the
other device is still connected, the recorder may not answer here until it hears and lets go
(finishing any import first); nothing on the recorder is lost. The new owner keeps trying with no
deadline. The old owner, hearing it was taken over, does the same as a release: finishes, lets go,
and hands over what was waiting.

**Safety rules**, whichever way it travels:

- *Transfers.* A transfer can't continue on another device: the protocol has no offset, and the
  session's resume after a drop starts the recording again from the beginning. So the one in
  progress always finishes on the old owner, nothing new starts there, and the rest move.
- *Recording.* Letting go never sends a command; a recorder that's recording keeps recording, and
  record control (Pause, Listen Live) is the new owner's once it connects.
- *Pending imports* continue on the new owner, which imports them when the recorder lists them
  (as automatic imports, so it asks for no notification permission). One the recorder no longer
  lists after a fresh listing is dropped; it's still on the recorder if it ever was.
- *No duplicates.* The library's identity (kind, serial, recording ID) keeps a synced recording from
  importing again. The gap is a recording the old owner imported that hasn't synced yet: the release
  names those, and the new owner neither offers nor imports them until they arrive
  (`DeviceSession.arrivingThroughSync`, at most a day). Tests check that each recording ends up in
  exactly one conversation on both devices.
- *A recording under way.* The release (and the synced record) carries `recordingInProgress`: the
  recording the recorder is making, and the conversation waiting for it (one whose recording asked
  the recorder to record too and hasn't got its track). The new owner keeps it among its adopted
  imports while it's in progress, imports it into that conversation once it's finished, and its
  device page says "For Design review". Optional fields; earlier builds neither send nor read them.

**Hand back** (iPhone, off by default; the device page's "Hand Back to My Mac When It’s Nearby"):
a recorder the iPhone took from a Mac goes back to that Mac when the Mac connects over the link,
the recorder is idle here (no transfer, no Listen Live), and the person hasn't chosen this iPhone in
the last 10 minutes. It's an offer the Mac accepts only if it has the recorder set up. It never
fires for a Mac that was already connected.

## Interface

The interface is generic and capability-driven:

- **Sidebar › Devices**: every configured device, with at most one accessory (a progress ring
  while importing, else a count of new recordings). The glyph is neon mint with a soft glow
  while a recorder is linked, secondary while it isn't, and the sidebar's colour for a watched
  folder. A `+` on hover adds a device.
- **List column**: Recording Now, the queue, New on <device>, and Already in Daybook (collapsed).
- **Device page**: the glyph hangs in the page margin; a status dot and byline; figure tiles
  for whatever status the method reports; Import N New; How recordings arrive (each method in
  preference order, with one action); Recently imported. Problems use one banner with at most
  two actions.
- **Add Device…** (File menu, sidebar, Settings, Welcome): choose a kind, then its methods in
  order of preference. The first is marked Recommended. A direct method's card is the
  pre-permission screen; its one button starts the search.
- **Settings › Devices**: per device, its methods and preferences, Forget… and Remove….
- **Menus**: File › Add Device… and Import from <device>…; Add Recording › From <device>…;
  the menu bar extra's per-device line (a handoff under way, or Use <recorder> on This Mac).
- **Handoff** (Mac): a bare line under the page's byline while a handoff works, a quiet box when it
  needs the person (refused, or waiting past its patience) with Take Over Anyway… and Stop Waiting;
  the More menu's Use on This Mac / Use on Alex’s iPhone; Settings › Devices' "Managed by" row.
  `--device-demo not-connected --handoff-demo waiting|overdue|finishing|refused|managed|done` (and
  `--device-demo importing --handoff-demo handing`) show each state.

## Listen Live captions

A recorder that streams live audio (`LiveListeningConnection`: Soundcore Work today) is captioned
on the shared `DaybookCaptions` engine, the same one the iPhone's recordings and the Mac's own
recordings use (docs/iphone.md, "One live-caption engine"). Captions are tentative proof that the
audio is arriving: never saved, synced, fused, summarized, or used as evidence; the saved portion
is transcribed in full later. This replaced chunked WhisperKit previews (15-second windows sent to
a second local runtime), which are gone, with their plumbing (`LiveTranscriber`,
`LiveTranscriptionError`, and the app's preview runtime).

- **Feeding.** `SoundcoreConnection` makes one captioner per Listen Live from
  `DeviceEnvironment.liveCaptions` (`LiveCaptionHooks`, shared by reference so the app can point it
  at its settings) and hands it every decoded packet as it arrives: 16 kHz mono, at the recorder's
  own rate and in its own bursts (what it recorded before listening began, then as it records). Each
  packet is stamped with its sample position in the live audio, and the captioner counts from zero
  (`timelineOrigin: 0`), so the engine's time map keeps every caption at its place even when it
  drops audio. Its backlog is raised to about a minute of 20 ms packets (`LiveCaptionHooks.backlog`);
  past that the oldest wait is dropped, never the audio being saved.
- **Defaults.** The hooks' default makes the Speech framework's captioner where it exists (macOS 26,
  iOS 26) in the device's language, never downloading one. The Mac points them at Settings › General
  › Live Captions (the same switch and language as its recordings, downloading the language when
  the person listens). On the iPhone the default applies until the app sets its own.
- **What the session publishes** (`DeviceSession`, `@MainActor`, an `ObservableObject`), for the Mac's
  device page and the iPhone's status sheet:
  - `liveCaptions: [LiveCaptionSegment]`: oldest first, tentative text replaced in place, then final;
    empty when not listening, or when captions are off or can't run. Read-only; demos set the
    connection's `live.captions`.
  - `isListeningLive: Bool`: the recorder's live audio is arriving on this device.

  The connection's `LiveCapture` also has `captionState` (`LiveCaptionState`: getting ready,
  downloading, listening, unavailable and why, or stopped), which the Mac's page uses for its status
  line. When listening ends the captions go with it and the captioner finishes on its own.
- **The Mac's page.** Listening shows "Live captions · tentative" and the newest six lines under the
  saved time (`LiveCaptionFeed`): the latest in Body, earlier in Secondary, words still being
  revised in Meta. Nothing shows when captions are off or on macOS 15.
- **Tests** (`SoundcoreSimulatorTests`, with a captioner that records what it's fed): bursts of ten
  packets and a quiet spell from the simulator (`Fault.pause`) arrive back to back on the live
  audio's timeline at 16 kHz, captions reach `DeviceSession.liveCaptions` and go when listening
  stops, the inert link never makes a captioner, and the session mirrors any `LiveCapture`.

## Daybook on iPhone

The iPhone app is a recorder of this Mac's (`daybook.iphone`; docs/iphone.md). Its tracks carry
that kind, the phone's device ID as serial, and the phone's recording ID.

| Method | What it is |
| --- | --- |
| `files`, "Through iCloud" (first) | `SyncedPhoneRecordings`: the phone's recordings in the library, which arrive with sync. Connected while sync is on; "Sync is off" otherwise. Each phone lists its own; a track whose serial is no paired phone's counts for every phone, so a single phone still lists its recordings if the IDs ever differ |
| `direct`, "Over Wi‑Fi" | `PhoneLinkConnection`, the app's adapter over DaybookLink (DaybookDevices can't depend on it, so the app supplies it through `DeviceEnvironment.phone`). Connected while the phone has a session; record control (`AnsweringRecordControl`, docs/multipoint.md), the phone's recording state, and its clock. Connect and Disconnect do nothing: the phone connects to the Mac |

- **Pairing.** Add Device › Daybook on iPhone, or Settings › Devices › Add iPhone…, opens the
  pairing step: the code from `LinkService.beginPairing()` and the instructions, a new code after a
  failed attempt (with why), "Paired with <name>", and the paired phones, each with Unpair. A paired
  phone joins Devices under its link ID. Unpairing (either side) removes the device; its recordings
  stay and keep arriving through sync.
- **When the link runs.** Only while pairing is open or a phone is paired: a Mac nobody pairs with
  never opens a listener, and `LinkService` advertises over Bonjour under the same rule. Tests use
  loopback and memory keys.
- **Device page.** Paired and connected or when last seen, what it's recording now (with Stop on
  iPhone), how recordings arrive, and its recent recordings. The list column shows all of them, as
  they're all in Daybook.
- **Settings › Devices.** Over Wi‑Fi status, Also record on <iPhone> when this Mac records, how
  recordings arrive (with a link to sync settings when it's off), and Unpair….
- **Bluetooth ownership** of a Soundcore shared with the phone is a synced device setting, moved
  between them by the handoff above.

## Debugging without hardware

- `--device-demo <scenario>` loads representative states for every surface. Scenarios are listed
  at the top of `Devices/Demo/DeviceDemo.swift`. Demos use an inert transport: they never scan,
  connect, or ask for Bluetooth permission. `live` shows Listen Live with captions.
- `--demo-captions` scripts Listen Live's captions (no speech recognition), for the simulator.
- `--device-simulator` runs the real Soundcore connection against `SimulatedSoundcore`, a
  recorder that speaks the protocol from generated fixtures. Its devices live in a throwaway
  preferences suite. Add `--autopilot` to walk through Add Device, connect, and import on its own.
- `--device other` opens the Other Recorder in a demo; `--snapshot-appearance light|dark` sets
  the appearance; `--place device` opens the first device.

## Adding a device kind

1. **Declare the kind.** Add a `DeviceIntegration` in `Sources/DaybookDevices/<Kind>/` with a
   `DeviceKind`: a stable `id` (it's stored on every imported track; never change it), name,
   short name, vendor, SF Symbol (check availability for macOS 15), methods in order of
   preference with their setup copy, audio source, `allowsMultiple`, discovery tips,
   and honest technical notes.
2. **Register it** in `DeviceCatalog.integrations`. The files method now works with no other
   code: setup, the sidebar, the page, Settings, menus, and automatic import.
3. **For a direct method**, separate three layers so it can be tested without hardware:
   - a transport protocol (radio state, scan, connect, disconnect, send, received bytes), with
     the real implementation (CoreBluetooth, IOUSBHost, Network.framework) behind it;
   - a protocol session that turns commands and replies into async calls with timeouts, and
     accepts a transfer only after every integrity check passes;
   - a `DeviceConnection` that owns the state machine: remembered device, reconnect with
     backoff, radio and permission changes, idle release, and `transfer` that stages audio and
     deletes partial files before throwing.
   Return it from `makeConnection(_:for:environment:)`, and add any optional abilities
   (`DiscoveringConnection` for setup, record control, live listening, details).
4. **Never** send commands that delete, reset, rebind, or update the device. Never import
   undecodable or incomplete audio. Never send audio to a server.
5. **Simulate it.** Write a simulated device that speaks the protocol from fixtures, with fault
   injection (drops, gaps, stalls, wrong sizes), and integration tests like
   `SoundcoreSimulatorTests`. Add parser fuzzing like `SoundcoreProtocolTests`.
6. **Demo it.** Add scenarios in `DeviceDemo`, capture every surface in light and dark.
7. **Document it** in `docs/` and record what's verified on hardware in `docs/validation.md`.

### Worked example: Plaud NotePin

What we know (research, October 2026): Plaud's app transfers recordings over Bluetooth, can
switch to a Wi-Fi "Fast Transfer", and **deletes recordings from the device after they
transfer**. USB access is disabled on Plaud Note from firmware 2.1, and NotePin S doesn't
support it. The Mac route Plaud offers is its cloud.

What a `plaud.notepin` integration would need:

| Step | Plaud NotePin |
| --- | --- |
| Kind | `id: "plaud.notepin"`, name "Plaud NotePin", short name "Plaud", vendor "Plaud", its own SF Symbol (not Soundcore's), `allowsMultiple: false`, `audioSource` a new `.plaud` case or `.imported` |
| Methods, in order | `files` first (export from the Plaud app to a watched folder: works today with no new code); `direct` over Bluetooth LE declared with `isImplemented: false` until its protocol is researched and verified; `account` declared, never implemented |
| Setup copy | The Plaud app's own delete-after-transfer behaviour means people who also use the app may find nothing new on the device; setup should say so |
| Direct, if pursued | A `PlaudTransport` (CoreBluetooth), a `PlaudSession` (its commands, paging, any encryption, and integrity checks), and a `PlaudConnection: DeviceConnection, DiscoveringConnection` with stable recording IDs (a start time if the device reports one). Wi-Fi Fast Transfer would be a second direct transport (`.localNetwork`) |
| Never | Delete-after-transfer, binding changes, or cloud upload |
| Tests | A `SimulatedPlaud` and integration tests for listing, import, reconnect, and integrity failures |
| Validation | Physical hardware on current firmware before calling the direct method supported |

With only the files method, step 1 and 2 are the whole integration.
