# Audio pipeline and hardware (Mac capture, iPhone capture, Soundcore Work, devices, playback)

Reviewer lane: the audio pipeline on macOS and iOS and hardware integration. This was a code review against `design-pass-2026-11`. I read docs/capture.md, devices.md, direct-soundcore.md, soundcore.md, iphone.md, alignment.md, multipoint.md and the validation sections, then the code.

Two read-only sub-reviews ran alongside mine:
- **Soundcore protocol stack.** IDs `SC-`. Evidence from `Sources/DaybookDevices/Soundcore/*`.
- **Device framework, handoff, and iOS background Bluetooth.** IDs `DF-`.

I checked their high findings myself (SC-01 = DF-01, SC-02, DF-02); the other SC/DF rows are their evidence. My own findings are `AH-`. Nothing was recorded, nothing in the repository was changed, and no real library was touched. One scratch probe was run (below).

## 1. Summary

The capture design is careful.
- Both apps write crash-safe originals with tested recovery: a Mac CAF that was never closed, and an iPhone fragmented M4A read to its last fragment.
- Timelines rest on host or continuous clocks, with per-second clock anchors and outlier-rejecting drift fits.
- Echo removal is offline, deterministic, bounded in memory, and leaves the original untouched.
- Soundcore never sends a delete.

The weaknesses are in what happens when the real world misbehaves.

**Ways a recording ends early or silently stops hearing:**
- On the Mac, the call writer's backlog is 256 buffers. For a process tap that is about **2.7 s**. A short disk stall therefore ends the whole recording, microphone included (AH-01).
- One failed microphone restart, or a 21st device change, ends it too (AH-04).
- A >5 s timing gap ends it (AH-05).
- Both apps' "the microphone is silent" check is sticky. A mic that goes to digital zeros mid-meeting (a closed MacBook lid in clamshell mode, a mute button, a dead interface) is never reported (AH-03).
- A Mac going to sleep also stops the Soundcore and iPhones that were recording along (AH-07).

**Device side:**
- A record-along Start queued behind a running import fires minutes later, after Daybook said "didn't start", and nobody stops it (SC-01/DF-01).
- One gap in Listen Live deletes all live audio so far (SC-02).
- An iPhone relaunched in the background grabs a recorder the Mac manages before it knows the ownership (DF-02).

**Quality and cost:**
- Mac originals are Float32 PCM. A typical call is about **2.3 GB an hour**, synced to iCloud as-is, against 29 MB an hour on the iPhone. A one-hour Mac call is bigger than the iPhone's whole 1 GB audio cache.
- Soundcore imports store decoded Float32 (230 MB/h) instead of the recorder's 29 MB/h Opus.
- Playback plays **one recording at a time**. Playing a Mac call from the start plays only the raw microphone, so on headphones the other side is missing (AH-02).
- There is no microphone choice on either app. With AirPods connected, both apps can record through (and, on the Mac, likely force into call mode) a headset nobody chose (AH-08, AH-09).

**The biggest opportunities:**
1. A capture policy that never ends a recording for a recoverable fault and always says when it can't hear.
2. Record commands that pre-empt transfers.
3. Compact originals.
4. Whole-conversation playback built on a per-track analysis (loudness, SNR, speech map). The same analysis is the right way to finally wire SNR into fusion (MSCQ-09).

## 2. Redesign proposals

Ranked by risk to a real recording being lost or degraded, then by quality gained.

### P1. A recording ends only when someone stops it, and it says when it can't hear (Mac and iPhone)

**What and why.** A recorder's first duty is to keep the audio. Today several recoverable conditions end the Mac recording outright: a writer backlog of 2.7 s, a timing gap over 5 s, a failed or 21st microphone restart. Other conditions go unnoticed: a source that stops delivering without an error, a microphone delivering zeros after it once heard something, a disk filling up at 2.3 GB/h. The iPhone already shows the better policy: gaps up to 5 minutes are padded, and backward jumps resync instead of stopping (PhoneTrackWriter.swift:144-154). The principle is the HIG's "keep people informed": problems surface where the person is looking, and the recording continues.

**Seam and files.**
- `PCMTrackWriter` (Sources/Daybook/Capture/PCMTrackWriter.swift), `RecordingController`, `MicrophoneSource`, `ProcessTapSource`, `ScreenCaptureAudioSource`.
- iPhone: `PhoneTrackWriter`, `PhoneRecorder`, `AudioLevelMeter`, `PhoneNotices`.
- Shared words: `RecordingWords`, DaybookUI `RecordingStatusWords`.

**Behaviour.**
- **Backlog.** Counted in seconds of audio, not buffers: at least 30 s per source, on both apps. On overflow the buffer is dropped and counted, and the existing host-time gap code pads the hole when writing catches up. The track notes "2.4 s of call audio were lost while the disk was busy". Only a writer that hasn't advanced in 60 s stops the recording, and a call-track problem never stops the microphone.
- **Gaps.** The Mac adopts the iPhone's rule: pad up to 5 min, start a new clock segment beyond that, and resync (dropping overlap) on a backward jump. Never stop.
- **Microphone restarts.** Limited by rate (more than 10 in 60 s), not lifetime. A failed restart is retried at 0.25, 0.5, 1 and 2 s, then on the built-in microphone, before it counts as a failure.
- **Stall watchdog.** The 15 Hz meter timer reads each writer's last-buffer host time. More than 3 s without a buffer while recording means:
  - the microphone engine restarts;
  - the tap rebuilds;
  - ScreenCaptureKit restarts once on the main display.

  A `kAudioHardwarePropertyServiceRestarted` listener rebuilds everything after coreaudiod restarts.
- **Hearing check (rolling).** "Not hearing" means no non-zero sample in the last 5 s, or below −90 dBFS for 20 s. It replaces the sticky `receivedSignal` on both apps and is said where the person looks:
  - Floating Notes: "The microphone isn't hearing anything", with the input's name and Choose Microphone… (P4);
  - the iPhone's recording surface and Live Activity;
  - a notification when Daybook isn't in front.
- **Space.** Every 30 s the free space is divided by the current byte rate:
  - 30 minutes left: a warning;
  - 3 minutes left: the call track stops first (two thirds of the bytes on the Mac), and the microphone goes on.
