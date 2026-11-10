# Networking, multipoint recording, and real-time transcription across devices

Reviewer lane: the Mac–iPhone local link, recording across devices, fusion and alignment of several sources, live captions merged across sources, and the iCloud transport that carries the iPhone's audio to the Mac. Reviewed the working tree on `design-pass-2026-11` (HEAD `1f6f1ba0`). I changed no repository files.

**How this was checked.**
- I read the code and docs for the link, multipoint orchestration and live captions.
- Two focused sub-reviews covered fusion and alignment, and sync transport. I spot-checked their key claims against the code before including them:
  - the anchor-fit rate bounds (`TranscriptFusion.swift:110-143`);
  - the 240-item region cuts (`MultiSourceFusion.swift:407-427`);
  - the named-speaker rule (`SourceFusion.swift:59-71`);
  - the dead SNR path (`SourceFusion.swift:122`, `MultiSourceFusion.swift:598`);
  - the courier deleting an expired record before delivering it (`CloudKitCourier.swift:429`);
  - the courier's 50 MB cap (`SyncCourier.swift:114`);
  - the missing background assertion at a Mac-led stop (`PhoneAppModel.swift:664-720`, `PhoneAppModel+Filing.swift:71`).
- The fusion sub-review ran release-build probes against `DaybookCore` with synthetic transcripts. The probe source is in `scratchpad/probe/main.swift`.
- I ran a release-build microbenchmark of `LiveCaptionMix`. The source is in `scratchpad/nm-bench/`.

Findings from the sub-reviews are marked *(fusion review)* or *(sync review)*. The previous audit's iCloud and security items aren't repeated. Where a fix there is incomplete, it's said.

## 1. Summary

The link's control plane is careful work:
- Record requests are idempotent by ID across reconnects (`LinkRecordAnswers`), and both sides retry with the same ID.
- Owed stops survive a relaunch and are keyed by conversation, so they can't stop an unrelated recording.
- Messages are additive within version 1, and unknown types, fields and values are counted, not fatal.
- Bookmarks land by the clock estimate, not by transport delay.

None of it has been exercised on two real devices yet (docs/validation.md:3243-3247, 2876-2880).

The risk of a wrong transcript sits where timing meets fusion:
- A phrase-anchor fit can store a false clock rate permanently: 3 phrases over 14 s gave a 2% rate, 285 s off at the end (*fusion review*).
- The echo-cancelled microphone inherits the raw microphone's drift.
- A correction made before a higher-priority recording joins can silently lose or double words.
- A renamed room speaker can relabel the call's unnamed speakers.
- When an iPhone starts a recording, every connected Mac joins. Each Mac files its own recording as the timeline's origin, so after sync two recordings that started up to 60 s apart sit at the same zero, and nothing places them.

Real-time de-duplication across sources exists (`LiveCaptionMix`), but it has four problems:
- It rebuilds from scratch on every caption update, on the main actor. One phone feed costs 16 ms per rebuild at 1 h and 64 ms at 4 h (best of 5); phone plus recorder averaged about 190 ms at 1 h.
- It keeps "this device's line first" rather than the line from the source that heard it best.
- It can't take back a retracted line.
- It places an already-recording recorder's captions minutes early.

Saved captions are then deleted as soon as any transcript made after they began exists, even one that doesn't cover the other devices' lines.

Multipoint doesn't yet feel instantaneous:
- The iPhone's audio reaches the Mac only through sync: 15–45 s by the CloudKit courier at best, and minutes to hours for recordings over 50 MB (about 100 minutes), which go by iCloud Drive.
- The Mac doesn't apply it until its own transcription and summary finish, so nearly every shared recording is summarized twice.

Three loss risks deserve attention:
- A follower stops recording 30 minutes after it last heard its leader, even mid-meeting.
- A courier record that is the only copy is deleted unread after 7 days.
- When a Mac stops a pocketed iPhone, the phone gets no background time to file and send its recording.

The biggest opportunities, in order:
1. One timing model.
2. Corrections stored as word spans.
3. A link courier: the phone's audio reaches the Mac over the encrypted local link in seconds, and the Mac takes it while busy, so there's one pass and one summary.
4. Following the leader on evidence instead of silence.
5. An incremental, quality-ranked live-caption merge.

## 2. Redesign proposals

Ranked by the risk of a wrong or lost transcript or recording, then by what makes recording on several devices feel instantaneous.

### P1. One timing model: a clock per track, physical rate bounds, one origin per conversation — L (pieces S–M)

**What and why.** Today a recording's place on the timeline is worked out in four places, with different rules:
- `SourceFusion.run` for placements and capture drift;
- `Meeting.timelinePlacement`, which gives rate 1 for capture-timed tracks;
- `compareSound`'s composition onto a reference;
- `alignedTime` for bookmarks and notes.

They disagree. That is the root of four high or medium findings:
- the echo-cancelled microphone takes the raw microphone's rate (FU-03);
- a phrase-anchor fit can choose any rate from 0.97 to 1.03 and is stored forever (FU-04);
- references placed only weakly propagate (FU-09);
- an unbounded capture `clockRate` (FU-11).

There's also no notion of one origin per conversation, so two Macs both claim it (MP-01). Physical clocks drift by tens of ppm, not by 3%. One record per track, computed once, used everywhere, and bounded by physics removes the class.

**Changes.**
- **One clock record.** `Meeting.clock(of:) -> TrackClock { offset, rate, method, confidence, dependsOn }` becomes the only source of placement. It is used by `SourceFusion`, `timelinePlacement`, `compareSound` composition (`AppState+Sources.swift:119-136`) and `alignedTime`.
- **Derived tracks.** A derived track inherits its original's offset only, never its rate.
- **Rate bounds.** Rate must stay within 1000 ppm everywhere: anchors (`TranscriptFusion.swift:123,143`), capture `clockRate` (`SourceFusion.swift:117`), and the aligner's ±1000 ppm, which already holds.
- **Anchor fits.** An anchor fit gives an offset only, unless its anchors span max(10 min, 30% of the overlap). Its confidence scales with that span.
- **Re-checking placements.**
  - The Mac re-checks `.transcript` and `.clock` placements by sound. Today `soundMayHelp` retries only `.pending` and `.clock` (`AppState+Sources.swift:387-390`).
  - A failed prior search retries as a full search (FU-07).
  - Dependents are placed again when their reference moves.
