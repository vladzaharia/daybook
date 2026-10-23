# Daybook architecture

Daybook is a native SwiftUI application for Apple silicon Macs running macOS 15 or later. Audio capture, model inference, meeting storage, and transcript synthesis execute in the application. Downloading a selected model is a separate operation from processing a recording.

## Components and data flow

```mermaid
flowchart LR
    Microphone[Microphone / AVAudioEngine] --> Capture[Capture staging]
    Computer[Computer audio / ScreenCaptureKit] --> Capture
    Soundcore[Soundcore export or experimental BLE transfer] --> Import[File or incoming-folder import]
    Capture --> Library[Local meeting library]
    Import --> Library
    Library --> ASR[WhisperKit transcription]
    Library --> Speakers[FluidAudio speaker turns]
    ASR --> Source[Per-source transcripts]
    Speakers --> Source
    Source --> Fusion[Alignment and conservative fusion]
    Fusion --> LLM[MLX local summarization]
    Notes[Live notes and highlights] --> LLM
    Glossary[Approved vocabulary and meeting-scoped proposals] --> ASR
    Glossary --> LLM
    LLM --> Summary[Summary and proposed terms]
    Summary --> Library
    Library <--> Sync[Coordinated immutable sync journal]
    Sync <--> iCloud[User-selected iCloud Drive folder]
```

| Component | Responsibility | Implementation |
| --- | --- | --- |
| App state | Owns selection, editing, processing queues, model selection, and UI state | [AppState](../Sources/Daybook/App/AppState.swift) |
| Capture | Saves microphone and computer audio separately, records timing, and preserves interrupted captures | [RecordingController](../Sources/Daybook/Capture/RecordingController.swift), [CaptureRecovery](../Sources/Daybook/Capture/CaptureRecovery.swift) |
| Detection | Uses meeting-window evidence and per-process audio activity, with start/end debounce | [MeetingDetection](../Sources/Daybook/Capture/MeetingDetection.swift) |
| Core domain | Represents meetings, sources, transcript provenance, corrections, speakers, summaries, and highlights | [Models](../Sources/DaybookCore/Models.swift) |
| Local storage | Copies original bytes, deduplicates imports, validates paths, recovers metadata, and supports local trash | [MeetingStore](../Sources/DaybookCore/MeetingStore.swift) |
| Inference | Loads downloaded speech, speaker, and language models in process | [LocalIntelligenceRuntime](../Sources/Daybook/Intelligence/LocalIntelligenceRuntime.swift) |
| Transcript synthesis | Aligns source clocks and removes only sufficiently evidenced duplicate passages | [TranscriptFusion](../Sources/DaybookCore/TranscriptFusion.swift) |
| Vocabulary | Keeps proposed terms scoped to their source meeting until user approval | [GlossaryStore](../Sources/DaybookCore/GlossaryStore.swift) |

The core library depends on Foundation, making persistence and alignment tests independent of model downloads or microphone permissions. The app uses actors for storage and inference. UI mutations belong to the main actor; the application owns sequencing across capture, import, editing, and inference operations.

## Capture and import

Microphone audio comes from `AVAudioEngine`; computer audio comes from `ScreenCaptureKit`. The app registers no video output and stores no screen frames. Computer capture can include audio from applications other than the meeting application. Separate source tracks share capture-session timing, so they can be combined without guessing their offsets from filenames or import dates. See [capture behavior and acceptance checks](capture.md).

Automatic recording is an explicit preference. Detection polls supported application/window patterns and audio activity, waits for sustained evidence before starting, and waits for evidence to disappear before ending. Browser process activity does not identify an individual browser tab. Localized or changed window titles, muted calls, sleep, and device changes need real-call validation; this is a heuristic, not an integration with each provider's meeting lifecycle API.

Soundcore recordings enter through exported audio or the experimental direct Bluetooth adapter. Protocol and native-codec tests do not establish physical firmware compatibility. The incoming-folder monitor waits for unchanged file metadata across scans before requesting import. The importer copies bytes, computes SHA-256 on the copied file, and deduplicates within the explicitly selected meeting. An advisory library-wide digest lookup is available for avoiding repeat incoming-folder deliveries. An unchanged size and modification time are a practical readiness signal, not a guarantee that an arbitrary external producer has closed a file.