- **Sleep (Mac).** Hold `ProcessInfo.beginActivity([.idleSystemSleepDisabled, .userInitiated])` while recording; today only device transfers do (DeviceSupport.swift:20). A forced sleep (the lid) still stops this Mac's tracks, but no longer pauses hardware recorders or stops iPhones recording along. On wake, Floating Notes says "Soundcore Work and Alex's iPhone kept recording" with Stop, and their files join the conversation as today.
- **Pauses (iPhone).** An interruption that ends without a resume recommendation, or a resume that fails, posts "Recording paused" with Open Daybook to Resume. Resume is retried when the app next becomes active.

**Test without hardware.**
- A writer with an injected per-write delay: a 5 s stall must keep both tracks, pad, and record the loss.
- Fake sources that stop delivering; that send zeros after speech; that emit 30 device changes in 10 minutes; whose restart fails twice then succeeds.
- Host-time jumps of +8 s and −0.5 s.
- A fake free-space provider.
- On iPhone, the `ScriptedAudioSession` interruption without `shouldResume` must post the paused notice.

**Needs hardware.**
- A real disk stall (library on an external HDD while Time Machine runs).
- `sudo killall coreaudiod` mid-call.
- Clamshell lid-close on the built-in mic.
- AirPods connecting and disconnecting 20+ times in a long meeting.
- A phone call in a pocket recording.

**Risks.** Changing "stop" to "continue with a gap" moves failures from loud to quiet, so the note and the visible state must be reliable. The sleep change reverses docs/multipoint.md:98-99, which needs a line in that doc.

**Size.** L (Mac M, iPhone S, words and notices S).

### P2. Record commands come before transfers, and live audio survives a gap (Soundcore)

**What and why.** `setRecording` and `download` share one lock (`exclusiveWhenQuiet`, SoundcoreSession.swift:285-303, 385-405). A record-along Start therefore waits behind an import of 12–24 minutes.
- The cascade gives up after 15 s and says the recorder didn't start.
- The queued Start still fires when the import ends. On the iPhone nothing stops that recording.
- The clock offset is measured from a `sentAt` taken before the wait, so every recording's date shifts by the wait (SC-01/DF-01, verified).

Separately, any sequence gap in Listen Live calls `abort`, then `finish(.failure)`, which deletes the file (SoundcoreSession.swift:589-611, 676-680, verified). A shared recording loses its live portion and captions source. A Bluetooth drop also ends live capture for good (DF-06).

The principle is that a control the person (or the cascade) uses must act now, or not at all.

**Seam and files.**
- `DeviceSession.recordCommand(_:deadline:) async -> Outcome`, implemented by `SoundcoreConnection.sendRecording` and `SoundcoreSession`.
- Callers: `RecorderCascade`, `MultiSourceCoordinator`, `LinkRecorders`.

**Behaviour.**
- A Start or Pause stops a non-live transfer (`1A 11`), requeues it at the front (not counted as an attempt), sends the command, then resumes the queue.
- The command carries a deadline and a cancellable handle. When the caller gives up, a queued command is dropped. A command that was already sent and confirms late is reversed (a Start nobody waits for gets Pause).
- `sentAt` is taken when the write goes out.
- For live transfers, a gap or undecodable packet keeps what arrived. The gap becomes silence, sized by sequence number × 20 ms, with a note. Capture re-arms when the connection returns (DF-06).
- The meter and captions say "Catching up…" until the stream position reaches real time (DF-07).
- Companion fix (DF-02): the iPhone applies last-known ownership from device storage before `hub.start()` (DaybookPhoneApp.swift:73; PhoneDevices.swift:161-172).

**Test without hardware.**
- `SimulatedSoundcore` with a paced transfer (as RecorderHandoffTests does): start a cascade mid-import, then assert the recorder starts within the deadline, or never.
- The simulator's `skipSlice` during live: the live file survives, with a padded gap.
- A disconnect mid-live then reconnect: captions resume.

**Needs hardware.** Whether firmware accepts Start right after `1A 11`, the latency, and whether a mid-transfer stop leaves the recorder in a good state (checklist item 1).

**Risks.** Pre-empting a transfer near its end wastes work. Exempt transfers within ~10 s of finishing.

**Size.** M.

### P3. The iPhone finishes a recording safely in the background, without re-encoding it

**What and why.**
- Stop deactivates the audio session (PhoneRecorder.swift:270) before joining segments (281-287), and nothing holds background time. `beginBackgroundTask` appears only in PhoneSync.swift:322 and PhoneDevices.swift:201.
- A Stop from the Lock Screen, Siri, or a Mac comes while Daybook is in the background. After a long recording with even one interruption, the join decodes and re-encodes the whole recording (RecordingAssembler.swift:51-87). iOS can suspend that midway.
- On next launch the journal still says recording, so a clean stop is labelled "Daybook quit while recording…".
- Every joined recording's original is also a second-generation 64 kbps AAC (AH-10, AH-11).

The principle: originals are kept as captured (AGENTS.md, "Preserve originals").

**Seam and files.** `RecordingAssembler.assemble`, `PhoneCaptureFinisher`, `PhoneRecorder.stop`, `PhoneAppModel.stopRecording`.

**Behaviour.**
- **Joining is passthrough.** `AVAssetReaderTrackOutput(outputSettings: nil)` reads each segment's AAC packets. `AVAssetWriterInput(outputSettings: nil, sourceFormatHint:)` appends them with re-timed PTS. Gaps are filled with AAC silence encoded once in the same format.
- **Priming.** Each later segment carries its encoder priming (2,112 frames). The preceding silence is shortened by that much, so the timeline stays within one AAC frame (21 ms), and the priming falls inside a pause.
- Joining a 3-hour recording becomes a copy of about 90 MB, seconds of I/O.
- Stop holds a `UIApplication` background task from the first line of `stopRecording` until filing hands off to sync. A join still expected to run long (a decode fallback for a format change) runs as a `BGContinuedProcessingTask` (iOS 26) titled "Saving recording".
- The journal records `state = .stopping` before the session goes, so a later recovery says "Saved after Daybook was interrupted while saving" rather than "quit while recording".

**Test without hardware.**
- Interrupt-and-resume recordings in `PhoneRecorderTests`: assert byte equality of each segment's packets inside the joined file, total duration within 21 ms, note and bookmark times unchanged.
- A recovery from a `.stopping` journal.

**Needs hardware.** A 2-hour recording with a phone call, stopped from the Lock Screen: time to "Saved", and no relabel on next launch.

**Risks.** Passthrough needs identical formats across segments. Today they are (48 kHz mono AAC 64k), but keep the decode path as a fallback.

**Size.** M.

