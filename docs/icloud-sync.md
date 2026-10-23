# iCloud library sync

Daybook keeps a complete local working library and exchanges changes through a private folder selected in iCloud Drive. Each Mac selects the same folder in Settings → Storage. The app retains that access with a security-scoped bookmark and reconciles while open, after metadata notifications, and every 30 seconds as a fallback. It works offline and resumes when files become available.

This preview uses the user's iCloud Drive folder rather than requiring an app-specific CloudKit account or a shared mutable database. A native ubiquity-container connection is also implemented for distribution builds that supply `DaybookICloudContainerIdentifier` and matching Apple provisioning/entitlements. The current signed preview does not claim a provisioned app container. It needs no server or Daybook account.

## What travels

Original audio and retained highlight sidecars, all source transcript runs and their model settings, unified transcripts, notes and timestamps, highlights, summaries, completed actions, speakers and available embeddings, correction history, folders, tags, template edits, and vocabulary records are synchronized. Active recordings finish locally first. The app's model weights, capture permissions, automatic-recording preference, and transient inference jobs are specific to each Mac. A remote processing indicator never pretends that an inference job is running locally.

Two devices receiving the same meeting identity reconcile their recordings and edits automatically. Independent recordings created as separate meetings are not automatically declared the same conversation based on dates. Attach additional audio to the intended meeting to align it; clock and text evidence then determine whether sources can be unified.

## Transport and durability

```text
Selected iCloud Drive folder/
  daybook-sync.json          # library identity and schema
  Events/<SHA-256>.json      # immutable meeting snapshots and deletion events
  Metadata/<SHA-256>.json    # immutable organization/template/vocabulary versions
  Blobs/<SHA-256>            # original audio and sidecar bytes
```

`NSFileCoordinator` coordinates access with the file provider. `NSMetadataQuery` requests updates for the selected tree. Evicted files trigger iCloud download requests and remain pending until readable. Files and event hashes are validated, relative paths cannot escape the library, symlinks are rejected, and a partially downloaded recording is not treated as an imported original. An uploaded local file is not assumed to have reached another Mac: upload and download counts remain visible.

Each Mac has its own durable checkpoint scoped to the shared library UUID and device identity. Events include causal parents. New local edits are published against the last applied revision, so seeing a remote event does not falsely make an offline edit its descendant. Pulling has two phases: return hydrated snapshots, then acknowledge only after the application saves all metadata successfully. Restarting between those phases offers the changes again. Failed local saves cannot advance the acknowledgment.

The app serializes sync with imports and defers it while capture or final inference is active. Notes edited while a transfer is in progress are rebased before applying remote changes. Account changes invalidate the pending sync receipt and disconnect the folder; reconnection is explicit. Changing folders is disabled through the durable apply phase.

## Conflicts and deletion

Independent changes are merged. Original tracks, model runs, and history remain additive. Concurrent edits to the same text or summary use a deterministic selected value and retain alternatives in History with a visible warning. This preserves work for review; it does not pretend to understand which wording the user intended. Folder/template/vocabulary records have per-item modification times and explicit deletion markers, so removing a term on one Mac does not silently resurrect it on another. Their immutable metadata versions also remain in the journal.

Deleting a conversation propagates a tombstone for that meeting UUID. Stale offline Macs cannot resurrect it. Current local files move into Daybook's Trash; earlier journal events and blobs remain recoverable. Consequently sync is not permanent erasure, and its journal is not currently compacted. Cloud storage grows with history.

To recover a synced deletion, restore the content under a **new meeting UUID**. Importing the preserved original audio from Trash creates a new conversation; notes and prior text can be copied from its retained `meeting.json` or journal snapshot. Moving the same UUID back into Meetings will encounter the existing tombstone. Local-only libraries can use `MeetingStore.restoreFromTrash` before that ID has ever been synchronized as deleted.

## Validation boundary

Automated tests use independent local libraries and a shared temporary filesystem transport. They cover byte-identical audio/sidecars, offline concurrent edits, organization, templates, vocabulary, restart before and after apply, deletion, damaged/missing objects, unsafe paths, and independent library identities. These exercise the same engine and application integration as iCloud, without uploading personal data.

Actual propagation through Apple's service on two physical Macs has not been exercised. Acceptance should include eviction, offline edits, account changes, quota exhaustion, very large recordings, and simultaneous first-time setup. Unresolved iCloud manifest conflicts are surfaced instead of silently choosing another library identity. Sync does not add its own content encryption or replace independent backups; local and iCloud protections are controlled by macOS and the user's account settings.

## Apple references

- [Synchronizing documents in iCloud](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment): metadata can arrive before file contents; download readiness must be handled separately.
- [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html): coordinated document access, conflict versions, and container discovery.
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator): coordinated reads and writes with file presenters/providers.
- [Enabling iCloud Storage](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingiCloud.html): app-owned container access requires matching entitlements; a folder bookmark does not grant an app arbitrary container access.
