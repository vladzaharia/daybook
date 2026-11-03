# Swift: core and kit

Audit of 2026-11-01 against main at 57ed5eb. 22 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| MSCQ-01 | medium | Two file-hash and copy loops have no autorelease pool, so memory grows with the file's size | `Sources/DaybookCore/AudioDigest.swift:22` | w2-sync | fixed |
| MSCQ-03 | medium | Sync status is a display string that both apps parse by prefix | `Sources/DaybookKit/LibrarySyncController.swift:175` | w1-observation | fixed |
| MSCQ-04 | medium | Photo writes go through a throwaway MeetingStore and skip the durability barrier | `Sources/DaybookKit/LibraryController+Photos.swift:38` | w2-core-data | fixed |
| MSCQ-05 | medium | Sync actors do long blocking file I/O on Swift's cooperative thread pool | `Sources/DaybookCore/LibrarySync.swift:82` | w2-sync | fixed |
| MSCQ-08 | medium | The iPhone's save-on-background assertion has no expiration handler | `Sources/DaybookKit/LibrarySaveQueue.swift:94` | w2-core-data | fixed |
| MSCQ-11 | medium | Conversation-info and failure-wording logic is copied between the Mac and iPhone apps, and the copies have drifted | `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift:116` | w1-shared-words | fixed |
| MSCQ-02 | low | A keychain read failure is treated as 'this device has no library key' | `Sources/DaybookCore/LibrarySyncSealing.swift:272` | w2-sync | fixed |
| MSCQ-06 | low | Large-library searches run on a detached task that is never cancelled | `Sources/DaybookKit/LibrarySearch.swift:136` | w2-core-data | fixed |
| MSCQ-07 | low | Saving a cloud API key deletes the old one, in iCloud Keychain, before the new one is added | `Sources/DaybookKit/Cloud/CloudKeyStore.swift:156` | w2-core-data | fixed |
| MSCQ-10 | low | Version History field keys are untyped strings, parsed with magic offsets in about 10 places | `Sources/DaybookCore/Models.swift:433` | w2-core-data | fixed |
| MSCQ-12 | low | DaybookKit mixes ObservableObject and @Observable, and the iPhone bridges between them with Combine | `Sources/DaybookKit/LibraryController.swift:14` | w1-observation | fixed |
| MSCQ-13 | low | LibrarySyncEngine.synchronize is a 367-line function on an actor with about 60 stored properties | `Sources/DaybookCore/LibrarySync.swift:233` | w2-sync | fixed |
| MSCQ-14 | low | Other functions and types are well over the size limit | `Sources/DaybookKit/LibrarySyncController.swift:922` | w2-sync | partial |
| MSCQ-15 | low | Ten hand-rolled lock classes could use Synchronization.Mutex, and two @unchecked Sendable conformances are unnecessary | `Sources/DaybookCore/DurableFiles.swift:102` | w2-core-data | fixed |
| MSCQ-16 | low | Dead public API, some of which contradicts documented rules | `Sources/DaybookKit/LibraryController+Requests.swift:71` | w2-core-data | fixed |
| MSCQ-17 | low | Hex encoding and entitlement reads are duplicated | `Sources/DaybookCore/SyncReplica.swift:426` | w2-sync | fixed |
| MSCQ-19 | low | LibraryController's conversation and vocabulary lists have public setters that skip saving | `Sources/DaybookKit/LibraryController.swift:16` | w1-observation | fixed |
| MSCQ-20 | low | Untyped save keys, and an unordered fire-and-forget write for the local work record | `Sources/DaybookKit/LibraryController.swift:255` | w2-core-data | fixed |
| MSCQ-21 | low | Sync maintenance failures are swallowed with no diagnostics | `Sources/DaybookCore/LibrarySyncCompaction.swift:295` | w2-sync | fixed |
| MSCQ-22 | low | Strict concurrency checking finds 6 warnings, and nothing prevents new ones | `Sources/DaybookCore/DurableFiles.swift:92` | w2-core-data | fixed |
| MSCQ-23 | low | Core and Kit tests bypass the shared temp-folder helper, duplicate RNGs, and sleep for fixed times | `Tests/DaybookKitTests/RecorderHandoffTests.swift:438` | w2-core-data | fixed |
| MSCQ-24 | low | LibrarySyncController's 30-second polling task outlives the controller, and its observers are never removed | `Sources/DaybookKit/LibrarySyncController.swift:1213` | w2-sync | fixed |

## Notes on partial fixes

- **MSCQ-14:** Done for my files. The controller is split into LibrarySyncController+Container.swift (container connector; prepareContainer is now checkAccount, waitForThisLibrary and attachContainer), +Encryption.swift (encryption control), and +Courier.swift with a real SyncCourierBridge type that owns the courier state. The core file is down from about 1,300 lines to about 890. The folder-account observer now calls detach(). resolveManifest is split into manifestCandidates plus a pure static resolved(from:). Container and encryption state stays in the controller because both apps observe it, so those two are extensions rather than separate objects. MeetingMerge.merge and LibraryController.applyPass belong to w2-core-data and are not touched; suggested split: mergeReceived/mergeMetadata in applyPass, and a FieldMerger struct for MeetingMerge.