### P4. Choose the microphone; never put headphones into call mode

**What and why.**
- **Mac.** The Mac records the system default input (MicrophoneSource.swift:47-53). With AirPods connected, macOS commonly makes them the default input. Daybook then opens their microphone, which switches them to the hands-free profile for the whole meeting: narrowband in both directions for the person, a 16/24 kHz You track. That happens even when the call app deliberately uses the built-in microphone.
- **Mac, call tap.** The call tap's private aggregate includes the output device as a sub-device, and its input streams come first in the IO list (ProcessTapSource.swift:146-157, 204-208). With AirPods as output, that may trigger the same switch. Suspected; needs hardware.
- **iPhone.** `.allowBluetoothHFP` makes a connected headset the input automatically (AudioSession.swift:113-115). A phone lying on the table records the meeting through the AirPods in its owner's ears, and everyone else is faint.
- **Neither app** offers a choice.

The principle is Apple's own behaviour: the input a recording uses is visible and changeable, as in QuickTime's and Voice Memos' input menus.

**Seam and files.**
- A pure `MicrophoneChoice.resolve(devices:runningElsewhere:preference:) -> Device`.
- Mac: `MicrophoneSource` sets the device on `engine.inputNode.auAudioUnit` (`setDeviceID`) and listens to `kAudioDevicePropertyDeviceIsAlive` and default-device changes. Settings › Recording › Microphone. Floating Notes' input name (FloatingStatusFeed.swift:165-182) becomes a menu.
- iPhone: `LiveAudioSession` with `setPreferredInput`, and an input row on the recording surface (RecordingComponents.swift:26) listing `availableInputs`.

**Behaviour.**
- **Automatic** is the default on both. Use the default input, except a Bluetooth headset whose input no other process is using (`kAudioDevicePropertyDeviceIsRunningSomewhere` false). Then use the built-in microphone, so Daybook never flips headphones into call mode. If the call app already uses the headset microphone, record it.
- On iPhone, Automatic means the built-in microphone unless the person picks the headset. The choice is remembered per port type.
- The chosen input shows as "MacBook Pro Microphone ▾" or "iPhone Microphone ▾".
- **Tap.** Measure on hardware whether today's aggregate flips AirPods. If it does, build a tap-only aggregate (no sub-device list).

**Test without hardware.** Policy fixtures (AirPods idle, AirPods in use by Zoom, a USB mic, built-in only), and a fake source asserting the device set before start and the fallback when the chosen device dies.

**Needs hardware.** AirPods (H2 and older), a USB headset, a Zoom call on the built-in mic, then on AirPods (checklist item 4).

**Risks.** Picking a non-default device means Daybook must follow its removal itself.

**Size.** M.

### P5. Echo removal that cannot remove your own voice

**What and why.** The delay search accepts the microphone *leading* the call by up to 250 ms (EchoDelayEstimator.swift:40, 105-111). A real echo can lead only by timestamp skew, a few milliseconds. A strong negative peak means the call track carries the person's own voice:
- a colleague's unmuted laptop in the same room;
- a hybrid room system;
- a shared video of yourself.

The canceller then shifts the reference *forward* by that lead (EchoRemover.swift:288, 294) and learns to subtract the person's own words from You. Those words survive only in the call transcript, attributed to someone else.

Separately, windows with no confident echo inherit a neighbour's delay and are still filtered and suppressed (EchoRemover.swift:257-277). A recording that moves from speakers to headphones keeps processing the headphone part.

The principle: a derived track must never be worse than its original for the purpose it replaces it for.

**Seam and files.** `EchoDelayEstimator` (lead limit), `EchoRemover.plan`/`cancel`, `EchoRemovalSkipReason`, `CaptureFinalizer`.

**Behaviour.**
- The lead is limited to 30 ms, widened to 80 ms for ScreenCaptureKit if hardware shows skew.
- A confident peak beyond the lead limit means skipping, with new reason `callCarriesYourVoice` ("Your voice was also in the call audio, so the microphone is transcribed as recorded").
- Stretches with no measured echo, or headphones per the route log, are passed through untouched, with 20 ms crossfades.
- A self-check after cancellation, in microphone-only stretches (call below −55 dBFS): the derived/original energy must be within 1 dB. If it is worse than −3 dB, the result is `failed(selfCheck)` and the original is transcribed.

**Test without hardware.**
- Synthetic: a call track containing the near-end voice delayed by 200 ms, with headphones (expect skip, near-end correlation ≥ 0.95).
- Speakers for 60 s, then headphones with double talk (expect bypass after the switch).
- Existing ERLE tests must still pass.

**Needs hardware.** Two laptops in one room on one Meet call (checklist item 9); a Bluetooth speaker's skew.

**Risks.** A too-tight lead limit could reject a real echo if a capture path stamps audio late. Measure the skew per path first.

**Size.** M.

### P6. Compact originals everywhere

**What and why.** Mac originals are Float32 at the device rate: the microphone (MicrophoneSource.swift:49, PCMTrackWriter.swift:132-133), a stereo call (ProcessTapSource.swift:130; CaptureSources.swift:124-125), and a 16 kHz Float32 derived copy (EchoRemover.swift:115-117).

| Source | Today | Proposed |
|---|---|---|
| Mac microphone (mono) | 0.69 GB/h | ALAC 24-bit, lossless; to be measured, est. 0.2–0.3 GB/h |
| Mac call (stereo) | 1.38 GB/h | ALAC 24-bit, or AAC 128 kbps stereo (58 MB/h) |
| Mac derived (16 kHz) | 0.23 GB/h | ALAC 16-bit, est. ~60 MB/h |
| **Mac total** | **≈2.3 GB/h, 9 GB for a 4-hour meeting** | **est. 0.3–0.5 GB/h** |
| iPhone | 29 MB/h | unchanged |
| Soundcore import (SC-08) | 230 MB/h (Float32 WAV) | recorder's Opus, 29 MB/h |
| Video file import | the whole movie, video included | the audio track only |

- All of it is copied into the library and synced to iCloud byte for byte (icloud-sync.md:123).
- An iPhone playing a one-hour Mac call downloads 1.4 GB against a 1 GB cache budget (icloud-sync.md:137).
- A movie import keeps its video and syncs it, though only its audio is used (AppState.swift:838; MeetingStore.swift:290, 324-330). I confirmed with `afinfo` on generated .mov and .mp4 files that AudioFile reads their audio, so this is size, not correctness.