Optional annotation files use `<audio basename>.highlights.json`; their current schema version is 1. Unversioned legacy sidecars are interpreted as version 1. The importer rejects unrelated JSON or unsupported schema versions with an explicit error. See the [sidecar example](soundcore.md#highlights-sidecar).

## Storage and recovery

The default root is `~/Library/Application Support/Daybook`:

```text
Daybook/
  Meetings/<meeting UUID>/
    meeting.json
    meeting.recovery.json
    Originals/<track UUID>.<original extension>
    Originals/<track UUID>.highlights-<SHA-256>.json
  Trash/<meeting UUID>/...
  Staging/<meeting UUID>/...
  Models/...
  glossary.json
  glossary.recovery.json
```

The current meeting schema is version 1. Metadata writes use an atomic sibling-file replacement, retaining the previous validated snapshot. Parsing errors or invalid metadata can recover from that snapshot; the damaged file is retained. A future schema is rejected instead of being silently overwritten or rolled back. A corrupt meeting produces a warning while other meetings remain available. This provides process-restart recovery, not a substitute for an independent backup or a guarantee against storage-device failure.

Tracks, transcription runs, and correction history are append-only during normal metadata saves. An older queued notes snapshot cannot remove a recording imported while that snapshot was pending. Import also merges with the latest persisted meeting. The UI still owns reconciling concurrent changes to editable metadata such as notes, titles, and speaker names.

Audio filenames inside the library use generated identifiers. Relative paths cannot escape their meeting directory, including through symlinks to existing ancestors or nonexistent leaf files. Original audio is never moved out of its import location or overwritten. Highlight sidecars use content-addressed filenames, so a later sidecar cannot overwrite the earlier bytes.

Moving a meeting to local Trash moves its entire directory. Its original ID acts as a persistent tombstone that rejects queued stale saves. Local-only restoration moves it back; once a deletion has synced, recovery requires a new meeting UUID. This is application trash, not permanent erasure or the macOS Trash service.

Files use user-only permissions. This version does not add application-level encryption. Optional iCloud Drive synchronization exchanges the complete meeting library through immutable records and content-addressed originals. Local inference stays independent of sync; see [sync architecture](icloud-sync.md).

Concurrent sync merges keep transcript text, its clock alignment, and correction-review candidates together as one derived view. Notes and their paragraph anchors also travel together, including the alternate version retained in conflict history. During a process lifetime, unchanged local originals reuse an integrity check keyed by digest, size, modification time, and filesystem identity; a restart or file change triggers hashing again. A differing local original is preserved under `SyncConflicts` before verified remote bytes replace it.

## Transcript clocks and fusion

Raw transcript times are nonnegative seconds within their own audio file. Unified times are seconds on a shared meeting timeline and may be negative: a wearable can begin before the computer recording. Original times remain in `SegmentProvenance`, and playback should seek using those source times.

The first usable source in the meeting's transcription history defines the timeline origin. The latest model run for each source participates in synthesis, but prior runs remain stored. Attaching a longer source does not change the existing origin. A verified offset from capture or manual alignment is used directly. Otherwise alignment searches for distinct shared phrases of at least four tokens and twenty normalized characters.

Automatic alignment requires at least three consistent anchors spanning ten seconds. A deterministic consensus fit estimates `meetingTime = sourceTime * rate + offset`, with rates restricted to 0.97–1.03. Candidate fits accept anchors within 1.5 seconds and must explain at least 60% of the selected anchors. Consensus work is bounded by sampling up to 120 anchors across the recording. Reports expose method, matched anchors, estimated rate/offset, and residual.

Duplicate removal is deliberately stricter than alignment. Passages must overlap in time, begin within two seconds, contain at least four tokens, and have identical normalized token sequences. Model confidence chooses the displayed punctuation/casing variant; all contributing source passages remain in provenance. Short acknowledgments, negation differences, extra clauses, conflicting passages, and different segmentation remain separate. Confidence is not treated as proof that a conflicting passage is wrong.

Tracks that cannot be aligned remain stored separately and are excluded from the unified transcript. A summary built from that transcript cannot claim to cover an unaligned recording. Manual timing can include it after review. A highlight with an unaligned source has no common-timeline timestamp; `Meeting.alignedTime(for:)` returns `nil`.

This initial fusion is text-based. It does not perform acoustic cross-correlation, word-level cross-source reconstruction, nonlinear time warping, or global speaker identity matching. Different ASR segment boundaries can leave duplicate passages, and heavy transcription differences can prevent automatic alignment. These are visible review cases rather than grounds to silently discard source speech.

`Meeting.applyFusion` preserves user corrections when provenance identities survive a source preference change. New transcription runs use conservative same-source text/time correspondence to transfer corrections. Ambiguous mappings become review items with their original text retained. The user can apply a saved correction to a chosen passage or keep it only in history.

## Notes, synthesis, and learning

The floating notes panel shares the meeting's notes with the main library. New note paragraphs receive monotonic capture timestamps; pre/post-recording paragraphs stay untimed and later wording changes retain their first anchor. Timed notes are distinct timeline entries, never falsely attributed as spoken words. Highlights collect nearby recorded context (30 seconds before/60 seconds after by default), retain source time when unaligned, and direct additional detail in synthesis. Notes, mapped highlights, the unified transcript, the selected template, and allowed glossary terms form synthesis input. Local model output selects a meeting kind when requested and produces structured sections/actions. See [the model runtime](model-runtime.md) for model versions, offline loading, context budgeting, and validation.

Processing requests freeze selected models, speaker effort, expected count, matching thresholds, and mode. `Process` handles new sources; `Refresh summary` needs only the language model; speaker relabeling reuses stored ASR words; full retranscription creates another source run. Older runs without words can be relabeled at passage granularity, with a visible notice. Source runs and summaries record the settings used. Failed speaker-only refreshes leave the prior successful run active.

Named speakers are editable labels on anonymous clusters. Reusable Community-1 embeddings can match sources and reruns within the same meeting using a configurable cosine threshold and runner-up margin. Distinct embedding backbones are never compared; ambiguous matches remain separate. Sortformer does not provide reusable embeddings. There is no automatic identity enrollment across meetings. Learning currently means preserving corrections, summary revisions, and vocabulary approval; it does not change model weights. Proposed vocabulary remains scoped to its originating meeting. Only explicitly approved terms are eligible for other conversations.

## Verification boundary

[Core tests](../Tests/DaybookCoreTests) exercise persistence recovery, schema safety, path validation, original-byte preservation, duplicate imports, concurrent stale snapshots, reversible trash, glossary isolation, manual and inferred timing, clock drift, repeated phrases, ambiguous passages, and correction provenance. They use temporary libraries and synthetic text/audio bytes, without downloading models.

[Application tests](../Tests/DaybookTests), an opt-in real-model smoke test, and manual hardware acceptance cover different layers. Passing unit tests does not establish transcription accuracy, speaker accuracy, Soundcore firmware compatibility, or reliable call detection on every meeting app. Those require representative audio and real-device recordings.