- **One origin.** When a conversation holds capture groups (`clockID`) from different Macs and none is pending, the first-filed group (or the leader's) stays the origin. The others become `.pending`, using a wall-clock prior. Better, they use the iPhone's `capture.peerClocks`, which measured both Macs over the link during the recording, so B−A comes from the phone's two measurements.
- **Clock exchange on the link.** Add optional monotonic timestamps (`mach_continuous_time` seconds) to `clock.request` and `clock.reply`. Fit offset and drift over the session instead of only the shortest round trip (`LinkClock.swift:71-94`).
  - The phone's first-sample anchor already records continuous time (`PhoneRecorder.swift:686-690`).
  - Its track can then be placed on the Mac's capture host timeline with a measured drift.
  - That drift tightens the aligner's rate prior to ±50 ppm around it.
- **Measurement choice.** Prefer the tighter clock measurement, not simply the later one (`AppState+Sources.swift:269-278`).

**Where.**
- `Sources/DaybookCore/MultiSource.swift`, `SourceFusion.swift`, `TranscriptFusion.swift`, `MultiSourceFusion.swift:201-206`, `Alignment/AudioAligner.swift`.
- `Sources/Daybook/App/AppState+Sources.swift`, `MultiSourceCoordinator.swift`.
- `Sources/DaybookLink/LinkClock.swift`, `LinkSession.swift:223-230`, and the clock messages in `LinkMessages.swift`.

**What the person sees.** Nothing new. Fused passages stop doubling or drifting on long calls, and a second Mac's recording lines up.

**Tests that prove it.**
- A raw microphone at 200 ppm, its echo-cancelled copy, the call, and a recorder placed by sound against the raw microphone all land within 50 ms at t = 3600 s.
- Three anchors within 14 s give an offset-only fit at rate 1.
- `clockRate` 48_000.5 is rejected. Fix the v0.2.2 fixture at `Tests/DaybookTests/Fixtures/Shipped/Generator/v0.2.2.swift:103`.
- A ±120 s prior that's 10 min wrong is found by the full-search retry.
- Two Mac capture groups merged by sync: the second becomes pending and is placed within 100 ms from the phone's peer clocks.
- Over the loopback relay (`LinkTestSupport.swift`), using an injected `LinkClock` with a 100 ppm skew, drift is estimated within 10 ppm over a simulated hour.

**Risks.** Re-fusing changes the wording of existing conversations. Gate this behind a fusion version, so a conversation changes only when it is fused again.

### P2. Corrections as word spans; a name stays where it was — L

**What and why.** `CorrectionTransfer` overwrites a whole target passage, and passages follow the segmentation of the highest-priority source.

When a microphone or call recording joins after a correction was made on a recorder's or an imported file's passage, the passages are cut again. Examples:
- a Soundcore conversation the Mac records into;
- an iPhone recording joining a Soundcore conversation;
- a call joining a phone-led conversation.

The *fusion review*'s probes:
- A correction followed by a microphone that splits the passage 8 | 4 words lost "golf hotel" with no review item.
- A 4 | 8 split doubled "echo foxtrot".

Two related problems:
- `keepingNamedSpeakers` gives any merged, unnamed passage the first named speaker in its provenance. A call passage heard by a renamed room cluster comes out labelled with the room cluster's name: exactly the case where far-field diarization had merged voices (FU-02).
- Corrections made on a `~live` portion don't follow the recorder's own file (FU-10).

The person's corrections are the most valuable edits in the library. They must never be lost silently.

**Changes.**
- Store each correction as source word spans: track, local start and end, old words → new words. Apply them inside the word network before voting, not to the resulting passages.
- A recorder's live portion and its file share one identity, with times mapped through their placements.
- `keepingNamedSpeakers` keeps a name only on passages, or home source segments, that carried it in the previous `unifiedTranscript`.
- When a span can't be placed, raise a review issue rather than overwrite.

**Where.** `Sources/DaybookCore/CorrectionTransfer.swift:89-100,135-136,153-156`, `MultiSourceFusion.swift:149-158,787-871`, `SourceFusion.swift:59-71`, `LivePortions.swift`, and the correction record in Version History.

**What the person sees.** A corrected sentence stays corrected, word for word, however many recordings join later. When it can't be, Review says so.

**Tests.**
- Both probes become tests: an 8 | 4 and a 4 | 8 re-cut after a recorder correction, with no word lost or doubled.
- A call passage plus a renamed room cluster stays unnamed.
- A correction on a `~live` passage carries to the recorder's file.

**Risks.**
- Migration. Keep the passage-level path for corrections recorded before the change, and have it raise a review item where it would overwrite.

### P3. A link courier, and a Mac that takes the phone's audio while busy — L

**What and why.** This is the biggest change for both loss and speed. Today the phone's audio leaves only through sync:
- The CloudKit courier carries recordings up to 50 MB (`SyncCourier.swift:114`), only from the phone to a Mac, in about 15–45 s.
- Anything longer goes by iCloud Drive.

Three loss and delay problems follow:
- If the phone is lost before its iCloud Drive upload, the courier record can be the only copy. A Mac that hasn't fetched within 7 days deletes it unread (`CloudKitCourier.swift:429`, SY-01).
- A Mac-led stop gives a pocketed phone no background time before filing (MP-06).
- The Mac then defers every pass while its own job runs (`AppState.swift:1039-1044`). The phone's audio, notes and request apply only after the Mac's transcription and summary, and a second summary follows (MP-05).

**The change.** Implement `SyncCourier` over DaybookLink, composed with CloudKit. The phone sends the journal event and blob files it just wrote to the Macs it recorded with:
- They go as sealed bytes in an encrypted library.
- They use a second `NWConnection` with the same pre-shared key, as chunked, resumable transfers verified by SHA-256.
- The Mac takes them through the existing `receiveCourierFiles` → inbox → 24-hour promotion path. It holds a verified second copy within seconds, with no internet, no push, and no 50 MB cap.

**Supporting changes.**
- The phone takes a background assertion at Stop, before `recorder.stop()`, and holds it until the courier sends are done.
- The Mac runs full passes while busy, protecting the active conversation, as it already does for jobs that carry a request (`carryingRequest`). An awaited track that lands before fusion is folded into the running job, so there's one fused transcript and one summary.
- The courier delivers before it deletes an expired record. The Mac fetches when it gets a `processing.nudge`, and every few minutes while a recording is awaited. Sends flush on reachability.
- The link gets priority lanes with real backpressure (LK-01). Each channel counts bytes in flight through `.contentProcessed`, and levels and captions are dropped while a lane is full, so a 100 MB transfer never delays a Stop or a bookmark.
- Peer-to-peer (AWDL) is a fallback when no shared network path appears within a few seconds (LK-04).

**Fit with privacy and the design.**
- The audio goes device to device, between paired devices only, over TLS‑PSK on the local network, with no server involved. That is less exposure than iCloud.
- docs/link.md:32 states "Audio and transcripts never travel over the link", and the owner should sign off on changing it. The threat model holds as written.

**Where.**
- New `Sources/DaybookKit/LinkCourier.swift`.
- `LibrarySyncController+Courier.swift`, `CloudKitCourier.swift:429,436-441`.
- `Sources/DaybookLink/LinkTransport.swift` (the bulk channel and in-flight accounting), `LinkSession.swift` (lanes), and `LinkMessages.swift` (`file.offer`, `file.chunk`, `file.done`, additive).
- `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:664-720` and `PhoneSync.swift:313-336`.
- `Sources/Daybook/App/AppState.swift:1035-1066` and `AppState+Sources.swift`.

**What the person sees.** On the Mac, "Adding iPhone recording…" follows Stop within seconds, then one summary. "Waiting for iPhone audio" appears only when the phone really is away.

**Tests (loopback, simulated devices).**
- The phone sends over the link courier, then its sync-folder writes are deleted. The Mac still applies and promotes the recording.
- A relay frozen mid-transfer resumes when the link reconnects.
- While a 50 MB transfer runs, levels are dropped and a `record.reply` arrives within 200 ms.
- A delivery during the Mac's own job folds into that job, giving exactly one summary.
- `InMemoryCourierService` backdated 8 days: the record is delivered, not deleted.

**Risks.**
- Battery and radio cost on the iPhone (about 29 MB per hour of AAC; small).
- A Mac with another library open is guarded by `capabilities.libraryID`.
- Folding into a running job needs care. Keep it to the "before fusion" point.

### P4. Follow the leader on evidence, not on silence — M

**What and why.** A device that records because another asked stops when that device "hasn't been reachable for 30 minutes" (`AppState+Phone.swift:239-249`, `MultipointCoordinator.swift:62-63,219-227`). Both directions fail people:
- An iPhone that leads a 2-hour workshop and whose battery dies, or whose app is killed, ends the Mac's recording 30 minutes later. The rest of the meeting is recorded nowhere.
- A phone that walked out with the person while its stop was owed leaves the Mac recording an empty room for 30 minutes, unannounced.

Silence on a radio isn't evidence about the room.

**The change.**
- At about 2 minutes of silence, the follower says so, without stopping. Floating Notes and the iPhone's recording screen show "Alex's iPhone is out of reach. This Mac keeps recording." with Stop, and a notification goes out.
- It checks the leader's sync presence (`SyncDeviceActivity` in `LibrarySyncPresence.swift`, refreshed about every 10 min). If presence still says the leader records the same conversation, it keeps going. If presence says it stopped, it stops, as the owed stop would have.
- After 30 minutes with no evidence either way, it stops only if its own input has also been quiet: the level meter below speech for 10 minutes. Otherwise it keeps recording with the notice up.
- The same applies on the iPhone for a Mac leader.

**Where.** `Sources/Daybook/App/AppState+Phone.swift:232-258`, `Apps/iOS/DaybookPhone/App/MultipointCoordinator.swift:195-227`, `Sources/DaybookCore/LibrarySyncPresence.swift`, the status words in DaybookKit, and the iPhone's notifications.

**Tests (fake clock, fake levels, fake presence).**
- The leader is silent for 30 min while the microphone hears speech: recording continues and the notice shows.
- The leader is silent and presence says it stopped: recording stops.
- The leader is silent and the room has been quiet for 10 min: recording stops.
- Mirror tests in `MultipointCoordinatorTests`.

**Risks.** A longer recording in rare cases. The quiet-room gate, the visible notice and the Stop button bound it.

### P5. Fusion that can't double words, with per-source quality from data that already syncs (closes MSCQ-09) — M–L

**What and why.** These are separate wrong-transcript paths from P1 and P2:
- **Doubled words at region cuts (FU-05).** Fusion cuts the word stream every 240 items. A 1–2 word fragment can't reach the "two exact matches" rule, so it is kept as distinct speech. In the *fusion review*'s probes, 3,000 shared words came out as 3,003; four 40k-word sources gave 40,089.
- **The wearer loses to the laptop (FU-13).** A Soundcore worn on the speaker counts as `.room` (0.8) and loses to the laptop microphone (1.0) for the wearer's own words (`MultiSourceFusion.swift:590-607`).
- **The dead quality path (MSCQ-09).** The stored-measurement pipeline and SNR weighting are dead code.

**The change.**
- Replace the regions with a time-banded alignment over the whole sequence. The compatible column range is monotone, so this costs O(words × band). The alternative is overlapping regions stitched at an anchored column.
- Add a post-fusion guard. An identical normalized run of four or more words from different sources, within twice the tolerance, is merged.
- Weight each source per speaker from the synced `BackgroundAudioAnalysis.level` (one byte a second, `BackgroundAudio.swift:21-35`), so both apps fuse the same words:
  - the wearer's close microphone wins for the wearer;
  - the call wins for remote speakers;
  - otherwise the loudest room microphone wins.
- Delete `MeetingAudioAlignment`, `FusionInputs.audioAlignments`, `audioPlacement` and `signalQuality`. Keep `Meeting.audioAlignments` decoding and merging as an inert legacy field.
- Port the full-search retry into `compareSound` first (P1).
- Gate all of this behind a fusion version.

**Where.** `Sources/DaybookCore/MultiSourceFusion.swift:269-295,407-427,491,548,590-607`, `FusionSummary.swift:141-168`, `Alignment/MeetingAudioAlignment.swift` (delete), `BackgroundAudio.swift`, and docs/alignment.md:25,127 and docs/architecture.md:125.

**Tests.**
- 3,000 shared words come out as exactly 3,000.
- 4 × 40k words come out as 40,000.
- A close microphone and a laptop microphone with synthetic level profiles: the wearer's words come from the close microphone.
- Determinism: the Mac's and the iPhone's fusion of the same synced conversation are byte-equal.

**Risks.** Wording changes on re-fusion, hence the version gate. Watch the cost of the global alignment with the 4 × 40k probe as a performance test.

### P6. Awaited audio that says where it is, and never silently stops waiting — M

**What and why.** "Waiting for audio from Alex's iPhone" (`ProcessingStatus.swift:211-215`) never says why. After two days the conversation quietly reads as done (`AwaitedRecording.lifetime`, `ProcessingStatus.swift:195-196,281-285`), although the Mac can know the cause from presence and the link: the phone is out of iCloud storage, hasn't been online since 10:02, or waits for the library's key. A person reading a summary made without the phone's half has been misled. The convention this follows: say what's wrong and offer the fix.

**The change.** Add an `ArrivalStatus` per awaited link:
- **Over the link (instant).** The phone reports its filing and send progress for a recording a connected Mac awaits, as an additive optional message.
- **Through presence.** Add a pending-upload count and the existing sync warning to the presence record.
- **On the Mac's page,** one clause after the wait: "· Sending 40%", "· Last online 10:02", or "· Alex's iPhone is out of iCloud storage".
- **At expiry,** instead of done: "Alex's iPhone audio didn't arrive", with Don't Wait and Wait Again (the existing `stopWaitingForRecordings` and `waitAgain`).
- **On the iPhone,** the matching line for its own unsent recordings.

**Where.**
- `Sources/DaybookKit/ProcessingStatus.swift:183-302` and `ConversationStatusPresentation.swift:459`.
- `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift:96` and `Sources/Daybook/UI/SourceHooks.swift:79`.
- `Sources/DaybookCore/LibrarySyncPresence.swift`, `Sources/DaybookLink/LinkMessages.swift`, and `Sources/Daybook/App/AppState+Phone.swift`.

**Tests.**
- After the lifetime, the status is a missing state, not `.done`.
- Presence carrying a storage-full warning gives that reason.
- Over loopback, the phone's send progress reaches the Mac's line.

**Risks.** Copy length. Keep to one clause, per the owner's minimal-copy rule: status, action, fix.

### P7. One conversation and one processor per meeting — M–L

**What and why.**
- **Crossing starts (MP-03).** A Mac and an iPhone started by hand together refuse each other's start and record two conversations (`AppState+Phone.swift:337-342`, `MultipointCoordinator.swift:339-345`, docs/multipoint.md:796-798). The Mac's line then says "Alex's iPhone didn't record. … Recording on this Mac only." (`MultiSourceCoordinator.swift:648-650`), but the phone did record. Both process, both summarize, and the later recording is moved by sound or transcript minutes later.
- **Two Macs (MP-01).** Both Macs run their own local jobs with no claim ("This Mac writes no requests for its own work", `AppState+Requests.swift:36-38`), so the conversation gets two summaries and a conflict in Version History.

**The change.**
- **Converge crossing starts.** A start for conversation P can arrive while this device began M less than 10 s ago, by the person or automatically, with nothing in M but this recording. Then both sides keep the lexicographically smaller conversation ID. The other side re-targets its capture (the Mac's `recordingID`, staging and notes; the phone's `captureID`) and answers `alreadyRecording`. Both sides apply the same rule to the request they receive, so they agree without comparing clocks.
- **One processor per conversation.** The leading device writes and claims a conversation-level request at recording start. Followers transcribe only their own tracks under per-track claims, so the work stays parallel, and leave fusion and the summary to the claim holder.

**Where.**
- `Sources/Daybook/App/AppState+Phone.swift:324-374` and `AppState.swift:1412-1450`.
- `Apps/iOS/DaybookPhone/App/MultipointCoordinator.swift:316-376`, `PhoneRecorder.swift`.
- `Sources/Daybook/App/AppState+Requests.swift` and `Sources/DaybookCore/ProcessingRequest.swift`.

**Tests (loopback).**
- Both sides start within 200 ms: one conversation ID, both tracks in it, and no "didn't record" line.
- Two simulated Macs and a phone: one summary, with the second Mac's track pending and then placed.

**Risks.** Re-targeting a live capture is delicate. Allow it only in the first 10 s, before notes, bookmarks or photos land in M.

### P8. Live captions v2: incremental, off the main actor, best source wins, replaced per recording — L

**What and why.** `LiveCaptionSession.rebuild()` runs `LiveCaptionMix.adding` over every line of every other device's feed on each update, on the main actor:
- each captioner snapshot triggers one (`LiveCaptionSession.swift:180-185`);
- each phone message triggers one (`AppState+Captions.swift:101-112`, `LiveCaptionSession.swift:102-119`).

My release-build benchmark, run with `LiveCaptionMix.swift` as shipped and synthetic speech at about 170 words a minute:

| Recording | Phone feed only (best of 5) | Phone and recorder feeds (average) |
|---|---|---|
| 30 min | 8 ms | 42 ms |
| 1 h | 16 ms | 193 ms |
| 2 h | 31 ms | 284 ms |
| 4 h | 64 ms | 698 ms |

You and Call update several times a second, so in a 2-hour shared recording this takes a large share of the main thread. Floating Notes typing lags on the Mac, and so does the iPhone with a Soundcore recording along. The only performance test has no baseline, so it can't fail (`LiveCaptionMixTests.swift:64-69`).

The rule itself has problems too:
- It keeps "this device's own lines first" (`LiveCaptionMix.swift:26-29`), whatever heard the speech best.
- It compares whole lines, so partial overlaps double words or drop the new tail.
- Verdicts aren't sticky, so lines can appear and vanish as this device's tentative lines change.
- Retracted lines never leave the Mac (LC-03).
- A recorder already recording has its captions placed minutes early (LC-04).
- Saved captions are deleted as soon as any later transcript exists (LC-05).

**The change.**
1. **Incremental merge off the main actor.** A `LiveCaptionMixer` actor:
   - Lines older than the newest minus 30 s are frozen, with their verdicts kept.
   - Normalized words are cached by line ID and text.
   - Only lines within the window of a change are evaluated again.
   - The main actor gets the visible tail (the last 6 lines) and a version number. The full list is built only for saves.
2. **One utterance, one line.** Lines from all sources that overlap in time and match on the shorter line's words form a cluster.
   - The cluster's text comes from the best source for the speaker: the wearer's close microphone, the call for remote speakers, otherwise the room microphone with the highest level. Levels already flow (`PhoneLevels`, the Soundcore live level).
   - A line that extends another contributes only its new words.
   - A cluster stays tentative until all its lines are final or 4 s have passed.
   - A feed line with no counterpart shows under its device's label.
3. **Retractions.** `LinkCaptions.removed: [UUID]?`, additive.
4. **Recorder offsets.** `LiveCaptureCaptions.Update.startedAt` becomes the live stream's own start (its first buffer, on this device's clock), not the recording's.
5. **Per-source replacement.** Each saved line keeps its source, and each source maps to its track:
   - a phone's by the companion link's recording ID;
   - a Soundcore's by its recording ID;
   - the Mac's own by its capture.

   A line is hidden once its track has a transcript, or a fused transcript covers its time. The file is deleted only when every line is covered. The store is keyed by capture, not by conversation.