**Seam and files.**
- Mac: a `CaptureEncoder` step in `CaptureFinalizer` after echo removal (which keeps reading the Float32 staging files), before `ingestCapture` (AppState.swift:1499-1540).
- Soundcore: SC-08/R1, a slot journal kept as the original.
- Imports: `AppState.importAudio` and the iPhone's file importer extract the audio track by passthrough.

**Behaviour.**
- Each encoded file is written in staging and its SHA-256 saved in `capture-result.json` before import, so crash recovery re-ingests the same bytes and dedupe by digest still works.
- Mic and derived tracks use lossless ALAC: samples stay as captured (Float32 → 24-bit is exact for ADC audio within ±1.0), and echo removal can run again later.
- The call may use AAC, because it already came through a VoIP codec.
- Older conversations keep their CAFs. A later "Compact older recordings" is optional.

**Test without hardware.**
- Round-trip: ALAC-decoded samples equal the 24-bit-quantized Float32 input.
- Recovery after a crash between encode and ingest re-ingests the same digest.
- Movie import stores an .m4a whose audio packets equal the movie's.

**Needs hardware.** Measured GB/h on real calls (checklist item 12).

**Risks.**
- Tests and the doc assert "originals byte-identical" to capture; they change to "sample-identical".
- A tap's float audio above 0 dBFS would clip at 24-bit integer. It was clipped at the DAC too, but note it.

**Size.** L.

### P7. Listen to the whole conversation, level-matched, from one per-track analysis that also feeds fusion

**What and why.** Both apps play one file (PlaybackEngine.swift:59, 95, `AVAudioPlayer`). Play from the start resolves to the first present track covering the time (MeetingEvidence.swift:74-85). For a Mac capture that is the raw microphone, imported first (AppState.swift:1512-1518), so on headphones the other side is silent. Tapping a You line plays the 16 kHz echo-cancelled copy; tapping a Them line plays the call. Levels differ by 10–20 dB between a laptop mic, a call, and a phone on a table, and nothing normalizes them.

Separately, MSCQ-09: SNR weighting exists in fusion (MultiSourceFusion.swift:598), but no production caller passes profiles (TranscriptFusion.swift:68).

The principle: a meeting recorder's playback is the meeting, as heard.

**Seam and files.**
- `PlaybackEngine` gains a conversation mode on `AVPlayer` + `AVMutableComposition`. Each placed recording becomes one composition track at its offset (and `scaleTimeRange` when its drift exceeds 50 ppm over the length). The echo-cancelled copy stands in for the raw mic where one exists; otherwise the raw mic. An `AVAudioMix` sets per-track volume, and `audioTimePitchAlgorithm = .timeDomain` handles 1.5–2× speech.
- `PlaybackTarget` resolves to timeline time.
- A new `TrackAnalysis` is stored on `RecordingTrack` and computed where the audio is: after capture, file import, or device import. It holds:
  - integrated loudness (BS.1770, gated);
  - SNR per 5 s as UInt8 dB (about 3 KB an hour);
  - speech regions, run-length encoded.

**Behaviour.**
- Play from anywhere plays every source together, each brought to about −20 LUFS (gain capped at +12 dB, with a limiter).
- A recording's own menu keeps "Play This Recording Only".
- The same analysis:
  - weights fusion by SNR (MSCQ-09);
  - offers Skip Silences in the player;
  - lets transcription skip non-speech stretches of long recorder files;
  - backs the "quiet recording" note.
- On iPhone, playback starts with the local tracks and adds the rest as they download.

**Test without hardware.**
- Sine sources at known offsets in a composition: their phase lines up at the timeline time.
- Analysis on signals of known LUFS and SNR.
- Existing fusion weight tests, with stored profiles.

**Needs hardware.** None essential; listening tests on the owner's real meetings.

**Risks.**
- Mixing a raw mic with echo and the call doubles the far end. Always prefer the cleaned copy or mute the raw mic during call-only stretches.
- Composition seek precision on AAC is fine for speech.

**Size.** L.

### P8. A device abstraction a second recorder brand can use

**What and why.** QUAL-07 removed the downcasts from `DeviceSession`, but Soundcore still leaks into shared code (DF-15):
- `DeviceEnvironment.soundcoreTransport`, `soundcoreTiming` and `soundcoreWiFi` (DeviceKind.swift:260-279);
- `DeviceRecordingStart` dating only Soundcore IDs (DeviceLibraryLinks.swift:131-143);
- leftover-staging cleanup matching only `Soundcore-` (DeviceHub.swift:92);
- the iPhone's single restore ID `phone.soundcore` (PhoneDevices.swift:55, 88);
- `AudioSource.soundcore` persisted in the model (Models.swift:30);
- kind-ID branches in `RecorderStatusWords` (542-549, 576, 583);
- `SoundcoreIssue` matched in DaybookUI's `AddRecorderFlow.swift:134`.

A second Bluetooth brand would fight Soundcore over CoreBluetooth restoration.

**Seam and files.** A `DeviceIntegration` per kind provides:
- the transport factory, with a per-kind hooks bag replacing the `soundcore*` fields;
- recording start and clock;
- problem words;
- the staging prefix;
- status words.

Around it:
- One shared `BluetoothCentral` per app (one restore ID) routes peripherals by service UUID.
- `AudioSource.recorder` plus the kind from `track.device`; `@Extensible` tolerates the new raw value.
- A `volume` variant of `ImportFolderWatcher` covers USB mass-storage recorders: bookmarked by volume UUID, "not connected" when unmounted, identity by content digest.

**Test without hardware.** A `FakeRecorderIntegration` driven through hub, session, handoff, cascade and status words, plus a lint that `SoundcoreWorkIntegration.id` appears only under `Soundcore/`.

**Risks.** A persisted enum case changes; old values must still decode.

**Size.** L.

### Options weighed and not proposed

- **Apple voice processing.** Keep it off for originals, as capture.md argues.
- **Real-time echo cancellation for live captions.** Feasible: run `EchoCanceller` in streaming mode on the 16 kHz caption feed once a rolling GCC-PHAT has a delay. But `CaptionEcho`'s word rule already hides echoed lines, so the value is low.
- **iPhone stereo capture.** The built-in microphone's `.stereo` polar pattern would double size for models that read mono. Not now.
- **APAC.** Spatial and irrelevant here.
- **Per-participant call capture.** There is no local API. Zoom and Teams expose per-person audio only to SDK bots; diarization stays the way.
- **macOS microphone modes.** Voice Isolation exists only through VPIO, so leave it to call apps.

