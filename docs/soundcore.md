# Soundcore Work integration

Research checked 2026-10-23. Soundcore Work is a device in Daybook's [device framework](devices.md) with two methods: **directly over Bluetooth** (primary and recommended; see [direct Soundcore](direct-soundcore.md)) and **from the Soundcore app** through a watched export folder (the fallback that works with every firmware). Physical-hardware validation of the Bluetooth method is still pending. Daybook does not use Soundcore’s cloud or transcription service.

## What the vendor documents

| Capability | Evidence and implication |
| --- | --- |
| Transfer to phone | The [official transfer guide](https://service.soundcore.com/article-description/How-do-I-transfer-files-to-my-phone-using-soundcore-Work) describes transfer through the Soundcore app, including real-time transfer and a Wi-Fi Fast Transfer option. The phone app is the supported bridge. |
| Audio export | The [D3200 user guide, page 6](https://salesforce-knowledge-download.s3.us-west-2.amazonaws.com/000030993/en_US/000030993.pdf) lists MP3 audio export and TXT, Markdown, DOCX, and PDF export for text. Export original audio for Daybook to process. This retrieved vendor manual is in Spanish. |
| Highlights | The same guide describes double-tapping the recorder to save a timestamp. It does not document a machine-readable highlight export schema. Daybook cannot assume highlights are embedded in an exported MP3. |
| USB access | The [current official product page](https://www.soundcore.com/products/d3200-soundcore-work-ai-voice-recorder) explicitly says audio cannot be exported through USB. A charging cable is not a mass-storage import path. |
| Cloud processing | The product page says vendor transcription sends audio to the cloud. Daybook's import workflow needs only the exported audio; its models run on the Mac. Vendor app configuration remains separate from Daybook. |
| Public vendor SDK | No public Anker-supported Work recording-download SDK or authenticated recording/highlight API was found in the reviewed official material. This is a research finding, not proof that a private partner interface cannot exist. |

## The export-folder workflow

This is the fallback method; with Bluetooth set up, recordings arrive without the phone.

1. Record on Soundcore Work, then transfer the recording into the Soundcore phone app.
2. Export the audio file. Transfer it to a local Mac folder, for example through AirDrop or a locally managed transfer.
3. Import the file into Daybook as a new meeting. To combine it with an existing computer recording, explicitly attach it to that meeting.
4. Daybook copies the original bytes into its local library and computes a SHA-256 digest. Reimporting identical bytes into the same meeting reuses the stored track.
5. Transcribe and synthesize with downloaded local models. Original recordings and each transcription run remain available.

Daybook watches the chosen folder (`ImportFolderWatcher`) and imports a file once it's unchanged across two scans, through the same `MeetingStore.importAudio` API, recording the device identity on the track. A file appearing in the folder creates a new conversation unless the person explicitly attaches it to another one. Import time is not evidence that two recordings describe the same conversation. Files in the folder are never moved, renamed, or deleted.

## Highlights sidecar

Daybook defines its own optional sidecar for timestamp annotations. This is **not a claimed Soundcore export format**. It can be created manually or produced by a future verified adapter:

For automatic discovery during file or folder import, put it beside the audio using the same basename: `conversation.mp3` and `conversation.highlights.json`. An unrelated `conversation.json` is not treated as a highlights file.

```json
{
  "schemaVersion": 1,
  "highlights": [
    { "time": 42.5, "text": "Discuss this decision" },
    { "time": 180, "text": "Follow-up question" }
  ]
}
```

`schemaVersion` is 1; older unversioned sidecars are read as version 1. Unsupported versions fail with an explicit error. `time` is finite, nonnegative seconds from the beginning of that audio file. `text` is required and may be empty. Pass the file explicitly as `sidecarURL` to `MeetingStore.importAudio`. The original sidecar is retained beside the audio, and annotations retain their originating track ID. Annotations are deduplicated by track, time, and text. Highlight times stay in source coordinates; a viewer converts them using the track's alignment report when presenting a common timeline.

## Combining a wearable and computer recording

`RecordingTrack.offset` or `TrackTranscript.knownOffset` represents a verified source start time on the common timeline. Capture can supply this for simultaneous local tracks. File creation/import dates are never converted into trusted offsets automatically.

When a wearable has no verified offset, `TranscriptFusion` requires at least three distinct shared phrases across at least ten seconds. A consensus fit estimates offset and modest clock drift, rejects inconsistent anchors, and exposes the alignment method and residual. The first usable source remains the timeline origin when recordings are attached later. Duplicate removal requires at least four identical normalized tokens and overlapping aligned times. Confidence chooses the displayed punctuation/casing variant while both source passages survive in provenance. Short replies and differing words, including negation or additional clauses, remain separate.

A recording with insufficient anchors is marked unaligned and excluded from the unified transcript. Its original transcript remains accessible. The user can establish a verified offset to include it. Overlapping passages that disagree are retained separately. This initial algorithm is conservative and can miss duplicates when two engines choose very different segment boundaries; acoustic alignment remains a future improvement. Optional same-model speaker embeddings now support configurable cross-source matching within a meeting.

## Direct Bluetooth

The community [Soundcore Manager repository](https://github.com/tacshi/Soundcore/blob/main/README.md) reports a reverse-engineered D3200 BLE protocol, offline recording access, and Wi-Fi SoftAP export. Its [protocol notes](https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md) are the research input for Daybook's own implementation; the community code is not bundled. It is not a vendor SDK.

The direct method, its connection state machine, integrity checks, and tests are described in [direct Soundcore](direct-soundcore.md). A recording's ID is its start by the recorder's own clock; Daybook measures that clock when it starts a recording and dates recordings by it ("The recorder's clock" there). A recording in progress, including one paused and kept open, is never imported until it's finished. It only reads: device binding changes, deletion, reset, and firmware commands are not part of it. Physical acceptance must still validate discovery, firmware compatibility, encrypted transfer integrity, throughput, and timestamp extraction against test recordings on a real recorder.

## Local persistence boundary

The default library is `~/Library/Application Support/Daybook`. Each meeting has an immutable-originals directory, current JSON metadata, and the previous valid metadata snapshot. Writes replace metadata atomically. A corrupt current file can recover from the previous snapshot; the damaged file is retained for diagnosis. Unrecoverable meetings produce visible warnings without hiding other meetings. Paths that escape the meeting directory, including through symlinks, are rejected.

Files use user-only POSIX permissions. This version does not implement application-level encryption; it relies on the Mac's account and disk protections. Daybook can optionally sync the library through a chosen iCloud Drive folder. Inference remains local. See [iCloud sync](icloud-sync.md) for conflict handling, scope, and recovery.

Corrections preserve the original transcript and append revision history. Proposed vocabulary stays scoped to its originating meeting. Only vocabulary explicitly approved by the user is available across meetings, so an automatically discovered therapy term does not silently enter a work-meeting prompt.

Removing a conversation moves its entire directory into Daybook's local `Trash` directory. Local-only trash can be reversed with `MeetingStore.restoreFromTrash`; synced deletion tombstones require restoring as a new meeting identity. Pending saves cannot recreate a trashed conversation, including after a restart. Ordinary metadata saves preserve already imported recordings, transcription runs, and revision history even if an older UI snapshot was queued during import.
