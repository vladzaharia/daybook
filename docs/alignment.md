# Multi-source alignment and fusion

Daybook can record one conversation several ways at once: computer audio (the call's remote side), the Mac microphone (raw, and an echo-cancelled copy), and a recorder in the room. It can also attach a recorder's file afterwards. This document covers the two steps under both cases:

1. **Audio alignment** (`Sources/DaybookCore/Alignment/`) finds where one recording sits on another's timeline, and how fast its clock runs, from the sound alone.
2. **Fusion** (`TranscriptFusion`, `MultiSourceFusion`) places every transcript on the meeting timeline. It then merges them into one transcript, word by word, with provenance.

Everything runs locally. Audio alignment uses Accelerate (vDSP) and AVFoundation decoding and needs no models.

## Pipeline contract

```swift
// 1. Line a recording up against another, off the main actor (decodes audio; features are cached).
let sound = try AudioAligner.align(other: recordingURL, reference: referenceURL, expectedOffset: prior, searchRadius: radius)
// 2. Store it as the recording's placement (`RecordingTrack.alignment`, a `SourceAlignment` composed onto the
//    reference's own clock, `meeting.clock(of:)`: `SourcePlacement.compose`).
// 3. Fuse with every stored placement (`FusionInputs(placements:)`), then store what fusion settled. This stores
//    unifiedTranscript, alignmentReports, fusionSummary, and the owner speaker.
let result = SourceFusion.fuse(meeting)
meeting.applyFusion(result.fusion)
meeting.applyPlacements(result.settled)
```

On the Mac, `MultiSourceCoordinator` lines up a recording that arrives (a recorder's, an imported file) with `AudioAligner.analyze(other:otherDigest:reference:referenceDigest:expectedOffset:searchRadius:cache:)`. It returns `AudioAlignment { offset, rate, confidence }` with `referenceTime = offset + rate × otherTime`, or nil when the recordings don't share enough sound. If `expectedOffset` is nil, or the radius isn't a positive finite number, it searches every placement where the two recordings overlap. Otherwise it searches only ±`searchRadius` seconds around the prior. The report also carries windows compared and matched, median peak, residual, ambiguity, overlap span, and an explanation.

A prior can be wrong: a recorder's clock set minutes off. When the search around the prior finds nothing at `placeConfidence` (0.5), `compareSound` searches the whole overlap and keeps what that finds only at `attachConfidence` (0.6), the confidence that joins a recording to a conversation.

Daybook 0.2.2 also stored pairwise measurements on the conversation (`Meeting.audioAlignments`, `TrackAudioAlignment`). Nothing writes them any more, but they're still read: fusion places a source by a stored measurement taken on the same bytes (`FusionInputs(meeting:)`), and sync merges them (see Sync).

`TranscriptFusion.fuse(_:tracks:)` keeps its old signature and behaviour for callers without audio evidence. It goes through the same engine.

A pipeline that decides placements itself can pass them in as `FusionInputs(placements: [trackID: TrackPlacement(offset:rate:method:confidence:)])`, with methods `.audio`, `.anchors`, `.timestamps`, or `.provided`. Placements take precedence over everything except the timeline reference. A derived recording without one of its own takes its original's offset, never its rate (below). Passing the rate this way replaces rescaling segment times. If a caller does rescale segments, and each segment cites its original times in a provenance entry for itself, fusion reads word timings and provenance in that original clock.

`TranscriptFusion.fuse(meeting:)` builds the inputs from a meeting: stored measurements, speakers, and the speakers the person renamed.

### One clock per recording

`Meeting.clock(of:)` returns a recording's `TimelineClock { offset, rate, method, confidence, dependsOn }`, and it's the only place a recording's place is worked out. `SourceFusion` gives it to fusion, `compareSound` composes a sound alignment onto the reference's clock, and bookmarks (`alignedTime`), notes, photos, and the inspector read it. In order:

1. its stored placement (`RecordingTrack.alignment`), once placed;
2. nothing while it waits to be placed (`pending`), or couldn't be (`unaligned`);
3. a derived copy without a placement of its own (the echo-cancelled microphone) takes its original's offset and runs at its own capture rate. The copy is resampled onto the capture's session clock, so the raw microphone's drift isn't its drift;
4. its capture offset, at the clock rate its capture measured (`TrackCaptureDetails.clockRate`);
5. what the latest fusion reported (a recording fusion placed by itself, as before multipoint), or nothing when fusion couldn't place it;
6. zero, for the conversation's first recording.

Rates stay within 1000 ppm everywhere (`ClockRate`): the aligner's own limit, a capture's measured rate (one outside it, such as a sample rate stored by mistake, reads as 1), and a fit from shared phrases. A placement stored with a rate outside it (an old phrase fit) reads at rate 1, kept right at the recording's middle.

A recording lined up against another (`dependsOn`, the placement's `referenceTrackID`) moves when that one does: `Meeting.applyPlacements` maps each dependent through the same change of timeline. A sibling on one capture clock that follows a placed one (`followingClockSiblings`) records it as its reference, so it moves too, at its own capture rate. Only a sure placement anchors another (`TimelineClock.isStrong`: the origin, capture timing, the person's setting, or the sound), never one placed only by shared phrases or the clocks.

### One origin

A conversation has one timeline origin. When an iPhone asks two Macs to record along, each Mac files its recording as the origin, so after sync both sit at zero. Each Mac recording's tracks carry `TrackCaptureDetails.captureID` and the Mac's link `deviceID`. `Meeting.separatingCaptureGroups` keeps the capture that started first (the leader's, when a Mac led), and makes every other capture `pending`, on one clock (`clockID`), with a clock prior. The prior is that capture's start on the first one's clock, from an iPhone's `capture.peerClocks` when one measured both Macs; otherwise it's from the Macs' own clocks. Processing then places it as any waiting recording: sound, transcript, then clocks. A recording lined up against one of its tracks (an iPhone's, by sound, on that Mac) was placed on that Mac's timeline, so it waits too, its prior moved as far. Captures filed before the ID was kept are told apart by their microphone tracks.

## Audio alignment

### Features

Each recording is read in 32k-frame chunks with `AVAudioFile`, averaged to mono, and resampled to 8 kHz with `AVAudioConverter`. Only frame-rate features are kept, 10 ms per frame, which is about 800 bytes per second of audio. Whole-file sample arrays are never built.

- **Onset envelope.** The features are 24 mel bands (100 Hz–3.8 kHz) from a 20 ms Hann window. Each band is in dB and is gated at its tracked background level plus 6 dB. The onset value is the positive band rise over 20 ms, averaged across bands, square-root compressed, and centred by subtracting a one-second moving average.
  - Log bands make it independent of gain and automatic gain control.
  - The gate keeps background noise from creating onsets.
  - Rises survive reverb tails and codecs.
- **Level.** The frame level in dB, used for activity detection.

The window length matters for reverberant rooms. A 32 ms window biased a reverberant recorder 13 ms late against clean call audio. A 20 ms window cut that bias to about 8 ms. This bias is physical: early reflections arrive after the direct sound.

`AudioFeatureCache` keeps features in memory, keyed by the file's SHA-256 or by path, size, and date. With a directory, it also persists them as `<sha256>-v1.features`. The Mac's (`MultiSourceCoordinator.features`) lives in its Caches folder and is given each recording's digest, so a recording is read once, not after every launch. Features can't reproduce speech, and the cache directory needn't sync. Reading a recording checks for cancellation between chunks, so a cancelled job stops mid-file.

### Search

1. **Coarse.** Up to 48 active 15-second windows of the other recording are compared with every allowed position in the reference. They're drawn only from the part of the recording that can overlap the reference under the search's bounds, so a short overlap in a long recording, with a prior, still gets its windows. The comparison is normalized cross-correlation of onset envelopes, using one real FFT of the whole reference that all windows share. Each window keeps its three best peaks, weighted by peak height and peak-to-sidelobe ratio. Without a prior, the search covers both recordings' full lengths, so clocks can differ by minutes or hours.
2. **Consensus.** Pairs of window peaks make offset-and-drift hypotheses, limited to ±1000 ppm. Each hypothesis is scored by how many windows agree within 60 ms. This is an exhaustive, deterministic RANSAC. The rival score is the best hypothesis more than 0.25 s away, which measures ambiguity, for example from repetitive sound.
3. **Fine.** Along the predicted overlap, a 10-second window every 5 seconds is matched within ±0.2 s of the consensus line, with parabolic sub-frame interpolation. Windows count only where both recordings have sound at that place. A Huber fit, followed by a refit on windows within 30 ms, gives the offset and drift.
4. **Confidence** is a product of five factors:
   - the evidence: matched windows, saturating near 20;
   - consistency: the share of comparable windows that matched;
   - sharpness: the median correlation peak;
   - distinctness: one minus the rival hypothesis's share;
   - precision: the residual.

   Partial overlap is judged only on the shared span, so a recorder that started earlier isn't penalized. Recordings with no shared sound find no three-window consensus and return nil. A weak match below confidence 0.15 also returns nil; the report still carries the candidate.

### Measured on synthetic recordings

The recordings are synthetic speech: voiced syllables shaped by formants, plus consonant bursts, from a remote and a local talker. The call capture is 16 kHz PCM with the remote side only. The recorder is 44.1 kHz AAC with both talkers, reverb (48 decaying reflections, RT60 about 0.45 s), noise, and gain swings between 0.35× and 1.6×, on its own clock. Results are from a debug build.

| Case | Offset error | Drift error | Confidence |
|---|---|---|---|
| Recorder 197 s in, +200 ppm | −8 ms | −6 ppm | 0.98 |
| Recorder 197 s in, −200 ppm | −10 ms | +2 ppm | 0.998 |
| Recorder starts 90 s earlier, ends 80 s later, +150 ppm | −9 ms | +1 ppm | 0.99 |
| Clean copy at another sample rate | < 1 ms | < 1 ppm | 0.999 |
| Only 40 s of overlap | < 20 ms | — | 0.35 |
| Unrelated conversation; adjacent but non-overlapping stretch | nil | | |
| 30 + 30 minute pair, +120 ppm | −9.5 ms | −0.2 ppm | — |

The 30-minute pair, decode included, took 2.5 s at load average 50. The test budget is 15 s. Of that, extraction took about 0.6 s for the PCM file and 1.3 s for the AAC file, and the full-range search about 0.45 s (0.22 s with a ±60 s prior).

## Fusion

### Timeline, per recording

Methods are tried in this order, and the method used is recorded in `TrackAlignment.method`:

1. `reference`: the first transcribed usable recording is the timeline origin and never moves.
2. `provided`: an offset from capture or set by the person, at the capture's measured rate. An echo-cancelled copy (`derivedFrom`) takes its original's offset at its own rate.
3. `audio`: the most confident stored `TrackAudioAlignment` (at least 0.3) whose other recording is already placed. Measurements made on different bytes (SHA-256 mismatch) are ignored. Offset and rate are composed through the placed recording, so a recorder aligned against the raw microphone lands correctly on a timeline defined by computer audio.
4. `anchors`: distinct shared phrases, tried against every placed recording, with the best fit winning. At least three anchors over 10 s place a recording. The fit measures a rate (within 1000 ppm) only when its anchors span max(10 minutes, 30% of the overlap); otherwise it's an offset at rate 1. A few phrases seconds apart can't tell a clock's drift from timing noise, and fusion version 1 accepted any rate from 0.97 to 1.03 from them, which put the end of a long recording minutes off. The fit's confidence grows with its span, in full from two minutes, so a short one can't move a recording into another conversation alone. A phrase fit stored with a rate outside 1000 ppm is fitted again the next time the conversation is fused.
5. `timestamps`: wall-clock starts from `recordingStartDates`. These are weak (confidence 0.2), and the explanation says so.
6. `unaligned`: the recording stays out of the unified transcript, as before.

`TrackAlignment` gained `confidence`, `referenceTrackID`, and `driftPPM`.

### Words

An original that has a transcribed derived copy (the raw microphone next to its echo-cancelled version) is left out. Otherwise the call heard through the speakers would come back through it.

Every placed transcript becomes a word stream on the meeting timeline. Words use recognizer timings when `TrackTranscript.words` spell the segment exactly. Otherwise they are spread over the segment by length, with a wider time tolerance. Sources are merged in priority order (call, microphone, room/other) into a word transition network, as in ROVER. Each source is aligned to the network by an edit distance in which a word may only pair with a column within its time tolerance. The alignment covers the whole sequence at once, within a band of columns close enough in time to each word, so its cost grows with words × band, not words × columns. Four recordings of 40,000 words fuse in under a second in a release build. Fusion version 1 cut the timeline every 240 items, and a fragment of a passage past a cut was kept twice (3,003 words out of 3,000 shared).

The time tolerances:

- 0.3 s for capture or audio timing;
- 0.6 s or more for phrase anchors;
- 2.5 s for timestamps;
- plus 0.75 s when word times are interpolated.

The alignment decides which words repeat speech already in the network:

- A passage needs at least two exact matches, covering at least 30% of its words, before any of it can repeat existing speech. Someone talking over another person can share "the" and "to" by chance.
- Two adjacent exact matches anchor a stretch. So does a single unique, closely timed match.
- Words between anchors join that stretch (substitutions and insertions).
- Leading and trailing words join when they fall inside the passage another source was transcribing.
- Replies shorter than four words ("yes", "okay") join only an unambiguous counterpart within half the tolerance, because two people can answer at once.

Unanchored words are distinct speech, such as crosstalk or a colleague only the recorder heard. They are never voted away, and are merged only by one guard against the same speech the rules miss: a run of four or more words from one source that repeats, word for word, a run of columns another source holds, within twice their tolerance, joins those columns.

### Voting

Each column is decided by weighted votes. A source scores *weight × (0.5 + 0.5 × confidence)*. A source that was transcribing the stretch but heard no word votes for nothing, at confidence 0.5.

The weight depends on the speech's role:

| Source | Remote speech (the call carries or covers the column) | Local speech |
|---|---|---|
| Call audio | 1.0 | 0.6 |
| Microphone | 0.5 | 1.0 |
| Room recorder or imported file | 0.5 | 0.8 |

One more factor adjusts the weight: sources placed by anchors are scaled by 0.9, and by timestamps by 0.6. Signal-to-noise ratio isn't a factor; the iPhone fuses without the audio to measure it, and both devices word a transcript alike.

Recognizers aren't calibrated against each other: the iPhone's model and the Mac's report confidence on different scales. When the sources come from more than one recognizer (`processingSettings.model`, else `modelID`), each word's confidence is compared as its rank among all the words that recognizer gave (0–1). Within one recognizer the order is unchanged, and sources from a single recognizer vote with their confidences as they are.

So the call's wording wins remote speech over one confident far-field mishearing. Two far-field recordings that agree outvote a low-confidence call word.

Some words resist removal. A negation, a number, or a word in a run of three or more words heard by one source alone is dropped only when at least two sources outvote it. Fusion records each decided word: `FusionSummary.disputedWords` counts them, and provenance keeps every version.

### Passages, speakers, provenance

Each output passage follows the segmentation of its earliest-priority source's segment and keeps that segment's ID. Adding a recording therefore doesn't renumber, re-split, or orphan existing passages or their corrections. A passage is split where the attributed speaker changes. Passages only one recording heard are passed through verbatim, as before. `trackID` is the source whose votes carried the passage, which is what playback seeks in.

`SegmentProvenance` has one entry per contributing source segment. Each entry holds:

- that source's own words and times in its own clock;
- `wordIndices`: the positions in the fused text that this source supplied or agreed with.

So you can tell, for every word, which recordings said it.

Speakers are labelled in priority order:

- Call audio keeps its diarized speakers, the remote participants.
- On the microphone, the dominant local voice is the owner. A local voice is one whose words the call didn't carry, and dominant means at least 70%. The owner is labelled `owner`, named "Me" until renamed, or keeps a microphone speaker the person already named.
- Other labels on the microphone and recorders are mapped onto established speakers by shared speech (`SpeakerMatcher.matchByCooccurrence`): at least six shared words, at least 70% with one speaker, and two labels from one recording can't claim the same speaker without a 2× margin.
- Labels the person renamed are never remapped.
- Brief label flips inside a passage follow the surrounding speaker.
- A merged passage whose fused speaker isn't one the person named keeps a name only where it stood in the transcript before: on the same passage, or on the passage made from the same home segment (`SourceFusion.keepingNamedSpeakers`). A name from another recording that heard the passage never labels it. A room recorder's cluster can take in the call's voice through the laptop's speakers, and naming that cluster mustn't name the remote speaker. Version 1 took any named speaker in the passage's provenance.

Embedding matches made at transcription time still apply first.

### Corrections

`Meeting.applyFusion` still runs `CorrectionTransfer`. Because passage IDs follow the first source, a correction keeps its passage when a recording is added. When one recorder segment is cited by two passages, transfer now prefers the passage with the corrected ID, then the one with clearly more shared source time. Previously that case always became a review item.

### Sync

`Meeting.audioAlignments` merges across Macs per recording pair, and the newest measurement wins without a conflict entry, because measurements are derived data. `fusionSummary` travels with the unified transcript and alignment reports as one derived view, so a summary never describes another Mac's transcript.

### Summary

`FusionSummary`, stored as `Meeting.fusionSummary` and deterministic for the same inputs, contains:

- per source: role, whether it was included, method, reference recording, offset, rate, drift in ppm, and confidence;
- per source, word counts: words in, words whose wording was used, words corroborated with another source, words merged as duplicates, and words overruled;
- totals, the owner speaker ID, and every speaker mapping with its reason;
- `version`, the fusion that made it.

### Fusion versions

`FusionSummary.currentVersion` is 2. A conversation's wording changes only when it's fused again for a reason: new audio, Adjust Timing, removing or putting back a recording, keeping or leaving out background audio, or processing again. Upkeep the person didn't ask for keeps the version the conversation was last fused with (`LibraryController.realign(_:keepingVersion:)`): background audio heard in an earlier recording, and stranded words joined to their speaker. A conversation fused before versions were recorded counts as 1.

| Version | Fusion |
|---|---|
| 1 | Words aligned in 240-item regions; raw confidences; a named speaker anywhere in a merged passage's provenance labels it; phrase fits measure any rate from 0.97 to 1.03, and stored ones are used at their rate. |
| 2 | One banded alignment and the four-word guard; confidences compared by rank across recognizers; names kept only where they stood; phrase fits held to 1000 ppm and measured only over a long span; a second Mac's recording made a source to place. |

The clock rules (one clock per recording, a derived copy at its own rate, capture rates within 1000 ppm) apply at every version: they place recordings, and both apps must read a placement alike.

## Known limits

- Accuracy figures come from synthetic speech, not from real rooms, laptop speakers, Bluetooth codecs, or recorder firmware. See [validation](validation.md#multi-source-alignment).
- Reverberant recorders align a few milliseconds late, about 8 ms in the synthetic room. This is negligible for transcripts, but don't use it for sample-accurate mixing.
- The rate is a single linear fit. Clock jumps, dropped audio, or a recorder pausing mid-file would need piecewise alignment. They currently show up as low confidence or a high residual.
- With headphones, the room recorder may share no sound with computer audio. It is then aligned against the microphone, which needs the owner or someone in the room to talk.
- Owner inference needs call audio and assumes the person recording dominates the microphone's local speech. In an in-person meeting, or with several people at the Mac, labels stay as diarized.
- Word voting can't recover words that no source recognized. When one recording alone hears a short insertion during another's passage, that insertion can be voted out.
- When a second Mac's recording is made a source to place (one origin), the notes and bookmarks that Mac took stay timed by its own start; only its recordings move.
- A waiting recording with no words of its own (silent computer audio) stays waiting until the sound places it or it follows a sibling on its clock.
