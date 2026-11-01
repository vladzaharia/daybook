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
- **Account changes.** `NSUbiquityIdentityDidChange` cancels the pass in flight (its receipt can no longer be acknowledged), drops the engine, and resolves again. Signing out pauses; signing back in to the same account resumes; a different account waits for the person. The account a library syncs with is recorded (the archived identity token) when the container first resolves, before any migration. A cancelled pass that's still unwinding (in the middle of copying a long recording) is waited for before the container is attached again, so the change never leaves sync off. The notification also arrives with the account unchanged (iOS posts it at launch, for one); then sync carries on as it was, on the Mac and the iPhone, with a chosen folder too. A cancelled pass isn't a failure: sync says what it said before the pass, never "Sync paused".
- **A new library, once.** A device creates `daybook-sync.json` only when the container holds none *and* iCloud has listed it: the engine is created with `waitsForListing`, and the controller calls `listingGathered()` when its `NSMetadataQuery` finishes its first gather. Until then a pass returns nothing and the status reads "Waiting for iCloud…", so a fresh iPhone or Mac doesn't start a second library beside one it can't see yet.
- **Two manifests anyway** (two devices launched at once on a new container and each wrote one; iCloud kept a conflict version or a renamed copy such as `daybook-sync 2.json`): every device resolves them the same way, whichever is the file and which the copy. The smallest library ID wins.
  - Plaintext libraries share one journal: the manifest lists the IDs it `supersedes` (an additive field older versions ignore), and a device whose checkpoint belongs to a superseded ID carries it over (with its bases), so it continues from the same heads and publishes nothing again.
  - New encrypted libraries (every new library is one) can't share a journal: each is sealed with its own key. Two whose `created` dates (an additive field set when a device starts a library) are within a week of each other were started together. The first one started wins, by the clocks of the devices that started them, and of two started the same second, the smallest ID. Every device must reach the same answer from the manifests alone (what each holds differs with what each has downloaded), so this is a way to agree, not a judgment of which holds more, and nothing depends on it being the fuller one: the winner replaces the others (`sealing.replaces`, as after Start Over, and `sealing.rivals`), their devices publish what they hold into it once they have its key, and nothing of a rival's is deleted until that's done. Its files are left alone (not read, not waited for, no warning) until every device that wrote presence in the last six months (an earlier identity of a reinstalled device aside; a device lost or given away stops counting six months after it was last seen) holds the winner's key: each has moved on and published what it holds, and what it failed to publish it still holds and publishes on a later pass. Then a rival's entries go as passes find them, and its objects once the winner holds what they hold (a recording republished under the winner's key); one nothing republished stays. Its key leaves iCloud Keychain once nothing in the sync folder is that library's any more (objects are checked as for a retired key, below). Encrypted libraries that weren't started together, or started over from different ones, still pause sync.
  - Once the resolved manifest is written, conflict versions are marked resolved and the renamed copies that were read are deleted, so one marker is left. A copy still in iCloud is asked for and resolved on a later pass. Only a conflict version that can't be read stops sync, as before.
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
swift run Daybook -DaybookDevelopmentFolderSync YES
open dist/Daybook.app --args -DaybookDevelopmentFolderSync YES
```

Use the launch argument: it works for any build, and `defaults write` can't reach a sandboxed build's preferences,
which live in its container (docs/sandbox.md).

With it, Settings › Library offers Choose Folder…, and a chosen folder is restored at launch. Builds signed for iCloud ignore it and never offer a folder. Tests connect folders directly with `LibrarySyncController.connect(to:)`.

## What travels

Original audio and retained highlight sidecars, all source transcript runs and their model settings, unified transcripts, notes and timestamps, highlights, summaries, completed actions, speakers and available embeddings, speaker profiles with their voiceprints ([below](#speaker-profiles)), correction history, folders, tags, template edits, and vocabulary records are synchronized. Active recordings finish locally first. The app's model weights, capture permissions, automatic-recording preference, and transient inference jobs are specific to each Mac. A conversation's processing status (transcribing, summarizing) travels as the device doing the work set it, and receivers keep it as synced rather than rewriting it (which would publish it back and conflict with that device's next status). What's shown comes from `ProcessingStatus`, which never presents another device's work as running here.

Two devices receiving the same meeting identity reconcile their recordings and edits automatically. Independent recordings created as separate meetings are not automatically declared the same conversation based on dates. Attach additional audio to the intended meeting to align it; clock and text evidence then determine whether sources can be unified.

## Transport and durability

```text
<container>/Documents/Daybook/     # or a chosen folder in development builds
  daybook-sync.json          # library identity and schema
  Events/<SHA-256>.json      # immutable meeting snapshots and deletion events
  Metadata/<SHA-256>.json    # immutable organization/template/vocabulary versions
  Blobs/<SHA-256>            # original audio and sidecar bytes
  Devices/<SHA-256>.json     # presence: one small mutable record per device (SHA-256 of its device ID)
  Compaction/<SHA-256>.json  # what compaction pruned, and what it proposes to (see Compaction)

Local library/Sync/          # never synchronized
  <library>-<device>.json    # causal checkpoint: heads, what was published, deletions, a pending pass
  Bases/<library>-<device>/  # each conversation's applied base, <meeting>.json, written when it changes
  audio-cache.json           # on-demand replicas: fetched and published audio, last played
  Inbox/<library ID>/        # courier deliveries waiting for iCloud Drive (Events/, Metadata/, Blobs/, Sealed/…)
  sealing.json               # sync folders this device synced encrypted (see Encryption)
  Courier/                   # the courier: outbox.json, Outbox/ (staged copies), cloudkit-state.json
