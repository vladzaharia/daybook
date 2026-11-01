# One app for iPhone and Mac (research, 2026-11-01)

The owner asked what it would take to ship the iPhone and Mac apps as one cross-platform app, so TestFlight and the App
Store carry both, then chose one bundle ID for everything: `local.daybook`. This is the record: what was there, the three
ways to do it, what was built on this branch, and what only the owner can do.

**Decision and recommendation.** Universal purchase with the two existing targets (option a), under one bundle ID,
`local.daybook`, for the iPhone app and every signed Mac build: the App Store and TestFlight build (sandboxed) and the
Developer ID download on GitHub (unsandboxed). One multiplatform target (b) buys nothing for distribution, and Mac Catalyst
or the iPhone app on a Mac (c) can't record calls. The code, scripts, checks, migration, and docs are on this branch; the
portal and App Store Connect steps are the owner's (docs/release.md, "One bundle ID"), and so is applying the
`release.yml` changes below, which this session wasn't allowed to make.

## Before

| | Mac | iPhone |
|---|---|---|
| Project | `Apps/macOS/project.yml` (XcodeGen), target `Daybook`, compiles `Sources/Daybook` in place; SwiftPM's `Daybook` executable stays for `swift build/test/run` | `Apps/iOS/project.yml`, targets `DaybookPhone`, `DaybookPhoneWidgets` (WidgetKit extension: Live Activity, controls, widgets), `DaybookPhoneTests` |
| Bundle IDs | `local.daybook.app` (signed); `local.daybook.app.adhoc` (ad hoc); `local.daybook.app.rehearsal…` (migration rehearsal); `swift run` none | `local.daybook.phone`; `local.daybook.phone.widgets`; tests `local.daybook.phone.tests` |
| App group | none | `group.local.daybook.phone` (the widgets' recording state) |
| Keychain groups | `<team>.local.daybook.app` first (pairing keys, sync identity), `<team>.local.daybook.shared` (library and cloud keys, iCloud Keychain) | `<team>.local.daybook.phone` first, `<team>.local.daybook.shared` |
| iCloud | `iCloud.local.daybook`: iCloud Documents (the journal) and CloudKit (the courier); push for `CKSyncEngine` | the same container and services; push |
| Other entitlements | hardened runtime, audio input; ad hoc builds sandboxed (`Daybook-Local.entitlements`); signed builds sandboxed only with `--sandbox` (`Daybook-Sandbox.entitlements`, never shipped) | Hotspot (Soundcore Wi‑Fi transfer); background modes audio, bluetooth-central, fetch, remote-notification, processing; Live Activities |
| Signing and distribution | Developer ID (cloud signing fails for a team key, so a `.p12` and the manually managed "Daybook Developer ID" profile), notarized, GitHub Release | automatic signing with the Admin API key, cloud-managed Apple Distribution, TestFlight in the App Store Connect record `local.daybook.phone` |

## Now

| Build | Bundle ID |
|---|---|
| iPhone app / widgets / tests | `local.daybook` / `local.daybook.widgets` / `local.daybook.tests` |
| Mac: Developer ID (unsandboxed), App Store and TestFlight (sandboxed, `--app-store`) | `local.daybook` |
| Mac: ad hoc / rehearsal | `local.daybook.adhoc` / `local.daybook.rehearsal…` (distinct, so they never create the app's container) |
| App group | `group.local.daybook` |
| Keychain groups | `<team>.local.daybook` first on both; then `<team>.local.daybook.app` (Mac) or `<team>.local.daybook.phone` (iPhone), so the old apps' items stay readable; then `<team>.local.daybook.shared` |
| iCloud container | `iCloud.local.daybook`, unchanged |

## The options

| | (a) Universal purchase, two targets | (b) One multiplatform target | (c) Mac Catalyst, or the iPhone app on a Mac |
|---|---|---|---|
| What it is | The Mac target and the iPhone target share a bundle ID and upload to one record, one platform each | One target with supported destinations iPhone and Mac; each destination compiles its own sources | The iPhone app's UIKit/SwiftUI code running on the Mac |
| Project | Unchanged: two specs, or one spec including both (prototyped) | One target, nearly every setting conditioned on the SDK (prototyped) | A new Catalyst port, or a checkbox in App Store Connect |
| Uploads | Two builds per release, one per platform, one record | Still two: an archive is per platform | One |
| Bundle ID | `local.daybook` | the same | the same |
| Existing installs | Mac: carried over in place (built here). iPhone: a new app; the library returns through iCloud | the same work | No Mac library at all: it's the iPhone app |
| Records calls | yes | yes | no: process taps, ScreenCaptureKit, meeting detection are AppKit/Core Audio and Mac-only |
| Developer ID alongside | yes, as `local.daybook` | yes | n/a |
| Cost | Done here, plus the owner's portal steps | (a)'s cost, plus restructuring two build scripts, CI caches, and the specs for no distribution gain | A rewrite of the Mac app |

### (a) Universal purchase, two targets

Apple: platforms added to a record use its bundle ID and SKU, "you must upload the builds for macOS … from a separate
Xcode target", and "set the bundle IDs to match the iOS app's bundle ID"; each platform keeps its own version numbers and
builds; separate records can't be merged; once App Review approves two platforms, a platform can't be removed
([Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)). Native AppKit
apps qualify ([forum 751188](https://developer.apple.com/forums/thread/751188)).

- **The bundle ID.** A record's bundle ID can't change after its first upload, so universal purchase meant either the
  iPhone's `local.daybook.phone` for the Mac too, or a new record. The owner chose a new record under `local.daybook`
  for everything. The Mac then has one identity everywhere: one preferences domain, one container when sandboxed, the
  same ID for the Developer ID download and the App Store build. The cost is on the iPhone, which becomes a new app to iOS
  ("What carries over"), and a retired record.
- **Project.** No restructuring. `Apps/macOS/Config/Signing.xcconfig` makes every signed build `local.daybook`;
  `scripts/build-app.sh --app-store` archives the sandboxed build and exports it with the `app-store-connect` method (a
  `.pkg`), `--upload` sends it; `asc-testflight.sh --platform MAC_OS` finds the Mac's builds in the shared record.
- **Sandbox.** The Mac App Store requires it (guideline 2.4.5(i)), and TestFlight requires an embedded provisioning profile
  (ITMS-90889; automatic signing embeds one) ([TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
  [forum 733942](https://developer.apple.com/forums/thread/733942)). The existing sandbox path covers it:
  `Daybook-Sandbox.entitlements` already has everything (sandbox, microphone, Bluetooth, network client and server,
  user-selected files, bookmarks, iCloud, push, keychain groups) and no temporary exceptions, and `SandboxMigration`,
  `ReplicaIdentity`, and `LegacyLibraryReturn` already handle the library's move.
- **Entitlements.** No conflict. `local.daybook` needs iCloud (`iCloud.local.daybook`, CloudKit), Push, App Groups,
  Hotspot, and, for the iPhone's summaries, Increased Memory Limit and Background GPU Access. The Mac's entitlements
  claim none of App Groups, Hotspot, or the last two, and Mac profiles only carry what applies to macOS (expected;
  unverified until the first Mac profile for `local.daybook` exists). The Mac's push key is
  `com.apple.developer.aps-environment`, the iPhone's `aps-environment`.
- **Keychain.** Profiles grant `keychain-access-groups` = `<team>.*` (the Developer ID profile did; unverified for a Mac
  App Store profile, which the owner's steps check). Reads look in every group an app lists and writes go to the first,
  so listing the old group after the new one keeps every old item readable and moves it on its next write (the sync
  identity store deletes and adds; the link's store updates in place).
- **App Review** (Mac and iPhone together; [guidelines](https://developer.apple.com/app-store/review/guidelines/)):
  - *Model downloads.* 2.4.5(iv) bars Mac App Store apps from downloading "code, or resources to add functionality",
    and 4.2.3(ii) asks to "disclose the size of the download and prompt users" before downloads an app needs at launch.
    Weights are data and every model download already shows its size and waits for the person, but a reviewer could
    read 2.4.5(iv) strictly. The most likely question at review.
  - *Recording.* 2.5.14: explicit consent and a clear indication while recording. Automatic recording on detected calls,
    and recording the other side of a call, are what a reviewer will ask about; the review notes should explain the
    preference and the indicators.
  - *Cloud keys.* No guideline bars the person's own Anthropic or OpenAI key. 5.1.2(i): apps "must clearly disclose where
    personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before
    doing so": the cloud summary setting has to say so plainly and stay off until the person turns it on (docs/cloud.md).
  - *Updates.* 2.4.5(vii): App Store builds can't carry their own updater, so Sparkle or Polaris (docs/sandbox.md,
    "Updates") stay in the Developer ID build.
  - *iPhone background modes and Hotspot* went through TestFlight's review under the old record (2.5.4: each for its
    purpose: recording, Soundcore, sync, CloudKit pushes, processing). The new record's first external build goes
    through Beta App Review again.
- **MLX, Metal, weights.** Unaffected: the metallib is built into the app, MLX compiles kernels at run time (allowed in
  the sandbox, no JIT entitlement), and Mac models live in the library's `Models`, which moves with it (about 21 GB on
  the owner's Mac, a rename on the same volume). The iPhone downloads its models again.
- **Widgets.** The extension stays iPhone-only, as `local.daybook.widgets`. A Mac widget would be a new macOS extension.
- **Developer ID alongside.** Yes, as `local.daybook`, unsandboxed, notarized, with its own updater if one ships.
  `SingleInstance` keeps it and the App Store build from running at once; moving between them moves the library. Whether
  macOS keeps privacy permissions across the two differently signed copies of one bundle ID is unverified.

### (b) One multiplatform target

Prototyped as `DaybookOne` in `Apps/Universal/project.yml` (commit `1939cc5`): `supportedDestinations: [iOS, macOS]`,
each app's sources behind `destinationFilters`, the widget embedded for iOS only. It builds for the Mac (ad hoc) and the
Simulator. What it took:

- XcodeGen writes `PRODUCT_BUNDLE_IDENTIFIER` (from `bundleIdPrefix` and the target name) and `INFOPLIST_FILE` (the first
  Info.plist it finds: the iPhone's, for both SDKs) at the target level, above any xcconfig. Both had to be conditioned
  on the SDK in the spec itself.
- The iPhone's Info.plist and entitlements, which its own spec names through `info` and `entitlements`, landed in the
  resources ("Multiple commands produce …/Info.plist") until excluded.
- Build phases have no destination filter, so the Mac's icon, notices, and manifest scripts each check `PLATFORM_NAME`.
- Entitlements, signing style and identity, icon, hardened runtime, versions, and product name all differ by SDK.

The shared code is already the Swift package; the two apps share no app-target sources. So (b) is the two apps behind
one target name, still archived and uploaded once per platform, with every difference moved into conditional settings,
and `build-app.sh`, `build-ios.sh`, CI's caches, and the checks merged for it. No distribution benefit over (a).

### (c) Mac Catalyst, or the iPhone app on a Mac

- **What the Mac app needs that isn't there:** Core Audio process taps (`CATapDescription`,
  `AudioHardwareCreateProcessTap`, a private aggregate device: `ProcessTapSource`), the ScreenCaptureKit fallback, call
  detection from the window list, `NSRunningApplication`, and Core Audio's process list (`MeetingDetection`), the
  floating notes panel, open and save panels, WhisperKit and MLXVLM (Mac-only products in `Package.swift`), and the whole
  AppKit interface. Catalyst would mean rebuilding the Mac app in UIKit with AppKit plug-ins for each of these.
- **The iPhone app on a Mac** ("Designed for iPhone") is on by default for iPhone apps on Apple silicon Macs
  ([Manage availability](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon/)).
  It would be a phone-sized window that records only the Mac's microphone, without Hotspot, Live Activities, or call
  audio, and it would run as `local.daybook` in `~/Library/Containers/local.daybook`, the Mac App Store build's
  container, with an iPhone replica's library where the Mac app keeps its own. The owner's steps turn it off; once a
  record's macOS platform ships, Apple replaces the iPhone app on Macs with the Mac app anyway.

## What carries over

**The Mac, in place** (a `local.daybook.app` release updated to `local.daybook`):

| What | How | Where |
|---|---|---|
| Library | `~/Library/Application Support/Daybook` doesn't depend on the bundle ID. Sandboxed, the manifest moves it into `local.daybook`'s container, else **Move Library…** | `SandboxMigration.legacyFolderName` counts both IDs; `LegacyLibraryReturn` looks in both IDs' containers |
| Preferences | copied once at launch, before anything reads a setting, from the `local.daybook.app` domain, when `local.daybook`'s shows no earlier use; the earlier domain is only read. Sandboxed, the manifest moves `local.daybook.app.plist` into the container under its own name first | `PreferencesCarryOver` (called from `DaybookEntry`), `Resources/container-migration.plist` |
| Pairing keys, sync identity | read through `<team>.local.daybook.app`, listed after the new group | `Resources/Daybook.entitlements`, `Daybook-Sandbox.entitlements` |
| Library and cloud keys | `<team>.local.daybook.shared`, unchanged | |
| iCloud container | the same | |
| iCloud account | iCloud's token is per app ([WWDC 2012 session 209 notes](https://wwdcnotes.com/documentation/wwdc12-209-icloud-storage-overview/); unverified here), so the carried-over token reads as another app's. The token records its app now; another app's is the same account when the container's manifest names a library this device has a checkpoint for. A manifest still in iCloud is asked for while sync says "Connecting to iCloud…" | `LibrarySyncController.prepareContainer`, `LibrarySyncEngine.journalOwnership`, docs/icloud-sync.md |
| One copy at a time | `local.daybook` running `Daybook`, and earlier releases, ad hoc builds, and rehearsals under either set of IDs | `AppIdentity.isMacApp`, `SingleInstance` |
| Privacy permissions, window state | follow the bundle ID: asked again once | |

Going back to a `local.daybook.app` release: the library and that release's own preferences are where they were; pairings
made since, and a sync identity written since, are in `<team>.local.daybook`, which it can't read.

**The iPhone** is a new app to iOS, which can't read another app's sandbox. The library returns through iCloud, keys
through the shared group and iCloud Keychain, and the old app's identity and pairing keys through
`<team>.local.daybook.phone`, so the Mac sees the same iPhone. Not carried over: unsynced recordings, live captions, the
list of recordings brought in on the phone, the phone's own settings, downloaded models, and Home Screen widgets and
controls (docs/iphone.md, "Moving to the new app"). Testers let the old app finish syncing, delete it, then install the
new one. A last release of the old app could hand what doesn't sync to the new one through the app group
`group.local.daybook`; that's described there and not built.

Tests: `PreferencesCarryOverTests`; `SandboxMigrationTests.testTheAppStoreBuildTakesTheLibraryFromAnEarlierRelease`;
`LibraryMoveTests.testTheLibraryComesBackFromAnEarlierSandboxedBuild` and `testWithTwoContainersTheNewerLibraryComesBack`;
`SingleInstanceTests`; `LibrarySyncContainerTests.testAnotherAppsAccountCarriesOverWhenTheContainerHoldsThisLibrary`,
`testAnotherAppsAccountWaitsForTheManifestInsteadOfPausing`, and `testAnotherAppsAccountWithAnotherLibraryOrTheSameAppPauses`;
`scripts/ci/tests/run-tests.sh` for the IDs in every check, `--app-store`, the manifest, and `asc-testflight.sh --platform`.

### The review finding: a manifest still in iCloud

The first version of the cross-app account check (`48d52dc`) read a manifest that wasn't downloaded yet as "not this
library" and paused with "Sync paused: the iCloud account changed". On a fresh App Store install, or the first launch after
the ID change, the manifest may well still be in iCloud, and that pause invites Sync with This Account, which forgets an
encrypted library. Now (`LibrarySyncEngine.journalOwnership`): a manifest in iCloud is asked for and sync keeps
"Connecting to iCloud…", checking again every `retryInterval`; it pauses only when the manifest, once here, names another
library, or when no manifest turns up at all within 24 checks (about two minutes), which an account that synced this
library wouldn't show.

## Prototypes and probes

All local: ad hoc, unsigned, or the Simulator, with Xcode 27.2 (27B52) and XcodeGen 2.45.4 on macOS 27.0. Nothing was
signed with a team, uploaded, or launched except the probes, under bundle IDs of their own.

| What | Result |
|---|---|
| `Apps/Universal/project.yml`: one spec including both apps' specs | Builds the Mac target (ad hoc, 75 s) and the iPhone app with its widget (Simulator, 130 s). The merged project-level settings collide, the later include winning (`ENABLE_USER_SCRIPT_SANDBOXING` Mac NO / iPhone YES, `MARKETING_VERSION`, each app's xcconfig), so each app needs them back at the target level; and XcodeGen's intermediate groups gave one "Apps" group two parents, which Xcode refuses to open, until turned off |
| The Mac target as the App Store kind | Builds unsigned with the manifest embedded |
| `DaybookOne`, one multiplatform target | Builds for the Mac and the Simulator after the fixes under (b); the Simulator build embeds the widget, the Mac build doesn't |
| Probe 1: a sandboxed ad hoc app, `local.daybook.research.manifest1`, whose manifest moves a library under another name and `local.daybook.research.source.plist` to `${BundleId}.plist` | On first launch macOS moved both, `UserDefaults.standard` read the moved values, and both sources were gone |
| Probe 2: `local.daybook.research.manifest2`, whose manifest lists `${BundleId}.plist` (absent), `local.daybook.research.source2.plist` (moved under its own name), and a library | macOS skipped the absent item and moved the rest; in the sandbox, `UserDefaults.standard.persistentDomain(forName: "local.daybook.research.source2")` and `UserDefaults(suiteName:)` both read the moved domain. That's how the App Store build reads `local.daybook.app`'s preferences |

Each probe leaves its container's protected metadata file (29 KB) in `~/Library/Containers`, as docs/sandbox.md
describes. The prototype project is commit `1939cc5`, removed in `c7fa98a`; build it from there with
`Apps/Universal/build-research.sh generate|mac|mac-store|phone|one-mac|one-phone`.

## release.yml

Not applied: this session's permission rules refused edits to the release workflow, so it's the owner's (or the lead's)
to apply. It changes the iPhone job's three `--bundle-id` arguments to `local.daybook`, adds the `mac_testflight` input
(and the `DAYBOOK_MAC_TESTFLIGHT` repository variable) and a `mac-testflight` job behind the same `release` environment
with the secrets the `iphone` job already uses (no new ones), and fixes a comment in `ci.yml`. It applies cleanly to
this branch (`git apply --check`) and passes `actionlint` with the repository's config.

```diff
--- a/.github/workflows/release.yml
+++ b/.github/workflows/release.yml
@@ -1,5 +1,7 @@
 # Releases Daybook: the iPhone app to TestFlight, and the Mac app as a Developer ID signed, notarized
-# download on a GitHub Release. Runs for a pushed v* tag, or by hand from main or a v* tag.
+# download on a GitHub Release; with mac_testflight (or the DAYBOOK_MAC_TESTFLIGHT variable), the Mac app
+# also goes to TestFlight. Both apps are one App Store Connect app, local.daybook (docs/release.md, "One
+# bundle ID"). Runs for a pushed v* tag, or by hand from main or a v* tag.
 # Signing jobs wait for approval in the `release` environment, which holds every secret.
 # docs/release.md covers the setup, the secrets, and how to cut a release.
 name: Release
@@ -30,6 +32,10 @@
         description: Mac app in the App Sandbox (docs/sandbox.md). Its first launch moves the library; always a prerelease
         type: boolean
         default: false
+      mac_testflight:
+        description: Also send the Mac app to TestFlight (docs/release.md, "One bundle ID")
+        type: boolean
+        default: false
 
 permissions: {}
 
@@ -81,6 +87,7 @@
       sandbox: ${{ steps.sandbox.outputs.sandbox }}
       iphone: ${{ steps.apps.outputs.iphone }}
       mac: ${{ steps.apps.outputs.mac }}
+      mac_testflight: ${{ steps.apps.outputs.mac_testflight }}
       testflight_group: ${{ steps.apps.outputs.testflight_group }}
     steps:
       - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
@@ -138,10 +145,14 @@
           created="$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq .created_at)"
           [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || { echo "::error::Unexpected creation time '$created'"; exit 1; }
           echo "created_at=$created" | tee -a "$GITHUB_OUTPUT"
+      # The Mac on TestFlight: a manual run's mac_testflight input, or the DAYBOOK_MAC_TESTFLIGHT
+      # repository variable (true) for every run that releases the Mac app.
       - name: Apps and TestFlight group
         id: apps
         env:
           APPS: ${{ inputs.apps || 'both' }}
+          MAC_TESTFLIGHT_INPUT: ${{ inputs.mac_testflight == true }}
+          MAC_TESTFLIGHT_DEFAULT: ${{ vars.DAYBOOK_MAC_TESTFLIGHT }}
           GROUP_INPUT: ${{ inputs.testflight_group }}
           GROUP_DEFAULT: ${{ vars.DAYBOOK_TESTFLIGHT_GROUP }}
         run: |
@@ -151,11 +162,16 @@
             mac) iphone=false; mac=true ;;
             *) echo "::error::Unknown apps choice $APPS"; exit 1 ;;
           esac
+          mac_testflight=false
+          if [[ "$mac" == true && ( "$MAC_TESTFLIGHT_INPUT" == true || "$MAC_TESTFLIGHT_DEFAULT" == true ) ]]; then
+            mac_testflight=true
+          fi
           group="${GROUP_INPUT:-$GROUP_DEFAULT}"
           if [[ "$group" == none ]]; then group=""; fi
           {
             echo "iphone=$iphone"
             echo "mac=$mac"
+            echo "mac_testflight=$mac_testflight"
             echo "testflight_group=$group"
           } | tee -a "$GITHUB_OUTPUT"
       - name: Release notes
@@ -241,7 +257,7 @@
           ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
           ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
         run: |
-          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook.phone \
+          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook \
             --version "$VERSION" --find-build "$BUILD_CANDIDATES" --uploaded-after "$RUN_CREATED_AT" | sed -n 's/^found=//p')"
           echo "build=$found" >> "$GITHUB_OUTPUT"
           if [[ -n "$found" ]]; then
@@ -275,7 +291,7 @@
           ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
           ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
         run: |
-          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook.phone \
+          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook \
             --version "$VERSION" --find-build "$BUILD_CANDIDATES" --uploaded-after "$RUN_CREATED_AT" | sed -n 's/^found=//p')"
           if [[ -n "$found" ]]; then
             echo "BUILD=$found" >> "$GITHUB_ENV"
@@ -290,7 +306,7 @@
           ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
           GROUP: ${{ needs.prepare.outputs.testflight_group }}
         run: |
-          args=(--bundle-id local.daybook.phone --version "$VERSION" --build "$BUILD"
+          args=(--bundle-id local.daybook --version "$VERSION" --build "$BUILD"
                 --notes-file notes/testflight.txt --timeout 3600)
           if [[ -n "$GROUP" ]]; then args+=(--group "$GROUP"); fi
           scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh "${args[@]}"
@@ -463,6 +479,135 @@
           retention-days: 14
           if-no-files-found: ignore
 
+  # The Mac App Store build (scripts/build-app.sh --app-store): sandboxed, local.daybook, the macOS platform
+  # of the same App Store Connect app as the iPhone's. The iphone job's steps with the Mac's archive. The
+  # GitHub Release doesn't wait for it.
+  mac-testflight:
+    name: Mac to TestFlight
+    needs: [prepare, validate]
+    if: needs.prepare.outputs.mac_testflight == 'true'
+    runs-on: xcode-27
+    timeout-minutes: 150
+    environment: release
+    permissions:
+      contents: read
+    env:
+      DAYBOOK_TEAM_ID: ${{ vars.DAYBOOK_TEAM_ID }}
+      VERSION: ${{ needs.prepare.outputs.marketing_version }}
+      RUN_CREATED_AT: ${{ needs.prepare.outputs.run_created_at }}
+    steps:
+      - name: Check the configuration
+        run: |
+          if [[ ! "$DAYBOOK_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
+            echo "::error::Set the DAYBOOK_TEAM_ID repository variable (scripts/ci/setup-github.sh)."; exit 1
+          fi
+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        with:
+          persist-credentials: false
+      # The iphone job's numbers: each platform has its own builds in the record.
+      - name: Build number for this attempt
+        env:
+          REF: ${{ github.ref }}
+          RUN_NUMBER: ${{ github.run_number }}
+          RUN_ATTEMPT: ${{ github.run_attempt }}
+          OFFSET: ${{ vars.DAYBOOK_BUILD_NUMBER_OFFSET || '1000' }}
+        run: |
+          numbers="$(scripts/ci/version.sh --ref "$REF" --version "$VERSION" --run-number "$RUN_NUMBER" \
+            --run-attempt "$RUN_ATTEMPT" --offset "$OFFSET" | grep '^build_')"
+          printf '%s\n' "$numbers"
+          {
+            echo "BUILD=$(printf '%s\n' "$numbers" | sed -n 's/^build_number=//p')"
+            echo "BUILD_CANDIDATES=$(printf '%s\n' "$numbers" | sed -n 's/^build_candidates=//p')"
+          } >> "$GITHUB_ENV"
+      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
+        with:
+          name: release-notes
+          path: notes
+      - name: Select Xcode
+        run: scripts/ci/select-xcode.sh --metal --expect-build "$DAYBOOK_RELEASE_XCODE_BUILD"
+      - name: Install XcodeGen
+        run: scripts/ci/install-xcodegen.sh
+      - name: Look for this run's Mac build in App Store Connect
+        id: earlier
+        env:
+          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
+          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
+          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
+        run: |
+          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook --platform MAC_OS \
+            --version "$VERSION" --find-build "$BUILD_CANDIDATES" --uploaded-after "$RUN_CREATED_AT" | sed -n 's/^found=//p')"
+          echo "build=$found" >> "$GITHUB_OUTPUT"
+          if [[ -n "$found" ]]; then
+            echo "BUILD=$found" >> "$GITHUB_ENV"
+            echo "::notice title=Already uploaded::Daybook for Mac $VERSION ($found) is in App Store Connect from an earlier attempt; skipping the archive and upload"
+          fi
+      # Package checkouts and manifests run before any secret exists.
+      - name: Fetch the packages at their pinned versions
+        if: steps.earlier.outputs.build == ''
+        run: scripts/build-app.sh --resolve-only
+      # As the mac job's archive: the API key exists for this step only (docs/release.md, "Secrets on the runner").
+      - name: Archive the App Store build
+        if: steps.earlier.outputs.build == ''
+        env:
+          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
+          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
+          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
+          DEVELOPMENT_P12_BASE64: ${{ secrets.DEVELOPMENT_P12_BASE64 }}
+          DEVELOPMENT_P12_PASSWORD: ${{ secrets.DEVELOPMENT_P12_PASSWORD }}
+        run: |
+          scripts/ci/secrets.sh run -- scripts/build-app.sh --app-store --archive-only \
+            --marketing-version "$VERSION" --build-number "$BUILD"
+      # Sandboxed as local.daybook, with the manifest that moves the library and preferences, and nothing else.
+      - name: Check the archive
+        if: steps.earlier.outputs.build == ''
+        run: scripts/ci/check-mac-app.sh --app build/macOS/Daybook.xcarchive/Products/Applications/Daybook.app --kind signed-sandbox
+      - name: Export and upload to App Store Connect (unless the build is there already)
+        if: steps.earlier.outputs.build == ''
+        env:
+          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
+          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
+          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
+        run: |
+          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook --platform MAC_OS \
+            --version "$VERSION" --find-build "$BUILD_CANDIDATES" --uploaded-after "$RUN_CREATED_AT" | sed -n 's/^found=//p')"
+          if [[ -n "$found" ]]; then
+            echo "BUILD=$found" >> "$GITHUB_ENV"
+            echo "::warning title=Upload skipped::Daybook for Mac $VERSION ($found) is already in App Store Connect; not uploading it again"
+          else
+            scripts/ci/secrets.sh run -- scripts/build-app.sh --app-store --upload --export-only
+          fi
+      - name: Wait for processing, set What to Test, add to the beta group
+        env:
+          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
+          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
+          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
+          GROUP: ${{ needs.prepare.outputs.testflight_group }}
+        run: |
+          args=(--bundle-id local.daybook --platform MAC_OS --version "$VERSION" --build "$BUILD"
+                --notes-file notes/testflight.txt --timeout 3600)
+          if [[ -n "$GROUP" ]]; then args+=(--group "$GROUP"); fi
+          scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh "${args[@]}"
+          where=""
+          if [[ -n "$GROUP" ]]; then where=" in the beta group \"$GROUP\""; fi
+          {
+            echo "### TestFlight (Mac)"
+            echo "Daybook for Mac $VERSION ($BUILD) is on TestFlight${where}."
+          } >> "$GITHUB_STEP_SUMMARY"
+      # A backstop: every secret is already gone unless a step was killed.
+      - name: Remove secrets
+        if: always()
+        run: scripts/ci/secrets.sh cleanup
+      - name: Upload logs
+        if: failure()
+        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
+        with:
+          name: mac-testflight-logs
+          path: |
+            build/macOS/ExportOptions.plist
+            build/macOS/DerivedData/Logs/
+          retention-days: 14
+          if-no-files-found: ignore
+
   # The GitHub Release starts as a draft as soon as the Mac app is packaged, and becomes public only
   # once every app the run releases is out (`publish`). Neither job holds Apple secrets.
   draft:
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -333,7 +333,7 @@
           metallib="$(find "$app" -name default.metallib -print -quit)"
           test -n "$metallib" || { echo "::error::No MLX default.metallib in the app: the Metal shaders weren't compiled"; exit 1; }
           echo "Metal library: $metallib"
-          # Sandboxed, as local.daybook.app.adhoc, with no migration manifest: an ad hoc build can never create the
+          # Sandboxed, as local.daybook.adhoc, with no migration manifest: an ad hoc build can never create the
           # app's container or move a library into it (docs/sandbox.md).
           scripts/ci/check-mac-app.sh --app "$app" --kind adhoc
       - name: Save derived data
```

`publish` doesn't wait for `mac-testflight`: the GitHub Release is the Developer ID download. One uncertainty: the export
signs the `.pkg` with a Mac Installer Distribution certificate. If cloud signing doesn't offer one to the team API key (as
it doesn't offer Developer ID; a recent report says the same for Mac App Store exports,
[clipboardManager PR 4](https://github.com/walhallaa/clipboardManager/pull/4)), the fallback is the Developer ID one's: a
`.p12` and a manual export, which means new secrets, the owner's call.

**Until the owner's steps are done, the next tagged release fails.** CI passes. With `release.yml` as it is, the `iphone`
job fails at "Archive DaybookPhone with its widget extension" if automatic signing can't register `local.daybook` and
`local.daybook.widgets` with their capabilities through the API key (unverified whether it can), and otherwise at
"Export and upload to App Store Connect", with no app record for `local.daybook`; the `mac` job fails at "Export with
Developer ID", where `asc-profile.sh` finds no Developer ID profile for `local.daybook` (or at "Archive", likewise).
With the changes above applied and no record yet, the `iphone` job's "Look for this run's build in App Store Connect"
fails first, before anything is archived. `draft` and `publish` never run, so nothing is released.

## Steps, effort, risks

1. **Done on this branch:** one bundle ID in both specs, the xcconfig, the entitlements, and every check; the Mac's
   carry-over of preferences, keychain, iCloud account, and library, with tests; the manifest wait; `--app-store`;
   `asc-testflight.sh --platform`; export compliance in the Mac's Info.plist; the docs.
2. **The owner's portal and App Store Connect steps**, in order (docs/release.md, "One bundle ID"): register
   `local.daybook` and `local.daybook.widgets` and `group.local.daybook`; capabilities; the new record with iOS and macOS;
   the Developer ID profile and the Mac App Store profile; apply the `release.yml` changes; TestFlight groups and a first
   release; retire `local.daybook.phone`.
3. **The sandbox's hardware checks** (docs/sandbox.md): the process-tap probe and the rehearsal, then the first TestFlight
   build on the real library, after a backup.
4. **Fix what the first uploads report**, most likely the Mac's icon or the privacy manifests (below).

Effort: the code is done. The owner's steps are an afternoon if nothing is rejected, a day if the icon, the installer
certificate, or review needs work. App Review's first pass on the Mac is the long pole.

**Risks.**

- *A container made too early.* Any sandboxed launch as `local.daybook` on a Mac before the manifest-carrying build (a
  sandboxed debug build, or the iPhone app installed on the Mac through TestFlight) creates the container, and macOS then
  never runs the manifest there. The launch check's **Move Library…** covers the library (tested), but settings start
  over then. `build-app.sh` refuses sandboxed Debug builds; turning off the iPhone app on Macs covers the other.
- *Testers on two iPhone apps.* The old and new apps would sync as the same iPhone. docs/iphone.md says to delete the old
  one once it's synced.
- *The icon.* The Mac ships `Daybook.icns` (all sizes to 512@2x) through `CFBundleIconFile`, with an asset catalog that
  has no AppIcon. Reports say App Store processing wants the icon in the asset catalog with `CFBundleIconName`
  (ITMS-90546; [example](https://github.com/hjl1045/keyopen/pull/32), [forum 86904](https://developer.apple.com/forums/thread/86904)).
  Unverified for this bundle. The fix, if needed: a Mac AppIcon set from `scripts/make-icon.swift`.
- *Privacy manifests.* Neither app has a `PrivacyInfo.xcprivacy`, and both use required-reason APIs (`UserDefaults`, file
  timestamps, disk space). App Store Connect has warned iOS uploads since 2024 (ITMS-91053); enforcement for macOS is
  unverified. Worth adding before App Store review.
- *Unverified:* that Mac App Store profiles grant `<team>.*` keychain groups; that iCloud's token differs per app (handled
  either way); that automatic signing registers new IDs through the API key; the installer certificate under cloud
  signing; that TestFlight Mac builds reach CloudKit (one [report](https://developer.apple.com/forums/thread/733942) of a
  sandboxed CloudKit app failing under TestFlight on macOS 26); that process taps work sandboxed (docs/sandbox.md); and
  whether privacy permissions survive between the Developer ID and App Store copies of `local.daybook`.

**Only the owner can decide:**

1. **The bundle ID:** decided, `local.daybook`.
2. **The App Store Connect record:** creating it with iOS and macOS, which makes the app a universal purchase for good once
   two platforms are approved; opting the iPhone app out of Macs; one price for both; retiring `local.daybook.phone`.
3. **Developer ID:** keep shipping it on GitHub beside the App Store (recommended: it's the only build that can carry its
   own updater), and whether it's ever sandboxed.
4. **The release workflow:** applying the changes above, and new secrets if the Mac export needs the manual fallback.
5. **The old iPhone app's last release,** if the hand-over through the app group is wanted (not built).

## Sources

- App Store Connect Help: [Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/),
  [Manage availability of iPhone and iPad apps on Macs](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon/),
  [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): 2.4.5, 2.5.2, 2.5.4, 2.5.14,
  4.2.3, 5.1.2(i), as published on 2026-11-01.
- [Migrating your app's files to its App Sandbox container](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container):
  `Move` takes a path or a [source, destination] pair; `${BundleId}`, `${Library}`, `${ApplicationSupport}`.
- [BundleIdPlatform](https://developer.apple.com/documentation/appstoreconnectapi/bundleidplatform) (`IOS`, `MAC_OS`,
  `UNIVERSAL`); Developer Forums threads [751188](https://developer.apple.com/forums/thread/751188) (AppKit and iOS
  sharing a bundle ID), [733942](https://developer.apple.com/forums/thread/733942) (TestFlight for Mac and profiles),
  [685723](https://developer.apple.com/forums/thread/685723) (keychain groups in profiles).
