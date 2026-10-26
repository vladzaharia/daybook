# iCloud library sync

Daybook keeps a local working library and exchanges changes through a journal in the app's own iCloud container, `iCloud.local.daybook` (`DAYBOOK_ICLOUD_CONTAINER`), at `<container>/Documents/Daybook`. Every Mac and the iPhone signed in to the same iCloud account use it. There's no folder to choose: a signed build with iCloud Drive on syncs automatically. A Mac keeps a complete copy, original audio included. An iPhone is an on-demand replica: it holds every conversation, but downloads audio only to play it (see [Replicas and audio](#replicas-and-audio)). The app reconciles while open, after metadata notifications, and every 30 seconds as a fallback. It works offline and resumes when files become available. It needs no server or Daybook account.

## The iCloud container

- **Entitlements.** Both apps are signed with `com.apple.developer.icloud-services = [CloudDocuments, CloudKit]` and the container in `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers`, plus push for the courier (`aps-environment` on iPhone, `com.apple.developer.aps-environment` on the Mac), through a provisioning profile (Mac: `Resources/Daybook.entitlements`, Developer ID or Apple Development; iPhone: `Apps/iOS/project.yml`). CloudKit and push serve only the [courier](#courier-cloudkit). Info.plist's `DaybookICloudContainerIdentifier` names the container. There's no `NSUbiquitousContainers` entry, so the container stays out of iCloud Drive in Finder and Files.
- **Resolution** (`LibrarySyncController.restore()`, in DaybookKit, the same on both platforms):
  1. No container in Info.plist, or (on macOS) no `ubiquity-container-identifiers` entitlement in the running app's signature: *Not available in this build*. Sync stays off; see [Development builds](#development-builds).
  2. Sync turned off on this device in Settings: *Off*.
  3. No `ubiquityIdentityToken`: *Signed out* when no iCloud account is signed in, otherwise *iCloud is off in System Settings* (iCloud Drive is off; also shown when the two can't be told apart).
  4. A different account from the one this library synced with: *Paused*, until the person chooses Sync with This Account (the library then merges into that account's container).
  5. `url(forUbiquityContainerIdentifier:)`, off the main thread. Nil: *Not available*, with Try Again.
  6. A previously chosen folder: the one-time move below.
  7. *Syncing with iCloud*: the engine runs on `<container>/Documents/Daybook`.
- **Account changes.** `NSUbiquityIdentityDidChange` cancels the pass in flight (its receipt can no longer be acknowledged), drops the engine, and resolves again. Signing out pauses; signing back in to the same account resumes; a different account waits for the person. The account a library syncs with is recorded (the archived identity token) when the container first resolves, before any migration. A cancelled pass that's still unwinding (in the middle of copying a long recording) is waited for before the container is attached again, so the change never leaves sync off.
- **A new library, once.** A device creates `daybook-sync.json` only when the container holds none *and* iCloud has listed it: the engine is created with `waitsForListing`, and the controller calls `listingGathered()` when its `NSMetadataQuery` finishes its first gather. Until then a pass returns nothing and the status reads "Waiting for iCloud…", so a fresh iPhone or Mac doesn't start a second library beside one it can't see yet.
- **Two manifests anyway** (two devices wrote one at once; iCloud kept a conflict version or a renamed copy such as `daybook-sync 2.json`): every device resolves them the same way. The smallest library ID wins; the manifest lists the IDs it `supersedes` (an additive field older versions ignore); conflict versions are marked resolved; renamed copies are left in place and ignored. A device whose checkpoint belongs to a superseded ID carries it over (with its bases), so it continues from the same heads and publishes nothing again. Only a conflict version that can't be read stops sync, as before.
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

Unsigned and ad hoc builds (`swift run Daybook`, `scripts/build-app.sh --ad-hoc`) and tests have no iCloud entitlement, so the container can't be used and sync is off. They have no CloudKit either, so no courier is created. The folder transport is still there for them, behind a hidden preference:

```sh
# Xcode ad hoc build (bundle ID local.daybook.app); a launch argument works for any build:
defaults write local.daybook.app DaybookDevelopmentFolderSync -bool YES
swift run Daybook -DaybookDevelopmentFolderSync YES
```

With it, Settings › Library offers Choose Folder…, and a chosen folder is restored at launch. Builds signed for iCloud ignore it and never offer a folder. Tests connect folders directly with `LibrarySyncController.connect(to:)`.

## What travels

Original audio and retained highlight sidecars, all source transcript runs and their model settings, unified transcripts, notes and timestamps, highlights, summaries, completed actions, speakers and available embeddings, correction history, folders, tags, template edits, and vocabulary records are synchronized. Active recordings finish locally first. The app's model weights, capture permissions, automatic-recording preference, and transient inference jobs are specific to each Mac. A conversation's processing status (transcribing, summarizing) travels as the device doing the work set it, and receivers keep it as synced rather than rewriting it (which would publish it back and conflict with that device's next status). What's shown comes from `ProcessingStatus`, which never presents another device's work as running here.

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
  <library>-<device>.json    # causal checkpoint: heads, what was published, deletions, a pending pass
  Bases/<library>-<device>/  # each conversation's applied base, <meeting>.json, written when it changes
  audio-cache.json           # on-demand replicas: fetched and published audio, last played
  Inbox/<library ID>/        # courier deliveries waiting for iCloud Drive (Events/, Metadata/, Blobs/)
  Courier/                   # the courier: outbox.json, Outbox/ (staged copies), cloudkit-state.json
```

`NSFileCoordinator` coordinates access with the file provider. `NSMetadataQuery` requests updates for the journal's tree. Evicted files trigger iCloud download requests and remain pending until readable. Files and event hashes are validated, relative paths cannot escape the library, symlinks are rejected, and a partially downloaded recording is never installed: audio reaches the library only by an atomic move after its SHA-256 matches. An uploaded local file is not assumed to have reached another Mac: upload and download counts remain visible.

Journal entries are immutable and named by their hash, so an engine reads and validates each one once; the directory listing on every pass stays the source of truth. Every event's header (conversation, parents, assets) stays in memory, but a snapshot is kept only while passes use it (a head, or the base of a merge) and is read again from the journal (and checked against its name) when needed, and library settings keep their data only for heads, so memory follows the size of the library, not of its history. If part of the journal is unread on a pass (still downloading, or deferred by limits), a conversation whose applied head wasn't read is held back rather than offered at an older revision, library metadata waits for a complete read, and a deletion already applied here is not republished. An entry that can't be read at all is a different case (see [Newer versions](#newer-versions)).

Each device has its own durable checkpoint scoped to the shared library UUID and device identity. Events include causal parents. New local edits are published against the last applied revision, so seeing a remote event does not falsely make an offline edit its descendant. Pulling has two phases: return hydrated snapshots, then acknowledge only after the application saves all metadata successfully. Restarting between those phases offers the changes again. Failed local saves cannot advance the acknowledgment. A conversation held back by a pass (audio not uploaded yet, a parent missing) keeps the record of what this device published for it, so a local edit is published once, not on every pass.

The checkpoint holds heads, published fingerprints, and deletions; each conversation's applied base is its own file under `Bases/`, written on acknowledgement only when it changed, and a pending pass records only the bases it changes. Checkpoints written by earlier versions (with every base inline, and a full copy in an unacknowledged pass) are moved over on first load, keeping the pending pass; the checkpoint keeps empty inline fields so an earlier version can still open it (it would publish its library once more, sequentially). A pass's publications share one sequence number and the checkpoint is saved once after them (and again with the pending pass), not after each one: a pass interrupted between writing an entry and saving (a crash, a cancelled background pass) writes the same bytes again next time for anything unchanged, so it leaves no sibling entries behind.

The app serializes sync with imports and defers it while final inference is active. While the Mac records, it runs settings-only passes (`SyncPassScope.metadataOnly`): library settings (recorder ownership, handoffs, folders, templates, vocabulary) are exchanged and conversations wait until the recording is filed, so another device's handoff or claim is seen during a long recording. An edit saved while a pass runs isn't in that pass: the library remembers it (`SyncApplied.editedDuringPass`) and asks for another pass when this one ends; the iPhone counts it as waiting and runs one at once. Notes edited while a transfer is in progress are rebased before applying remote changes. Account changes invalidate the pending sync receipt and pause sync (see [The iCloud container](#the-icloud-container)). Changing transport is disabled through the durable apply phase.

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

A replica configured with a `SyncDeviceIdentity` writes its own `Devices/<SHA-256 of device ID>.json` at the end of a pass, and the controller's 30-second timer rewrites it when due even while passes wait (recording, processing). It rewrites the record when the identity or activity changes or when the last write is older than `presenceRefreshInterval` (10 minutes by default):

```json
{ "format": "DaybookDevice", "schemaVersion": 1, "deviceID": "…", "deviceClass": "mac",
  "displayName": "Studio Mac", "canProcess": true, "audioPolicy": "eager", "lastSeen": "2026-10-23T17:40:00Z",
  "installation": "…",
  "activity": { "recordingConversationID": "…", "since": "2026-10-23T17:31:12Z", "expiresAt": "2026-10-23T18:05:00Z",
                "recorders": [{ "kind": "soundcore.work", "serial": "…", "isRecording": true, "recordingID": "…",
                                "startedAt": "2026-10-23T17:31:15Z", "asOf": "2026-10-23T17:40:00Z" }] } }
```

- **Activity** (optional) says what the device is doing: the conversation it's recording into, since when, and the recorders it drives. `LibrarySyncController.publishActivity(recording:since:recorders:)` writes it at once; the Mac calls it when a recording starts and stops, as does the iPhone's recorder. Its `expiresAt` is set at each write, two and a half refresh intervals ahead, and readers ignore it after that (`KnownSyncDevice.isRecording(at:)`, `recordingMac(at:)`). On the iPhone, `MacPresence.recordingLine` names a Mac that's recording. An activity that can't be read is left out; the device is still listed.
- **Installation** is a random ID kept with the device ID. A record written recently (within an hour) by another installation means two devices share this device ID (one was cloned from the other): the one with the greater installation ID stops writing the record (`sharesIdentity`), and its controller takes a new device ID after the pass, carries its checkpoints over, and reconnects; the other keeps the ID.
- **The device ID** is kept in a this-device-only keychain item (`SyncDeviceIdentityStore.keychain(for:)`, one per library folder), mirrored in preferences. On the first launch with it, the ID in preferences moves there unchanged. Preferences that say it moved, with no keychain item here, were copied from another Mac (Migration Assistant, a backup): this Mac takes a new ID and carries its checkpoints over, so two Macs never share one. Without a keychain (unsigned builds, `swift test`), preferences hold it as before.

`knownDevices()` lists every presence record, this device, and any device seen only on journal entries, which is an older Daybook with no presence (`reportsPresence == false`). `lastSeen` is clamped to the reader's clock. On the phone, `devices.latestProcessor` gives "Waiting for your Mac · last seen 2 h ago". If it's nil and `hasPeersWithoutPresence` is false, no Mac has synced this library yet.

The format is versioned. Additive fields (`installation`, `activity`) keep `schemaVersion` 1. An incompatible change must bump it, and readers skip versions they don't know. Readers also skip files of another format, files over 64 KB, malformed files, and records whose file name doesn't match their device ID. Unknown device classes read as `other`. Presence is advisory: a failed write never fails a pass. Daybook versions without presence only list `Events/`, `Metadata/`, and `Blobs/`, so they ignore `Devices/` and any other new folder. A frozen copy of the version 1 engine (`LegacyLibrarySyncFixture.swift`) checks this in the tests.

## Courier (CloudKit)

iCloud Drive can take minutes to hours to move a file between devices, and longer on cellular. The courier carries the journal files the iPhone writes to the Mac through CloudKit as well, usually within seconds over any network. It doesn't wait for Wi-Fi: the sends after a recording and the Mac's fetch on a push run as user-initiated CloudKit work with cellular allowed, which the system doesn't defer for Wi-Fi, power, or Low Power Mode the way it defers CloudKit's default, discretionary work (`CloudKitCourier.immediateGroup`). iCloud Drive, the backup, follows the iPhone's Settings › Cellular › iCloud Drive switch, which no app can override. iCloud Drive still carries every file exactly as before; the courier only gets some there first. When the courier is off, slow, or refuses a file, sync is what it was without it.

**What travels.** After a pass, `SyncResult.writtenFiles` lists the files that pass wrote into the sync folder: events, metadata, and audio objects it copied there (a file written by a pass that later failed is reported by the next one that returns). Each is a `SyncJournalFile`: its path relative to the sync folder, its SHA-256, and its size. Only `Events/`, `Metadata/`, and `Blobs/` entries named by their SHA-256 travel; the manifest and presence never do.

**The pieces** (DaybookKit, shared by both apps):

- `SyncCourier`, the protocol: `start(role:receiver:onStatus:)`, `send`, `flush`, `fetch`, `removeExpired`, `status`. Roles are `.send` (the iPhone) and `.receive` (a Mac).
- `CourierOutbox`, which every courier uses: what's waiting (with a staged copy of its bytes in `Sync/Courier/Outbox/`), what was sent, what was left to iCloud Drive, and which files are known to be on the server, in `Sync/Courier/outbox.json`.
- `CloudKitCourier`, the real one, and `InMemoryCourier` over `InMemoryCourierService`, the fake the tests use.
- `LibrarySyncController` owns the wiring (`courier`, `courierRole`, `courierStatus`).

**Sending, once.** After each pass, `LibrarySyncController` hands `writtenFiles` to the courier and asks it to send now. The courier takes a file only if it hasn't before (waiting, sent, or skipped), stages a coordinated, hash-checked copy (`LibrarySyncEngine.copyJournalFile`), so iCloud evicting the original can't change what's sent, and remembers it in the outbox, which survives relaunches. A retried pass, or one that reports the same file again, sends nothing new. Sent files are remembered for 30 days. On the iPhone, the pass after a recording is filed runs under a background-task assertion, and `PhoneSync.synchronizeFinishing` keeps it until the courier has taken the files and tried sending them (`finishCourierSends()`); if the assertion runs out, the wait ends and CloudKit carries on as the system allows.

**CloudKit.** `CloudKitCourier` runs a `CKSyncEngine` on the private database of the app's container (`iCloud.local.daybook`):

- **Records.** One custom zone, `Courier`, and one record per file, type `CourierFile`. Its fields are `path`, `sha256`, `size`, `deviceID`, `libraryID`, `createdAt`, and `asset` (a `CKAsset`). The record name is `<library ID>.<path with / as .>`, e.g. `3F2A….Events.<sha256>.json`, so sending a file again replaces the record instead of adding one; a "server record changed" answer means it's there already and counts as sent. The courier never queries, so the schema needs no indexes.
- **Pushes and scheduling.** The engine subscribes to the database and fetches when CloudKit pushes, so both apps carry push entitlements and register for remote notifications once the courier is available (`onCourierAvailable`). On the Mac a push the app sees also asks for a fetch (`fetchCourier()`). The iPhone's engine leaves the `Courier` zone out of its fetches, so it never downloads its own recordings back.
- **Retries.** The engine retries network failures, rate limits (honouring retry-after), busy zones, and a temporarily unavailable account itself. A refusal for lack of iCloud storage waits 1 minute, doubling to at most 6 hours, then goes again. A missing zone is recreated and the file resent. A staged file that's gone, or a file refused for a reason that won't pass, is left to iCloud Drive. Three such refusals in a row (a schema missing from Production, say), or one error saying CloudKit won't serve the container at all (bad container, missing entitlement, permission failure, a restricted managed account), turn the courier off until the account changes or the app launches again, so it doesn't upload recordings for nothing.
- **Off, quietly.** The courier isn't created at all unless the build is signed for CloudKit with the container (on the Mac this reads the code signature; creating a `CKContainer` without the entitlement would stop the app). It turns itself off when there's no iCloud account, iCloud is restricted, or the account can't be determined, and tries again when the account changes. Off, it takes nothing, and whatever was waiting is left to iCloud Drive. There is no message: iCloud Drive carries everything.
- **Accounts and resets.** Signing out or switching accounts clears the outbox (the engine drops its pending changes itself). If the person deletes the app's iCloud data (the zone is purged or its encrypted data reset), the courier keeps nothing and resends nothing.
- **Size.** Files over 50 MB, the maximum Apple documents for a CloudKit asset field, aren't sent; iCloud Drive carries them. That's about 100 minutes of the phone's 64 kbit/s AAC.

**Receiving into the engine.** A Mac's courier hands each fetched file to `LibrarySyncEngine.receiveCourierFile(_:libraryID:contents:)` while CloudKit's copy is still in its staging area. The engine:

1. accepts only an `Events/`, `Metadata/`, or `Blobs/` path named by the SHA-256 it came with, for the library this replica syncs (`waitingForLibrary` until a pass has read the manifest; the file stays on the courier);
2. reports `alreadyHave` when the sync folder holds the file downloaded, or the inbox holds it;
3. otherwise checks the size, copies it while checking its SHA-256, and moves it into `Sync/Inbox/<library ID>/<path>`. A file that doesn't match is `rejected` and discarded.

The controller then asks for a pass and returns the settled files (stored, already here, or rejected), which the courier deletes from CloudKit. Nothing from the inbox is written into the sync folder while the sender may still upload it: a second device writing the same file there is how iCloud Drive makes conflict copies (`daybook-sync 2.json`). A delivery whose sync-folder copy hasn't appeared at all after a day (`courierPromotionDelay`; the iPhone was lost or reset before iCloud Drive uploaded it) is written there from its verified inbox copy at the end of a pass, so a second Mac or a new iPhone gets it too. Its name is its content, so the sender's copy arriving later is the same file; the inbox copy is pruned once the sync folder's is there.

**Reading with an inbox.** A pass lists each journal folder as the union of the sync folder's entries and the inbox's (`journalListing(in:)`), so a delivery is a remote change to `hasRemoteChanges()`, and the same file arriving later through iCloud Drive isn't one. An entry is read from the sync folder when its copy there is downloaded and matches its name, and otherwise from the inbox, asking iCloud to download the sync folder's copy. Audio is installed the same way: an eager pass copies a delivered object while the sync folder's copy isn't downloaded, and `fetchAudio` uses one instead of waiting for iCloud. Every copy is checked against its SHA-256 again on the way into the library; a delivery that no longer matches is discarded and iCloud Drive's copy takes over. A pass that publishes a track whose audio came by courier doesn't upload that object: the device that recorded it does. With an empty or missing inbox, everything behaves exactly as before.

**De-duplication.** A file has one name everywhere: its path in the sync folder, which is its SHA-256. The courier's record name is derived from it, so a resend replaces itself; the engine's journal listing de-duplicates the sync folder's and the inbox's copies by name; and once the sync folder holds the file downloaded and identical, the end of each pass deletes the inbox copy (`pruneCourierInbox()`). It never deletes one sooner, because a pass may have applied it, and losing an applied entry could roll a conversation back.

**Expiry.** CloudKit has no expiry, so the courier deletes `CourierFile` records older than 7 days that its device knows about: a sender, the files it sent (`removeExpired()`, at start and at most hourly after a pass); a receiver, any it fetches that are that old, without delivering them. A receiver deletes what it stored as soon as it's stored, so records normally live seconds to minutes. Courier storage counts against the person's iCloud storage while it lasts.

**Status.** `LibrarySyncController.courierStatus` (`CourierStatus`) has the availability, how many files wait to send and since when, the last error, and whether iCloud storage is full. A send is stuck after 15 minutes (`isStuck`). The iPhone's sync line then says "Waiting to send 2 items to your Mac", or "iCloud storage is full"; nothing else in the interface mentions the courier.

**Limits.** With more than one Mac, the first Mac to store a file deletes it from the courier, so another Mac that hadn't fetched it yet gets it through iCloud Drive. Only the iPhone sends; transcripts and summaries from the Mac travel by iCloud Drive alone. A file that arrives before a Mac has read the library's manifest isn't delivered again and expires (iCloud Drive carries it).

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
- **Requests.** `requestSync()` runs a pass after `syncDebounce` (two seconds), so a burst of edits makes one pass; nil turns automatic passes off (test rigs drive passes themselves). `hasPendingSyncRequest` says one is waiting and `awaitIdle()` returns once none is waiting or running. Pull to refresh on the iPhone goes through `PhoneSync.synchronize`, so it joins a pass already running. The iPhone's background refresh is scheduled whether or not sync is connected (the same task resumes recorders' automatic imports); its pass runs only when connected.
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

Independent changes are merged. Original tracks, model runs, and history remain additive. Concurrent edits to the same text or summary use a deterministic selected value and retain alternatives in History with a visible warning. This preserves work for review; it does not pretend to understand which wording the user intended. Folder/template/vocabulary records have per-item modification times and explicit deletion markers, so removing a term on one Mac does not silently resurrect it on another. Their immutable metadata versions also remain in the journal. `MeetingMerge` is deterministic, commutative, and idempotent.

- **No common ancestor.** Two devices that created the same conversation (the phone and the Mac each start a multipoint conversation) merge against a neutral skeleton: a default or empty value (no folder, template, or placement, Automatic, empty notes, a placeholder title) counts as unset, so a value set on either side wins with no conflict; the earlier date wins; notes merge paragraph by paragraph (by anchor ID, else by text) with the other side's paragraphs placed by recording time; processing status takes the one further along. A conflict is recorded only when both sides set different values.
- **Criss-cross histories.** When heads share more than one maximal common ancestor (both devices applied the same merge, then edited), the base is the merge of all of them, computed the same way (git's recursive strategy), so what either removed after the shared merge stays removed and a revert sticks.
- **Edits from before photos.** A snapshot from a Daybook that predates photos carries no photos, and its summary sections no photo IDs; when its history has them, they're taken from its parents.

Deleting a conversation propagates a tombstone for that meeting UUID. Stale offline Macs cannot resurrect it. Current local files move into Daybook's Trash; earlier journal events and blobs remain recoverable. Consequently sync is not permanent erasure, and its journal is not currently compacted. Cloud storage grows with history.

- **Deleted while this device adds to it.** A conversation deleted on another device while this one records or processes into it (`protecting`) is left alone until that ends. Then, if it holds recordings, photos, bookmarks, or note paragraphs the deletion never saw (compared with the merge of the deletion's parents), that content is kept as a new conversation: files, history, and open requests included, with a Version History entry ("Kept after it was deleted on another device") and a notice. The deleted ID stays deleted. The new ID is derived from the deletion, so devices that keep the same conversation make one. Derived work alone (a transcript, a summary) doesn't bring a deleted conversation back. The Mac's automatic trash (a recording moved to another conversation) syncs before deciding, and anything that still arrives afterwards is kept the same way.
- **Restoring.** Restore from the Trash checks this device's checkpoints (`LibrarySyncController.isSyncedDeletion`): once sync has published the deletion, the conversation comes back as a new conversation (its files cloned, its notes and history kept, "Restored from the Trash" in Version History), whether or not sync is on; one whose deletion never synced keeps its ID.
- **Audio installed before a deletion arrived.** A conversation folder with no `meeting.json` (an eager pass installed its audio, then the deletion arrived before the pass was saved) goes to the Trash with it.

## Newer versions

A newer Daybook may write values, entries, or settings this version doesn't know. None of it stops sync or is lost when this version edits:

- **Enum values.** Stored enums in conversations, requests, and library settings are wrapped in `Extensible`/`ExtensibleOptional` (`ExtensibleValues.swift`): an unknown raw value reads as a neutral fallback (`syncFallback`; Automatic for a kind, nil for a placement, imported for a status) and is written back unchanged until someone here sets a new value. Known values encode exactly as before. A request whose mode this version doesn't know is never claimed here (`ProcessingRequest.isUnderstood`).
- **Journal entries.** An event or settings version that declares a newer `schemaVersion`, doesn't decode, or is damaged is remembered as unreadable for the life of the process (read again after a relaunch, perhaps after an update). It isn't a pending download, isn't read again every pass, and doesn't keep a phone running full passes; the warning stays while it's there. A conversation applies as far as this version can read it: heads that descend only from unreadable entries are set aside, while heads waiting for a download still hold it.
- **Library settings.** Settings versions merge from the readable heads without waiting for an unreadable parent (they merge item by item, last change wins). A version whose settings declare a newer schema is left out here and never superseded by this device; one that doesn't decode is skipped with a warning; and a single item in a shape this version can't read is kept and written back unchanged (`LibraryValue.unreadableValue`), never treated as a deletion.
- **Extra fields** are ignored when reading. An older version's edit doesn't carry them forward; photos are the one case handled specially (above).

Processing claims are judged by this device's clock from when it first saw each heartbeat (`ClaimObservations`), plus the lease the holder granted itself, so a Mac whose clock runs ahead, or a heartbeat that took minutes to arrive, never makes a live claim look expired. A claim whose own expiry is half an hour behind this device's clock is stale at once.

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

Courier tests never touch CloudKit. `LibrarySyncInboxTests` (DaybookCore) withhold files from the simulated iCloud folder to play iCloud Drive lagging behind, and cover:

- what a pass reports writing, once;
- a verified delivery read before iCloud Drive brings it, with its audio installed, and nothing written into the sync folder (not even by a later edit on the Mac);
- the same files arriving through iCloud Drive pruning the inbox without rolling anything back;
- damaged, short, foreign, and non-journal deliveries rejected, an unknown library waiting, and a delivery damaged after it was stored discarded in favour of iCloud Drive's copy;
- `fetchAudio` installing from the inbox without waiting for iCloud.

`LibrarySyncCourierTests` (DaybookKit) run an iPhone and a Mac controller with `InMemoryCourier`:

- each written file sent once through network failures, retries, and a relaunch;
- files over the size limit left to iCloud Drive;
- storage-full refusals waiting longer each time;
- the Mac storing, applying before iCloud Drive, and deleting from the courier;
- a damaged courier file discarded while iCloud Drive still delivers;
- an unavailable courier leaving sync unchanged (and `CloudKitCourier` never created without the entitlement);
- seven-day expiry by the sender and by a receiver.

The iPhone's `SyncServicesTests` check that a filed recording reaches the courier, that a stuck send shows in the sync line, and that an edit made during a pass is synced right after it while a pull to refresh joins the running pass.

Merge, history, and compatibility tests (DaybookCore) cover: two creations of one conversation with notes, folder, and template on one side (`MeetingMergeTests`, `LibrarySyncTests`); merges commutative and idempotent; criss-cross histories with tag, bookmark, and photo removal and a revert, and three devices (`LibrarySyncHistoryTests`); an edit from the version 1 engine keeping photos and summary photo IDs; a held conversation publishing an edit once over many passes; a crash between writing an entry and saving the checkpoint; bases in their own files and only used snapshots in memory; newer-schema events, unknown enum values and extra fields, and settings in a newer format (`LibrarySyncCompatibilityTests`, `ExtensibleValuesTests`); upgrading in place from the version 1 engine's local state with an unacknowledged pass and a half-read journal; a fresh device waiting for the listing; two manifests resolving to one library; a deletion arriving while a device records into the conversation, two devices keeping the same deleted conversation, and audio installed before a deletion (`LibrarySyncDeletionTests`); a courier delivery whose sync-folder copy never arrives; recording activity in presence and settings-only passes; claims under clock skew and latency (`ProcessingRequestTests`); and random histories across an eager Mac, an on-demand iPhone, and the version 1 engine from fixed seeds (`LibrarySyncConvergenceTests`). DaybookKit's `LibrarySyncApplyTests` and `SyncDeviceIdentityTests` cover the same through `LibraryController` (status kept as synced, restore as a new conversation, edits during a pass, handoffs while recording, settings a newer version wrote) and the device identity (moving to the keychain, copied preferences, two devices sharing an ID); `LibrarySyncContainerTests` an account change during a long pass.

Migration and container tests (`LibrarySyncMigrationTests`, `LibrarySyncContainerTests`) use a temporary "chosen folder" and a temporary "container" with a scripted account. They cover a verified, idempotent copy that leaves the folder byte-for-byte unchanged; continuing in the container without republishing; merging into a container another library started (checkpoint carried over) and one another Mac moved into first; evicted journal files that wait and resume, with this Mac's own audio used instead of downloads; never overwriting the container or copying damaged files; no entitlement (sync off, folder transport only behind the development preference); signed out, iCloud Drive off, container unavailable; turning sync off and on; and account changes pausing until the person chooses.

Actual propagation through Apple's service on two physical Macs, or a Mac and an iPhone, has not been exercised; nor has the container on a signed build, nor the courier against CloudKit (see `docs/validation.md`). Acceptance should include:

- the courier: a phone recording reaching the Mac on Wi-Fi and cellular ahead of iCloud Drive, pushes arriving with the app in front and in the background, the Mac deleting what it stored, storage-full and offline sends, and records expiring;
- eviction, offline edits, and account changes;
- quota exhaustion, very large recordings, and simultaneous first-time setup;
- on an iPhone:
  - whether iOS presents evicted items as `.icloud` placeholders or dataless files;
  - `startDownloadingUbiquitousItem` and download errors on cellular and Low Power Mode;
  - upload state reported for phone recordings before eviction;
  - `BGAppRefreshTask` time limits;
  - battery and thermals.

Two manifests resolve deterministically to the smallest library ID (above); only a conflict version that can't be read is surfaced. Sync does not add its own content encryption or replace independent backups; local and iCloud protections are controlled by macOS and the user's account settings.

## Apple references

- [Synchronizing documents in iCloud](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment): metadata can arrive before file contents; download readiness must be handled separately.
- [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html): coordinated document access, conflict versions, and container discovery.
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator): coordinated reads and writes with file presenters/providers.
- [Enabling iCloud Storage](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html): app-owned container access requires matching entitlements; a folder bookmark does not grant an app arbitrary container access.
- `CKSyncEngine` (CloudKit headers in the Xcode 27.1 SDK, `CKSyncEngine.h`): needs the CloudKit and remote-notification entitlements; retries network, rate-limit, and account errors itself; one engine per database in Production. Apple's sample: [sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine).
- [CloudKit Web Services Reference, "Data Size Limits"](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html): 1 MB per record, not counting assets; 50 MB per asset field.
