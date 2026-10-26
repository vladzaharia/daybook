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

To come with the sandboxed build: entitlements for it, a container migration manifest in signed sandboxed builds
only, ad hoc builds under their own bundle ID so they can never create or migrate the real container, a launch check
that offers **Move Library…** when the library didn't move, re-granting folders whose old bookmarks don't resolve,
and a process-tap probe.

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
