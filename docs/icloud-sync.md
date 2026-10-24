# iCloud library sync

Daybook keeps a local working library and exchanges changes through a journal in the app's own iCloud container, `iCloud.local.daybook` (`DAYBOOK_ICLOUD_CONTAINER`), at `<container>/Documents/Daybook`. Every Mac and the iPhone signed in to the same iCloud account use it. There's no folder to choose: a signed build with iCloud Drive on syncs automatically. A Mac keeps a complete copy, original audio included. An iPhone is an on-demand replica: it holds every conversation, but downloads audio only to play it (see [Replicas and audio](#replicas-and-audio)). The app reconciles while open, after metadata notifications, and every 30 seconds as a fallback. It works offline and resumes when files become available. It needs no server or Daybook account.

## The iCloud container

- **Entitlements.** Both apps are signed with `com.apple.developer.icloud-services = [CloudDocuments]` and the container in `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers`, through a provisioning profile (Mac: `Resources/Daybook.entitlements`, Developer ID or Apple Development; iPhone: `Apps/iOS/project.yml`). Info.plist's `DaybookICloudContainerIdentifier` names the container. There's no `NSUbiquitousContainers` entry, so the container stays out of iCloud Drive in Finder and Files.
- **Resolution** (`LibrarySyncController.restore()`, in DaybookKit, the same on both platforms):
  1. No container in Info.plist, or (on macOS) no `ubiquity-container-identifiers` entitlement in the running app's signature: *Not available in this build*. Sync stays off; see [Development builds](#development-builds).
  2. Sync turned off on this device in Settings: *Off*.
  3. No `ubiquityIdentityToken`: *Signed out* when no iCloud account is signed in, otherwise *iCloud is off in System Settings* (iCloud Drive is off; also shown when the two can't be told apart).
  4. A different account from the one this library synced with: *Paused*, until the person chooses Sync with This Account (the library then merges into that account's container).
  5. `url(forUbiquityContainerIdentifier:)`, off the main thread. Nil: *Not available*, with Try Again.
  6. A previously chosen folder: the one-time move below.
  7. *Syncing with iCloud*: the engine runs on `<container>/Documents/Daybook`.
- **Account changes.** `NSUbiquityIdentityDidChange` cancels the pass in flight (its receipt can no longer be acknowledged), drops the engine, and resolves again. Signing out pauses; signing back in to the same account resumes; a different account waits for the person. The account a library syncs with is recorded (the archived identity token) when the container first resolves, before any migration.
- **Turning sync off** keeps local and iCloud copies, and stays off across launches until Turn On.

## Moving from a chosen folder

Earlier Mac builds synced through a folder the person chose in iCloud Drive (a security-scoped bookmark, `syncFolderBookmark`). The first time a signed build finds the container, it moves that journal there once (`LibrarySyncMigration`, in DaybookCore), then syncs only with the container. Settings shows "Migrating 120 of 340 files…".

- **The old folder is only read.** Nothing in it is changed, moved, or deleted, and it's never connected again: its bookmark is retired to `syncMigratedFolderBookmark`, kept only to finish copying audio. Evicted files are asked to download, which doesn't change them.
- **Copy, verify, then move into place.** Every file goes through a temporary file in the container that's hashed before it's renamed into place: events and metadata against their names (the SHA-256 of their bytes), audio objects against theirs. A file already in the container is kept: verified by hash when it's local, trusted by name when it's still in iCloud (the engine verifies it when it reads it). Different bytes under the same name, or a damaged source file, are skipped and listed, never overwritten. Running again copies only what's missing, so an interrupted move simply resumes.
- **Audio this Mac already has** is copied from its own library (verified the same way) instead of downloading it from the old folder.
- **Order and switch-over.** The manifest, events, and metadata go first; sync switches to the container as soon as they're all there. Audio objects still downloading keep copying in the background (every 30 seconds) until done; meanwhile other devices see those recordings as not uploaded yet, which is a normal state.
- **Partially downloaded files.** Evicted files (placeholders or dataless files) are requested with `startDownloadingUbiquitousItem`, skipped, and retried every few seconds. The status adds "Waiting for iCloud to download N."
- **A container that already has a journal** is merged by content, which is safe because journal entries are immutable and content-addressed:
  - *Another Mac moved first* (the same library identity): only missing files are copied, including events the second Mac wrote to the folder after the first one moved. Both continue from their own checkpoints.
  - *A different library identity* (the iPhone started the container, or Macs used different folders): the container's manifest is kept. This Mac's checkpoint (`Sync/<library>-<device>.json`) is copied to the container's identity, so the engine continues from the same applied heads and republishes nothing; both libraries' conversations appear everywhere. Two libraries holding the same conversation merge like concurrent offline edits.
- **Account changes** during the move pause it like sync; copied files stay, and the move resumes.
- **The old folder can't be found** (moved, deleted, or not mounted): sync pauses with Try Again and Sync Without It. Without it, this Mac still publishes everything its library holds; history and deleted conversations kept only in that folder stay there.
- **Record.** `syncContainerMigration` keeps the source, container, both library identities, when sync switched and when copying finished, counts, skipped files, and whether a checkpoint was carried over (`LibrarySyncController.migrationRecord`).
- A Mac still running an older build keeps writing to the folder. When it updates, it moves too, and its later changes merge.

## Development builds

Unsigned and ad hoc builds (`swift run Daybook`, `scripts/build-app.sh --ad-hoc`) and tests have no iCloud entitlement, so the container can't be used and sync is off. The folder transport is still there for them, behind a hidden preference:

```sh
# Xcode ad hoc build (bundle ID local.daybook.app); a launch argument works for any build:
defaults write local.daybook.app DaybookDevelopmentFolderSync -bool YES
swift run Daybook -DaybookDevelopmentFolderSync YES
```

With it, Settings › Library offers Choose Folder…, and a chosen folder is restored at launch. Builds signed for iCloud ignore it and never offer a folder. Tests connect folders directly with `LibrarySyncController.connect(to:)`.

## What travels

Original audio and retained highlight sidecars, all source transcript runs and their model settings, unified transcripts, notes and timestamps, highlights, summaries, completed actions, speakers and available embeddings, correction history, folders, tags, template edits, and vocabulary records are synchronized. Active recordings finish locally first. The app's model weights, capture permissions, automatic-recording preference, and transient inference jobs are specific to each Mac. A remote processing indicator never pretends that an inference job is running locally.

Two devices receiving the same meeting identity reconcile their recordings and edits automatically. Independent recordings created as separate meetings are not automatically declared the same conversation based on dates. Attach additional audio to the intended meeting to align it; clock and text evidence then determine whether sources can be unified.

## Transport and durability

```text
<container>/Documents/Daybook/     # or a chosen folder in development builds
  daybook-sync.json          # library identity and schema
  Events/<SHA-256>.json      # immutable meeting snapshots and deletion events
  Metadata/<SHA-256>.json    # immutable organization/template/vocabulary versions
  Blobs/<SHA-256>            # original audio and sidecar bytes
  Devices/<SHA-256>.json     # presence: one small mutable record per device (SHA-256 of its device ID)

Local library/Sync/          # never synchronized
  <library>-<device>.json    # causal checkpoint
  audio-cache.json           # on-demand replicas: fetched and published audio, last played
```

`NSFileCoordinator` coordinates access with the file provider. `NSMetadataQuery` requests updates for the journal's tree. Evicted files trigger iCloud download requests and remain pending until readable. Files and event hashes are validated, relative paths cannot escape the library, symlinks are rejected, and a partially downloaded recording is never installed: audio reaches the library only by an atomic move after its SHA-256 matches. An uploaded local file is not assumed to have reached another Mac: upload and download counts remain visible.

Journal entries are immutable and named by their hash, so an engine reads and validates each one once and keeps it in memory; the directory listing on every pass stays the source of truth. If part of the journal is unread on a pass (still downloading, or deferred by limits), a conversation whose applied head wasn't read is held back rather than offered at an older revision, library metadata waits for a complete read, and a deletion already applied here is not republished.

Each Mac has its own durable checkpoint scoped to the shared library UUID and device identity. Events include causal parents. New local edits are published against the last applied revision, so seeing a remote event does not falsely make an offline edit its descendant. Pulling has two phases: return hydrated snapshots, then acknowledge only after the application saves all metadata successfully. Restarting between those phases offers the changes again. Failed local saves cannot advance the acknowledgment.

The app serializes sync with imports and defers it while capture or final inference is active. Notes edited while a transfer is in progress are rebased before applying remote changes. Account changes invalidate the pending sync receipt and pause sync (see [The iCloud container](#the-icloud-container)). Changing transport is disabled through the durable apply phase.

## Replicas and audio

Each replica chooses an audio policy when it creates its `LibrarySyncEngine` (`SyncReplicaConfiguration.audioPolicy`). The policy is local state; nothing about it is synchronized, and both kinds publish identical events.

- **Eager** (the Mac default, and the behaviour before iPhone): a conversation applies only once every original is copied into the local library and verified. Missing audio is a pending download.
- **On demand** (iPhone): conversations, transcripts, summaries, notes, and library metadata apply as soon as their events are readable. Tracks stay complete and valid, with SHA-256, duration, and provenance. Their audio stays in the sync folder. `SyncResult.notLocalAudio` lists those tracks, and `audioAvailability(for:)` answers per track. This is a normal state. It is not counted in `pendingDownloads`, never produces a warning, and never blocks `acknowledge`. A pass never reads or downloads a blob, so it can't judge one corrupt.

**Publishing with partial audio.** An on-demand replica publishes a track whose audio it doesn't hold (never fetched, or evicted) by reference: the event carries the same path and SHA-256, provided an event in the journal or an object in `Blobs/` already has that hash. Every other replica sees the track as before. It doesn't download an object just to re-verify it, either. A track with no local file and no remote object is still `missingLocalAudio`, as on a Mac. Recordings made on the phone are ordinary originals, usually AAC in `.m4a`. They upload to `Blobs/` like any Mac recording and arrive on eager replicas byte for byte.

**Fetch on demand.** `fetchAudio(for:in:options:progress:)` makes one track's audio local:

1. If the object is evicted, it requests the iCloud download (`startDownloadingUbiquitousItem`). Then it waits, polling the download state and any provider error.
2. If no Mac has uploaded the object yet, it reports `waitingForUpload` and keeps waiting until `options.timeout` (`notUploadedYet`).
3. Off the actor, a coordinated read copies the object while computing its SHA-256 in the same pass.
4. A verified copy moves into `Meetings/<id>/<relativePath>`.

Progress phases are `waitingForUpload`, `downloading`, `copying`, and `installed`. The download fraction comes from `SyncCloudFiles.downloadFraction`, and the copy reports bytes. Cancelling the calling task stops the fetch at any point and leaves nothing partial. A hash mismatch throws `integrityMismatch` and installs nothing. A different file already at the path is preserved under `SyncConflicts/`. After installing, the engine asks iCloud to drop its own local copy of the object, so the phone doesn't keep the audio twice.

**Cache policy.** `AudioCachePolicy` sets a byte budget (1 GB by default on the phone). `evictAudio(protecting:)` runs after each fetch and whenever the app asks. It deletes local copies, least recently played first (`noteAudioPlayed`), until tracked audio fits the budget. It deletes only what the cloud already holds:

- fetched audio whose object is still in the sync folder;
- originals recorded or imported on this device, once iCloud reports their object uploaded (`evictsUploadedOriginals`).

It never deletes:

- originals that aren't uploaded yet;
- files changed since they were verified;
- protected (playing) tracks;
- anything not listed in `audio-cache.json`.

Losing that index therefore only makes eviction more cautious. Eager replicas never evict.

## Devices and presence

A replica configured with a `SyncDeviceIdentity` writes its own `Devices/<SHA-256 of device ID>.json` at the end of a pass. It rewrites the record when the identity changes or when the last write is older than `presenceRefreshInterval` (10 minutes by default):

```json
{ "format": "DaybookDevice", "schemaVersion": 1, "deviceID": "…", "deviceClass": "mac",
  "displayName": "Studio Mac", "canProcess": true, "audioPolicy": "eager", "lastSeen": "2026-10-23T17:40:00Z" }
```

`knownDevices()` lists every presence record, this device, and any device seen only on journal entries, which is an older Daybook with no presence (`reportsPresence == false`). `lastSeen` is clamped to the reader's clock. On the phone, `devices.latestProcessor` gives "Waiting for your Mac · last seen 2 h ago". If it's nil and `hasPeersWithoutPresence` is false, no Mac has synced this library yet.

The format is versioned. Additive fields keep `schemaVersion` 1. An incompatible change must bump it, and readers skip versions they don't know. Readers also skip files of another format, files over 64 KB, malformed files, and records whose file name doesn't match their device ID. Unknown device classes read as `other`. Presence is advisory: a failed write never fails a pass. Daybook versions without presence only list `Events/`, `Metadata/`, and `Blobs/`, so they ignore `Devices/` and any other new folder. A frozen copy of the version 1 engine (`LegacyLibrarySyncFixture.swift`) checks this in the tests.

## Phone cadence and the controller hook

The engine assumes no platform and holds no timers. The controller (moving to DaybookKit) owns scheduling. Pass `SyncReplicaConfiguration.mac(displayName:canProcess:)` or `.phone(displayName:)` when creating the engine. The existing three-argument initializer remains the eager, presence-free Mac behaviour. The hook:

```swift
// Create once per connected folder.
let engine = try LibrarySyncEngine(localRoot: libraryURL, remoteRoot: folder, deviceID: deviceID,
                                   replica: isPhone ? .phone(displayName: name) : .mac(displayName: name, canProcess: hasModels))

// One pass. Triggers: launch, foreground, local edit (debounced), metadata notification, timer, background refresh.
func pass(trigger: Trigger) async throws {
    if trigger == .timer, !hasLocalEdits, await !engine.hasRemoteChanges() { return }  // listing only; no reads
    let limits: SyncPassLimits = isPhone ? (trigger == .backgroundRefresh ? .background : .interactive) : .unlimited
    let result = try await engine.synchronize(meetings: library, deletedMeetingIDs: trashed,
                                              libraryMetadata: metadata, limits: limits)
    save(result.meetings.filter { result.changedMeetingIDs.contains($0.id) }, deleting: result.deletedMeetingIDs)
    try await engine.acknowledge(result.checkpointID)          // only after saving, as today
    if result.hasMoreWork { schedulePass(after: .seconds(1)) }  // continue a bounded pass
}
```

- **Cancellation.** Cancel the task running `synchronize` (for example from a `BGAppRefreshTask` expiration handler). Publications already written stay valid, and an unacknowledged pull is offered again next time.
- **`SyncPassLimits`.** These bound first-time journal reads and wall-clock time (and, on eager replicas, audio copying). Leftover work sets `hasMoreWork`.
- **Suggested phone cadence.**
  - Run a pass on launch and on foreground, and two seconds after a local edit.
  - While visible, check `hasRemoteChanges()` every one to two minutes.
  - In the background, run `BGAppRefreshTask` passes with `.background` limits.
  - Macs keep their 30-second fallback with `.unlimited`.
- **Other engine calls.**
  - Playback: call `fetchAudio`, then `noteAudioPlayed`.
  - Storage pressure: call `evictAudio()`.
  - Models: after a download or removal, call `updateDevice(_:)` (for `canProcess`).
  - Status: `knownDevices()`.
  - Tests and an `NSMetadataQuery`-backed controller can supply their own `SyncCloudFiles` (download request, download fraction, upload state, local-copy eviction).

## Conflicts and deletion

Independent changes are merged. Original tracks, model runs, and history remain additive. Concurrent edits to the same text or summary use a deterministic selected value and retain alternatives in History with a visible warning. This preserves work for review; it does not pretend to understand which wording the user intended. Folder/template/vocabulary records have per-item modification times and explicit deletion markers, so removing a term on one Mac does not silently resurrect it on another. Their immutable metadata versions also remain in the journal.

Deleting a conversation propagates a tombstone for that meeting UUID. Stale offline Macs cannot resurrect it. Current local files move into Daybook's Trash; earlier journal events and blobs remain recoverable. Consequently sync is not permanent erasure, and its journal is not currently compacted. Cloud storage grows with history.

To recover a synced deletion, restore the content under a **new meeting UUID**. Importing the preserved original audio from Trash creates a new conversation; notes and prior text can be copied from its retained `meeting.json` or journal snapshot. Moving the same UUID back into Meetings will encounter the existing tombstone. Local-only libraries can use `MeetingStore.restoreFromTrash` before that ID has ever been synchronized as deleted.

## Validation boundary

Automated tests use independent local libraries and a shared temporary filesystem transport. They cover byte-identical audio/sidecars, offline concurrent edits, organization, templates, vocabulary, restart before and after apply, deletion, damaged/missing objects, unsafe paths, and independent library identities. These exercise the same engine and application integration as iCloud, without uploading personal data.

Replica tests (`LibrarySyncReplicaTests`) simulate iCloud in a temporary folder. Objects are present only as `.name.icloud` placeholders, or are withheld as not uploaded, until a requested download is delivered. Upload state and download fractions are scripted. The tests cover:

- on-demand apply and acknowledgement without audio;
- fetch progress, cancellation (while waiting and mid-copy), timeout, and integrity failure;
- eviction order, the budget, protected tracks, and originals not yet uploaded;
- a real AAC `.m4a` recorded on the phone arriving on an eager Mac beside audio the phone never held;
- presence listing, throttling, and versioning;
- the version 1 engine syncing with a phone and ignoring new files;
- concurrent eager and on-demand edits converging;
- bounded and cancelled passes;
- partial journal reads that must not roll back.

Migration and container tests (`LibrarySyncMigrationTests`, `LibrarySyncContainerTests`) use a temporary "chosen folder" and a temporary "container" with a scripted account. They cover a verified, idempotent copy that leaves the folder byte-for-byte unchanged; continuing in the container without republishing; merging into a container another library started (checkpoint carried over) and one another Mac moved into first; evicted journal files that wait and resume, with this Mac's own audio used instead of downloads; never overwriting the container or copying damaged files; no entitlement (sync off, folder transport only behind the development preference); signed out, iCloud Drive off, container unavailable; turning sync off and on; and account changes pausing until the person chooses.

Actual propagation through Apple's service on two physical Macs, or a Mac and an iPhone, has not been exercised; nor has the container on a signed build (see `docs/validation.md`). Acceptance should include:

- eviction, offline edits, and account changes;
- quota exhaustion, very large recordings, and simultaneous first-time setup;
- on an iPhone:
  - whether iOS presents evicted items as `.icloud` placeholders or dataless files;
  - `startDownloadingUbiquitousItem` and download errors on cellular and Low Power Mode;
  - upload state reported for phone recordings before eviction;
  - `BGAppRefreshTask` time limits;
  - battery and thermals. Unresolved iCloud manifest conflicts are surfaced instead of silently choosing another library identity. Sync does not add its own content encryption or replace independent backups; local and iCloud protections are controlled by macOS and the user's account settings.

## Apple references

- [Synchronizing documents in iCloud](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment): metadata can arrive before file contents; download readiness must be handled separately.
- [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html): coordinated document access, conflict versions, and container discovery.
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator): coordinated reads and writes with file presenters/providers.
- [Enabling iCloud Storage](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html): app-owned container access requires matching entitlements; a folder bookmark does not grant an app arbitrary container access.
