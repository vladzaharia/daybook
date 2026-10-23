# Daybook

A native Mac app for conversations you want to remember. Record microphone and computer audio, import Soundcore recordings, take notes beside a call, and turn the result into transcripts and summaries using models running inside the app.

Requires an Apple silicon Mac and macOS 15 or newer. This is a working preview with local inference, optional iCloud Drive sync, and experimental direct Soundcore support. Live-call, physical-device, and real multi-Mac iCloud acceptance checks remain.

## Run

Open `dist/Daybook.app`, or build it from source:

```sh
./scripts/build-app.sh
open dist/Daybook.app
```

The build produces an application and `dist/Daybook-macOS-arm64.zip`. Source builds require Xcode with Swift 6.2 or newer and the Metal compiler component. If needed:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
```

The app runs without a server, account, or API key. Select **Models & settings** to download a transcription model, summary model, and a speaker model if speaker detection is enabled. Weights download from Hugging Face; inference uses local files only. Macs with at least 16 GB default to Qwen 7B summaries; smaller Macs default to Qwen 1.5B. **Refresh summary** reuses saved transcripts. The processing menu also offers speaker-only relabeling and full retranscription. Each job freezes its selected models and quality settings; previous runs, corrections, and completed actions are retained.

## Use

1. **Record** captures the microphone and, by default, computer audio as separate tracks. macOS requests the required permissions. Disable computer audio for microphone-only conversations.
2. **My notes** and the floating **Notes window** edit the same saved notes. The panel opens on the right, stays above other windows, and records a timestamp for each new note paragraph. Editing later preserves that anchor. Timed notes appear alongside speech in the transcript, clearly labeled as your writing. Mark key moments and stop from the panel, main window, or menu bar.
3. **Import recording** accepts ordinary audio files. Export audio from the Soundcore phone app, then AirDrop or copy it to the Mac. A selected export folder can be watched for automatic import.
4. **Add audio** inside an existing conversation attaches a second recording of that conversation. Daybook estimates timing from shared transcript phrases, retains both sources, and builds one transcript. Review alignment in **Sources**; enter a verified offset if automatic alignment cannot establish a reliable match.
5. Processing performs transcription, optional speaker separation, meeting-type selection, summary generation using your notes, and vocabulary suggestions. Edit speaker names or transcript passages directly. Approve vocabulary to reuse it in other conversations.
6. Organize conversations into folders and comma-separated tags. Choose Automatic or one of twelve editable summary templates, or create your own in Settings.
7. Connect a private **iCloud Drive folder** in Settings → Storage on each Mac. Choose the same folder to exchange recordings, transcripts, notes, summaries, highlights, organization, templates, vocabulary, and history. Models and capture permissions remain specific to each Mac.
8. Export Markdown or full JSON from the conversation menu. Move a conversation to the library's **Trash** to remove it from the active list while retaining a recoverable copy.

Automatic recording is off initially. Turn it on in **Recording & imports**. Detection combines a recognized meeting-window title with audio-device activity; start and end are debounced. A running Zoom app alone does not start recording. Browser calls must initially show microphone activity, so a muted browser call may require manual start. Stopping manually suppresses automatic restart for that call.

## What is implemented

- Native three-column library, transcript search, notes, summaries, actions, source audio playback, and edit history.
- Separate microphone and system audio capture, common timeline, partial-file recovery, and right-side notes panel.
- Automatic meeting detection for supported native apps and browsers, with an explicit opt-in and visible stop controls.
- Soundcore file import, settled-file folder watching, SHA-256 duplicate detection, and optional `name.highlights.json` sidecars. Experimental direct Bluetooth status, recording controls, and validated local audio transfer are in Recording & imports.
- Embedded WhisperKit transcription, FluidAudio speaker diarization, and MLX language-model summaries; multiple downloadable models and offline installation checks.
- Bounded audio decoding, long-transcript summarization across multiple passes, cancellation, and retry with preserved sources.
- Conservative multi-recording alignment, drift estimation, source provenance, editable timing, and preservation of ambiguous passages.
- Automatic meeting-kind selection, twelve original editable templates, custom templates, folders, and tags. Highlights get dedicated source context and extra emphasis in summary prompts.
- Optional coordinated iCloud Drive synchronization with immutable source blobs, causal revision history, conflict preservation, transfer status, and restart-safe acknowledgments.
- Durable local JSON metadata, original audio, atomic writes, recovery snapshots, correction history, and meeting-scoped vocabulary proposals.

## Practical limits

- Direct Soundcore Bluetooth support is experimental and has not been tested on the physical device. Wi-Fi transfer, MFi/External Accessory integration, and automatic double-tap marker extraction are not claimed. Exported MP3s are not assumed to contain markers. Sidecars and manual marks are supported. See [direct-device notes](docs/direct-soundcore.md) and [notes/highlight research](docs/notes-and-highlights-research.md).
- Multi-source synthesis operates on timed transcripts. It is not acoustic source separation or waveform-level beamforming. Unmatched sources remain separate and are excluded from the summary until aligned. Different wording and short repeated replies remain visible instead of being silently discarded.
- Speaker labels are provisional. Community-1 supplies embeddings for configurable matching between sources and reruns within a conversation. Sortformer has a four-speaker limit and does not supply reusable voice profiles. Cross-meeting voice enrollment is not implemented.
- Meeting detection uses OS/window heuristics, not vendor call APIs. Muted browser starts, localized titles, unsupported apps, and other browser audio can affect detection. Real calls need acceptance testing.
- Computer meeting transcription runs after capture finishes. Experimental Soundcore live reception includes provisional local transcript previews; the saved recording is processed in full after reception ends. Slow previews may skip windows while audio continues to be saved.
- Changing models does not silently redo old work. Choose Re-transcribe audio or Re-label speakers explicitly. Ambiguous transfers of your corrections are surfaced for review.
- Learning stores edits and vocabulary; it does not fine-tune models. Generated summaries can omit or misinterpret details, especially with compact models. Source transcripts and original audio remain available for review.
- Audio capture keeps uncompressed CAF originals. At 48 kHz, stereo system audio plus a mono microphone can use about 2 GB per hour. Imported files retain their original format.
- The delivered preview is Developer ID signed using the existing signing identity on this Mac. It has not been notarized. The build script defaults to ad-hoc signing unless `DAYBOOK_SIGN_IDENTITY` is set. Trusted public distribution still needs notarization and live-device acceptance checks.

## Local data

```text
~/Library/Application Support/Daybook/
  Meetings/<UUID>/meeting.json
  Meetings/<UUID>/meeting.recovery.json
  Meetings/<UUID>/Originals/...
  Staging/<UUID>/...          # live capture and interrupted-session recovery
  Models/...
  Trash/<UUID>/...            # reversible conversation removal
  glossary.json
  library.json              # folders, templates, vocabulary versions
  Sync/...                  # local checkpoints, not a shared database