**Where.**
- `Sources/DaybookCaptions/LiveCaptionMix.swift`, `LiveCaptionSession.swift`, `LiveCaptionStore.swift:46,108-153`.
- `Sources/DaybookUI/Captions/SavedCaptions.swift:26-68`.
- `Sources/Daybook/Captions/AppState+Captions.swift:89-123`, `LiveCaptionsController.swift`, `CaptionEcho.swift`.
- `Apps/iOS/DaybookPhone/Captions/CaptionShare.swift`, `LiveCaptionsController.swift`.
- `Sources/DaybookLink/LinkMessages.swift:587-617`.
- `Sources/DaybookDevices/Framework/LiveCaptureCaptions.swift:47`.

**What the person sees.** One line per utterance in Floating Notes and on the iPhone's recording screen, labelled with the source it came from, with no flicker. After Stop, the phone's and the recorder's lines stay readable until their own recordings are transcribed.

**Tests.**
- A hard performance bound: 4 h, three feeds, 10 updates a second, under 2 ms average per update. Use an explicit time assertion or an `XCTClockMetric` baseline.
- A partial overlap shows each word once.
- This device's tentative revisions don't toggle a feed line.
- A retraction travels over loopback in `LinkSharedRecordingTests`.
- An already-recording recorder's line lands within 0.5 s of its time.
- A phone that started 30 min before the Mac keeps 0–30 min of captions after the Mac's transcript lands.