## 3. Findings

Severity: high = a recording can be lost or a person is misled; medium = degraded or flaky; low = polish. Ordered by severity.

| ID | Sev | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| AH-01 | high | **Mac:** a 2.7 s disk stall ends the whole recording. The writer allows 256 queued buffers. A process tap delivers ~10.7 ms buffers (512 frames), so that is ~2.7 s. Overflow raises `diskBacklog`, and `writerFailed` stops the whole recording for any `PCMTrackWriterError`, even from the call track. The sidecar is rewritten on the same queue (AH-18), which adds to stalls. | PCMTrackWriter.swift:77, 93-99, 184-187; RecordingController.swift:260-264, 313-323; capture.md "1,024 of the call's ~10 ms IO cycles" | P1: a backlog counted in ≥30 s of audio; drop and pad on overflow; stop only after 60 s with no progress; never stop the mic for the call. | S |
| AH-02 | high | **Playback:** a call plays one side only. Both apps play a single file. Timeline playback picks the first present track, which for a Mac capture is the raw microphone (imported first). On headphones the other side is absent. A You line plays the 16 kHz cleaned copy, a Them line the call. | TranscriptReading.swift:168-181; MeetingEvidence.swift:74-85; AppState.swift:1512-1518; PlaybackEngine.swift:59, 95; iPhone PlaybackController.swift:86-87 | P7: mixed conversation playback. | L |
| AH-03 | high | **Both apps:** a microphone that goes silent mid-recording is never reported. "Microphone silent" is sticky: `receivedSignal` becomes true at the first non-zero sample and never resets. Zeros after that go unreported: a MacBook lid closed in clamshell mode, a mute switch, a dead USB interface. | PCMTrackWriter.swift:30; CaptureLevels.swift:47; iPhone AudioLevelMeter.swift:32; PhoneRecorder.swift:768 | P1: a rolling hearing check, shown in Floating Notes, the recording surface, the Live Activity, and a notification. | S |
| AH-07 | high | **Mac sleep:** closing the lid stops every device recording along. The sleep hook stops the recording, and the cascade then pauses hardware recorders and stops iPhones recording along, which could have continued. Daybook holds no idle-sleep assertion while recording. | RecordingController.swift:109-126; AppState+Phone.swift:72, 263-269; docs/multipoint.md:98-99; DeviceSupport.swift:20 (the only `beginActivity`) | P1: an idle-sleep activity while recording; a forced sleep stops only this Mac's tracks; on wake, show who kept recording. | M |
| SC-01 / DF-01 | high | **Soundcore:** a Start that waits behind an import fires minutes later. A record-along Start waits behind a running import because one lock serves both. The cascade reports "didn't start" after 15 s, but the queued Start fires when the import ends and nobody stops it. `sentAt` is taken before the wait, so the clock offset is wrong. | SoundcoreSession.swift:285-303, 385-405 (verified); SoundcoreConnection.swift:643-673; RecorderCascade.swift:191-197; MultiSourceCoordinator.swift:546-563 | P2. | M |
| SC-02 | high | **Soundcore:** one gap deletes all live audio. A Listen Live or record-along sequence gap or decode error aborts the transfer, and `finish(.failure)` deletes the live file, losing all live audio so far (captions source and live portion). A stall or disconnect keeps it. | SoundcoreSession.swift:589-611, 676-680 (verified), cf. 655-662 | P2: keep and pad on a gap. | S |
| DF-02 | high | **iPhone:** recorders start before the library loads. `devices.start()` runs in `App.init`, and ownership applies from library metadata that isn't loaded. A background (Bluetooth restoration) relaunch never loads the library. The iPhone can hold a recorder the Mac manages, hear its button, and import nothing in that process. | DaybookPhoneApp.swift:73; PhoneDevices.swift:161-172, 230-237 (verified ordering) | Apply last-known ownership from device storage before `hub.start()`; load the library under background time when a recorder connects. | M |
| AH-04 | medium | **Mac:** microphone restarts are fragile. Restarts have a lifetime cap of 20, and one failed restart (the new device reporting 0 Hz for a moment) ends the whole recording. AirPods flapping over a long day reaches 20. | MicrophoneSource.swift:24, 50, 74-84 | P1: a rate cap, retries with backoff, then fall back to the built-in mic. | S |
| AH-05 | medium | **Mac:** gap rules stop recordings the iPhone would keep. The Mac stops a track on a >5 s forward or >100 ms backward timing jump; for the mic that ends the recording. The iPhone pads up to 5 min and resyncs backward. | PCMTrackWriter.swift:156-166 vs PhoneTrackWriter.swift:144-154 | P1: the iPhone's policy on the Mac. | S |
| AH-06 | medium | **Mac:** a source that stops silently isn't noticed. Nothing watches for a source that stops delivering without an error: a coreaudiod restart, a dead aggregate, a stalled ScreenCaptureKit stream. There is no `kAudioHardwarePropertyServiceRestarted` listener, and the tap's watchdog only checks "never heard". | ProcessTapSource.swift:236-264; grep finds no ServiceRestarted | P1: a per-source last-buffer watchdog that rebuilds. | S |
| AH-08 | medium | **Mac:** the microphone always follows the system default input, with no choice. With AirPods as default input, Daybook opens their mic and (expected) flips them to hands-free for the whole call, even when the call app uses the built-in mic. The tap aggregate includes the output device's streams, so AirPods as output may do the same. Suspected; needs hardware. | MicrophoneSource.swift:47-53; ProcessTapSource.swift:146-157, 204-208 | P4. | M |
| AH-09 | medium | **iPhone:** a connected headset becomes the input automatically. `.allowBluetoothHFP` makes a connected headset the input, so a table recording uses AirPods in someone's ears. There is no input choice. | AudioSession.swift:113-115; no `setPreferredInput` anywhere | P4. | S |
| AH-10 | medium | **iPhone:** Stop saves in the background without background time. Stop deactivates the session before assembling and filing, and holds no background task. A Lock Screen, Siri, or Mac stop of a long interrupted recording re-encodes in the background, can be suspended, and is then labelled "Daybook quit while recording". | PhoneRecorder.swift:270, 281-293; PhoneAppModel.swift:664-718; `beginBackgroundTask` only at PhoneSync.swift:322, PhoneDevices.swift:201 | P3. | S |
| AH-11 | medium | **iPhone:** any multi-segment recording is re-encoded. One interruption, a media reset, a >5 min gap, or a crash means the whole recording is decoded and re-encoded at 64 kbps. The library's original is then second-generation AAC. | RecordingAssembler.swift:42-87 | P3: a passthrough join. | M |
| AH-12 | medium | **Mac:** originals are Float32 PCM, about 2.3 GB an hour. They are synced as-is. A one-hour call to play on an iPhone is 1.4 GB, over its 1 GB cache. | PCMTrackWriter.swift:132-133; CaptureSources.swift:124-125; ProcessTapSource.swift:130; EchoRemover.swift:115-117; icloud-sync.md:123, 137 | P6. | L |
| AH-13 | medium | **Imports:** videos are kept whole. A video file is stored and synced with its video, though only its audio is used. | AppState.swift:838; MeetingStore.swift:288-292, 324-330 | P6: extract the audio track by passthrough at import. | S |
| AH-14 | medium | **Echo removal** can remove the person's own voice. The delay search accepts the mic leading the call by up to 250 ms. When the call carries the person's own voice, the canceller time-advances the reference and removes that voice from You. | EchoDelayEstimator.swift:40, 105-111; EchoRemover.swift:288, 294 | P5: a lead limit and a `callCarriesYourVoice` skip. | S |
| AH-16 | medium | **iPhone:** a paused pocket recording isn't announced. An interruption without a resume recommendation (or a failed auto-resume) leaves a pocket recording paused; only the Live Activity says so. There is no "Recording paused" notification. | PhoneRecorder.swift:518-530; PhoneNotices.swift (only stopped, recorder, and meeting notices) | P1: a paused notice with Open to Resume, and a retry on activation. | S |
| AH-17 | medium | **Mac:** no free-space watch while recording. At 2.3 GB/h, a laptop with 10 GB free fills in ~4 h, then stops. Only Welcome checks space. | WelcomeWindow.swift:124; no capacity check under Capture/ | P1: warn at 30 min left; at 3 min stop the call track first. | S |
| SC-03 | medium | **Soundcore:** time can vanish without an error. An all-zero slot is trimmed to TOC `0x00`, which decodes to 0 samples with no error (sub-review measured 100 slots → 0 samples). Nothing compares decoded duration with slot count. | SoundcoreOpusDecoder.swift:29-56; SoundcoreSession.swift:622-626 | Expect 320 samples per packet; flag a duration mismatch above 0.5%. | S |
| SC-04 | medium | **Soundcore:** yields have no limit. A head that names another ID, or audio before the head, counts as "another app"; the import retries forever and says "Waiting for the Soundcore app" even on a Mac. | SoundcoreSession.swift:223-266; SoundcoreConnection.swift:561-569 | Cap at 3 yields, iOS only. | S |
| SC-05 | medium | **Soundcore:** the clock correction never ages. It is measured only on Daybook's Start, never ages, and applies to all recordings past and future. DST, time zone changes, or the Soundcore app re-syncing shift dates silently. | SoundcoreClock.swift:33, 67-71; SoundcoreConnection.swift:322-345 | A history of measurements, nearest in time wins. | M |
| SC-06 | medium | **Soundcore:** recordings can be skipped by date. Automatic import filters by the recorder's own date, so a clock behind wall time skips the first hours after setup silently. | SoundcoreConnection.swift:592-595 | Use "not present in the setup listing" (persisted IDs). | S |
| SC-07 | medium | **Soundcore:** battery reading mixes scales. Values ≤ 9 map to (n+1)×10; larger values are literal. 5% literal would show 60% and never warn. | SoundcoreProtocol.swift:92-96 | Settle the scale per recorder; verify on hardware. | S |
| SC-08 | medium | **Soundcore:** the stored original is decoded PCM. The library keeps a 16 kHz Float32 WAV (230 MB/h) and discards the recorder's Opus (29 MB/h), so a later decoder fix can't be reapplied. | SoundcoreOpusDecoder.swift:16-23; SoundcoreSession.swift:546-548 | P6/SC R1: a slot journal as the original. | L |
| SC-09 | medium | **Soundcore:** large Wi-Fi messages are dropped. Messages over 1 MiB are dropped though the WebSocket allows 16 MiB, so a batching recorder always falls back to Bluetooth. | SoundcoreProtocol.swift:52; SoundcoreWebSocket.swift:9, 84 | Feed ≤ 64 KB pieces; one limit. | S |
| SC-10 | medium | **Soundcore:** decoding runs on the main actor. Decrypt, Opus decode, and WAV write for every 20 ms packet run on the main actor; Wi-Fi delivers ~390 at once. | SoundcoreSession.swift:87, 586-605 | Move them to a background actor. | M |
| SC-11 | medium | **Soundcore:** the access point is marked open too late. It is marked only after `1A 05` replies. If Bluetooth drops as the AP starts, nothing closes it next time. | SoundcoreFastTransfer.swift:211-225 | Mark it before sending. | S |
| SC-12 | medium | **Soundcore:** every transfer restarts from zero, though requests carry an offset. A marginal link can loop forever on an hour-long file. | SoundcoreSession.swift:554-556; SoundcoreWiFi.swift:75 | P6/SC R1: resume from the slot journal. | L |
| DF-03 | medium | **Handoff** hangs if the owner quits mid-release: release state is memory-only, and `.ownerFinishing` never goes overdue. | RecorderHandoff.swift:161-175, 716-750 | Resume the release on relaunch; overdue plus Take Over Anyway. | S |
| DF-04 | medium | **Recorder claims never expire.** An owner device that is wiped or gone leaves "Managed by X", calm, forever, while the recorder overwrites its oldest files when full. | RecorderStatusWords.swift:229-231, 338-340 | An attention state after N days, with Use on This Mac. | S |
| DF-05 | medium | **Import lists are lost on relaunch.** Handed-off imports, shared-recording file imports, and the manual queue live only in memory. | DeviceSession.swift:22, 74-78, 729-775; DeviceImportQueue.swift:6 | Persist in `DeviceStorage`. | S |
| DF-06 | medium | **Live capture** isn't re-armed after a Bluetooth drop; captions and the meter end for the rest of the meeting. | SoundcoreSession.swift:362-372; RecorderCascade.swift:211, 237-240 | P2. | S |
| DF-07 | medium | **Live capture starts at the file's beginning.** For a recorder already recording, the meter and captions show old audio for up to 15–30 min while catching up. | MultiSourceCoordinator.swift:534-544; devices.md "Feeding" | P2: "Catching up…". | M |
| DF-08 | medium | **False start from the button catch-up.** A recording started <60 s before the link returned counts as a button press, so the iPhone starts its own recording after a handoff. | SoundcoreConnection.swift:1139, 1152-1157 | Skip it for adopted or followed recordings. | S |
| DF-09 | medium | **The watched folder** asks iCloud to re-download imported files and re-hashes the folder after every launch. | ImportFolderWatcher.swift:50, 266-274, 319-331 | Persist a fingerprint → digest map. | S |
| DF-10 | medium | **Duplicate imports from a shared folder.** Two devices watching the same iCloud folder both import a new file. The Mac's identity check runs before the lock re-acquire; there is no merge after sync. | ImportFolderWatcher.swift:188-191; AppState.swift:857-883 | Check again after re-acquiring; reconcile duplicates on sync. | M |
| DF-11 | medium | **iPhone imports** run without background time (`ProcessInfo` activities don't keep iOS apps running). A suspension means the whole Bluetooth transfer repeats. | DeviceSupport.swift:18-25; DeviceSession.swift:469-498 | A background assertion from transfer end through ingest. | S |
| DF-12 | medium | **The iPhone recorder Live Activity** disappears after a relaunch while the recorder keeps recording. | SoundcoreConnection.swift:214, 663; RecordingActivityController.swift:128 | Persist `startedHereID`. | S |
| DF-15 | medium | **Soundcore** still leaks into shared device code, UI, and the persisted model. | listed in P8 | P8. | L |
| AH-15 | low | **Echo removal** filters stretches with no echo. Windows without a confident echo inherit a neighbour's delay and are still filtered and suppressed (for example, the headphone part after speakers). | EchoRemover.swift:257-277 | P5: bypass plus a near-end self-check. | S |
| AH-18 | low | **Sidecar and journal rewrites grow.** Clock anchors are stored every second, and the whole pretty-printed sidecar or journal is rewritten every 10 s (Mac, on the audio queue) or 5 s (iPhone). At 4 h that is ~14,400 anchors, ≈1.3 MB per write: ~3–4 GB of flash writes per 4-hour iPhone recording. | PCMTrackWriter.swift:175-187; CaptureModels.swift `CaptureJSON` (prettyPrinted); CaptureJournal.swift:192; PhoneRecorder.swift:140, 736-740 | Anchors every 10 s after the first minute (or running least-squares sums plus resync points), compact JSON, written off the audio queue. | S |
| AH-19 | low | **Padded gaps aren't counted.** Silence is inserted without a note of where or how much. Zero-filled seams can click. | PCMTrackWriter.swift:163-166, 190-199; PhoneTrackWriter.swift:148-151 | Record `gaps` per track and show the total in capture details; 5 ms fades at seams. | S |
| AH-20 | low | **The meter** shows the latest buffer's RMS: 10 ms for the call tap, ~85 ms for the mic. The You and Call meters move with different ballistics. | PCMTrackWriter.swift:24-33 | RMS with a ~300 ms time constant; 1 s peak hold. | S |
| AH-21 | low | **Stale docs.** capture.md says fusion doesn't apply `clockRate`; SourceFusion does. | capture.md:163, 685 vs SourceFusion.swift:114-119 | Fix the two lines. | S |
| AH-22 | low | **ScreenCaptureKit fallback** filters on `content.displays.first`. Unplugging that external display mid-call stops the stream, and the call track ends. | CaptureSources.swift:97-98, 160 | Use the main display; restart once on `didStopWithError`. Needs hardware. | S |
| AH-23 | low | **Background cost.** The Live Activity's level updates every 2 s for the whole recording, and the iPhone's 15 Hz meter loop runs on the main actor while locked. | RecordingActivityController.swift:21; PhoneRecorder.swift:138, 736-740 | When backgrounded: update on hearing or silence changes only; meter at 2 Hz unless a Mac listens. | S |
| SC-15 | low | **Recorder double-tap highlights** aren't imported, and nothing says so. | validation.md:3156; no highlight code under Soundcore/ | A technical note; capture during the hardware test. | S |
| DF-14 | low | **Partial files.** The watched folder's "stable" (two equal scans 5 s apart) can import a partial file from a slow writer. The finished file then imports again. | ImportFolderWatcher.swift:8-9, 264, 342-352 | Also require mtime ≥ 30 s old and a readable container. | S |

The sub-reviews' remaining lows (SC-13 hotspot `.internal` error, SC-14 unused flags and trailer bytes, SC-16 list trailer length, SC-17 wrong words for a deleted recording, SC-18 swallowed write errors, DF-13 library failures shown as recorder problems) are real but small. Each is an S fix in the files they cite.

## 4. Hardware acceptance checklist (priority order)

Mac, iPhone (and Duo), Soundcore Work. For each step: what to do, then what to observe. This complements docs/validation.md "Call capture and echo removal", which covers the per-app tap checks.

1. **Record-along while importing (SC-01/DF-01).**
   - Do: leave a ≥1 h recording un-imported, connect so automatic import starts, then start a Daybook recording with record-along on the iPhone, and separately on the Mac.
   - Observe: the chip after 15 s; whether the recorder's light turns on when the import ends; whether it is still recording after Daybook stops; the recording's date in the list.
2. **Close the lid mid-meeting (AH-07).**
   - Do: record on the Mac with the iPhone and Soundcore recording along, then close the lid.
   - Observe: which devices stop; what Floating Notes and the iPhone say on wake.
3. **Clamshell (AH-03).**
   - Do: record on the built-in mic, attach an external display, close the lid.
   - Observe: whether `microphone.caf` turns to digital zeros, and whether anything warns.
4. **AirPods and call mode (AH-08, AH-09).**
   - Do, Mac: AirPods connected, Zoom set to the built-in mic, start a recording.
   - Observe: whether the AirPods switch to hands-free (Audio MIDI Setup sample rate; sound quality), for (a) Daybook's microphone and (b) the call tap alone with "Include computer audio" on and the mic set to built-in.
   - Do, iPhone: start a table recording while wearing AirPods.
   - Observe: the journal's start route and the far voices' level.
5. **Disk stall (AH-01).**
   - Do: put the library on an external USB disk, record a call, and copy a 20 GB folder to that disk mid-call (or let Time Machine run).
   - Observe: no "The disk couldn't keep up" stop.
6. **iPhone interruptions in a pocket (AH-16).**
   - Do, locked: receive and answer a phone call; invoke Siri; let an alarm fire; play a video in another app and come back.
   - Observe for each: whether it resumed on its own (journal `interruptions[].resumed`), and how long the gap was.
7. **Stop from the Lock Screen after an interruption (AH-10, AH-11).**
   - Do: record 2 h with one call in the middle, then stop from the Live Activity while locked.
   - Observe: time to "Saved"; on next launch, no "Daybook quit while recording".
8. **coreaudiod restart and device churn (AH-04, AH-06).**
   - Do: during a tapped call, `sudo killall coreaudiod`; separately, connect and disconnect AirPods 25 times over an hour.
   - Observe: both tracks continue, with notes.
9. **Own voice in the call (AH-14).**
   - Do: two laptops in one room on one Meet call, the colleague unmuted, you on headphones.
   - Observe: the sign of `echoRemoval.delay.delaySeconds`, and whether your words disappear from You.
10. **Listen Live gap and reconnect (SC-02, DF-06, DF-07).**
    - Do: a 30-minute shared recording next to a busy phone, then walk the recorder out of range for 1 minute.
    - Observe: whether live audio survives, whether captions resume, and whether a recorder already recording shows old audio as live.
11. **Soundcore fidelity and clock (SC-03, SC-05, SC-07).**
    - Do: record 10 min of spoken numbers, a click every 10 s, and silences; compare Daybook's duration and click times with the Soundcore app's export (within 0.1%). Compare battery at 50/20/10/5%. Note the start time against the wall clock.
12. **Long recordings and size (AH-12, AH-18).**
    - Do: a 4-hour Mac call and a 4-hour iPhone recording.
    - Observe: GB on disk and in iCloud, finalize (echo removal) time, sidecar and journal size, battery used on the phone.
13. **Background relaunch with a recorder (DF-02).**
    - Do: make the Mac the owner, stop iPhone Daybook from Xcode, trigger a Bluetooth restoration launch.
    - Observe: whether the Mac can still connect; which device hears the button.
14. **Duo postures.**
    - Do: fold, unfold, and set to table posture mid-recording.
    - Observe: route events in the journal, and no gaps over 100 ms (`clockAnchors` resyncs).
15. **ScreenCaptureKit fallback (AH-22).**
    - Do: record a call app Daybook can't name with an external display as the first display, then unplug it.
    - Observe: the call track's end, and the warning.

## 5. Decisions recommended

- **MSCQ-09 (SNR weighting and the stored-alignment pipeline): wire SNR in, through stored per-track profiles.**
  - Compute a coarse profile where the audio is (P7's `TrackAnalysis`: SNR per 5 s as UInt8 dB, about 3 KB an hour, 12 KB for 4 h) and store it on the track, synced. The Mac and the iPhone then fuse identically without the phone holding audio.
  - Weight only tracks that carry a profile. Existing conversations keep their fused wording until new input re-fuses them, so there is no migration and no surprise rewording.
  - Keep reading `Meeting.audioAlignments`, since synced conversations may carry it. Correct the docs to say production placement comes from `MultiSourceCoordinator` (`AudioAligner.align`) and `SourceAlignment`. That is the safe interim fix MSCQ-09 named.
- **hig-ios-14 (Time Sensitive): enable the capability (self-serve; the owner adds it to `local.daybook`), and use it only where audio is being lost now.**
  - The app already marks "Recording stopped" as time sensitive (PhoneNotices.swift:111, 143-146). Without the capability, iOS silently delivers it as an ordinary notification that Focus holds.
  - Use it for Recording stopped and the new Recording paused (P1).
  - For hig-ios-14's own notice (a recorder records, this iPhone doesn't), I agree with the device sub-review: keep it ordinary, since the recorder's audio is being saved meanwhile, and add a "Record on This iPhone" foreground action.

The other open decisions are outside this lane.

## 6. Not findings (checked, fine)

**Crash safety.**
- The Mac CAF that was never closed is recovered to its on-disk length (InterruptedCaptureTests.swift:109).
- The iPhone fragmented M4A is readable to the last fragment and recovered (PhoneRecorderTests.swift:247, 270).
- Sidecars and journals are written atomically, owner-only. Staging is 0700, files 0600. The iPhone uses class C protection.

**Timing.**
- Gaps are judged against the latest anchor (not the first), so drift never reads as a gap.
- The drift fit rejects 3σ outliers and treats rates beyond ±1000 ppm as faults.
- The iPhone timeline uses `mach_continuous_time`, so a phone that sleeps through an interruption still places the next segment (tested).
- Fusion applies capture `clockRate` (SourceFusion.swift:114-119).

**Echo DSP.**
- Streaming, bounded memory (chunked readers).
- The temporary file is renamed only on success; the original is opened read-only; the result is idempotent and stored in `capture-result.json`.
- The cross-spectrum convention is checked: conj(R)·M, so a positive delay means the mic lags.

**Process tap.**
- Daybook's own process is excluded; the tap is private and unmuted.
- Helpers are followed every 3 s; the tap rebuilds on an output change.
- The permission watchdog only fires while the app's output runs.
- A tap failure never costs the recording; the call falls back to ScreenCaptureKit only without a new prompt.
- ScreenCaptureKit excludes Daybook's own audio.

**iPhone session.**
- `.playAndRecord`/`.default` keeps a full-band, unprocessed microphone.
- Ringtones don't interrupt (`prefersNoInterruptionsFromSystemAlerts`).
- Removing AirPods falls back to the built-in mic without interrupting.
- Playback never takes the session while recording (PlaybackController.swift:199-204, MODERN-iOS-02 holds).
- AAC-LC 64 kbps mono at 48 kHz (29 MB/h) is a sound choice for speech.

**Movies.** AudioFile reads the audio of .mov and .mp4 (checked with `afinfo` on generated files), so imported videos do transcribe; AH-13 is about size only.

**Soundcore (sub-review).**
- No delete command is ever sent (allow-list test).
- Crypto: constant-time compare, ephemeral P-256 keys, non-overlapping CTR counters.
- The Wi-Fi peer-identity fix from the 2026-11-01 audit holds.
- Imported state derives from library tracks.

**Devices (sub-review).**
- A transfer always finishes on the old owner during a handoff.
- The iPhone checks a recording's identity again under the library lock before ingest.
- In-progress recordings are never imported early.
- The Mac starts devices only after its library loads.

Scratch probe used: (scratch)/movtest (generated t.mov and t.mp4 read by `afinfo`). The Soundcore sub-review's probes are in (scratch)/wavcheck.
