# One app for iPhone and Mac (research, 2026-11-01)

The owner asked what it would take to ship the iPhone and Mac apps as one cross-platform app, so TestFlight and the App
Store carry both. This is the record: what's there today, the three ways to do it, what was built on this branch, and
what only the owner can do.

**Recommendation, in short.** Universal purchase with two targets (option a). The Mac's App Store build takes the
iPhone's bundle ID, `local.daybook.phone`, and joins the iPhone's existing App Store Connect record as its macOS
platform. Developer ID on GitHub stays, as `local.daybook.app`. One multiplatform target (b) buys nothing for
distribution, and Mac Catalyst or the iPhone app on a Mac (c) can't record calls. The code, build script, checks, and
docs for (a) are on this branch; the portal and App Store Connect steps are the owner's, and wiring the Mac into
`release.yml` is a proposal below.

## Today

| | Mac | iPhone |
|---|---|---|
| Project | `Apps/macOS/project.yml` (XcodeGen), target `Daybook`, compiles `Sources/Daybook` in place; SwiftPM's `Daybook` executable stays for `swift build/test/run` | `Apps/iOS/project.yml`, targets `DaybookPhone`, `DaybookPhoneWidgets` (WidgetKit extension: Live Activity, controls, widgets), `DaybookPhoneTests` |
| Bundle IDs | `local.daybook.app` (signed); `local.daybook.app.adhoc` (ad hoc); `local.daybook.app.rehearsal…` (migration rehearsal); `swift run` none (`DAYBOOK_BUNDLE_ID`, `Apps/macOS/Config/Signing.xcconfig`) | `local.daybook.phone`; `local.daybook.phone.widgets`; tests `local.daybook.phone.tests` |
| App group | none | `group.local.daybook.phone` (app and widgets) |
| Keychain groups | `<team>.local.daybook.app` first (pairing keys, sync identity), `<team>.local.daybook.shared` (library and cloud keys, iCloud Keychain) | `<team>.local.daybook.phone` first, `<team>.local.daybook.shared` |
| iCloud | `iCloud.local.daybook`: iCloud Documents (the journal) and CloudKit (the courier); push for `CKSyncEngine` | the same container and services; push |
| Other entitlements | hardened runtime, audio input; ad hoc builds sandboxed (`Daybook-Local.entitlements`); signed builds sandboxed only with `--sandbox` (`Daybook-Sandbox.entitlements`, not shipped yet) | Hotspot (Soundcore Wi‑Fi transfer); background modes audio, bluetooth-central, fetch, remote-notification, processing; Live Activities |
| Signing and distribution | Developer ID (cloud signing fails for a team key, so a `.p12` and the manually managed "Daybook Developer ID" profile), notarized, GitHub Release | automatic signing with the Admin API key, cloud-managed Apple Distribution, TestFlight in the App Store Connect record `local.daybook.phone` |

Nothing of the Mac's is in App Store Connect: it has no app record (docs/release.md, "One-time setup").

## The options

| | (a) Universal purchase, two targets | (b) One multiplatform target | (c) Mac Catalyst, or the iPhone app on a Mac |
|---|---|---|---|
| What it is | The Mac target builds with the iPhone's bundle ID and uploads to the iPhone's record as its macOS platform | One target with supported destinations iPhone and Mac; each destination compiles its own sources | The iPhone app's UIKit/SwiftUI code running on the Mac |
| Project | Unchanged: two specs, or one spec including both (prototyped) | One target, nearly every setting conditioned on the SDK (prototyped) | A new Catalyst port, or a checkbox in App Store Connect |
| Uploads | Two builds per release, one per platform, one record | Still two builds per release: an archive is per platform | One |
| Mac bundle ID | `local.daybook.phone` for the App Store build | the same | the same |
| Existing Mac installs | Library, preferences, keychain, iCloud, identity carry over (built here) | the same work | No Mac library at all: it's the iPhone app |
| Records calls | yes | yes | no: process taps, ScreenCaptureKit, meeting detection are AppKit/CoreAudio and Mac-only |
| Developer ID alongside | yes, as `local.daybook.app` | yes | n/a |
| Cost | Done here, plus the owner's portal steps | (a)'s cost, plus restructuring two build scripts, CI caches, and the specs for no distribution gain | A rewrite of the Mac app |

