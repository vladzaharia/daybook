# iCloud and sync

Audit of 2026-11-01 against main at 57ed5eb. 15 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| icloud-1 | high | Turning on encryption (or rotating the key) doubles the library in iCloud, and retiring the old copy is all-or-nothing, so a full quota stalls it for good | `Sources/DaybookCore/LibrarySyncSealer.swift:649` | w2-sync | fixed |
| icloud-3 | high | A new device that finds the container empty (offline at first launch) starts a second encrypted library, and then sync pauses on every device with no way out | `Sources/DaybookCore/LibrarySync.swift:917` | w2-sync | fixed |
| icloud-5 | high | The iPhone has no way out of "account changed" and tells the person to try again later | `Apps/iOS/DaybookPhone/App/PhoneSync.swift:135` | w2-settings-sync-cloud | fixed |
| icloud-10 | medium | Every edit publishes the whole conversation: about 1.9 MB for an hour-long two-source call, after a 2-second pause | `Sources/DaybookCore/LibrarySync.swift:389` | w2-sync | fixed |
| icloud-11 | medium | The sync engine keeps two full copies of every conversation in memory, besides the app's own | `Sources/DaybookCore/LibrarySync.swift:555` | w2-sync | fixed |
| icloud-2 | medium | A full iCloud quota is never detected: the Mac says "Up to date" and the iPhone says "Uploading N items" forever, which also hides the courier's "iCloud storage is full" | `Sources/DaybookCore/LibrarySync.swift:1537` | w2-sync | fixed |
| icloud-4 | medium | Deleting Daybook's data from iCloud strands every device at "The library in iCloud is no longer encrypted" | `Sources/DaybookCore/LibrarySync.swift:796` | w2-sync | fixed |
| icloud-6 | medium | A manifest still in iCloud (every fresh install, or an evicted file) shows as "Sync paused" with an attention icon | `Sources/DaybookCore/LibrarySync.swift:784` | w2-sync | fixed |
| icloud-8 | medium | The sync checkpoint is written without fsync, and a checkpoint that won't decode stops sync for good | `Sources/DaybookCore/LibrarySync.swift:987` | w2-sync | fixed |
| icloud-9 | medium | The Mac keeps every recording twice on disk, and once macOS evicts the iCloud copy, editing that conversation re-downloads gigabytes before the edit syncs | `Sources/DaybookCore/LibrarySync.swift:1287` | w2-sync | fixed |
| icloud-13 | low | The cross-app account check ignores libraries started over and libraries this Mac was waiting to get the key for | `Sources/DaybookCore/LibrarySync.swift:1064` | w2-sync | fixed |
| icloud-14 | low | A crash mid-upload leaves partial .upload-* files in Blobs/ and Sealed/Blobs/ in iCloud forever | `Sources/DaybookCore/LibrarySync.swift:1303` | w2-sync | fixed |
| icloud-15 | low | The Mac runs a full pass and writes the checkpoint twice every 30 seconds even when nothing changed | `Sources/DaybookKit/LibrarySyncController.swift:1216` | w2-sync | fixed |
| icloud-16 | low | The courier stays off for the whole process if the first iCloud account check fails or can't decide | `Sources/DaybookKit/CloudKitCourier.swift:160` | w2-sync | fixed |
| icloud-7 | low | A device whose clock runs ahead silently reverts later edits to folders, templates, vocabulary, and recorder ownership on every device | `Sources/DaybookKit/LibraryController.swift:524` | w2-core-data | fixed |
