# Files written by shipped versions

`ShippedFormatTests` reads these with today's code, the way the app does, to catch a field that
was renamed, retyped, made required, or dropped since a release. Each file was written by the
shipped tag's own code, not by stripping keys from today's encoding. All content is synthetic:
made-up titles, words, people ("Alex"), paths (`/Users/example/...`), digests, and IDs. There are
no real recordings, transcripts, or model weights.

| Folder | What the app wrote | Written by |
| --- | --- | --- |
| `Library/Meetings/<id>/meeting.json` | One conversation: tracks, per-track transcripts with words and segments, the unified transcript with provenance, alignment reports, summary with sections and action items, highlights, timed notes, speakers, revisions; v0.2.2 adds recorder identity, a derived (echo-cancelled) track, capture details, source alignment, companions, source suggestions, audio alignments, the fusion summary, processing requests, and model provenance | the tag's `MeetingStore.save` |
| `Library/library.json` | Folders (one deleted), a custom template, vocabulary; v0.2.2 adds recorder ownership and a handoff record | the tag's encoder for it (`AppState` in v0.1.0, `LibraryController` in v0.2.2) |
| `Library/glossary.json` | The vocabulary as the glossary store kept it | the tag's `GlossaryStore.save` |
| `Capture/capture-session.json`, `microphone.json`, `systemAudio.json`, `capture-result.json` | A Mac recording's staging sidecars, as left in `<library>/Staging/<conversation>/` | the tag's capture types and encoder (`RecordingController.persist` in v0.1.0, `CaptureJSON` in v0.2.2) |
| `defaults.plist` | What UserDefaults held: model choices and processing preferences; v0.1.0's import-folder record; v0.2.2's model selections and configured devices with each method's storage | the tag's types, encoded as the app stored them |

Not included: `meeting.recovery.json` and `glossary.recovery.json` (identical copies on a first
save), audio, and security-scoped bookmarks (machine-specific; the tests make their own). Values
stored as `Data` in `defaults.plist` are JSON from a plain `JSONEncoder`, so their key order varies
between runs, as it did in the app.

Not every structure existed at both tags. v0.1.0-preview had no configured devices (one import
folder and its completed files in global preferences, which today's `DeviceHubMigration` moves into
a device), no model selections (catalog IDs such as `whisper-base`), and none of v0.2.2's
multipoint, capture-detail, or provenance fields. The iPhone's own files (`phone-capture.json`)
belong with the iPhone tests.

## How they were made

`Generator/generate.sh` remakes both folders. For each tag it builds a scratch Swift package from
`git show`/`git archive` of that tag and runs a generator that encodes fixed synthetic values:

- **v0.1.0-preview** (`Generator/v0.1.0-preview.swift`): the tag's whole `Sources/DaybookCore`,
  plus the app's Codable types copied out of their files by line range, because those files also
  need AppKit, ScreenCaptureKit, or FluidAudio: `CapturedTrackRole`, `CapturedAudioTrack`,
  `CaptureResult`, and `CaptureSessionManifest` (`RecordingController.swift`), `ProcessingPreferences`
  (`ProcessingPreferences.swift`), and `SpeakerQuality`/`SpeakerAnalysisOptions` without the FluidAudio
  configuration (`SpeakerAnalysisOptions.swift`).
- **v0.2.2** (`Generator/v0.2.2.swift`): the tag's DaybookCore, DaybookCaptions, DaybookDevices,
  DaybookLink, and DaybookKit targets as its `Package.swift` declared them, so model selections,
  configured devices, device storage, and the Soundcore snapshot are written by v0.2.2's own code;
  plus the capture types from `CaptureModels.swift`, `AudioOutputRoute`, and `MeetingCandidate`'s
  stored properties. `ProcessingPreferences` and `SpeakerAnalysisOptions` live in targets that need
  MLX and FluidAudio, so the generator declares their stored properties and coding keys as v0.2.2
  had them.

```sh
Tests/DaybookTests/Fixtures/Shipped/Generator/generate.sh [work directory]
```

Rerunning it reproduces the JSON files byte for byte. Add a folder for a new release the same way:
copy a generator, point it at the tag, and add its tests to `ShippedFormatTests`.