**Risks.** Complexity in a feature that's "never the transcript". Keep the cluster rule small and bounded.

## 3. Findings

IDs: LK link, MP multipoint, LC live captions, FU fusion and alignment (*fusion review*), SY sync transport (*sync review*).

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| MP-01 | high | When an iPhone starts a recording, every connected Mac joins, up to 60 s late (cascade window). Each Mac files its recording as the timeline's origin, because its own copy had no tracks yet. After sync, both sit at their capture offsets and nothing places them: `phoneRecordingsArrived` handles only device tracks. Both Macs also process with no claim, so there are two summaries. No test covers two Macs recording one conversation. | `Apps/iOS/DaybookPhone/App/MultipointCoordinator+Cascade.swift:11,44-55`; `Sources/Daybook/App/AppState+Sources.swift:345`; `Sources/DaybookCore/MultiSource.swift:191`; `Sources/Daybook/App/AppState+Phone.swift:463-479`; `AppState+Requests.swift:36-38` | One origin per conversation; later Mac capture groups go pending with the phone's peer-clock prior (P1); one processor per conversation (P7). Test: two simulated Macs and a phone over loopback | M |
| MP-02 | high | A follower stops 30 min after it last heard its leader, whatever the room is doing. A dead or killed leader ends a meeting's only remaining recording; a departed leader leaves the Mac recording an empty room for 30 min, unannounced | `Sources/Daybook/App/AppState+Phone.swift:239-258`; `Apps/iOS/DaybookPhone/App/MultipointCoordinator.swift:62-63,219-227` | Notice at 2 min; presence evidence; stop at 30 min only if the room is quiet (P4) | M |
| MP-03 | medium | Crossing starts make two conversations. The Mac says "Alex's iPhone didn't record. … Recording on this Mac only." though it did. Both process and summarize before the later one is matched and moved | `Sources/Daybook/App/AppState+Phone.swift:337-342`; `MultiSourceCoordinator.swift:648-650`; `Apps/iOS/DaybookPhone/App/MultipointCoordinator.swift:339-345`; docs/multipoint.md:796-798 | Converge on the smaller conversation ID in the first 10 s (P7) | M |
| MP-04 | medium | Awaited audio gives no reason, and after 2 days it silently reads as done, though presence or the link could say why | `Sources/DaybookKit/ProcessingStatus.swift:195-196,211-215,281-285`; `ConversationStatusPresentation.swift:459` | `ArrivalStatus`, and "audio didn't arrive" at expiry (P6) | M |
| MP-05 | medium | The Mac defers every pass while recording (settings only) and while a job without a request runs. The phone's audio, notes and request apply only after the Mac's whole pipeline, then a second summary runs *(sync review)* | `Sources/Daybook/App/AppState.swift:1039-1044` | Full passes while busy, protecting the active conversation; fold an awaited track into the running job (P3) | M |
| MP-06 | medium | A Mac-led stop on a pocketed iPhone: the audio session is deactivated, then the pre-filing pass and filing run with no background assertion. The recording survives (journal recovery) but may not reach the Mac until Daybook is opened *(sync review)* | `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:664-720`; `PhoneAppModel+Filing.swift:71`; the only assertion is at `PhoneSync.swift:313-336` | `BackgroundAssertion` from Stop through the courier sends | S |
| MP-07 | low | Stale multipoint docs: the aligner "returns nil" (it runs); the no-common-ancestor merge "until sync treats that case" (it does); segments "rescaled" (placements are passed instead) | docs/multipoint.md:749,768-770,55-58 against `MultiSourceCoordinator.swift:47-49`, `MeetingMerge.swift:11-14`, `SourceFusion.swift:105-113` | Correct the docs | S |
| MP-08 | low | The Mac creates the phone's conversation before it checks it can record. A refused start leaves an empty copy until the phone's copy syncs | `Sources/Daybook/App/AppState+Phone.swift:353-373` | Create it only after `canRecordInto` and a successful start | S |
| LK-01 | medium | Levels "dropped while one is on its way" never drop: sends are fire-and-forget into one TCP stream. Levels, captions, notes and record replies queue in order, so on a congested link a Stop reply or bookmark waits behind them | `Apps/iOS/DaybookPhone/Link/PhoneLink.swift:446-457`; `Sources/DaybookLink/LinkSession.swift:300-314`; `LinkTransport.swift:257-265`; docs/link.md:241 | Bytes-in-flight accounting via `.contentProcessed`; priority lanes (control > notes > captions > levels); drop levels and coalesce captions above about 16 KB in flight. Test: frozen relay | M |
| LK-02 | low | Each event stream keeps the newest 512 events and drops older ones silently, control events included, if the main actor stalls | `Sources/DaybookLink/LinkTypes.swift:291` | Separate streams: unbounded for control and app messages, newest-N for levels and captions; count drops | S |
| LK-03 | low | Notes and bookmarks are at-most-once on a session that's dead but not yet timed out (15 s, or 60 s in background recording). `send` throws only when no session exists, so nothing is owed. Sync restores it later | `Sources/DaybookLink/LinkService.swift:164-168`; `Sources/Daybook/App/AppState+SharedNotes.swift:88-103`; `PhoneLink.swift:410-416` | Per-lane sequence numbers with a cumulative ack in `pong`; resend unacked on reconnect (additive) | S–M |
| LK-04 | medium | Peer-to-peer is off: no link on client-isolated, guest, or infrastructure-less networks (hotels, conference rooms, a plane), the places a second device helps most | `Sources/DaybookLink/LinkTypes.swift:61`; `LinkTransport.swift:106`; `LinkClient.swift:424` | `includePeerToPeer` as a fallback after a few seconds without an infrastructure path. `LinkLocalNetwork` already accepts fe80:: (`LinkTransport.swift:157`). Needs devices | M |
| LK-05 | low | Clock exchange uses wall clocks only, with no drift estimate. A wall-clock step between the first sample and the measurement shifts the prior. `recorderClock` prefers the later measurement over the tighter one | `Sources/DaybookLink/LinkClock.swift:71-94`; `Sources/Daybook/App/AppState+Sources.swift:269-278` | Monotonic timestamps and an offset-plus-drift fit; choose by uncertainty (P1) | S–M |
| LK-06 | low | The threat model says "Audio and transcripts never travel over the link", but live captions (speech text) and notes do | docs/link.md:32; `Sources/DaybookLink/LinkMessages.swift:587-617` | Reword: "audio never; live captions and notes of a shared recording do" | S |
| LC-01 | high | Live-caption merge rebuilds from scratch on every update, on the main actor. Measured 16/31/64 ms per rebuild at 1/2/4 h with one phone feed, and about 190–280 ms at 1–2 h with phone and recorder feeds. The perf test has no baseline | `Sources/DaybookCaptions/LiveCaptionSession.swift:102-119,180-185`; `LiveCaptionMix.swift:40-58`; `Tests/DaybookCaptionsTests/LiveCaptionMixTests.swift:64-69`; bench in `scratchpad/nm-bench/` | Incremental `LiveCaptionMixer` actor with frozen verdicts; publish only the tail (P8) | L |
| LC-02 | medium | "Own device first" whole-line de-duplication. A line under 60% repeated shows in full and doubles words; one at or above 60% is dropped with its new tail. Verdicts are recomputed each time, so lines flicker | `Sources/DaybookCaptions/LiveCaptionMix.swift:26-35,61-65` | Clusters, best source by role and level, sticky verdicts (P8) | L |
| LC-03 | medium | Retracted tentative lines stay on the Mac and are saved as said. The phone sends only changed lines, the assembler drops an emptied tentative tail, the feed keeps the rest, and finish marks everything final | `Apps/iOS/DaybookPhone/Captions/CaptionShare.swift:11-23`; `Sources/DaybookCaptions/LiveCaptionModels.swift:122-130`; `LiveCaptionMix.swift:19-23`; `LiveCaptionSession.swift:135-142` | `LinkCaptions.removed`; `CaptionShare` diffs IDs | S |
| LC-04 | medium | A recorder's live captions count from when listening began, but are offset by its recording's start. A recorder already recording (or joined by its button, about 5 s later) has its lines placed early, by minutes in the first case. Lines before zero are dropped, the rest are never matched as repeats, and saved times are wrong. Verify on hardware that the stream starts "now" | `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift:790-796`; `Framework/LiveCaptureCaptions.swift:47`; `Sources/Daybook/Captions/AppState+Captions.swift:91-96`; `MultiSourceCoordinator.swift:306-311,534-543` | Stamp the live stream's own start in `Update.startedAt` | S |
| LC-05 | medium | Saved captions are deleted once any transcript made after they began exists, whatever it covers. The Mac's own transcript erases the phone's and recorder's lines; on the iPhone, the Mac's erases the 30 min before the Mac joined; an Upgrade or another recording's run erases an untranscribed recording's captions. The iPhone's `trackID` is ignored | `Sources/DaybookCaptions/LiveCaptionStore.swift:108-128`; `Sources/DaybookUI/Captions/SavedCaptions.swift:29-31` | Per-source, per-track replacement; hide, and delete only when all lines are covered (P8) | M |
| LC-06 | low | One captions file per conversation. A second recording into it overwrites the first's unreplaced captions and inherits the first's `trackID` until filed | `Sources/DaybookCaptions/LiveCaptionStore.swift:46,148-153` | Key by capture (conversation plus recording ID) | S |
| LC-07 | low | Every 10-second save during a Mac recording re-reads and decodes every conversation's captions, then deep-compares them on the main actor | `Sources/Daybook/Captions/AppState+Captions.swift:42-46`; `LiveCaptionsController.swift:114-120`; `LiveCaptionStore.swift:67-69` | Re-read only the conversation saved | S |
| LC-08 | low | The iPhone never gets the Mac's Call captions. With headphones on the Mac, the phone's captions of a shared call miss the remote side | `Apps/iOS/DaybookPhone/Link/PhoneLink.swift:607-608` | Optionally send Call lines to a phone that lists `liveCaptions` | S |
| FU-01 | high | A correction loses or doubles words when a higher-priority source joins later. Probes: "golf hotel" lost and "echo foxtrot" doubled, with no review item | `Sources/DaybookCore/CorrectionTransfer.swift:89-100,135-136`; `MultiSourceFusion.swift:149-158,787-871` | Word-span corrections (P2) | L |
| FU-02 | high | A renamed speaker from any source labels a merged, unnamed passage, including a call passage heard by a renamed room cluster | `Sources/DaybookCore/SourceFusion.swift:59-71` (read and confirmed) | Keep a name only where it was before (P2) | S |
| FU-03 | high | The echo-cancelled microphone takes the raw microphone's rate; recorder placements composed on the raw microphone ignore its drift. Probe: 0.72 s late at 1 h at 200 ppm, so remote speech heard by call and recorder stops merging after about 1.7 h at 100 ppm | `Sources/DaybookCore/SourceFusion.swift:116-120`; `MultiSourceFusion.swift:201-206`; `MultiSource.swift:191`; `CaptureFinalizer.swift:105` | One clock per track (P1) | S–M |
| FU-04 | high | Phrase-anchor fits accept any rate in 0.97–1.03 from three phrases spanning 10 s, are stored as `.transcript`, are never re-checked by sound, and can move a recording to another conversation. Probe: rate 0.9796, 285 s off at 14,000 s | `Sources/DaybookCore/TranscriptFusion.swift:110-143` (read and confirmed); `SourceFusion.swift:22-28`; `AppState+Sources.swift:387-390`; `SourceMatcher.swift:167-168` | Offset-only unless long span; 1000 ppm cap; re-check by sound (P1) | S |
| FU-05 | medium | Words doubled at the 240-item region cuts (3,003 of 3,000; 40,089 of 40,000) | `Sources/DaybookCore/MultiSourceFusion.swift:407-427,491,548` (cuts read and confirmed) | Banded global alignment and a duplicate guard (P5) | M |
| FU-06 | medium | A short overlap in a long file fails sound alignment even with a right prior: windows are subsampled over the whole file first (a 12 h file gives nil) | `Sources/DaybookCore/Alignment/AudioAligner.swift:132-143` | Draw windows only from the part that can map under `lagBounds` | S |
| FU-07 | medium | No full-search retry when the clock prior is wrong; `.noMatch` sets `audioChecked` for good. The retry the docs describe is in dead code | `Sources/Daybook/App/AppState+Sources.swift:126,400-401,416-419`; docs/alignment.md:25 | Retry a full search, accepting it only at `attachConfidence` (P1) | S |
| FU-08 | medium | The transcript check runs fusion on the main actor; the anchor search is O(S·R) plus an O(S²) uniqueness check. Probe: 36 s wall time for 4 × 40k words with one source needing anchors | `Sources/Daybook/App/AppState+Sources.swift:444-466`; `TranscriptFusion.swift:101-107` | Run detached; index rare tokens; limit to the prior's window | M |
| FU-09 | medium | A reference placed only by clock or transcript can anchor other placements, and dependents aren't re-placed when it moves | `Sources/DaybookCore/MultiSource.swift:224`; `AppState+Sources.swift:133-135,393` | Strong references only; track dependencies (P1) | S |
| FU-10 | medium | Corrections and names made on a `~live` portion don't follow the recorder's own file (traced by reading only) | `Sources/DaybookCore/CorrectionTransfer.swift:153-156`; `MultiSourceFusion.swift:132` | One identity for portion and file (P2) | S–M |
| FU-11 | low | Capture `clockRate` is unbounded; the shipped v0.2.2 fixture stores 48_000.5 | `Sources/DaybookCore/SourceFusion.swift:117`; `Tests/DaybookTests/Fixtures/Shipped/Generator/v0.2.2.swift:103` | 1000 ppm guard; fix the fixture | S |
| FU-12 | low | Alignment can't be cancelled inside a decode (about 10 s for 4 h); the shared feature cache gets no SHA key and no directory, so features are decoded again after every launch | `Sources/DaybookCore/Alignment/AudioAligner.swift:85-87`; `AudioFeatureCache.swift:13,20`; `MultiSourceCoordinator.swift:48` | Check cancellation per chunk; pass `sha256`; use a Caches directory | S |
| FU-13 | medium | No per-speaker source weighting: a worn Soundcore counts as room (0.8) and loses the wearer's words to the laptop microphone (1.0) | `Sources/DaybookCore/MultiSourceFusion.swift:590-607` | Quality from synced levels (P5) | M |
| FU-14 | low | Confidences from different ASR engines (Mac and iPhone models) are compared as if calibrated | `Sources/DaybookCore/MultiSourceFusion.swift:644-645` | Normalize per engine, or compare ranks | S |
| FU-15 | low | MSCQ-09's interim doc fix was never applied: the docs and comments still describe SNR weighting | docs/alignment.md:25,127; docs/architecture.md:125; `FusionSummary.swift:141-143` | Correct them, or implement P5 | S |
| SY-01 | high (rare) | The courier deletes an expired record (7 days) before delivering it, and it can be the only copy (phone lost before its iCloud Drive upload) | `Sources/DaybookKit/CloudKitCourier.swift:429` (read and confirmed); `InMemoryCourier.swift:159` | Deliver, then delete. Test: backdate 8 days; the record is promoted, not deleted | S |
| SY-02 | medium | Claim heartbeats (every 60 s and at each stage) publish the whole conversation. A 10–20 minute enhancement of a long multi-source conversation is an estimated 150–250 MB that every device downloads and decodes; the icloud-10 fix covered only the phone | `Sources/Daybook/App/AppState+Requests.swift:5-11,214-226`; `LibrarySync.swift:300` | Carry heartbeat and progress in presence `activity`; publish the claim only at claim, release and finish | M |
| SY-03 | medium | Courier-delivered audio is never noted for eviction, so the recording stays on the Mac twice; sealed inbox blobs are hashed on every pass. icloud-9's fix misses this path | `Sources/DaybookCore/LibrarySync.swift:139,1648` (read and confirmed); `LibrarySyncInbox.swift:201-221` | Drop the inbox blob once verified bytes are installed and iCloud lists the object | S |
| SY-04 | medium | Recordings over 50 MB (about 100 min) never use the courier, so they have no fast path and no second copy | `Sources/DaybookKit/SyncCourier.swift:114` (read and confirmed) | Chunked courier records, or the link courier (P3) | M |
| SY-05 | low | Mac reachability from presence flaps: presence is rewritten every 600 s against a 900 s window judged on the writer's clock | `Sources/DaybookCore/SyncReplica.swift:88`; `ProcessingCapabilities+Devices.swift:56`; `MacPresence.swift:33`; `LibrarySyncPresence.swift:221` | 2.5× the refresh interval, judged from this device's first sighting | S |
| SY-06 | low | A `processing.nudge` doesn't fetch the courier, and network recovery doesn't flush courier sends | `Sources/Daybook/App/AppState+Phone.swift:165-167`; `Apps/iOS/DaybookPhone/App/PhoneAppEnvironment.swift:160` | Fetch on nudge and periodically while awaited; flush on reachability | S |
| SY-07 | low | A courier file not settled at fetch (an error swallowed by `try?`) isn't offered again, because the change token has moved on; iCloud Drive still carries it, later | `Sources/DaybookKit/LibrarySyncController+Courier.swift:171`; `CloudKitCourier.swift:436-441` | Keep unsettled IDs and fetch them again | S |
| SY-08 | low | An eager pass requests only the first missing blob per conversation per pass | `Sources/DaybookCore/LibrarySync.swift:1630` | Request every missing asset before throwing | S |
| SY-09 | low | Applying a pass on the main actor: settings encoded each pass and meetings merged by linear lookups, O(n²) | `Sources/DaybookKit/LibraryController.swift:865-879` | Dictionary lookups; `MeetingMerge` off the main actor | S |