```

`NSFileCoordinator` coordinates access with the file provider. `NSMetadataQuery` requests updates for the journal's tree. Evicted files trigger iCloud download requests and remain pending until readable. Files and event hashes are validated, relative paths cannot escape the library, symlinks are rejected, and a partially downloaded recording is never installed: audio reaches the library only by an atomic move after its SHA-256 matches. An uploaded local file is not assumed to have reached another Mac: upload and download counts remain visible.

Journal entries are immutable and named by their hash, so an engine reads and validates each one once; the directory listing on every pass stays the source of truth. Every event's header (conversation, parents, assets) stays in memory, but a snapshot is kept only while passes use it (a head, or the base of a merge) and is read again from the journal (and checked against its name) when needed, and library settings keep their data only for heads, so memory follows the size of the library, not of its history. If part of the journal is unread on a pass (still downloading, or deferred by limits), a conversation whose applied head wasn't read is held back rather than offered at an older revision, library metadata waits for a complete read, and a deletion already applied here is not republished. An entry that can't be read at all is a different case (see [Newer versions](#newer-versions)).

**Warnings.** A pass that carries on past a problem returns a warning, which Settings › Library shows under the sync status
as one plain sentence, with the technical part behind Details (`SyncWarningWords.compose` and `split`): "Part of the
library’s history couldn’t be read yet." (a file still settling, or a file error), "Part of the library’s history in iCloud
is damaged and was skipped." (an entry that won't read, with its name and what's wrong behind Details), "A recording here
differed from its copy in iCloud, so both are kept." (where the changed one went, behind Details), and the like. Daybook's
own sentences ("Some changes were made with a newer version of Daybook. Update Daybook to see them.", "Waiting for iCloud
to download a change.") are the whole warning. The library's notice in the conversation list shows the sentences only.

Each device has its own durable checkpoint scoped to the shared library UUID and device identity. Events include causal parents. New local edits are published against the last applied revision, so seeing a remote event does not falsely make an offline edit its descendant. Pulling has two phases: return hydrated snapshots, then acknowledge only after the application saves all metadata successfully. Restarting between those phases offers the changes again. Failed local saves cannot advance the acknowledgment. A conversation held back by a pass (audio not uploaded yet, a parent missing) keeps the record of what this device published for it, so a local edit is published once, not on every pass; while that publication waits to be applied, an edit back to the applied value is published too. A deletion made here is recorded as synced in the checkpoint together with its tombstone.

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
- **The device ID** is kept in a this-device-only keychain item (`SyncDeviceIdentityStore.keychain(for:)`, one per library folder), mirrored in preferences. On the iPhone the item is named by the library's path within the app's container, because the container's own path changes when the app is updated or reinstalled (an item named by the full path, as earlier versions kept it, moves over; the app's own library also takes the latest item kept under an earlier container's path). Each item records its library (the keychain item's label, the path within the container), and an item kept under another path is taken only when it records this library, or, in a release build, records none (an earlier version's, which only the app's library ever had). A debug build, which may have opened demo libraries in the same container, takes none of those, so a library never takes another library's identity (`SyncDeviceIdentityStore.adoptable`). Before, each such move gave the iPhone a new device ID. On the first launch with it, the ID in preferences moves there unchanged. Preferences that say it moved, with no keychain item here, were copied from another Mac (Migration Assistant, a backup): this Mac takes a new ID and carries its checkpoints over, so two Macs never share one. Without a keychain (unsigned builds, `swift test`), preferences hold it as before.

`knownDevices()` lists every presence record, this device, and any device seen only on journal entries, which is an older Daybook with no presence (`reportsPresence == false`). `lastSeen` is clamped to the reader's clock. On the phone, `devices.latestProcessor` gives "Waiting for your Mac · last seen 2 h ago". If it's nil and `hasPeersWithoutPresence` is false, no Mac has synced this library yet.

**One device, listed once.** A device reinstalled with the same sync folder used to take a new device ID (the iPhone's keychain item was named by the library's full path, which changes with the app's container; see above), and one whose keychain item is gone still does, so its presence appeared once per install. Each record now says when its device ID first wrote it (`firstSeen`, kept from the record as it's rewritten). The rule (`KnownSyncDevice.noteSuperseded`):

- An ID is **superseded** by another of the same name and class whose `firstSeen` is after this one's `lastSeen`: the same device, under a new ID. Two devices with the same name in use at the same time overlap, so neither is; if a superseded ID syncs again, it isn't any more. This device never is.
- An ID not seen for **180 days** (`KnownSyncDevice.retiredAfter`) is retired. It comes back if the device syncs again.
- `inUse(at:)` leaves both out. It's what "Devices in This Library" lists (and counts), and the devices Settings lists as stopping until they're updated when encryption is turned on. Automatic encryption and compaction still count every ID seen in the last 30 days: one that only looks like an earlier install of another device (the same name and class) may be a device that's merely away. Only the choice of which Mac compacts leaves superseded IDs out. Presence files are never deleted, and everything keyed by device ID (presence lookups, recorder ownership and handoffs, key holders, compaction's acknowledgements) still sees every ID in `knownDevices()`. A record written before `firstSeen` existed supersedes nothing until its device writes one; the first write after updating counts as its start.

The format is versioned. Additive fields (`installation`, `activity`, `firstSeen`, `capabilities` (what a Mac does for other devices, role by role, with its models; docs/multipoint.md, "Where summaries run"), `compaction` (see Compaction), and `features`, `key`, and `sealed`, see Encryption) keep `schemaVersion` 1. An incompatible change must bump it, and readers skip versions they don't know. Readers also skip files of another format, files over 64 KB, malformed files, and records whose file name doesn't match their device ID. Unknown device classes read as `other`. Presence is advisory: a failed write never fails a pass. Daybook versions without presence only list `Events/`, `Metadata/`, and `Blobs/`, so they ignore `Devices/` and any other new folder. A frozen copy of the version 1 engine (`LegacyLibrarySyncFixture.swift`) checks this in the tests.

## Courier (CloudKit)

iCloud Drive can take minutes to hours to move a file between devices, and longer on cellular. The courier carries the journal files the iPhone writes to the Mac through CloudKit as well, usually within seconds over any network. It doesn't wait for Wi-Fi: the sends after a recording and the Mac's fetch on a push run as user-initiated CloudKit work with cellular allowed, which the system doesn't defer for Wi-Fi, power, or Low Power Mode the way it defers CloudKit's default, discretionary work (`CloudKitCourier.immediateGroup`). iCloud Drive, the backup, follows the iPhone's Settings › Cellular › iCloud Drive switch, which no app can override. iCloud Drive still carries every file exactly as before; the courier only gets some there first. When the courier is off, slow, or refuses a file, sync is what it was without it.

**What travels.** After a pass, `SyncResult.writtenFiles` lists the files that pass wrote into the sync folder: events, metadata, and audio objects it copied there (a file written by a pass that later failed is reported by the next one that returns). Each is a `SyncJournalFile`: its path relative to the sync folder, its SHA-256, and its size. Only `Events/`, `Metadata/`, and `Blobs/` entries named by their SHA-256 travel (and an encrypted library's `Sealed/` files, see Encryption); the manifest and presence never do.

**The pieces** (DaybookKit, shared by both apps):

- `SyncCourier`, the protocol: `start(role:receiver:onStatus:)`, `send`, `flush`, `fetch`, `removeExpired`, `status`. Roles are `.send` (the iPhone) and `.receive` (a Mac).
- `CourierOutbox`, which every courier uses: what's waiting (with a staged copy of its bytes in `Sync/Courier/Outbox/`), what was sent, what was left to iCloud Drive, and which files are known to be on the server, in `Sync/Courier/outbox.json`.
- `CloudKitCourier`, the real one, and `InMemoryCourier` over `InMemoryCourierService`, the fake the tests use.
- `LibrarySyncController` owns the wiring (`courier`, `courierRole`, `courierStatus`).

**Sending, once.** After each pass, `LibrarySyncController` hands `writtenFiles` to the courier and asks it to send now. The courier takes a file only if it hasn't before (waiting, sent, or skipped), stages a coordinated, hash-checked copy (`LibrarySyncEngine.copyJournalFile`), so iCloud evicting the original can't change what's sent, and remembers it in the outbox, which survives relaunches. A retried pass, or one that reports the same file again, sends nothing new. Sent files are remembered for 30 days. On the iPhone, the pass after a recording is filed runs under a background-task assertion, and `PhoneSync.synchronizeFinishing` keeps it until the courier has taken the files and tried sending them (`finishCourierSends()`); if the assertion runs out, the wait ends and CloudKit carries on as the system allows.

**CloudKit.** `CloudKitCourier` runs a `CKSyncEngine` on the private database of the app's container (`iCloud.local.daybook`):

- **Records.** A custom zone, `Courier` (and `SealedCourier` for an encrypted library's files, see Encryption), and one record per file, type `CourierFile`. Its fields are `path`, `sha256`, `size`, `deviceID`, `libraryID`, `createdAt`, and `asset` (a `CKAsset`). The record name is `<library ID>.<path with / as .>`, e.g. `3F2A….Events.<sha256>.json`, so sending a file again replaces the record instead of adding one; a "server record changed" answer means it's there already and counts as sent. The courier never queries, so the schema needs no indexes.
- **Pushes and scheduling.** The engine subscribes to the database and fetches when CloudKit pushes, so both apps carry push entitlements and register for remote notifications once the courier is available (`onCourierAvailable`). On the Mac a push the app sees also asks for a fetch (`fetchCourier()`). The iPhone's engine leaves both zones out of its fetches, so it never downloads its own recordings back.
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

## Encryption

A library can be encrypted in iCloud, end to end: Apple holds only sealed files, and every device that syncs it holds the
library's key in iCloud Keychain. It turns on by itself: a new library starts encrypted, and an existing one is encrypted
once every device in use can read it (below, "Turning it on"). Settings can turn it on sooner (Settings › Library › iCloud
Sync › Encrypt Library in iCloud on the Mac, Settings › iCloud on the iPhone), and there's no turning it off: resetting
means a new library. Builds that can't keep a key (unsigned and ad hoc, without the keychain group) stay plaintext.

- **What it protects.** The library's content at rest in iCloud without Advanced Data Protection, and from someone who
  has the Apple Account's password but no trusted device's passcode (iCloud Keychain is end-to-end encrypted). The
  courier's CloudKit records hold only sealed bytes. Tampering is detected: every sealed file is authenticated, and a
  manifest replaced by a plaintext one pauses sync on every device that synced the library encrypted.
- **What it doesn't.** An Apple Account together with a trusted device's passcode; a compromised device; the Mac's
  working library and Time Machine (FileVault and an encrypted backup do that); the iPhone's iCloud Backup when the
  person includes the encrypted library in it (Storage › Include in iPhone Backups, off by default for an encrypted
  library: docs/iphone.md, "Backups"). Still visible to Apple: how many files there are and their sizes, when
  they were written, how many devices sync and their kind, the library and key IDs, and the courier records' sizes and
  dates. A Daybook that doesn't encrypt (0.3.0 and earlier) keeps writing its presence record, name included, in
  plaintext. iCloud.com's Data Recovery keeps deleted files for 30 days, and Apple may keep plaintext that long after
  it's retired.

**Keys.** One 32-byte key per library (`LibraryKey`), current until it's rotated. Its ID is HMAC-SHA256(key,
"DBSEAL1 key id" ‖ library ID), first 16 bytes; HKDF-SHA256 with the library ID as salt derives a naming key ("DBSEAL1
names") and a content key ("DBSEAL1 content"). It's kept in iCloud Keychain (`KeychainLibraryKeyStore`): a generic
password, service `local.daybook.library-key`, account `<library ID>:<key ID>`, synchronizable, readable after first
unlock (a locked iPhone's background pass needs it), in the keychain group both apps list, `<team>.local.daybook.shared`.
Its value is `{key, libraryID, keyID, createdAt, createdBy}`. Each app lists its own group first, so items stored without
a group (pairing keys, the device ID) stay where they were. Unsigned and ad hoc builds have no group, so they can't open
an encrypted library (they can't sync at all). A key reaches a device three ways: iCloud Keychain; a paired device over
the local link (docs/link.md, "Library keys"); or a recovery key, 128 random bits shown as seven groups of four Crockford
base32 characters (two of them check characters), which the manifest keeps each key wrapped with (AES-GCM under
HKDF-SHA256(recovery key, library ID, "DBSEAL1 recovery"), bound to the key's ID and library).

**Format** (`SealedObject.swift`, DBSEAL version 1). Every journal file of an encrypted library is a sealed object: an
84-byte header (`DBSEAL`, version 1, kind: 1 event, 2 settings, 3 object, 4 presence; suite 1; 2^20-byte chunks;
key ID; library ID; S; plaintext length), then the plaintext in 1 MiB chunks, each AES-256-GCM-sealed with a key derived
for the object alone (HKDF-SHA256 of the content key, salt S, "DBSEAL1 file" ‖ kind), nonce = the chunk's index, and the
header, index, and a final-chunk flag authenticated. S = HMAC-SHA256(naming key, kind ‖ library ID ‖ SHA-256(plaintext))
is the file's name, so names reveal nothing without the key but stay deterministic: the same key and content give the
same name and bytes on every device, a pass that writes an entry again writes identical bytes, and de-duplication works
as before. Reordered, dropped, truncated, or altered chunks, another library's or kind's object, an unknown key, and
plaintext that doesn't match the name are all refused. Known-answer vectors from an independent implementation freeze
the format (`SealedObjectTests`); a change needs a new version.

```text
<container>/Documents/Daybook/
  daybook-sync.json          # schemaVersion 2, with "sealing"
  Sealed/Events/<S>          # sealed events
  Sealed/Metadata/<S>        # sealed library settings versions
  Sealed/Blobs/<S>           # sealed originals and sidecars
  Devices/<SHA-256>.json     # presence: plaintext essentials, the name and activity sealed
  Events/, Metadata/, Blobs/ # plaintext from before encryption, read only, until retired

