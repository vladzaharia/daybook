# The App Sandbox on the Mac

The owner decided, after a security review, to run the Mac app in the App Sandbox. Every capability Daybook uses maps to
an ordinary entitlement or to a permission macOS already asks for; nothing needs a temporary exception in a shipping
build, and the provisioning profile doesn't change. What makes it a project rather than a switch:

1. **The library moves, once.** A sandboxed app's `Application Support` is inside its container,
   `~/Library/Containers/local.daybook.app/Data/Library/Application Support/Daybook`. On the owner's Mac the library is
   about 21 GB, mostly models, and the move is one-way: the container is created once, by whichever build with the
   bundle ID launches sandboxed first.
2. **Process taps.** Recording only the call app uses a Core Audio process tap. Credible reports say taps work with
   `com.apple.security.device.audio-input` in the sandbox, but it isn't verified for Daybook (the probe below).
3. **File flows that break quietly** when the app can only read what the person chose.

So it ships in two steps:

- **Release N** (this code, unsandboxed): everything that has to be right *before* the switch. File flows that work
  sandboxed, an identity that survives the move, a way back, and debug flags that fail clearly.
- **Release N+1** (the switch): the sandboxed build, first as a GitHub prerelease, once the probe and a migration
  rehearsal pass on real hardware and the owner has used it for real calls, sync, and the Soundcore.

## What release N changes