## 4. Decisions recommended

- **MSCQ-09 (SNR weighting and the stored audio-alignment pipeline): remove the pipeline, and bring quality weighting back only from data that already syncs.**
  - Delete `MeetingAudioAlignment`, `FusionInputs.audioAlignments`, `audioPlacement` and `signalQuality` from fusion. Keep `Meeting.audioAlignments` decoding as an inert legacy field. The live pipeline already stores sound placements as synced `SourceAlignment(.audio)` on each track, and two stores of one fact with different precedence is a hazard.
  - Do not compute SNR from local audio. The iPhone has none, so the two devices would fuse different words and fight in sync, and a per-second Float profile would add about 60–115 KB per 4-hour track.
  - Derive per-source, per-speaker weights from the synced `BackgroundAudioAnalysis.level` (P5), gated by a fusion version.
  - Until then, apply the interim doc fix (FU-15).
- **xdev-settings-08 (processing settings only on the Mac): make the speaker and language processing preferences synced library settings.**
  - Several devices now carry out each other's work: two Macs recording one conversation, an upgrade run by another Mac, the iPhone transcribing its own recordings.
  - A per-device preference makes the transcript depend on which device happened to take the claim. That's a determinism bug in multipoint.
  - Keep only resource limits per device. Offer the transcription language on the iPhone; it's the least contentious part, and it decides which model covers a recording.