Local library/Sync/sealing.json   # this device synced an encrypted library here: never publish plaintext there
```

**The manifest.** `{"format":"DaybookSync","schemaVersion":2,"libraryID":…,"sealing":{"scheme":"DBSEAL-1","current":…,
"sealedSince":…,"migrator":…,"legacyRetired":…,"keys":[{"id":…,"created":…,"recovery":…}],"replaces":[…]}}` (`replaces` only
in a library that started over). Version 2 is the switch:
every earlier Daybook (0.1.0-preview through 0.3.0) stops at it with "This library was synced by a newer Daybook
(version 2). Update Daybook to sync." and changes nothing; the frozen version 1 engine checks this in the tests. The gate
stays strict however tolerant decoding is: version 2 with an unknown scheme reads as newer too. Unlike the rest of the
journal the manifest changes (keys added, a recovery key saved, plaintext retired, keys retired); versions written at once
by devices of the same library merge the same way in any order, every key kept and the newest current. An encrypted library
wins over a plaintext one started beside it (its devices carry on in it once they have the key); two different encrypted
libraries pause sync, unless they started over from the same one (below) or were both started new within a week (two
devices on a new container, [above](#the-icloud-container)). A compacted library is version 3, encrypted or not
([Compaction](#compaction)), which Daybook 0.4 stops at in turn.

**On a pass.** The engine reads the manifest, then the keychain (every pass, so a key that arrives is picked up at once).
Without the current key it reads and writes nothing (`keyUnavailable`): local recording and editing go on, the courier
still takes deliveries, presence says it's waiting, and the status says "Waiting for this library’s key." (on the Mac,
"Turn on iCloud Keychain, or get the key from another device.") with Get Key from (a paired device), Enter Recovery
Key, and, when no device has the key, Start Over (below). A recording that can't open yet says it plays once this device
has the key (`AudioFetchError.keyUnavailable`). With the key, an entry's ID is
still the SHA-256 of its plaintext record, so parents, heads, merges, and checkpoints are exactly as before; only the
files differ. Sealed and plaintext copies of an entry are one entry. Objects are found sealed under any key held here,
else in plaintext from before; they're written sealed under the current key. Installing an object opens it while hashing
the plaintext, into a temporary file that's moved into place only when the SHA-256 matches; cancellation and damage
behave as before. Sealing and opening read the file once, in two overlapping lanes, so they take about the time a copy and
its SHA-256 did (a 1 GiB original seals in 0.4 s on an M-series Mac, within 7 MiB of memory).

**Turning it on** (`enableSealing`, `LibrarySyncController.enableEncryption`). After a pass that's acknowledged, a
device with a plaintext library turns it on by itself (`encryptOnceEveryDeviceCan`) when every other device that synced
in the last 30 days lists the `sealed-1` feature. One seen longer ago, or only in the journal, doesn't hold it back: if it's
still on 0.3.0 or earlier, it says "Update Daybook to sync" when it's back and changes nothing. An iPhone leaves it to a Mac
that synced in that time, which seals the history from its own audio. No recovery key is made then; Settings offers Create
Recovery Key once it's on. From Settings, turning it on first lists the devices that would stop syncing until they're
updated (their presence doesn't list the feature, or they were seen only in the journal), and offers a recovery key.
Either way, a new key is stored and read back, and only then is the manifest rewritten as version 2 with this device as
the migrator. The courier drops plaintext files it still holds and deletes those it sent.
A Mac that moved from a chosen folder (above) offers to delete that folder's plaintext copy of the journal
(`deleteRetiredFolderJournal`): its manifest, `Events/`, `Metadata/`, `Blobs/`, and `Devices/`, nothing else.

**The sealer** (`LibrarySyncSealer.swift`) seals the history again, never rewrites it, so nothing is republished: every
event of a live conversation, only the deletion of a deleted one (its snapshots and audio are left behind), every settings
version, and the objects live conversations use (their merged heads and highlight sidecars). The migrator does it, within
each pass's limits; each device also seals plaintext entries it wrote itself (a pass already running when the manifest
changed). A migrator not seen for two weeks is replaced by the next Mac with the key. An iPhone migrator (it turned
encryption on, or rotated the key) downloads recordings to seal only on an unrestricted network: Wi‑Fi or wired, not
Low Data Mode (`SyncReplicaConfiguration.network`, from `NetworkConditionMonitor`'s `NWPathMonitor`; restricted until it
first reports), unless the person allows cellular, as for model downloads: Settings › iCloud › Use Cellular Data, shown
while this iPhone is encrypting (`PhoneSettings.encryptsOverCellular`, off by default; the network it reports is then
`allowing(cellular:)`, unrestricted on any network). It asks for `sealerDownloadBatch` (4) at a time, seals each as it
arrives (also on cellular, once it's here), and then lets iCloud drop the downloaded copy. Reading back what it sealed
waits for Wi‑Fi the same way. Off Wi‑Fi, Settings says "Encrypting · 12 left · Waiting for Wi‑Fi"; back on Wi‑Fi, or once
cellular is allowed, a pass starts, and a download arriving makes the next cheap check (`hasRemoteChanges`) run one.

**Retiring the plaintext.** The migrator deletes a plaintext file only when its sealed counterpart was read back whole and
iCloud reports it uploaded, another device holds the key or a recovery key was saved, and a week has passed since
encryption began. Then `Events/`, `Metadata/`, and `Blobs/` are emptied (the folders stay), plaintext presence records
are deleted, and the manifest records `legacyRetired`. Only files a pass read and accounted for are deleted; an object
nothing it read names is left alone. Plaintext that reappears later (Data Recovery, a stale device) is sealed if it's live
and deleted. Until then, an iPhone keeps originals it recorded rather than evict them. A device that was away across
retirement and still has a deleted conversation applies the deletion (its parents are gone, not on their way) or, if it
changed the conversation meanwhile, keeps it as a new one. An on-demand replica publishes a recording it doesn't hold by
reference only to an object in the sync folder; one the journal names but that isn't there waits.

**Rotating** ("Erase Deleted Conversations from iCloud", `rotateKey`). A new key becomes current, the sealer seals what's
live under it, and once every device seen in the last 30 days that reads encrypted libraries reports it holds the new key
and a week has passed, the old key's files are deleted and the manifest stops listing it. Deleted conversations' history
isn't carried over, so it's erased from iCloud. The manifest records when the old key was retired (`sealing.retired`).
For at least 30 days the old key stays in iCloud Keychain, so a file sealed with it later (a device that was away) or
restored from iCloud.com's Data Recovery (which keeps deleted files that long) stays readable and is sealed again, or
deleted if it's a deleted conversation's. Then it's removed (`removeRetiredKeys`), on whichever device next completes a full
pass, once every device that wrote presence in the last six months (`KnownSyncDevice.retiredAfter`) holds the current key
(one away for months may hold only the old key, with files sealed with it to bring, and it's the one to seal them again;
an earlier identity of a reinstalled device counts as that device's later one; a device lost or given away stops counting
six months after it was last seen), and nothing in the sync folder is still sealed with it: entries, compaction records
(sealed again under the current key first), and objects. An object's header says which key sealed it; a recording the
journal names is known by its name under each key held here, so it isn't downloaded for this (an iPhone keeps most
recordings only in iCloud). One nothing names is downloaded to read its header, on an iPhone on Wi-Fi only, and let go
of again. On iCloud Keychain that removes it from every device, which finishes the erasing: a copy of the old files Apple
might still hold can't be opened with a key that's gone. A file found sealed with a retired key this device doesn't hold is
never deleted: it's left for a device that holds the key to seal again, not waited for, and not a warning. For 30 days
from when a device first finds one (`SyncCheckpoint.heldAside`, `heldAsideWindow`) it counts: it may be what that device
last applied, and a compaction record among them may list what was pruned, so the compacting Mac doesn't compact. Its
author, if it no longer holds the key either, can't read its own entries: when what it last applied of a conversation is
gone that way, it publishes its copy again, changed or not, merged with what's there or as new when nothing else of it is
there (see [Compaction](#compaction)); it does so on its first full pass after finding them. After 30 days a device that
still held the key would have sealed it again, so nothing will open it: it stays, and is ignored. What a device remembers
of a file sealed with a key it no longer holds vouches for nothing. Remove a lost device from the Apple Account before
rotating, so it doesn't receive the new key. Its presence stays in the sync folder, and holds the old key's removal back
until it hasn't been seen for six months. There are no per-conversation keys: a deletion can't shred one key, so erasing
is this coarse step.

**Starting over** (`startOver`, LibrarySyncStartOver.swift; "Start Over…" beside the waiting line on both apps, behind a
confirmation: "What’s only in iCloud is lost. Conversations on your devices stay and sync again."). When the key is lost
on every device (no device holds it, iCloud Keychain doesn't bring it, and there's no recovery key), a new library
replaces the old one: a new library ID and a new key (stored and read back first), and a manifest whose `sealing.replaces`
names the old library. This device becomes the migrator. No checkpoint carries over (`replaces` isn't `supersedes`), so
every device publishes its own library into the new one as it gets the key, like a device meeting a different library
identity (above); devices holding the same conversation merge like concurrent edits. The old library's files are
deleted: at once its plaintext history from before encryption (`Events/`, `Metadata/`, which the new library must never
read as its own), its sealed objects that aren't downloaded here, and any downloaded sealed file whose header names it;
later, each sealed entry a pass opens that names a replaced library, and downloaded objects that do (passes on devices
with the new key), with the courier's inbox for those libraries. Plaintext recordings from before encryption (`Blobs/`)
stay, so a conversation published again can still use one; the new library's sealer seals what's used and, once
retirement allows, deletes the rest (a library that started over never wrote plaintext, so a recording nothing names is
the old library's). For two weeks after the start an iPhone holding a conversation whose recording isn't in the new library
yet waits for another device to publish it rather than call it missing; a recording that existed only in the old
library's files is lost, and the iPhone then reports it missing. The old library's keys, if any device still holds one,
leave iCloud Keychain on the next pass (`removeReplacedLibraryKeys`); a losing new library's, once nothing of it is left
(above).

**No separate "reset encryption".** Start Over is the disaster path for a lost key: a new library ID and key, every device's
copies kept and published again. It isn't offered, and the engine refuses it, while any device may still hold the key,
because a reset then would be unsafe, not merely redundant:

- *What's only in iCloud would be deleted for nothing.* Starting over deletes the old library's sealed files at once,
  since nothing can read them. With the key still around, some of them are the only copy: an iPhone evicts its own
  recordings once another device holds the key and iCloud has them, so until a Mac downloads them they exist only sealed
  in iCloud, and a deleted conversation's history or another device's unsynced edits may too.
- *A device waiting for the key usually just hasn't got it yet.* iCloud Keychain can take minutes to hours, and a
  paired device or a recovery key can bring it sooner. Replacing the library then strands the devices that do have it.
- *What a reset would be for is already there with the key.* Rotating ("Erase Deleted Conversations from iCloud") gives a
  new key, erases deleted conversations' history, and now removes the old key; a new library ID adds nothing.

So with the key: Erase Deleted Conversations from iCloud. Without it anywhere (no device holds it, iCloud Keychain doesn't
bring it, no recovery key): Start Over.

- **Only when the key is gone.** Start Over is offered only while this device waits for the key, and not while another
  device may hold it: one whose presence said so in the last two weeks (`keyHolderAbsence`), or the migrator that made
  the key that recently and hasn't said it's waiting. Get the key from that device instead. The engine refuses the same
  way (`keyAvailable`).
- **Two devices at once.** The new manifest is written after reading the old one again under coordination: a device
  that finds another's new library there already joins it (and forgets its own new key). Two that both wrote one leave
  iCloud versions that resolve like any (`resolveManifest`): a library that's replaced gives way to the one replacing it,
  and of libraries started over from the same one the smallest ID wins and replaces the others, whose files then go the
  same way and whose devices publish again into the winner. An encrypted library that didn't start over from the same
  one still pauses sync.

**The courier** carries sealed files in a zone of their own, `SealedCourier` (the same `CourierFile` record type), which
Daybook 0.3.0 and earlier never fetch or clear. A sealed file's name isn't its bytes' SHA-256: the inbox accepts
`Sealed/{Events,Metadata,Blobs}/<name>` with the SHA-256 of the bytes that travel, checks that the header names this
library and the folder's kind, and prunes a delivery once the sync folder's copy has the same bytes. It's opened when it's
read. Files the sealer writes are history every device has, so the courier doesn't carry them.

**Presence** in an encrypted library keeps its plaintext essentials (device ID and class, whether it can process, audio
policy, last seen, installation) and adds `features` (`["sealed-1", "compact-1"]`, in every library) and `key` (`{"state": "ready" |
"waiting", "id": …}`); the name and activity travel in `sealed`, a presence object. A device waiting for the key writes no
name. Presence written as sync connects, before a pass has read the manifest, reads it first, and says nothing private
while it isn't downloaded.

**Moving from a chosen folder** into an encrypted container seals every entry and object as it's copied (presence isn't
copied), and waits for the key without it. Nothing is copied until the container's manifest is downloaded, and nothing
into a container this device synced encrypted that has lost its manifest.

**Downgrades.** Once a device has seen a library encrypted in a sync folder (`Sync/sealing.json`), a plaintext manifest
there, or none, pauses sync: "The library in iCloud is no longer encrypted." Choosing another iCloud account forgets it.

**New libraries.** A library a device starts is encrypted from the start when it can keep a key
(`SyncReplicaConfiguration.sealsNewLibrary`, from `LibrarySyncEngine.sealsNewLibraries`), its key stored before the
manifest names it. Turned on in 0.4.1, ahead of the device checks in docs/validation.md ("Library encryption") on the
owner's Mac and iPhone.

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
- **Requests.** `requestSync()` runs a pass after `syncDebounce` (two seconds), so a burst of edits makes one pass; nil turns automatic passes off (test rigs drive passes themselves). `hasPendingSyncRequest` says one is waiting and `awaitIdle()` returns once none is waiting or running. A request made while the requested pass runs (an edit saved meanwhile, a courier delivery) waits for it and runs after it rather than cancelling it. Pull to refresh on the iPhone goes through `PhoneSync.synchronize`, so it joins a pass already running. The iPhone's background refresh is scheduled whether or not sync is connected (the same task resumes recorders' automatic imports); its pass runs only when connected.
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

- **Next steps.** Ticking a next step is the person's decision, apart from the summary's words: the words merge without the ticks (so a tick on one device and a speaker's name following into the summary on another don't conflict), and each step's tick merges three-way on its own, found by its ID, else, for a summary written again or one written on each device, by its words and owner (`MeetingMerge`).
- **No common ancestor.** Two devices that created the same conversation (the phone and the Mac each start a multipoint conversation) merge against a neutral skeleton: a default or empty value (no folder, template, or placement, Automatic, empty notes, a placeholder title) counts as unset, so a value set on either side wins with no conflict; the earlier date wins; notes merge paragraph by paragraph (by anchor ID, else by text) with the other side's paragraphs placed by recording time; processing status takes the one further along. A conflict is recorded only when both sides set different values.
- **Criss-cross histories.** When heads share more than one maximal common ancestor (both devices applied the same merge, then edited), the base is the merge of all of them, computed the same way (git's recursive strategy), so what either removed after the shared merge stays removed and a revert sticks.
- **Edits from before photos.** A snapshot from a Daybook that predates photos carries no photos, and its summary sections no photo IDs; when its history has them, they're taken from its parents.

Deleting a conversation propagates a tombstone for that meeting UUID. Stale offline Macs cannot resurrect it. Current local files move into Daybook's Trash; earlier journal events and blobs remain until compaction (below) prunes the conversation's history and keeps only its deletion. Consequently sync is not permanent erasure (in an encrypted library, rotating the key is).

- **Deleted while this device adds to it.** A conversation deleted on another device while this one records or processes into it (`protecting`) is left alone until that ends. Then, once the deletion and its parents are read (until then it waits, as it does when a pass didn't examine its journal), if it holds recordings, photos, bookmarks, or note paragraphs the deletion never saw (compared with the merge of the deletion's parents), that content is kept as a new conversation: files, history, and open requests included, with a Version History entry ("Kept after it was deleted on another device") and a notice. The deleted ID stays deleted, and the kept conversation is saved before the deleted one moves to the Trash. The new ID is derived from the deletion, so devices that keep the same conversation make one. Derived work alone (a transcript, a summary) doesn't bring a deleted conversation back. The Mac's automatic trash (a recording moved to another conversation) syncs before deciding, and anything that still arrives afterwards is kept the same way.
- **Restoring.** Restore from the Trash checks this device's checkpoints (`LibrarySyncController.isSyncedDeletion`): once sync has published the deletion, the conversation comes back as a new conversation (its files cloned, its notes and history kept, "Restored from the Trash" in Version History), whether or not sync is on; one whose deletion never synced keeps its ID.
- **Audio installed before a deletion arrived.** A conversation folder with no `meeting.json` (an eager pass installed its audio, then the deletion arrived before the pass was saved) goes to the Trash with it.

## Compaction

The journal is immutable, and every library settings version carries every setting, speaker profiles' voiceprints
included (about 1 KB each, so roughly 0.5 MB a version with 20 full profiles). The first speaker-labelling pass also
publishes an event for each conversation it relabels. Without compaction the sync folder grows with every change ever
made. Compaction (`LibrarySyncCompaction.swift`) deletes history no device needs any more, in steps every device applies on
its own whenever it next syncs, however long it was away.

```text
<container>/Documents/Daybook/
  Compaction/<SHA-256>.json   # compaction records (a plaintext library)
  Sealed/Compaction/<S>       # sealed ones (an encrypted library, DBSEAL kind 5)
