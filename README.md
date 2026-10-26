# Daybook

A native Mac app for conversations you want to remember. Record microphone and computer audio, import Soundcore recordings, take notes beside a call, and turn the result into transcripts and summaries using models running inside the app.

Requires an Apple silicon Mac and macOS 15 or newer. This is a working preview with local inference, iCloud sync, and direct Soundcore Work support over Bluetooth (verified against a simulator; not yet on physical hardware). Live-call, physical-device, and real multi-Mac iCloud acceptance checks remain.

[Photos](docs/photos.md) can be added on Mac or iPhone, viewed beside the transcript, and included in summaries and exports. The Mac reads their text locally with Apple Vision; originals and captions sync with the conversation.

## Run

Open `dist/Daybook.app`, or build it from source:

```sh
brew install xcodegen          # once
./scripts/build-app.sh --debug # a development build; add --ad-hoc without a team
open dist/Daybook.app
```

The Mac app is built by Xcode from `Apps/macOS/project.yml` (XcodeGen; the generated `Apps/macOS/DaybookMac.xcodeproj` is ignored by git). Its target compiles `Sources/Daybook` in place and links the package's libraries, so `swift build`, `swift run Daybook`, and `swift test` keep working for development. The build produces an application and `dist/Daybook-macOS-arm64.zip`. Source builds require Xcode with Swift 6.2 or newer, the Metal compiler component, and XcodeGen. If needed:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache
```

| Command | Result |
|---|---|
| `./scripts/build-app.sh` | Release: `xcodebuild archive`, then `-exportArchive` with the `developer-id` method (Developer ID Application and its provisioning profile, which carries iCloud) |
| `./scripts/build-app.sh --debug` | Debug, signed with Apple Development |
| `./scripts/build-app.sh --ad-hoc` | Signed to run locally: no team, no profile, no iCloud. Sync stays off. Sandboxed, as `local.daybook.app.adhoc`, with its own library. Combine with `--debug` |
| `./scripts/build-app.sh --sandbox` | Release, signed, in the App Sandbox: its first launch moves the library into the app's container ([docs/sandbox.md](docs/sandbox.md)) |
| `./scripts/build-app.sh --sandbox-rehearsal` | Ad hoc, as `local.daybook.app.rehearsal`: rehearses that move with a synthetic library |
| `./scripts/build-app.sh --generate-only` | Regenerates the Xcode project only |

### Signing and iCloud

Signed builds use automatic signing with the team from `DAYBOOK_TEAM_ID`: export it, or put `DAYBOOK_TEAM_ID = ABCDE12345` in `Apps/macOS/Config/Signing.local.xcconfig` (ignored by git), which Xcode also reads. Without a team, the script signs ad hoc. Identifiers: `local.daybook.app` and the iCloud container `iCloud.local.daybook` (`DAYBOOK_ICLOUD_CONTAINER`), shared with the iPhone app. The app keeps the hardened runtime. Release builds aren't sandboxed yet: the code is ready for the App Sandbox, which moves the library into the app's container, and the switch ships separately ([docs/sandbox.md](docs/sandbox.md)). Entitlements: `Resources/Daybook.entitlements` for signed builds (audio input; iCloud Documents and CloudKit with the container; push, for the CloudKit courier) and `Resources/Daybook-Local.entitlements` for ad hoc builds, which run in the App Sandbox under their own bundle ID, `local.daybook.app.adhoc`, with a library of their own in its container.

The script never changes the Apple Developer account unless asked. Signing for iCloud needs profiles that already exist; without them `xcodebuild` stops and says which profile is missing.

### First-time provisioning

Once, by the account owner, on the Mac that builds releases:

```sh
DAYBOOK_TEAM_ID=ABCDE12345 ./scripts/build-app.sh --allow-provisioning-updates
```

It needs the team's Apple Account signed in to Xcode (Settings › Accounts) and the Developer ID Application certificate in the keychain. It passes `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` to the archive and the export, so Xcode registers the `local.daybook.app` identifier with the iCloud capability (iCloud Documents and CloudKit), Push Notifications, and the `iCloud.local.daybook` container, registers this Mac, creates the Mac development profile, and creates the Developer ID profile while exporting. Later builds, including `--debug`, use those profiles without the flag. If Xcode reports that the container can't be assigned, add it once in Xcode › Signing & Capabilities for the Daybook target (with `Apps/macOS/DaybookMac.xcodeproj` open), then run the command again.

The app runs without a server, account, or API key. Select **Models & settings** to download a transcription model, summary model, and a speaker model if speaker detection is enabled. Weights download from Hugging Face; inference uses local files only. Summaries default to Gemma 4 sized to the Mac's memory: E2B under 16 GB, 12B at 16–31 GB, and 26B A4B at 32 GB and more. Where Apple Intelligence is on, Apple's on-device model names conversations and suggests vocabulary, with nothing to download. **Refresh summary** reuses saved transcripts. The processing menu also offers speaker-only relabeling and full retranscription. Each job freezes its selected models and quality settings; previous runs, corrections, and completed actions are retained.

## Use

1. **Record** captures your microphone and the call as separate tracks. When a meeting app is detected, only that app's audio is captured (a Core Audio process tap); otherwise all computer audio is. After you stop, the call's echo is removed from your microphone so your voice and the other side's never double up; the raw microphone is kept as the original. If a Soundcore Work is connected, it records alongside automatically and its recording joins the same conversation. macOS requests the required permissions. Disable computer audio for microphone-only conversations.
2. **My notes** and the floating **Notes window** edit the same saved notes. The panel opens on the right, stays above other windows, and records a timestamp for each new note paragraph. Editing later preserves that anchor. Timed notes appear alongside speech in the transcript, clearly labeled as your writing. Mark key moments and stop from the panel, main window, or menu bar.
3. **Import recording** accepts ordinary audio files. Export audio from the Soundcore phone app, then AirDrop or copy it to the Mac. A selected export folder can be watched for automatic import.
4. **Add a recording** to an existing conversation, or let a recorder's file arrive later: Daybook matches it to the conversation it overlaps, lines it up from the sound itself (falling back to shared phrases, then the clocks), transcribes only the new recording, and fuses every source into one transcript, keeping your corrections, speaker names, note times, and bookmarks. The summary is regenerated; the earlier one stays in Version History. Unclear matches become a suggestion you confirm. Review each source's timing in the inspector's Audio section, and adjust it if needed.
5. Processing performs transcription, optional speaker separation, meeting-type selection, summary generation using your notes, and vocabulary suggestions. Edit speaker names or transcript passages directly. Approve vocabulary to reuse it in other conversations.
6. Organize conversations into folders and comma-separated tags. Choose Automatic or one of twelve editable summary templates, or create your own in Settings.
7. **Sync** is automatic on a signed build: with iCloud Drive on, Daybook keeps its library in its own iCloud container, and every Mac and the iPhone signed in to the same account exchange recordings, transcripts, notes, summaries, highlights, organization, templates, vocabulary, and history. There's no folder to choose. A Mac that synced through a chosen iCloud Drive folder in an earlier build moves that folder's journal into the container once, and leaves the folder untouched. Settings › Library shows the state. Models and capture permissions remain specific to each Mac.
8. Export Markdown or full JSON from the conversation menu. Move a conversation to the library's **Trash** to remove it from the active list while retaining a recoverable copy.

Automatic recording is off initially. Turn it on in **Settings › General**. Detection combines a recognized meeting-window title with audio-device activity; start and end are debounced. A running Zoom app alone does not start recording. Browser calls must initially show microphone activity, so a muted browser call may require manual start. Stopping manually suppresses automatic restart for that call.

## What is implemented

- Native three-column library, transcript search, notes, summaries, actions, source audio playback, and edit history.
- Separate microphone and call capture (per-app process tap with a ScreenCaptureKit fallback), offline echo removal from the microphone, measured clock-drift correction, continuation across microphone and output-device changes, live You/Call input levels, partial-file recovery, and a floating notes panel.
- Multipoint recording with a connected recorder, automatic matching of later recordings to their conversation, audio-based alignment with drift, and multi-source fusion that votes word by word across sources, removes duplicated speech, and attributes your microphone to you.
- Automatic meeting detection for supported native apps and browsers, with an explicit opt-in and visible stop controls.
- Soundcore file import, settled-file folder watching, SHA-256 duplicate detection, and optional `name.highlights.json` sidecars. Recorders are added in **Settings › Devices**: Soundcore Work connects directly over Bluetooth (recommended) with status, recording controls, and validated audio transfer; any other recorder can deliver files to a watched folder.
- Embedded WhisperKit transcription, FluidAudio speaker diarization, and MLX language-model summaries; multiple downloadable models and offline installation checks.
- Bounded audio decoding, long-transcript summarization across multiple passes, cancellation, and retry with preserved sources.
- Multi-recording alignment from audio, transcripts, or clocks; word-level source provenance; editable timing; and preservation of ambiguous passages.
- Automatic meeting-kind selection, twelve original editable templates, custom templates, folders, and tags. Highlights get dedicated source context and extra emphasis in summary prompts.
- Coordinated iCloud synchronization through the app's iCloud container, with a one-time move from a previously chosen folder, immutable source blobs, causal revision history, conflict preservation, transfer status, and restart-safe acknowledgments.
- Durable local JSON metadata, original audio, atomic writes, recovery snapshots, correction history, and meeting-scoped vocabulary proposals.

## Practical limits

- Direct Soundcore Bluetooth support is verified against a simulated recorder and protocol fixtures but has not been tested on the physical device. Wi-Fi transfer, MFi/External Accessory integration, and automatic double-tap marker extraction are not claimed. Exported MP3s are not assumed to contain markers. Sidecars and manual marks are supported. See [direct-device notes](docs/direct-soundcore.md) and [notes/highlight research](docs/notes-and-highlights-research.md).
- Alignment, echo removal, and multi-source fusion are verified on synthetic audio only; real calls, rooms, and recorders still need acceptance testing ([validation](docs/validation.md)). Fusion votes between transcripts; it is not acoustic source separation or beamforming. Unmatched sources remain separate and are excluded from the summary until aligned.
- Speaker labels are provisional. Community-1 supplies embeddings for configurable matching between sources and reruns within a conversation, including for Nemotron 3's turns. Nemotron 3 tells up to eight speakers apart; Sortformer has a four-speaker limit and does not supply reusable voice profiles. Cross-meeting voice enrollment is not implemented.
- Meeting detection uses OS/window heuristics, not vendor call APIs. Muted browser starts, localized titles, unsupported apps, and other browser audio can affect detection. Real calls need acceptance testing.
- Computer meeting transcription runs after capture finishes. While recording (macOS 26 and later), tentative on-device live captions of You and the call, and of Soundcore live reception, show that audio is being heard; they're never the transcript, and the saved recording is processed in full afterwards. Captions that fall behind skip audio while all of it is still saved.
- Changing models does not silently redo old work. Choose Re-transcribe audio or Re-label speakers explicitly. Ambiguous transfers of your corrections are surfaced for review.
- Learning stores edits and vocabulary; it does not fine-tune models. Generated summaries can omit or misinterpret details, especially with compact models. Source transcripts and original audio remain available for review.
- Audio capture keeps uncompressed CAF originals. At 48 kHz, stereo system audio plus a mono microphone can use about 2 GB per hour. Imported files retain their original format.
- Releases are Developer ID signed through an Xcode export with a provisioning profile, so they can use iCloud. Notarization runs when `DAYBOOK_NOTARY_PROFILE` is set, and in the release workflow for every tagged release. Trusted public distribution still needs live-device acceptance checks.

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

`swift run Daybook` and other unbundled runs keep a separate library, `~/Library/Application Support/Daybook Development` (with its own models), so development never opens the app's library.

Library directories and files restrict access to the current macOS user. Inference never uploads audio or text. Sync stores the library in Daybook's container in your iCloud account (turn it off in Settings › Library); no analytics service is used. The library in iCloud can be encrypted end to end with a key kept in iCloud Keychain (Settings › Library › Encrypt Library in iCloud; see [encryption](docs/icloud-sync.md#encryption)); otherwise protection depends on your Mac and iCloud settings. Sync preserves deleted conversations in local Trash and historical journal entries. Deletion tombstones prevent stale Macs from resurrecting the same meeting ID. See [sync architecture and recovery](docs/icloud-sync.md) before restoring a synced deletion.

## Verify

```sh
swift test
```

Unit and integration tests use temporary libraries and synthetic audio; they do not record your surroundings or download model weights. Tests cover two independent libraries exchanging audio and offline edits, metadata tombstones, timestamped notes, native Opus decoding, Bluetooth protocol fixtures, capture timing and failure recovery, detection debounce and suppression, concurrent imports and notes, storage corruption/path safety, duplicate handling, transcript fusion and provenance, speaker-word mapping, glossary isolation, and model/parser failures.

The separate diagnostic exercises real embedded models without adding a meeting to your library:

```sh
swift run Daybook --smoke-test --download-models --output /tmp/daybook-smoke.json
```

After installation, run it again with networking denied (an unbundled build: the ad hoc app runs in the App
Sandbox already, and keeps its models in its container):

```sh
swift build -c release
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  .build/release/Daybook --smoke-test --notes-highlights --output /tmp/daybook-offline-smoke.json
```

See [validation](docs/validation.md) for results and remaining live-device checks, [architecture](docs/architecture.md) for implementation detail, [model runtime](docs/model-runtime.md) for offline-loading behavior, and [capture](docs/capture.md) for permissions and timing. [Third-party notices](THIRD_PARTY_NOTICES.md) describe dependencies and model licenses.

For a signed and notarized release, set the team and a saved notarytool keychain profile:

```sh
DAYBOOK_TEAM_ID=ABCDE12345 DAYBOOK_NOTARY_PROFILE='your-saved-profile' ./scripts/build-app.sh
```

The profile stores credentials in Keychain; do not put passwords or API secrets in the repository. Without a profile, the script signs and packages locally without submitting anything to Apple.

## Releases and CI

GitHub Actions builds every push to `main` and every pull request (`.github/workflows/ci.yml`) on GitHub's Xcode 27 runner (`xcode-27`, Xcode 27.1). It runs the package tests, builds and tests the iPhone app on a simulator, and builds the Mac app ad hoc.

Pushing a `vX.Y.Z` tag on a commit that's on `main` starts `.github/workflows/release.yml`. After approval in the `release` environment, the iPhone app goes to TestFlight and the Mac app is signed with Developer ID, notarized, and attached to a draft GitHub Release with SHA-256 checksums and signed build provenance; the release is published once both apps are out. Both are signed by Xcode's cloud-managed signing with an App Store Connect API key. A Developer ID `.p12` is an optional fallback for the Mac app.

```sh
git tag -a v1.4.0 -m "Daybook 1.4.0" && git push origin v1.4.0
```

[Releases and CI](docs/release.md) covers the one-time App Store Connect and GitHub setup (`scripts/ci/setup-github.sh` prints its plan and changes nothing without `--apply`), the secrets, export compliance, versions, and troubleshooting.