- **hig-ios-14 (the "recorder is recording, this iPhone isn't" notification): request the Time Sensitive capability.**
  - A recording a person thinks is happening, but isn't, is the kind of interruption Time Sensitive exists for.
  - Add a notification action, "Record on iPhone", that opens Daybook and records into the same conversation.

## 5. Not findings (checked and fine)

**The link.**
- Pairing is robust: one attempt at a time, codes burned on any failure, refusals believed only before the first commit.
- A replaced session is closed before the new `.connected` is sent, so events stay ordered (`LinkService.swift:363-371`).
- Record requests are idempotent by ID across reconnects (`LinkSession.swift:269-296`, `LinkRecordAnswers`). Both sides ask again with the same ID: the Mac for 45 s (`MultiSourceCoordinator.swift:182,674-683`), the phone for 30 s.
- Forward compatibility: unknown types, fields and values are ignored and counted; an unreadable reply is a refusal; growing values are `LinkOpenValue`.
- Heartbeats run at the slower side's pace, with a probe on wake and on path changes.
- Owed stops are kept for a day and keyed by conversation, so they can't stop an unrelated recording.

**Timing across devices.**
- The phone waits for its first sample before asking Macs, and its anchor stores host and continuous time.
- A bookmark's time doesn't depend on transport delay (`createdAt` plus the clock estimate).
- Shared notes go out in order per channel, the latest change wins on clock-corrected `changedAt`, and nothing echoes (`SharedNotesTracker`).
- `PhoneLevels` is non-observable and holds at most 15 readings.
- The iPhone link's activity follows `recorder.isActive`, not the Live Activity, so a recording with Live Activities turned off keeps the link.