```

- **Records.** A record is a *proposal* (each live conversation's root, its one head when proposed, and the deleted
  conversations) or a *commit* (the entries it pruned, by ID, and the proposal it carried out). Immutable and
  content-addressed like the journal, sealed under the current key in an encrypted library, never sent by the courier.
  A commit is final: every device treats an entry it lists as gone, even while its file is still there (so two devices
  never merge with different bases), and never waits for one. A missing parent a commit doesn't list is still waited for, as before; a reader that finds an entry deleted
  before the commit that lists it has arrived waits for the commit. Pruned files are deleted only once every commit is
  in iCloud.
- **Library settings.** Settings merge item by item, the latest change winning, with no common ancestor. Every settings
  version that isn't a head goes at once; a device that publishes against one that's gone merges the same way.
- **Conversations** go in two steps, because a merge needs the history back to the common ancestor, and a device still
  holding a deleted conversation needs what the deletion saw to tell what it added since. A proposal names each live
  conversation's one head as its root, and the deleted conversations. Each device acknowledges it in its presence
  (`compaction`, the proposal's ID) once everything it has applied of those conversations is the root or after it, and
  it has applied those deletions (keeping what it added as a new conversation), so it never publishes against what's
  pruned; an edit it made before seeing the root, concurrent with it, keeps it from acknowledging. When every device seen
  in the last 30 days has acknowledged it, a commit prunes each root's ancestors, for the conversations whose every
  head still descends from the root, and each deleted conversation's history but its deletions (as an encrypted
  library's sealer already did). A conversation with two heads waits until someone edits it again; a proposal whose root
  a head no longer descends from, or that's a week old, is replaced (or withdrawn). Each round prunes up to the previous
  proposal's roots.
- **Highlight sidecars.** A conversation's sidecars are those any of its events names (an iPhone that never downloaded
  one publishes an edit without it), so an ancestor that alone names one stays (`prunableHistory`).
- **Who compacts.** One Mac: the one with the smallest device ID among the Macs seen in the last 30 days (that hold the
  current key, in an encrypted library, and aren't an earlier identity of a reinstalled Mac), after a pass that read the
  whole journal with nothing pending, deferred, or unreadable, and only when every device seen in that time says it
  reads compacted libraries (presence feature `compact-1`; a presence record it can't read, written in that time, holds
  it back too). It compacts when there's enough to gain (`SyncCompactionPolicy.standard`: 256 entries or 8 MB) and at
  most every six hours. More than eight commit records are consolidated into one. In an encrypted library the records
  are history like the rest: the sealer seals them again under a new key, and an old key isn't retired while one is
  still sealed with it. A record a newer Daybook wrote that this version can't read is a warning, and stops this Mac
  from compacting. So does a record sealed with a retired key this Mac doesn't hold, for 30 days after it first finds it.
  A Mac that sees no other device in the last 30 days, while another that isn't an earlier identity was seen in the last
  180 (or a presence record can't be read), prunes no conversation's history: every acknowledgement would pass for want
  of anyone to give one. Nor does a Mac whose clock looks more than a week ahead (`clockLooksAhead`): of the devices whose
  presence it has seen change in the last week by its own clock, even the freshest says it was written more than a week
  before. What it read is kept in its checkpoint (`presenceSightings`), so a change made while it was off counts. That
  covers a clock six months ahead, where every other device looks gone; a device whose presence never changes (lost,
  given away) says nothing about the clock, so it never holds compaction back. Once the clock is set right, a run or a
  proposal dated after now doesn't hold compaction back either: the proposal is replaced.
- **Earlier Daybooks.** They'd wait forever for parents that are gone, so before the first commit the manifest becomes
  version 3 (`compactedSchemaVersion`, with `compaction.since`), plaintext or encrypted. Every earlier Daybook stops at it
  with "This library was synced by a newer Daybook (version 3). Update Daybook to sync." and changes nothing (the frozen
  version 1 engine checks this in the tests). One that synced in the last 30 days holds compaction back until it's
  updated; one seen longer ago doesn't.
- **A device back after what it applied was pruned** (away more than 30 days, or restored from a backup) has edits made
  meanwhile merged against the base it stored when it applied them (`Sync/Bases/`, history every device built on), with
  the current heads, and published on the next pass as an ordinary edit (`Rebase`). Heads a commit lists as pruned aren't
  waited for, even while part of the journal is unread; heads gone without a commit saying so wait for a whole read, and
  then merge with no common ancestor. When they're gone because they're sealed with a retired key this device no longer
  holds, its copy is published again even unchanged (merged with no common ancestor, or as new when nothing else of the
  conversation is there): nobody else may ever read what it wrote then. Without local edits it simply applies what's
  there. A deleted conversation it still holds with changes since it last synced keeps only what it added since then
  (what it had synced stands for what the deletion saw), never derived work alone. An edit it published before it went
  away that never reached iCloud, against what has since been pruned, merges with no common ancestor, as two devices that
  created the same conversation do: values both set differently are kept in History with a warning. That's the one case
  compaction changes a merge, and it needs a device that wrote while offline and stayed away more than 30 days.

Not compacted: audio objects (`Blobs/`, `Sealed/Blobs/`) stay, as before; an encrypted library's sealer retires those no
live conversation uses, and rotating the key erases a deleted conversation's.

Measured on a synthetic library (docs/validation.md, "Sync follow-ups"): 200 settings versions, each with 20 profiles of
24 voiceprints (0.4 MB), and 100 conversations relabelled three times. Before compaction the journal was 601 files and
109 MB, plaintext or encrypted; after it, 103 files and 0.7 MB (one settings version, each conversation's root, a commit).
A new device's first pass took 3.6 s before and 1.0 s after (plaintext; encrypted, 6.5 s and 2.1 s), in a debug build.

## Speaker profiles

Speaker profiles and their voiceprints ([architecture](architecture.md#speakers-and-profiles)) are library settings (`LibraryMetadata.speakerProfiles` and `.voiceprints`), so they travel in the journal's settings versions (`Metadata/`, sealed with everything else once the library is encrypted) and are kept in `library.json`:

```json
"speakerProfiles": [{ "id": "<UUID>", "modifiedAt": 783000000,
  "value": { "id": "<UUID>", "name": "Vlad", "createdAt": 783000000 } }],