| Area | Before | Now |
|---|---|---|
| Home folder | `NSHomeDirectory()` / `homeDirectoryForCurrentUser`, which the sandbox turns into the container | `UserHome` (DaybookCore) reads the account's home with `getpwuid`: iCloud Drive suggestions in open panels, the import folder's name, Settings' library path |
| Highlights sidecar | `call.highlights.json` beside an imported recording was read whenever it existed; unreadable, the whole import failed | read first; unreadable, the recording imports without it and a notice says to choose both files. The import panel accepts JSON, and a sidecar chosen or dropped with its recording pairs with it by name |
| Markdown export with photos | a save panel, then `<name> Photos/` created beside the file (not granted in the sandbox) | a folder panel (**Export Here**), `<title>.md` and `<title> Photos/` inside, never replacing anything (`<title> 2`, …). JSON and photo-free Markdown keep the save panel |
| Signed out vs. iCloud Drive off | the `MobileMeAccounts` preferences domain (forbidden in the sandbox) | CloudKit's account status for the app's container, only when the build is signed for CloudKit |
| Identity | the sync device ID (also the link's device ID) in a keychain item named after the library's folder | also recorded in `<library>/Sync/replica.json` with a digest of the Mac's hardware UUID, and restored when the library has moved on the same Mac (below) |
| `swift run` | opened the app's library | its own library, `~/Library/Application Support/Daybook Development` |
| Path flags | `--library`, `--snapshot`, `--models`, `--output`, `--audio`, `--evaluate` took any path | a sandboxed run stops at launch when a path is outside what it can reach, and says where it may write (`LaunchPaths`) |
| Going back | — | an unsandboxed build that finds the library in the sandboxed build's container offers to move it back (below) |

### Identity across the move

The sync device ID lives in a this-device-only keychain item named after the library's folder
(`SyncDeviceIdentityStore.keychain(for:)`), mirrored in preferences; the link's device ID is the same ID, so a phone
recognizes this Mac by it. Moving the library changes the folder, and a sandboxed app's preferences are in its
container. Without help the Mac would take a new device ID: a full (safe) republish of the library, and every paired
iPhone paired again.

`ReplicaIdentity` (Mac app) writes `Sync/replica.json` (never synchronized) after the library opens and when the app
quits: the sync device ID, the installation ID, the link device ID, the library's path, and a digest of the Mac's
hardware UUID (the UUID itself isn't stored). At launch, before sync reads its identity, a library whose path differs
from the one recorded, on the same Mac, gets that identity back: in the keychain item for its new folder (or
preferences, in builds without a keychain), and the link ID. A library copied to another Mac doesn't match the digest
and takes its own identity, as before; a library that hasn't moved keeps its live keychain item and preferences.

Sync itself never reads an empty or relocated library as deletions: deletions are only explicit (the Trash, or a
tombstone). `LibrarySyncRelocationTests` check that an empty library under a known device ID publishes no deletions,
and that a lost device ID republishes everything without deleting anything.

### Going back (`LegacyLibraryReturn`)

An unsandboxed build (an earlier release, or a later one built without the sandbox) whose own library is missing,
or older than the one in `~/Library/Containers/<bundle ID>/Data/Library/Application Support/Daybook`, asks before it
opens anything: **Move Library Back** or **Not Now**.

- Moving renames the container's library into place (same volume, instant). Anything already at the place is set
  aside as `Daybook (Older Copy <date>)`, never deleted, and put back if the move fails.
- The sandboxed app's own preferences are copied from its container (the system's window and panel state stays
  behind), then the app relaunches; `replica.json` brings the identity along.
- Not Now opens the library where it is, and the question comes back only once the container's library changes.
- Only the app's own library is considered: never `--library`, `swift run`, or tests.

## Capabilities and entitlements

| Capability | Code | In the sandbox |
|---|---|---|
| Microphone | `MicrophoneSource`, `RecordingController` | `com.apple.security.device.microphone` (and `device.audio-input`, which the hardened runtime already needs) |
| Call audio: process tap | `ProcessTapSource` (`CATapDescription`, `AudioHardwareCreateProcessTap`, a private aggregate device) | `device.audio-input`, `NSAudioCaptureUsageDescription`. Unverified sandboxed: run the probe |
| Call audio: ScreenCaptureKit fallback | `CaptureSources` | Screen & System Audio Recording permission (no entitlement) |
| Call detection | `MeetingDetection` (window list, Core Audio process list, `NSRunningApplication`) | none; window titles need Screen Recording, as now |
| Soundcore over Bluetooth | `SoundcoreTransport` | `com.apple.security.device.bluetooth` |
| Link to iPhone, Bonjour | `LinkService` | `com.apple.security.network.server` and `.client` |
| Model downloads | `ModelHubClient`, `ModelArtifactFetcher` | `com.apple.security.network.client` |
| iCloud Drive, CloudKit, push | sync, the courier | already entitled in signed builds |
| Keychain (link keys, sync identity) | `LinkKeyStore`, `SyncDeviceIdentityStore` | unchanged: the data-protection keychain's default access group is the app's identifier |
| Open and save panels, drops, paste | imports, Add Photo, export, the import folder, the development sync folder | `com.apple.security.files.user-selected.read-write`, `files.bookmarks.app-scope` |
| Metal, MLX, Core ML, Speech, Foundation Models, Vision, notifications, menu bar | | none |
| `Process` | the smoke test's `/usr/bin/say` | inherits the sandbox; its output goes to the container's temporary folder |

No login item, App Intents, Apple Events, XPC services, or helpers.

## Release N+1: the switch

### Builds

A container is created once, by whichever sandboxed build with the bundle ID launches first, and macOS moves files
into it (the container migration manifest) only then. So only one kind of build ever uses `local.daybook.app`
sandboxed, and only it carries the manifest that moves the real library:

| Build | Bundle ID | Sandboxed | Manifest | Library |
|---|---|---|---|---|
| Signed (Developer ID, Apple Development), the default | `local.daybook.app` | no | none | `~/Library/Application Support/Daybook` |
| Signed with `--sandbox` / `DAYBOOK_SANDBOX=1` (release only) | `local.daybook.app` | yes | `Resources/container-migration.plist`: moves `${ApplicationSupport}/Daybook` | the container's |
| Ad hoc (`--ad-hoc`, or no team) | `local.daybook.app.adhoc` | yes | none | its own container's, empty at first |
| Rehearsal (`--sandbox-rehearsal`) | `local.daybook.app.rehearsal` (or `DAYBOOK_REHEARSAL_BUNDLE_ID`) | yes | `Resources/container-migration-rehearsal.plist`: moves `${ApplicationSupport}/Daybook Rehearsal` to `${ApplicationSupport}/Daybook` | its own container's |
| `swift run`, `.build/debug/Daybook` | none | no | none | `~/Library/Application Support/Daybook Development` |

`Apps/macOS/Config/Signing.xcconfig` derives all of it from `DAYBOOK_SIGNING` (`signed`, `local`, `rehearsal`) and
`DAYBOOK_SANDBOX` (`NO` by default): `PRODUCT_BUNDLE_IDENTIFIER`, `CODE_SIGN_ENTITLEMENTS`, and
`DAYBOOK_MIGRATION_MANIFEST`. The target's "Embed container migration manifest" script copies the manifest into
`Contents/Resources/container-migration.plist` (after `plutil -lint`), or removes a stale one, before signing.

A container can't be fully removed from the command line: the files inside can, but macOS protects
`.com.apple.containermanagerd.metadata.plist`, and a container that still has it isn't created again (so its
manifest never runs again). Remove it in Finder, or rehearse again under a new `DAYBOOK_REHEARSAL_BUNDLE_ID`.

### Entitlements

`Resources/Daybook-Local.entitlements` (ad hoc and rehearsal builds) is sandboxed: `app-sandbox`, `device.audio-input`,
`device.microphone`, `device.bluetooth`, `network.client`, `network.server`, `files.user-selected.read-write`,
`files.bookmarks.app-scope`, and one temporary exception, read-write `/private/tmp/daybook/`, so the debug flags have a
place outside the container that a person can find (`--library /tmp/daybook/ui --snapshot /tmp/daybook/shots`).