**Merging and fusion.**
- `MeetingMerge` handles two devices creating the same conversation with no common ancestor: the status further along wins, and default titles are treated as unset.
- Fusion is deterministic.
- Provenance stays in source-clock time when rate ≠ 1.
- Speaker IDs are `runID:cluster`, so two sources' "Speaker 1" never collide.
- `realign` is detached and drops stale results.
- Voting tie-breaks are deterministic (*fusion review*).

**Sync.**
- Inbox deliveries are verified (size, SHA-256, sealed header, library).
- Leases are judged from this device's first sighting, so clock skew doesn't matter.
- Claims are never cleared.
- A track removal merges as its own mark.
- Sealing costs about 0.4 s per GiB, off the main actor.
- The phone keeps its original until it's uploaded and the key is held elsewhere (*sync review*).

## 6. Paths and expected delays

Traced in code. The numbers are estimates until measured on two devices.

| Action | Path | Expected delay | What decides where it lands |
|---|---|---|---|
| Bookmark on the iPhone, shown on the Mac | `LinkSharing.bookmarkAdded` → `PhoneLink.enqueue(.notes)` → `LinkClient` → TLS/TCP → `LinkService` → `LinkEventHub` → main actor `PhoneLink.handle` → `AppState.phoneBookmarked` | 10–100 ms; seconds behind levels and captions on a congested link (LK-01) | `createdAt` on the phone's clock, moved by the link estimate (error about half the best round trip, a few ms), minus `recordingStartedAt` (`AppState+SharedNotes.swift:109-117`) |
| Stop on the Mac, iPhone stops | `recordingWillFinish` → `CompanionRecorders.macRecordingStopped` → `request(.stop)` → phone `answer` → `stopRecording` → reply | 50–300 ms, then filing | Unreachable: owed for a day; the phone also follows the Mac's idle state when it reconnects |
| Start on the iPhone, Mac joins | `beginCascade` → `askMacsToJoin` waits for the first sample (≤1.5 s) → `request(.start)` → `answerPhone` → `RecordingController.start` (call audio first) → ack | 1–3 s from the tap | The phone's track covers the opening; clock prior from the link |
| Start on the Mac, iPhone joins | `recordingDidStart` → `CompanionRecorders.start` → `ask` → phone `answer` → `startRecording` + first sample | 0.5–2 s after the Mac's capture | Only when the phone is in front or recording: the link is closed in the background |
| iPhone captions on the Mac | 1 s batches → `phoneCaptioned` → full `rebuild()` on the main actor | about 1–1.5 s plus recognizer lag | `LinkCaptions.startedAt` moved by the clock estimate |
| iPhone's audio on the Mac | stop → (Mac-led: a pass) → filing → `.filed` pass seals into `Blobs/` → CloudKit courier → push → Mac inbox → pass (deferred while the Mac's own job runs) | 15–45 s to the inbox on good Wi‑Fi; 30–90 s on cellular for 29 MB; over 50 MB, iCloud Drive (minutes to hours); applied only after the Mac's own job | Track placement: link clock prior, then sound |