```

Library directories and files restrict access to the current macOS user. Inference never uploads audio or text. Optional sync stores the selected library in iCloud Drive; no analytics service is used. Daybook does not add application-level encryption; protection depends on your Mac and iCloud settings. Sync preserves deleted conversations in local Trash and historical journal entries. Deletion tombstones prevent stale Macs from resurrecting the same meeting ID. See [sync architecture and recovery](docs/icloud-sync.md) before restoring a synced deletion.

## Verify

```sh
swift test
```

Unit and integration tests use temporary libraries and synthetic audio; they do not record your surroundings or download model weights. Tests cover two independent libraries exchanging audio and offline edits, metadata tombstones, timestamped notes, native Opus decoding, Bluetooth protocol fixtures, capture timing and failure recovery, detection debounce and suppression, concurrent imports and notes, storage corruption/path safety, duplicate handling, transcript fusion and provenance, speaker-word mapping, glossary isolation, and model/parser failures.

The separate diagnostic exercises real embedded models without adding a meeting to your library:

```sh
swift run Daybook --smoke-test --download-models --output /tmp/daybook-smoke.json
```

After installation, run the packaged app with networking denied:

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  dist/Daybook.app/Contents/MacOS/Daybook \
  --smoke-test --notes-highlights --output /tmp/daybook-offline-smoke.json
```

See [validation](docs/validation.md) for results and remaining live-device checks, [architecture](docs/architecture.md) for implementation detail, [model runtime](docs/model-runtime.md) for offline-loading behavior, and [capture](docs/capture.md) for permissions and timing. [Third-party notices](THIRD_PARTY_NOTICES.md) describe dependencies and model licenses.

For a signed and notarized release, use an existing Developer ID identity and a saved `notarytool` keychain profile:

```sh
DAYBOOK_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DAYBOOK_NOTARY_PROFILE='your-saved-profile' ./scripts/build-app.sh
```

The profile stores credentials in Keychain; do not put passwords or API secrets in the repository. Without a profile, the script signs and packages locally without submitting anything to Apple.