"voiceprints": [{ "id": "vp-<32 hex>", "modifiedAt": 783000000,
  "value": { "id": "vp-…", "profileID": "<UUID>", "origin": "named",
             "vector": { "space": "fluid-community1-embedding-df2625ac79a7ac6b", "dimensions": 256, "half": "<base64>" },
             "meetingID": "<UUID>", "speakerID": "<run>:<label>", "trackID": "<UUID>", "condition": "microphone",
             "speechSeconds": 182.4, "recordedAt": 783000000, "addedAt": 783000000 } }]
```

- **One record per item.** A profile and each voiceprint are separate `LibraryValue`s, merged as folders are: the later change wins, a deletion marker wins a tie, and equal clocks resolve by encoding, the same in any order. Voiceprints are written once and only ever retired (a deletion marker), so two devices teaching one profile keep every voiceprint either taught, and a retirement or removal on one device stays. The same sample learned on two devices has one ID (a hash of its origin, profile, conversation, speaker, and space, and for a name the rename's ID), so it's one record. A profile's ID comes from the name that started it, so one name given on two devices before they sync is one profile.
- **Merges.** Merging a profile into another writes only the merged profile's record, with `"mergedInto": "<UUID>"` and its name kept; deleting it would lose the forwarding. Every device follows it (`SpeakerProfileMerges`): its voiceprints count for the kept profile, an identity naming it stands for the kept one (a Mac rewrites them as it reconciles), and its name finds the kept profile. Because nothing else changes, a voiceprint or label another device adds to the merged profile before the merge arrives follows it too. The record merges like any profile (the later change wins), so a merge and a rename of the merged profile made on two devices at once keep whichever came later. Chains are followed to the end; two devices merging each profile into the other make a cycle, and the merge made first is set aside, so both keep the later one. A Daybook from before merges keeps `mergedInto` as a key it doesn't know and shows both profiles.
- **Conversations.** Which speaker is which profile (`Meeting.speakerIdentities`: named, confirmed, recognized, suggested, or dismissed, with the profile, the similarity, the name Daybook gave and the one before it, the rename it came from, and the profiles the person rejected) merges three-way per speaker, like the speakers; one taken off on one side stays off. A label is the speaker's name, so every device shows it.
- **Vectors** are IEEE half floats in base64 (`VoiceVector`): 684 characters for Community-1's 256 values, rounded once when made, so what's read back is exactly what was written. A voiceprint is about 1 KB. A profile keeps at most 24 per embedding space, so 20 profiles add at most about 0.5 MB to each settings version. Settings versions are immutable, so every settings change (a folder renamed, a recorder handed over) writes them again, until compaction prunes every version that isn't a head ([above](#compaction)); Macs write new voiceprints only when a name is given or a recognition clears the learning bar, and to a full profile only from newer conversations. Each speaker's embedding already traveled in its conversation, so an unencrypted library's plaintext folders carry voiceprints in the clear, as they did embeddings.
- **Who reconciles.** Macs reconcile (they make the embeddings), deterministically, so two Macs write the same records for the same library. The iPhone applies what arrives: labels are names, and a name given on the phone teaches the profile on the Mac when it arrives. Its answers to labels (Not, Yes, No) and its profile edits (rename, merge, forget, delete) use the same DaybookKit actions as the Mac's and reach the profiles when the Mac next reconciles. For live identification the phone builds a `SpeakerProfileBook` from its library settings (`SpeakerProfileBook(metadata:)`, then `identify(_:matching:)`) with the same thresholds; it compares only within the embedding space of the vector it's given.
- **Newer versions.** Profiles, voiceprints, and identities keep keys this version doesn't know. An origin or identity source it doesn't know reads as the least trusted (learned, suggested) and is written back unchanged, and an identity it doesn't know is left alone. A voiceprint whose vector this version can't read (no `half`, a newer encoding) stays unreadable and travels on unchanged. Daybook versions from before profiles keep both lists under keys they don't know and merge them item by item, so they drop nothing another device taught.

## Newer versions

A newer Daybook may write values, entries, or settings this version doesn't know. None of it stops sync or is lost when this version edits:

- **Enum values.** Stored enums in conversations, requests, and library settings are wrapped in `Extensible`/`ExtensibleOptional` (`ExtensibleValues.swift`): an unknown raw value reads as a neutral fallback (`syncFallback`; Automatic for a kind, nil for a placement, imported for a status) and is written back unchanged until someone here sets a new value. Known values encode exactly as before. A request whose mode this version doesn't know is never claimed here (`ProcessingRequest.isUnderstood`).
- **Journal entries.** An event or settings version that declares a newer `schemaVersion`, doesn't decode, or doesn't validate is remembered as unreadable for the life of the process (read again after a relaunch, perhaps after an update). It isn't a pending download, isn't read again every pass, and doesn't keep a phone running full passes; the warning stays while it's there. Bytes that don't match their name (a file still settling) and file errors are different: they're read again every pass. A conversation applies as far as this version can read it: heads that descend only from unreadable entries are set aside, while heads waiting for a download still hold it.
- **Library settings.** Settings versions merge from the readable heads without waiting for an unreadable parent (they merge item by item, last change wins). A version whose settings declare a newer schema is left out here and never superseded by this device; one that doesn't decode is skipped with a warning; and a single item in a shape this version can't read is kept and written back unchanged (`LibraryValue.unreadableValue`), never treated as a deletion.
- **Extra fields** are kept. A conversation, its recordings, bookmarks, summary, sections, action items, photos, and speaker identities, and each library setting (a folder, template, vocabulary term, recorder owner, handoff, speaker profile, voiceprint, and the settings as a whole) keep the JSON keys this version doesn't know (`UnknownFields`), exactly as written, and write them back after their own, so an edit made here doesn't remove them for the devices that use them (an edit made from a fresh value, such as a rename, takes them from the stored item). The record around each setting (`LibraryValue`) keeps its own until this device writes a new version of it, which describes that version alone. Merges carry them key by key as they merge everything else (`UnknownFields.merged`): a key changed on one side takes that side's value, and two different values keep the greater encoding, with the other in History; a newer list of per-item settings merges item by item, the later change winning. Anything this version writes without them encodes exactly as before. Daybook 0.3.0 and earlier drop them when they edit; photos are the one case handled specially for those (above). Notes (each paragraph's anchor) and transcripts don't keep them.

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

Encryption tests (`SealedObjectTests`, `LibraryKeyringTests`, `LibrarySyncSealingTests` in DaybookCore;
`LibrarySyncEncryptionTests` and `KeychainLibraryKeyStoreTests` in DaybookKit; `LinkLibraryKeyTests`) use a
`MemoryLibraryKeyStore` for iCloud Keychain (one shared between replicas plays it on, separate ones off) and cover:
known-answer vectors; every altered header, chunk, and tag byte, truncation, reordering, and the wrong kind, library, or
key; recovery keys; the version 1 engine refusing version 2 with the sync folder byte-identical afterwards; a plaintext
library written exactly as before; downgrades; merged manifests; encrypted replicas converging with no title, note,
transcript, speaker name, or device name anywhere in the sync folder; a replica without the key writing nothing and
publishing once it arrives; recovery keys and link grants; damaged sealed audio; phone recordings on an eager Mac and
by-reference publishing; the eviction guard; sealing history without republishing, retirement and its conditions, stale
and restored plaintext, rotation erasing a deleted conversation; sealed courier files in their own zone, ignored by an
earlier Daybook; and moving a chosen folder into an encrypted container. A 1 GiB sealing benchmark runs with
`DAYBOOK_SEALED_PERFORMANCE=1`.

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

Merge, history, and compatibility tests (DaybookCore) cover: two creations of one conversation with notes, folder, and template on one side (`MeetingMergeTests`, `LibrarySyncTests`); merges commutative and idempotent; criss-cross histories with tag, bookmark, and photo removal and a revert, and three devices (`LibrarySyncHistoryTests`); an edit from the version 1 engine keeping photos and summary photo IDs; a held conversation publishing an edit once over many passes; a crash between writing an entry and saving the checkpoint; bases in their own files and only used snapshots in memory; newer-schema events, unknown enum values and extra fields, and settings in a newer format (`LibrarySyncCompatibilityTests`, `ExtensibleValuesTests`); extra fields kept through edits and merges (`UnknownFieldsTests`); upgrading in place from the version 1 engine's local state with an unacknowledged pass and a half-read journal; a fresh device waiting for the listing; two manifests resolving to one library; a deletion arriving while a device records into the conversation, two devices keeping the same deleted conversation, and audio installed before a deletion (`LibrarySyncDeletionTests`); a courier delivery whose sync-folder copy never arrives; recording activity in presence and settings-only passes; claims under clock skew and latency (`ProcessingRequestTests`); and random histories across an eager Mac, an on-demand iPhone, and the version 1 engine from fixed seeds (`LibrarySyncConvergenceTests`). DaybookKit's `LibrarySyncApplyTests` and `SyncDeviceIdentityTests` cover the same through `LibraryController` (status kept as synced, restore as a new conversation, edits during a pass, handoffs while recording, settings a newer version wrote) and the device identity (moving to the keychain, copied preferences, two devices sharing an ID); `LibrarySyncContainerTests` an account change during a long pass.

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

Two manifests resolve deterministically to the smallest library ID (above); only a conflict version that can't be read is surfaced. Unless the library is encrypted (see Encryption), sync adds no content encryption of its own; either way it doesn't replace independent backups.

## Apple references

- [Synchronizing documents in iCloud](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment): metadata can arrive before file contents; download readiness must be handled separately.
- [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html): coordinated document access, conflict versions, and container discovery.
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator): coordinated reads and writes with file presenters/providers.
- [Enabling iCloud Storage](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html): app-owned container access requires matching entitlements; a folder bookmark does not grant an app arbitrary container access.
- `CKSyncEngine` (CloudKit headers in the Xcode 27.1 SDK, `CKSyncEngine.h`): needs the CloudKit and remote-notification entitlements; retries network, rate-limit, and account errors itself; one engine per database in Production. Apple's sample: [sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine).
- [CloudKit Web Services Reference, "Data Size Limits"](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html): 1 MB per record, not counting assets; 50 MB per asset field.