## 7. What only two real devices can verify

**Link and network.**
- Bonjour, the local-network prompt, client-isolated and guest Wi‑Fi, IPv6 networks, and the AWDL fallback (LK-04).
- Clock accuracy on real Wi‑Fi with iPhone power save, and the real drift between an iPhone and a Mac over 2 hours (P1's drift prior).
- Real Start, Stop and Bookmark latencies, and the head-of-line delay while captions, levels or a file transfer run (LK-01, P3).

**iOS background behaviour.**
- Whether the link survives a background recording, calls and the Lock Screen.
- Whether iOS suspends Daybook between a Mac-led stop and filing (MP-06).
- How long a background assertion lasts, and whether a CKSyncEngine upload resumes after suspension.

**Live captions and devices.**
- The live-caption rebuild rate and its main-thread share with real recognizers: SpeechAnalyzer's volatile-result rate on a Mac, Nemotron on an iPhone (LC-01).
- Whether a Soundcore's live stream starts "now" for a recorder already recording (LC-04).

**Alignment and fusion on real audio.**
- Sound alignment of a Mac microphone against an iPhone microphone in one room.
- The echo-cancelled drift magnitudes behind FU-03.

**Sync and iCloud.**
- Push latency and coalescing.
- The courier's real 50 MB limit.
- Whether Optimize Mac Storage evicts container blobs (SY-03).
- Snapshot sizes for a 4-hour, 3-source conversation (SY-02).

**Several devices at once.**
- Two Macs and one iPhone end to end (MP-01, P7). Loopback tests with two simulated Macs can prove the logic first.
- Crossing starts on real hardware (MP-03).