### (a) Universal purchase, two targets

Apple: platforms added to a record use its bundle ID and SKU, "you must upload the builds for macOS … from a separate
Xcode target", and "set the bundle IDs to match the iOS app's bundle ID"; each platform keeps its own version numbers and
builds; separate records can't be merged; once App Review approves two platforms, a platform can't be removed
([Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)). Native AppKit
apps qualify ([forum 751188](https://developer.apple.com/forums/thread/751188)). The iPhone record's bundle ID can't
change after its uploads, so the universal ID is `local.daybook.phone`. The name says "phone", but nobody sees a bundle
ID except in `~/Library` paths.

- **Project.** No restructuring. The Mac spec gains nothing; `Apps/macOS/Config/Signing.xcconfig` makes signed builds
  `local.daybook.phone` when `DAYBOOK_SANDBOX = YES`, else `local.daybook.app`. `scripts/build-app.sh --app-store`
  archives that build and exports it with the `app-store-connect` method (a `.pkg`), `--upload` sends it.
- **Sandbox.** The Mac App Store requires it (guideline 2.4.5(i)), and TestFlight requires an embedded provisioning profile
  (ITMS-90889; Xcode's automatic signing embeds one) ([TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
  [forum 733942](https://developer.apple.com/forums/thread/733942)). The existing sandbox path covers it:
  `Daybook-Sandbox.entitlements` already has everything (sandbox, microphone, Bluetooth, network client and server,
  user-selected files, bookmarks, iCloud, push, keychain groups), no temporary exceptions, and `SandboxMigration`,
  `ReplicaIdentity`, and `LegacyLibraryReturn` already handle the library's move. What the bundle ID change added is below.
- **Existing Mac installs.** See "What carries over". The container is named after the bundle ID, so it's
  `~/Library/Containers/local.daybook.phone`; Developer ID with `--sandbox` now uses it too, so there's only ever one.
- **Entitlements.** No conflict. The App ID `local.daybook.phone` already has iCloud (`iCloud.local.daybook`, CloudKit),
  Push, App Groups, and Hotspot. The Mac's entitlements claim none of App Groups or Hotspot, and Mac profiles only carry
  what applies to macOS (expected; unverified until the first Mac App Store profile is generated). The Mac's push key is
  `com.apple.developer.aps-environment`, the iPhone's `aps-environment`: both already in place.
- **Keychain.** The sandboxed build keeps listing `<team>.local.daybook.app` first, so it reads the pairing keys and sync
  identity the unsandboxed app stored. That needs the Mac App Store profile to grant `<team>.*` for
  `keychain-access-groups`, as the Developer ID profile does (unverified for Mac App Store profiles; owner step 3 checks it).
- **App Review** (Mac and iPhone together; [guidelines](https://developer.apple.com/app-store/review/guidelines/)):
  - *Model downloads.* 2.4.5(iv) bars Mac App Store apps from downloading "code, or resources to add functionality",
    and 4.2.3(ii) asks to "disclose the size of the download and prompt users" before downloads an app needs at launch.
    Weights are data and every model download already shows its size and waits for the person, but a reviewer could
    read 2.4.5(iv) strictly. Other Mac App Store apps download Whisper and LLM weights (unverified which and how they
    were reviewed). The most likely question at review.
  - *Recording.* 2.5.14: explicit consent and a clear indication while recording. Automatic recording on detected calls,
    and recording the other side of a call, are what a reviewer will ask about; the review notes should explain the
    preference and the indicators.
  - *Cloud keys.* No guideline bars the person's own Anthropic or OpenAI key. 5.1.2(i) now says apps "must clearly
    disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit
    permission before doing so": the cloud summary setting has to say so plainly and stay off until the person turns it
    on (docs/cloud.md).
  - *Updates.* 2.4.5(vii): App Store builds can't carry their own updater, so Sparkle or Polaris (docs/sandbox.md,
    "Updates") stay in the Developer ID build only.
  - *iPhone background modes and Hotspot* are already through TestFlight's review for the iPhone (2.5.4: each for its
    purpose: recording, Soundcore, sync, CloudKit pushes, processing). Unchanged.
- **MLX, Metal, weights.** Unaffected: the metallib is built into the app, MLX compiles kernels at run time (allowed in
  the sandbox, no JIT entitlement), and models download into the container's `Application Support/Daybook/Models`,
  which the manifest moves with the library (about 21 GB on the owner's Mac, a rename on the same volume).
- **Widgets.** The extension stays iPhone-only. A Mac widget would be a new macOS extension target, not needed for this.
- **Developer ID alongside.** Yes, as today, as `local.daybook.app`, unsandboxed, notarized, with its own updater if one
  ships. The two Mac builds are different apps to macOS (two preferences domains, two sets of permissions), and
  `SingleInstance` keeps them from running at once; moving between them moves the library ("What carries over").
- **Release pipeline.** See "Proposed release.yml".

### (b) One multiplatform target

Prototyped as `DaybookOne` in `Apps/Universal/project.yml` (commit `d0f1033`): `supportedDestinations: [iOS, macOS]`,
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
  audio. Worse, it would run as `local.daybook.phone` in `~/Library/Containers/local.daybook.phone`, the Mac App Store
  build's container, with an iPhone replica's library in the very folder the Mac app opens. Owner step 1 turns it off.
  When a record's macOS platform ships, Apple replaces the iPhone app on Macs with the Mac app anyway.

## What carries over (option a, built)

| What | How | Where |
|---|---|---|
| Library (`Application Support/Daybook`, models included) | the manifest moves it into the container; if the container already existed, **Move Library…** at launch (an APFS clone, checked file by file); back out with **Move Library Back** | `Resources/container-migration.plist`; `SandboxMigration.legacyFolderName` counts `local.daybook.phone`; `LegacyLibraryReturn` looks in both containers |
| Preferences | the manifest moves `local.daybook.app.plist` to `${BundleId}.plist`: `${BundleId}` alone would name a file the unsandboxed app never wrote. A sandboxed probe (below) showed macOS moving it and the app reading it as its own | `Resources/container-migration.plist`; going back copies `local.daybook.phone.plist` from the container |
| Pairing keys, sync identity | the same keychain group, listed first; the identity item named after the old place is copied to the new one, `replica.json` as before | `Daybook-Sandbox.entitlements` (unchanged), `SandboxMigration.check` |
| Library and cloud keys | `<team>.local.daybook.shared`, unchanged | |
| iCloud container and CloudKit | the same container on the same App ID | |
| iCloud account | iCloud's account token is per app ([WWDC 2012 session 209 notes](https://wwdcnotes.com/documentation/wwdc12-209-icloud-storage-overview/); unverified here), so the App Store build would have read the Developer ID build's token as another account and paused sync. The token now records its app; another app's token is the same account when the container's manifest names a library this device has a checkpoint for | `LibrarySyncController.prepareContainer`, `LibrarySyncEngine.holdsJournal`, docs/icloud-sync.md |
| One copy at a time | `local.daybook.phone` with the `Daybook` executable is Daybook; the iPhone app on a Mac (`DaybookPhone`) isn't | `SingleInstance.isDaybook` |
| Privacy permissions, window state | follow the bundle ID: asked again once | |

Tests: `SandboxMigrationTests.testTheAppStoreBuildTakesTheLibraryFromTheUnsandboxedApp`,
`LibraryMoveTests.testTheLibraryComesBackFromTheAppStoreBuild` and `testWithTwoContainersTheNewerLibraryComesBack`,
`SingleInstanceTests`, `LibrarySyncContainerTests.testAnotherAppsAccountCarriesOverWhenTheContainerHoldsThisLibrary` and
`testAnotherAppsAccountWithAnotherLibraryOrTheSameAppPauses`; `scripts/ci/tests/run-tests.sh` for `--app-store`, the
sandboxed bundle ID in `check-mac-app.sh` and `package-mac.sh`, the manifest's rename, and `asc-testflight.sh --platform`.

## Prototypes

All built locally, ad hoc or unsigned or for the Simulator, with Xcode 27.2 (27B52) and XcodeGen 2.45.4 on macOS 27.0.
Nothing was signed with a team, uploaded, or launched except the probe.

| Prototype | Result |
|---|---|
| `Apps/Universal/project.yml`: one spec including both apps' specs | Builds the Mac target (ad hoc, 75 s warm) and the iPhone app with its widget (Simulator, 130 s). The merged project-level settings collide, the later include winning (`ENABLE_USER_SCRIPT_SANDBOXING` Mac NO / iPhone YES, `MARKETING_VERSION`, each app's xcconfig), so each app needs them back at the target level; and XcodeGen's intermediate groups gave one "Apps" group two parents, which Xcode refuses to open, until turned off |
| The Mac target as the App Store kind | Builds unsigned as `local.daybook.phone` with the manifest embedded |
| `DaybookOne`, one multiplatform target | Builds for the Mac and the Simulator after the fixes under (b); the Simulator build embeds the widget, the Mac build doesn't |
| A sandboxed probe app, ad hoc, `local.daybook.research.manifest1`, whose manifest moves a library under another name and `local.daybook.research.source.plist` to `${BundleId}.plist` | On first launch macOS moved both; `UserDefaults.standard` read the moved values (`"probe": "preferences carried over"`, `onboardingCompleted` true), and both sources were gone. The container's protected metadata file remains (29 KB), as docs/sandbox.md describes |

The prototype project is commit `d0f1033`, removed again once the shipping spec had what it showed; build it from that
commit with `Apps/Universal/build-research.sh generate|mac|mac-store|phone|one-mac|one-phone`.

## Proposed release.yml

Not applied: changing the release workflow was refused by this session's permission rules, so it's the owner's (or the
lead's) to apply. Everything it calls exists and is tested. In `workflow_dispatch.inputs`:

```yaml
      mac_testflight:
        description: Also send the Mac app to TestFlight (the iPhone app's record needs its macOS platform; docs/release.md)
        type: boolean
        default: false
```

In `prepare`, an output `mac_testflight: ${{ steps.apps.outputs.mac_testflight }}`, and in the "Apps and TestFlight
group" step, with `MAC_TESTFLIGHT_INPUT: ${{ inputs.mac_testflight == true }}` and
`MAC_TESTFLIGHT_DEFAULT: ${{ vars.DAYBOOK_MAC_TESTFLIGHT }}` in its `env`:

```bash
mac_testflight=false
if [[ "$mac" == true && ( "$MAC_TESTFLIGHT_INPUT" == true || "$MAC_TESTFLIGHT_DEFAULT" == true ) ]]; then
  mac_testflight=true
fi
echo "mac_testflight=$mac_testflight" | tee -a "$GITHUB_OUTPUT"
```

A job after `mac`, behind the same `release` environment, with the same secrets the `iphone` job uses and no new ones:

```yaml
  mac-testflight:
    name: Mac to TestFlight
    needs: [prepare, validate]
    if: needs.prepare.outputs.mac_testflight == 'true'
    runs-on: xcode-27
    timeout-minutes: 150
    environment: release
    permissions:
      contents: read
    env:
      DAYBOOK_TEAM_ID: ${{ vars.DAYBOOK_TEAM_ID }}
      VERSION: ${{ needs.prepare.outputs.marketing_version }}
      RUN_CREATED_AT: ${{ needs.prepare.outputs.run_created_at }}
    steps:
      # The iphone job's first five steps as they are: Check the configuration, checkout, Build number
      # for this attempt (BUILD and BUILD_CANDIDATES), the release-notes artifact, then:
      - name: Select Xcode
        run: scripts/ci/select-xcode.sh --metal --expect-build "$DAYBOOK_RELEASE_XCODE_BUILD"
      - name: Install XcodeGen
        run: scripts/ci/install-xcodegen.sh
      - name: Look for this run's Mac build in App Store Connect
        id: earlier
        env: { ASC_KEY_ID: …, ASC_ISSUER_ID: …, ASC_KEY_P8_BASE64: … }   # as in the iphone job
        run: |
          found="$(scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh --bundle-id local.daybook.phone --platform MAC_OS \
            --version "$VERSION" --find-build "$BUILD_CANDIDATES" --uploaded-after "$RUN_CREATED_AT" | sed -n 's/^found=//p')"
          echo "build=$found" >> "$GITHUB_OUTPUT"
          if [[ -n "$found" ]]; then echo "BUILD=$found" >> "$GITHUB_ENV"; fi
      - name: Fetch the packages at their pinned versions
        if: steps.earlier.outputs.build == ''
        run: scripts/build-app.sh --resolve-only
      - name: Archive the App Store build
        if: steps.earlier.outputs.build == ''
        env: { ASC_KEY_ID: …, ASC_ISSUER_ID: …, ASC_KEY_P8_BASE64: …, DEVELOPMENT_P12_BASE64: …, DEVELOPMENT_P12_PASSWORD: … }
        run: scripts/ci/secrets.sh run -- scripts/build-app.sh --app-store --archive-only --marketing-version "$VERSION" --build-number "$BUILD"
      - name: Check the archive
        if: steps.earlier.outputs.build == ''
        run: scripts/ci/check-mac-app.sh --app build/macOS/Daybook.xcarchive/Products/Applications/Daybook.app --kind signed-sandbox
      - name: Export and upload to App Store Connect (unless the build is there already)
        if: steps.earlier.outputs.build == ''
        env: { ASC_KEY_ID: …, ASC_ISSUER_ID: …, ASC_KEY_P8_BASE64: … }
        run: scripts/ci/secrets.sh run -- scripts/build-app.sh --app-store --upload --export-only   # after the same second look as the iphone job
      - name: Wait for processing, set What to Test, add to the beta group
        env: { ASC_KEY_ID: …, ASC_ISSUER_ID: …, ASC_KEY_P8_BASE64: …, GROUP: ${{ needs.prepare.outputs.testflight_group }} }
        run: |
          args=(--bundle-id local.daybook.phone --platform MAC_OS --version "$VERSION" --build "$BUILD"
                --notes-file notes/testflight.txt --timeout 3600)
          if [[ -n "$GROUP" ]]; then args+=(--group "$GROUP"); fi
          scripts/ci/secrets.sh run -- scripts/ci/asc-testflight.sh "${args[@]}"
      - name: Remove secrets
        if: always()
        run: scripts/ci/secrets.sh cleanup
```

`publish` doesn't wait for it: the GitHub Release is the Developer ID download. One uncertainty: the export signs the
`.pkg` with a Mac Installer Distribution certificate. If cloud signing doesn't offer one to the team API key (as it
doesn't offer Developer ID; a recent report says the same for Mac App Store exports,
[clipboardManager PR 4](https://github.com/walhallaa/clipboardManager/pull/4)), the fallback is the Developer ID one's: an
Apple Distribution and Mac Installer Distribution `.p12` and a manual export, which means new secrets: the owner's call.

## Recommendation and steps

Option (a). In order:

1. **Owner: decide the bundle ID** (below), and that Developer ID stays.
2. **Done on this branch:** sandboxed Mac builds as `local.daybook.phone`, the migration and its tests, `--app-store`,
   the checks, `asc-testflight.sh --platform`, export compliance in the Mac's Info.plist, the docs.
3. **Owner: App Store Connect and the portal** (docs/release.md, "Mac on TestFlight", One-time setup): turn off the
   iPhone app on Macs, check the App ID, make the Mac App Store profile and installer certificate (first
   `--app-store --allow-provisioning-updates` on the owner's Mac), add the macOS platform, first upload, beta group.
4. **Owner: the sandbox's hardware checks** (docs/sandbox.md): the process-tap probe and the rehearsal, then the first
   TestFlight build on the real library, after a backup.
5. **Apply the release.yml proposal**, run it once by hand with `mac_testflight`, then set `DAYBOOK_MAC_TESTFLIGHT`.
6. **Fix what the first upload reports**, most likely the icon or the privacy manifest (risks below).

Effort: the code here is done. Steps 3 to 5 are an afternoon for the owner if nothing is rejected, and a day if the icon,
the installer certificate, or review needs work. App Review's first pass on the Mac (step 6 onward) is the long pole.

**Risks.**

- *A container made too early.* Any sandboxed launch as `local.daybook.phone` on a Mac before the manifest-carrying build
  (a sandboxed debug build, or the iPhone app installed on the Mac through TestFlight) creates the container, and macOS
  then never runs the manifest there. The launch check's **Move Library…** covers it (tested), but settings start over
  then. `build-app.sh` refuses sandboxed Debug builds; owner step 1 covers the iPhone app.
- *The icon.* The Mac ships `Daybook.icns` (all sizes to 512@2x) through `CFBundleIconFile`, with an asset catalog that
  has no AppIcon. Reports say App Store processing wants the icon in the asset catalog with `CFBundleIconName`
  (ITMS-90546; [example](https://github.com/hjl1045/keyopen/pull/32), [forum 86904](https://developer.apple.com/forums/thread/86904)).
  Unverified for this bundle. The fix, if needed: a Mac AppIcon set generated by `scripts/make-icon.swift`, named in
  `ASSETCATALOG_COMPILER_APPICON_NAME`.
- *Privacy manifests.* Neither app has a `PrivacyInfo.xcprivacy`, and both use required-reason APIs (`UserDefaults`, file
  timestamps, disk space). App Store Connect has warned iOS uploads since 2024 (ITMS-91053); enforcement for macOS is
  unverified. Worth adding before App Store review of either app.
- *Unverified:* that Mac App Store profiles grant `<team>.*` keychain groups; that iCloud's token differs per app (handled
  either way); that the installer certificate works with cloud signing; that TestFlight Mac builds reach CloudKit (one
  [report](https://developer.apple.com/forums/thread/733942) of a sandboxed CloudKit app failing under TestFlight on
  macOS 26); that process taps work sandboxed (docs/sandbox.md's probe); that the Developer ID and App Store builds can
  share one container, if a sandboxed Developer ID build is ever shipped.

**Only the owner can decide:**

1. **The bundle ID.** Keep `local.daybook.phone` for both (recommended), or start a new record under a neutral ID such as
   `local.daybook`: a new app for every tester, the iPhone's local data (recordings not yet synced, live captions,
   downloaded models) left behind in the old app's container, and this branch's ID changed throughout.
2. **The App Store Connect record:** adding the macOS platform, which can't be removed once two platforms are approved;
   opting the iPhone app out of Macs; one price for both.
3. **Developer ID:** keep shipping it on GitHub beside the App Store (recommended: it's the only build that can carry its
   own updater), and whether it ever becomes sandboxed (it then needs a Developer ID profile for `local.daybook.phone`).
4. **The release workflow:** applying the proposal, and new secrets if the Mac export needs the manual fallback.

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