`scripts/ci/check-mac-app.sh --app <app> --kind adhoc|rehearsal|signed|signed-sandbox` reads what was actually
signed: the bundle ID, every sandbox capability, the temporary exceptions (only that one, only in ad hoc and
rehearsal builds), and the manifest (none, the rehearsal's, or the real one). CI runs it on every ad hoc build;
`scripts/ci/tests/run-tests.sh` checks it against stand-in apps signed with the repository's entitlements files.

### Moving the library

macOS moves the library into the container once, through the manifest, when it creates the container. That's the
expected path, and it's a rename on the same volume. Everything else is the launch check's (`SandboxMigration`, at the
top of `AppState.init`, before anything writes preferences or sync resolves its identity), for the app's own library
in a sandboxed build:

1. `ReplicaIdentity` restores the identity of a library that moved (above). If sync's keychain item is still named
   after the old place, it's copied to the new folder's name: the item never leaves this Mac, so it's always this
   Mac's identity, even if `replica.json` predates the move.
2. The launch is classified from four facts: whether the old place (`~/Library/Application Support/Daybook`, which the
   sandbox can't read but can see) holds a library, whether the container's library holds anything (conversations,
   models, the Trash, settings), whether preferences show an earlier launch, and whether the identity was found.

| Outcome | When | What happens |
|---|---|---|
| `fresh` | nothing anywhere | a new library |
| `moved` | the library is in the container, nothing at the old place | nothing: the usual case after the manifest |
| `stillAtOldLocation` | the container's library is empty, and the old place has one or preferences say there was one | **Move Library…** before anything opens (below) |
| `bothPresent` | both have one | the container's opens; a sheet says the old copy is still readable by other apps (**Keep It** or **Show in Finder**), once |
| `identityMissing` | the library is in place but no identity was found | the library opens; sync takes a new ID (republishing, never deleting) and a notice says to pair the iPhone again if it can't find the Mac |

The outcome is recorded in preferences (`sandboxMigration`). **Move Library…** holds the library closed (no devices,
sync, iPhone link, or requests), then: an open panel beside the old place (the sandbox can read the old library only
once the person chooses it); an APFS clone of it into a hidden folder in the container, checked item by item (path,
kind, size) against the original, then renamed into place; an empty folder already there is replaced, one with
anything in it never is; the old library is only read. Then **Move to Trash** or **Keep It** for the old copy, and the
app starts over with the library in place. With nothing at the old place, **Start Fresh** opens a new library instead
of **Quit**.

### Folders chosen before the sandbox

Folders Daybook keeps access to are remembered with security-scoped bookmarks. One made by an unsandboxed build may
not open in the sandbox, so a plain bookmark of the same folder is kept beside it (release N writes it whenever the
scoped one opens), and still says where the folder is:

- **A recorder's import folder** (`ImportFolderWatcher`, key `location`): the device shows "Choose iCloud Drive ›
  Daybook Import again to keep importing", and Choose Folder… starts beside it.
- **The folder this Mac synced through before the iCloud container** (`LibrarySyncController`, `syncFolderLocation`):
  a folder that's there but can't be opened is `previousFolderAccessLost`, not "can't be found". Settings › Library
  offers **Choose Folder Again…** (an open panel where it was) or **Sync Without It…**; choosing it again replaces the
  bookmark and the move to iCloud goes ahead.
- The development sync folder (`-DaybookDevelopmentFolderSync YES`) says to reconnect it; Choose Folder… does.

## The process-tap probe

Whether Core Audio process taps work in the sandbox decides whether the switch keeps call-only capture. Debug builds
have a probe that runs the tap alone, records nothing, and reports each second's peak level:

```sh
./scripts/build-app.sh --ad-hoc --debug            # sandboxed, bundle ID local.daybook.app.adhoc
# Play something in Music (or join a test call), then:
dist/Daybook.app/Contents/MacOS/Daybook --capture-probe com.apple.Music --seconds 15 --output /tmp/daybook/probe.json
```

macOS asks for System Audio Recording the first time (for `local.daybook.app.adhoc`). The report says whether the
run was sandboxed, which processes the tap followed, and the peaks. Exit status 0 means audio was heard: taps work
sandboxed. 1 means the tap ran but heard only silence (the permission is off, or nothing played); 2 means it couldn't
start (`error` says why). Try a browser call too (`com.google.Chrome`, `com.apple.Safari`), whose audio comes from
helper processes. If taps don't work sandboxed, the switch still records calls, through ScreenCaptureKit (all Mac
audio), and docs/capture.md needs a note.

## Updates (Polaris / Sparkle)

The Polaris integration design (an untracked spec in the owner's checkout, `docs/superpowers/specs/2026-10-24-polaris-key-integration-design.md`)
assumes an unsandboxed app. A sandboxed app that updates with Sparkle needs Sparkle's installer launcher service
(`SUEnableInstallerLauncherService` in Info.plist) and `com.apple.security.temporary-exception.mach-lookup.global-name`
for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`
([Sparkle: Sandboxing](https://sparkle-project.org/documentation/sandboxing/)). Those are temporary exceptions, so
the entitlement checks below would have to allow exactly them. Nothing here implements Sparkle.

## References

- [Migrating your app's files to its App Sandbox container](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container)
- Apple Developer Forums threads 763674, 767586, 741479, and 742147 (container migration in practice), 848578
  (process taps in a sandboxed app)
