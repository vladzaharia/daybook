# Releases and CI

Three GitHub Actions workflows build Daybook on GitHub-hosted Macs:

- **CI** (`.github/workflows/ci.yml`) builds and tests every push to `main`, every pull request, and manual runs.
- **Release** (`.github/workflows/release.yml`) ships a `v*` tag on a commit that's on `main`, or a manual run from `main`. The iPhone app goes to TestFlight. The Mac app is signed with Developer ID, notarized, and attached to a draft GitHub Release, which is published once both apps are out.
- **CI under load** (`.github/workflows/starved.yml`) runs the tests on starved machines nightly and on demand, to find timing-dependent tests. Nothing waits for it.

Signing uses an App Store Connect API key with Xcode's cloud-managed signing. A Developer ID `.p12` is an optional fallback for the Mac app.

Both apps are one App Store Connect app with one bundle ID, `local.daybook`, so TestFlight and the App Store can carry the iPhone and Mac apps together (universal purchase); `scripts/build-app.sh --app-store` builds the Mac's App Store version. See [One bundle ID](#one-bundle-id). Until the owner's steps there are done and `release.yml` names the new ID, a tagged release fails ([Known blockers](#known-blockers)).

## Pipeline

| Workflow | Job | Runner | What it does |
|---|---|---|---|
| CI | `lint` | `ubuntu-24.04` | actionlint (pinned, checksum-verified, with shellcheck on every `run:` block), shellcheck on every script under `scripts/` (all bash), and `scripts/ci/tests/run-tests.sh`, which also compiles the Python helpers with warnings as errors |
| CI | `package` | `xcode-27` | `swift build --build-tests --force-resolved-versions` once (then `git diff --exit-code -- Package.resolved`), then `swift test --skip-build` per test-target group, then the timing-budget test alone (see below) |
| CI | `iphone` | `xcode-27` | `scripts/build-ios.sh --test` on a simulator (iPhone Duo if the image has one, otherwise iPhone 18 Pro), the two encoder timing tests alone (see below), then an unsigned Release device archive checked the way a release would be |
| CI | `mac` | `xcode-27` | `scripts/ci/tests/run-tests.sh --require-all` (every group, including the macOS-only ones: CryptoKit's JWT check, the archive checks, the upload retry, the build scripts, and the keychain), then `scripts/build-app.sh --debug --ad-hoc` (Release with the `mac_configuration` input, which a manual run and `release.yml` set; a release's validation always builds Release), then the bundle is checked for its signature, icon, MLX `default.metallib`, and App Sandbox entitlements (`scripts/ci/check-mac-app.sh --kind adhoc`: sandboxed, `local.daybook.adhoc`, no migration manifest) |
| CI | `caches` | `ubuntu-24.04` | pushes to `main` only: deletes the caches this run's keys superseded (`scripts/ci/prune-caches.sh`) |
| CI under load | `package` | `xcode-27` | nightly and manual: the package's test bundles at background priority while busy loops take every core |
| CI under load | `iphone` | `xcode-27` | nightly and manual: every iPhone test three times (`-test-iterations 3`) |
| Release | `validate` | (CI's jobs) | calls `ci.yml` on the release commit with `mac_configuration: Release`, so the Mac app is built the way the release builds it. The signing jobs wait for it |
| Release | `prepare` | `ubuntu-24.04` | checks the ref (`scripts/ci/check-ref.sh`: a `v*` tag must point at a commit on `main`), works out the version (`scripts/ci/version.sh`) and when the run was created, and writes release notes and What to Test (`scripts/ci/release-notes.sh`) |
| Release | `iphone` | `xcode-27`, environment `release` | works out its build number (see [Versions](#versions)), looks for this run's build in App Store Connect, archives `DaybookPhone` with `DaybookPhoneWidgets` (`build-ios.sh --archive`), checks the archive (`check-ios-archive.sh`), exports with `app-store-connect` and uploads it (`build-ios.sh --export upload`), then waits for processing, sets What to Test, and adds the build to the beta group (`asc-testflight.sh`) |
| Release | `mac` | `xcode-27`, environment `release` | works out its build number, resumes a notarization a previous attempt left pending, fetches the packages, archives (`build-app.sh --archive-only`, sandboxed with the `sandbox` input), exports with `developer-id` (`mac-export.sh`, which runs `build-app.sh --export-only`), then checks that the app's `CFBundleShortVersionString` and `CFBundleVersion` are the run's version and build and that it's the kind of build the run asked for (`check-mac-app.sh`: unsandboxed, or sandboxed with the migration manifest), notarizes, staples, and writes the ZIP, a DMG when possible, and `SHA256SUMS.txt` (`package-mac.sh`), and attests their build provenance |
| Release | `draft` | `ubuntu-24.04` | tags only, after `mac`: verifies the checksums and creates the GitHub Release as a **draft** with the Mac files (`scripts/ci/github-release.sh draft`). A re-run updates its own draft; it never touches a published release |
| Release | `publish` | `ubuntu-24.04` | tags only, after `draft` and, when the run releases the iPhone app, after `iphone` succeeded: publishes the draft (`github-release.sh publish`). `draft` and `publish` are the only jobs with `contents: write`, and they hold no Apple secrets |

Hardening:

- Every workflow starts from `permissions: {}`, and each job asks for `contents: read` (or `write` in `draft` and `publish` only). The Release `mac` job alone adds `id-token: write` and `attestations: write`, for build provenance.
- Actions are pinned to commit SHAs, with the version in a comment, and the repository requires it (Settings › Actions › "Require actions to be pinned to a full-length commit SHA", `sha_pinning_required`). Checkouts don't persist credentials.
- Secret scanning with push protection, Dependabot alerts, and Dependabot security updates are on. `.gitignore` keeps signing material out (`*.p8`, `*.p12`, `AuthKey_*`, `*.mobileprovision`, `*.provisionprofile`, `*.cer`).
- `.github/dependabot.yml` opens weekly update pull requests for the actions (grouped) and the Swift packages; see [Dependency updates](#dependency-updates).
- Nothing uses `pull_request_target`.
- Concurrency groups cancel superseded pull request runs and never cancel a release. CI's group includes the workflow's name, which is "Release" when `release.yml` calls it, so a push to `main` can't queue behind or replace a release's validation.
- Secrets are environment secrets in `release`. Only jobs that a reviewer approved can read them, and only from `main` or a `v*` tag. Each secret is passed only to the steps that need it, and becomes a file only while such a step runs: see [Secrets on the runner](#secrets-on-the-runner).
- Runners are GitHub-hosted only. The repository's `.github/actionlint.yaml` lists `xcode-27` under actionlint's `self-hosted-runner` key only because actionlint 1.7.12 predates the label. It's GitHub-hosted.

## Runner and Xcode

- **Label:** `runs-on: xcode-27`, the Xcode 27 image, a public preview announced in [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404). The readme is [`images/macos/xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md); image 20261012.0260.1 runs macOS 27.0.1 on arm64. That label is the standard size, free for public repositories. `xcode-27-xlarge` is a paid larger runner and isn't used.
- **Xcode:** 27.1 (27A9275, the same build as the development Macs), selected with `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer` by `scripts/ci/select-xcode.sh`. That script fails if the version isn't 27.1 (or a 27.1.x patch) or a required SDK is missing. The release's signing jobs also require the exact build: `DAYBOOK_RELEASE_XCODE_BUILD`, a repository variable that defaults to `27A9275` when unset. A new build on the image fails the release (not CI) until someone has seen CI pass with it and set the variable. Every job that selects Xcode writes its version and build to the run summary. On this image `Xcode.app` is 27.0, and `Xcode_27.1.app` links to `Xcode_27.1_Release_Candidate.app`. The image's next rollout ([#15011](https://github.com/actions/runner-images/pull/15011)) installs the 27.1 release at the same path and makes it the default.
- **SDKs and simulators:** the iOS 27.1 SDK is there; it has the iPhone Duo hinge APIs. The image preinstalls only the iOS 27.0 simulator runtime: iPhone 17, 17e, 18 Pro, 18 Pro Max, Air, and iPads, with **no iPhone Duo**. Apple's iOS 27.1 simulator runtime supports only the iPhone Duo device type ([#15000](https://github.com/actions/runner-images/issues/15000)). So CI tests on **iPhone 18 Pro with iOS 27.0**, built with the 27.1 SDK. The `#available(iOS 27.1, *)` hinge code compiles there but doesn't run. `scripts/ci/pick-simulator.sh` prefers an iPhone Duo, so CI moves to one with no change once an image ships it. Exercising the Duo on CI today would mean downloading the runtime in the job (`xcodebuild -downloadPlatform iOS`, several GB). The Duo checks stay local, as in `docs/iphone.md`.
- **Metal toolchain:** the image doesn't include it, so `select-xcode.sh --metal` runs `xcodebuild -downloadComponent MetalToolchain` (with retries) in the jobs that build MLX. Apple serves whatever toolchain matches the Xcode, and the download can't be pinned, so the job records its build (`xcodebuild -showComponent MetalToolchain`, e.g. 27A266a) and `metal --version` in the run summary.
- **Packages:** every build uses only the versions `Package.resolved` pins. `swift build` runs with `--force-resolved-versions`, and CI then checks `git diff --exit-code -- Package.resolved`. `build-app.sh` and `build-ios.sh` copy the file into the generated project, resolve with `-onlyUsePackageVersionsFromResolvedFile` (as every build, test, and archive does), and fail if Xcode would change it. `build-app.sh --resolve-only` and `build-ios.sh --resolve` only fetch the packages.
- **XcodeGen:** 2.45.4, the version the projects are developed with, installed by `scripts/ci/install-xcodegen.sh`. It downloads the release ZIP and checks its SHA-256.

## CI details

**Caches.** MLX, WhisperKit, and FluidAudio dominate the build.

- `package` caches `.build`.
- `iphone` caches its derived data, without logs and the index.
- `mac` caches its derived data and `SourcePackages`, per configuration.

Keys combine the Xcode build with a hash of `Package.resolved`, `Package.swift`, and the project spec. Only pushes to `main` save a cache, and only when the key is new. Pull requests restore from the base branch and never save, so they can't fill or poison the 10 GB cache quota. A dependency or Xcode change starts a new cache.

After a push to `main`, the `caches` job (`scripts/ci/prune-caches.sh`) deletes the older caches of each family the run used: same key up to the hash, so `swiftpm-macOS-27A9275-…`, `ios-dd-macOS-27A9275-…`, and `mac-dd-macOS-27A9275-Debug-…`. It deletes them only when the run's own cache for that family is saved, so a failed run never removes the last good one. It's the only job with `actions: write`, and it builds nothing: it runs that one script. (When `release.yml` calls CI, its `validate` job grants `actions: write` as a ceiling only, because GitHub checks a called workflow's permissions before the run starts; the `caches` job never runs there.) Caches of an older Xcode build age out after 7 days unused. Run CI manually with `clean` ticked to build without caches.

**Test waits.** Every wait in the tests (`waitUntil`/`waitFor` in `Tests/DaybookTestSupport` and `DaybookPhoneTests/TestSupport.swift`, and the link tests' loopback timeouts) is multiplied by `DAYBOOK_TEST_TIMEOUT_SCALE`. CI's package and iPhone test steps set it to 2 (`TEST_RUNNER_DAYBOOK_TEST_TIMEOUT_SCALE` for `xcodebuild`, which hands it to the test runner without the prefix); CI under load sets 5. The isolated timing steps below keep their own budgets, unscaled.

**Timing-sensitive tests.** Three tests depend on timing that an overloaded machine can miss:

- `AudioAlignerTests.testThirtyMinutePairAlignsWithinBudget` must align a 30-minute pair within 15 s. On a development Mac at load average 50 it takes 1 to 4 s.
- The iPhone test `testCrashRecoveryProducesAudioNotesAndBookmarks` waits up to 30 s for the encoder's utility queue to reach the disk.
- The iPhone test `testRealTimeSegmentsReachTheDiskAtEachFragmentInterval` depends on the same encoder reaching the disk at each fragment interval.

None is disabled. Hosted runners are small shared VMs, so CI runs them **on their own, after everything else has built and run, with one retry**:

- The package test runs through `scripts/ci/retry.sh 2`. A pass on the second attempt leaves a "Passed on retry" warning on the run.
- The two iPhone tests run together in "Encoder timing tests" with `-retry-tests-on-failure -test-iterations 2`, which reruns only a failed test and records both attempts in the result bundle. xcodebuild counts a pass on the retry as a pass, so `scripts/ci/xcresult-retries.sh` reads the bundle (`xcresulttool get test-results tests`) and leaves the same "Passed on retry" warning, in the run summary too.

The main runs skip just these tests (`--skip` and `-skip-testing`), and the iPhone tests run with `-parallel-testing-enabled NO`. A real regression fails twice and fails the job. A retry warning that keeps coming back means the budget needs a look. The nightly [CI under load](#ci-under-load) run shows how much margin they have.

**CI under load.** `.github/workflows/starved.yml` runs at 07:37 UTC every night and from Actions › CI under load › Run workflow. It never runs on pull requests, no release calls it, and it has no secrets (no environment, `contents: read`). It restores CI's caches from `main` and never saves one.

- `package` builds normally, then starts one busy loop per core at background priority (`taskpolicy -c background`) and runs each test bundle with `taskpolicy -c background swift test`, so the tests compete with the loops for every core. The timing-budget test runs with the rest, without its retry.
- `iphone` runs every iPhone test three times in a row (`-test-iterations 3`, no retry), the encoder tests included. A test that fails any iteration fails the job, and `xcresult-retries.sh` names each one that passed some iterations and failed others.

A red night isn't a broken build. It names the tests whose timing assumptions don't hold under load; compare with `docs/validation.md`, and fix the test or its budget before an ordinary CI run starts failing on it.

**Artifacts.** On failure, CI uploads the swift test logs, the iPhone `.xcresult` bundles and Xcode logs, or the Mac build logs. They're kept for 14 days.

**The release check in CI.** The `iphone` job runs `check-ios-archive.sh` on an unsigned archive with `continue-on-error`. Problems that would block a release then show up on every run without failing it. Today it reports the missing app icon (see [Known blockers](#known-blockers)).

## Signing

### How it works

Every release job authenticates Xcode with the App Store Connect API key. The key goes to xcodebuild as `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID`, together with `-allowProvisioningUpdates`. The release jobs never pass `-allowProvisioningDeviceRegistration`, so runners are never registered as devices.

That's the one exception to "nothing but the owner's first-time provisioning passes `-allowProvisioningUpdates`" (AGENTS.md): the release pipeline, authenticated by the key in the approval-gated `release` environment. `build-app.sh` and `build-ios.sh` refuse the key unless they run on GitHub Actions under `release.yml`, so a local build or an agent can't reach that path by setting the variables.

- **Archive** (`build-ios.sh --archive`, `build-app.sh --archive-only`): automatic signing with Apple Development.
  - A fresh runner has no development certificate, so Xcode creates one through the key. It appears in the account as *Apple Development: Created via API*.
  - Xcode fetches or creates the development profiles for the existing identifiers.
  - These certificates sign nothing that ships, and revoking old ones is harmless: see [Development certificates](#development-certificates).
- **Export** (`-exportArchive`): the archive is re-signed for distribution with a **cloud-managed** certificate. The private key stays with Apple, so no certificate or `.p12` is exported anywhere.
  - The iPhone export uses Apple Distribution with the App Store profiles.
  - The Mac export uses Developer ID Application with the Developer ID profile that carries the iCloud container.
  - The iPhone export uses `destination: upload`, which sends the build straight to App Store Connect.
- **Notarization:** `xcrun notarytool submit` with the same key, then `notarytool wait --timeout`: 45 minutes for the app, 20 for the DMG, well inside the job's 150 minutes. Each submission ID goes to the run summary. Then `xcrun stapler staple` runs, and `spctl` assesses the result.
  - If Apple is still working on the app when the wait runs out, the job fails and keeps that submission (`pending.json` with its ID, and `submit.zip`, exactly what was sent) as the `mac-notarization-<attempt>` artifact for 7 days. Re-run the failed job: `scripts/ci/notary-resume.sh` finds it, asks Apple for its status, and if it's accepted or still in progress, unpacks that app and waits for the same submission instead of building and submitting again. A rejected one, or none, means a fresh build.
  - If the DMG isn't notarized in time, it's left out with a warning, and the release ships the ZIP.

### Development certificates

Automatic signing signs each archive with an Apple Development identity before the export re-signs it for distribution. A fresh runner has none, so without one Xcode creates an *Apple Development: Created via API* certificate on every archive, two per release run, and the team's limit (10) is reached within a few releases: archives then fail with "Your account has reached the maximum number of certificates" (it happened on v0.4.1's first attempt).

So the pipeline keeps **one** development certificate for every run. `scripts/asc-development-certificate.sh` makes it, for the owner, with the Admin key:

```sh
export DAYBOOK_ASC_KEY_PATH=~/keys/AuthKey_ABC123DEFG.p8 DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID=<issuer uuid>
scripts/asc-development-certificate.sh          # --repo OWNER/NAME --environment release are the defaults
```

- It makes a key and a signing request in a private temporary directory, asks App Store Connect for the certificate, packs both as a `.p12` with a random password, and checks that macOS imports it with an Apple Development identity. It then stores the `.p12` and its password as the `release` secrets `DEVELOPMENT_P12_BASE64` and `DEVELOPMENT_P12_PASSWORD` (through `gh`'s standard input) and the certificate's ID as the repository variable `DAYBOOK_DEVELOPMENT_CERTIFICATE_ID`. Nothing stays on disk. If a step after making the certificate fails, it revokes it again.
- The two archive steps pass the secrets to `secrets.sh`, which imports the `.p12` (and Apple's WWDR G3 intermediate, by digest) into the step's temporary keychain. Automatic signing finds a valid development identity and creates no certificate.
- It's optional and never blocks a release: without the secrets, or with a `.p12` that's wrong, expired, or revoked, the step warns in the run's summary and the archive creates a certificate as before.
- The certificate lasts a year. Run the script again before it expires; the new one replaces the secrets and the variable, and the old one can then be revoked.
- A development certificate can't sign anything people install from TestFlight or the GitHub Release: those are re-signed for distribution at export.

`scripts/asc-certificates.sh` lists the *Created via API* development certificates and revokes old ones, never the pipeline's (`DAYBOOK_DEVELOPMENT_CERTIFICATE_ID`, read through `gh`, or `--keep ID`):

```sh
scripts/asc-certificates.sh                      # dry run: lists them, with their age; changes nothing
scripts/asc-certificates.sh --revoke             # revokes the ones older than 30 days (--older-than N)
```

- It considers only development certificates (Apple, iOS, or Mac Development) named "Created via API". Distribution and Developer ID certificates, and people's own development certificates, are never touched.
- Age comes from the expiration date (development certificates last a year). The 30-day default keeps the certificate of any release run that might still be going.
- When: after setting up the pipeline's certificate (`--older-than 0 --revoke` clears the ones runs made before it), after renewing it, or when Xcode reports that the team has reached its certificate limit. Run the dry run first and read the list.

### Capabilities and entitlements

| App ID | Capabilities on the account | Signed entitlements |
|---|---|---|
| `local.daybook` (iPhone) | App Groups (`group.local.daybook`); iCloud with iCloud Documents and CloudKit, container `iCloud.local.daybook`; Push Notifications; Hotspot; Increased Memory Limit and Background GPU Access, ready for when the app claims them (docs/iphone.md) | `Apps/iOS/project.yml`: the iCloud keys, `aps-environment`, the app group, `keychain-access-groups` = `<team>.local.daybook`, `<team>.local.daybook.phone`, `<team>.local.daybook.shared`, Hotspot. Info.plist's `UIBackgroundModes` adds `remote-notification` (not a capability) |
| `local.daybook` (Mac: Developer ID, Apple Development, and the App Store) | the same App ID; the Mac's entitlements claim none of App Groups, Hotspot, or the memory and GPU capabilities | `Resources/Daybook.entitlements` (unsandboxed): audio input; `com.apple.developer.icloud-services` = `CloudDocuments`, `CloudKit`; the container in `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers`; `com.apple.developer.aps-environment`; `keychain-access-groups` = `<team>.local.daybook`, `<team>.local.daybook.app`, `<team>.local.daybook.shared`. Sandboxed (`--app-store`, `--sandbox`), `Resources/Daybook-Sandbox.entitlements`: the same plus the App Sandbox ([docs/sandbox.md](sandbox.md)) |
| `local.daybook.widgets` | App Groups | the app group only |
| `local.daybook.app`, `local.daybook.phone`, `local.daybook.phone.widgets` | the IDs before the one bundle ID; they stay registered, and nothing new is signed with them | |

- CloudKit and push serve the courier (`docs/icloud-sync.md`, "Courier (CloudKit)"). `CKSyncEngine` needs both; CloudKit sends its own pushes, so there's no APNs key or certificate.
- **Push is `development` in the files and `production` in what ships.** `DAYBOOK_APS_ENVIRONMENT` in each `Config/Signing.xcconfig` is `development`, which is what Apple Development profiles grant, and archives are signed that way. The exports re-sign with the distribution profile, so TestFlight (App Store profile) and Developer ID builds carry `production` and use CloudKit's **Production** environment, Xcode setting `com.apple.developer.icloud-container-environment` to `Production`. Writing `production` into the files instead fails development signing: "the provisioning profile grants it for the value 'development'". Apple's guidance is the same: keep `development` and let the export re-sign it.
- **Keychain groups** need no capability: a profile grants `keychain-access-groups` = `<team>.*`, which covers every group. Both apps list `<team>.local.daybook` first, the default for items stored without a group (link pairing keys, the sync device ID); then the group they used before the one bundle ID (`<team>.local.daybook.app` on the Mac, `<team>.local.daybook.phone` on the iPhone), so items stored there stay readable (a read looks in every group listed, and a write moves an item to the first); then the shared group, which holds library and cloud keys in iCloud Keychain for both apps (`docs/icloud-sync.md`, "Encryption"). Check a profile with `security cms -D -i <profile> | plutil -p - | grep -A2 keychain-access-groups`: it lists `48H7CLBV8Y.*`. The "Daybook Developer ID" profile did; `scripts/ci/check-ios-archive.sh` checks a signed iPhone archive's groups and their order. If a profile ever didn't, signing fails with the group named.
- Ad hoc and local builds (`build-app.sh --ad-hoc`, `Resources/Daybook-Local.entitlements`, `swift run`), simulator builds, and CI's unsigned builds carry neither CloudKit nor push, create no courier, and need no profile. They have no keychain groups either, so they can't open an encrypted library (they can't sync at all).
- Ad hoc builds run in the App Sandbox under their own bundle ID, `local.daybook.adhoc`, with no migration manifest; signed builds are `local.daybook` and stay unsandboxed unless built with `--sandbox` or `--app-store` ([docs/sandbox.md](sandbox.md)).

### Secrets on the runner

Third-party code runs on the release runners: package manifests, swift-syntax macros, and the compilers' work on MLX, WhisperKit, FluidAudio, swift-transformers, swift-huggingface, swift-crypto, and swift-jinja. So the signing material exists only in the steps that use it:

- Each such step gets the secrets in its environment and runs its command inside `scripts/ci/secrets.sh run -- …`. That writes the API key as `$RUNNER_TEMP/daybook-secrets/AuthKey_<id>.p8` (directory 700, file 600) and, when the step has the `.p12`, creates a temporary keychain with it; runs the command; and deletes both when the command ends, however it ends (including SIGINT and SIGTERM). Nothing reaches `$GITHUB_ENV`, so later steps don't even see the paths.
- Packages are fetched (`build-ios.sh --resolve`, `build-app.sh --resolve-only`) before any secret is written, so package manifests never run next to one.
- **The archive steps need the API key while third-party code compiles.** Archiving signs for development with automatic signing, which creates the runner's development certificate and profiles through the key (`-allowProvisioningUpdates`). That's the constraint: an unsigned archive would lose its entitlements at export. The key exists for that step only, and the `.p12` isn't on the runner yet.
- The Developer ID `.p12` is imported only for the Mac export and the notarize-and-package step, after everything has compiled, and its keychain is deleted at the end of each. Its password and the keychain's reach `security` on standard input, never a command line.
- The steps that only talk to App Store Connect (looking for an earlier upload, the upload itself, TestFlight) get the key the same way, one command at a time.
- A final `always()` step runs `secrets.sh cleanup` as a backstop, for a step that was killed before it could clean up.

| Step | API key | Developer ID `.p12` | Compiles third-party code |
|---|---|---|---|
| Fetch the packages | | | manifests only |
| Look for this run's build (iPhone); resume a pending notarization (Mac, re-runs) | yes | | |
| Archive (iPhone, Mac) | yes | | **yes** |
| Upload (iPhone), TestFlight (iPhone) | yes | | |
| Export with Developer ID (Mac) | yes | when configured | |
| Notarize, staple, package (Mac) | yes | when configured (signs the DMG) | |

### API key roles

Apple ties each capability to the role of a **team** key, created under App Store Connect › Users and Access › Integrations. The table follows Apple's documentation at the time of writing. The first release run is what confirms it for this team.

| Capability | Admin | App Manager | Developer |
|---|---|---|---|
| Upload builds (`-exportArchive` with `destination: upload`) | yes | yes | yes |
| Notarize (`notarytool --key`) | yes | yes | yes |
| TestFlight: What to Test, beta groups, Beta App Review | yes | yes | no |
| Certificates, identifiers, and profiles through the API, which automatic signing with `-allowProvisioningUpdates` needs (development certificate, profiles, cloud-managed Apple Distribution) | yes | no (a team key can't carry the per-user "Certificates, Identifiers & Profiles" access) | no |
| Cloud-managed **Developer ID** certificate | only if Apple allows it for the key, see below | no | no |

**Use an Admin key.** It's the only team role that can do all of the iPhone path. The key is powerful, so it lives only in the approval-gated `release` environment. Revoke it in App Store Connect if it ever leaks, and generate a new one.

**Developer ID needs the fallback.** Apple restricts Developer ID certificates to the Account Holder. An Admin *user* can use the cloud-managed Developer ID certificate only after the Account Holder grants access in Users and Access; a team key has no such setting. Confirmed on the first release run (2026-10-24): with the Admin key alone, the Mac export fails with "Cloud signing permission error" and "No profiles for 'local.daybook.app' were found". The fallback below covers it. Cloud-managed Apple Distribution, which the iPhone uses, does work with the Admin key.

### Fallback: a Developer ID .p12

If cloud-managed Developer ID signing isn't permitted for the key, give the Mac job the certificate itself. The workflow uses it **only when the `DEVELOPER_ID_P12_BASE64` secret is set**.

1. The Account Holder creates a **Developer ID Application** certificate: Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application, or Certificates on developer.apple.com.
2. Export it with its private key from Keychain Access (My Certificates, the certificate › Export, `.p12`) with a strong password.
3. Store it: `DEVELOPER_ID_P12_PASSWORD='…' scripts/ci/setup-github.sh … --developer-id-p12 path/to/developer-id.p12 --apply`.

In the steps that get it (see [Secrets on the runner](#secrets-on-the-runner)), `secrets.sh` works in this order:

1. It creates a temporary keychain with a random password and imports the `.p12`. Both passwords reach `security` on its standard input (`security -i`), never on a command line where `ps` would show them.
2. It deletes the `.p12` file.
3. It allows codesign to use the key without a prompt (`set-key-partition-list`).
4. It adds Apple's Developer ID G2 intermediate (downloaded, SHA-256 pinned), because macOS ships only the older intermediate.
5. It checks that a Developer ID Application identity is present.

Automatic export doesn't work even then: with a team key it still asks for cloud-managed Developer ID signing and fails before it looks for the profile. So the Mac job's export step (`scripts/ci/mac-export.sh`) signs manually when the keychain is there:

1. It runs `scripts/ci/asc-profile.sh`. It downloads the newest active, **manually managed** Developer ID (`MAC_APP_DIRECT`) profile for the archived app's bundle ID (`local.daybook`) through the API, checks that the profile contains the certificate of the keychain's Developer ID identity, installs it, and sets `DAYBOOK_DEVELOPER_ID_PROFILE` to its UUID. It only reads. Xcode refuses its own managed profiles ("Mac Team Direct Provisioning Profile: …") for a manual export, so the team has a separate one. The first, **"Daybook Developer ID"**, was created through the API on 2026-10-24 for `local.daybook.app` with the Developer ID Application (G2) certificate; the one bundle ID needs its counterpart for `local.daybook` ([One bundle ID](#one-bundle-id), step 4).
2. `build-app.sh --export-only` sees `DAYBOOK_DEVELOPER_ID_PROFILE` and exports with `signingStyle` manual, the "Developer ID Application" certificate, and that profile, leaving the API key out of the export. The archive step still uses the key for development signing.

If the certificate is replaced, step 1 fails with that message: create a new manually managed Developer ID profile for `local.daybook` with the new certificate (Certificates, Identifiers & Profiles, or `POST /v1/profiles` with the Admin key), and export the new certificate's `.p12`. With a local identity, `package-mac.sh` can also sign, notarize, and staple a **DMG**; cloud signing only works inside `-exportArchive`, so a cloud-signed release ships the ZIP alone. When the step's command ends, `secrets.sh` deletes the keychain and restores the keychain search list.

The iPhone app doesn't need a fallback: cloud-managed Apple Distribution is available to an Admin key.

## Secrets and variables

Environment **`release`** secrets:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | the API key's 10-character Key ID |
| `ASC_ISSUER_ID` | the Issuer ID (a UUID, at the top of App Store Connect › Users and Access › Integrations › App Store Connect API) |
| `ASC_KEY_P8_BASE64` | `base64` of `AuthKey_<KeyID>.p8` (downloadable once, when the key is created) |
| `DEVELOPER_ID_P12_BASE64` | optional: `base64` of the Developer ID Application `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | optional: the `.p12` password |
| `DEVELOPMENT_P12_BASE64` | optional: `base64` of the pipeline's Apple Development `.p12` ([Development certificates](#development-certificates)) |
| `DEVELOPMENT_P12_PASSWORD` | optional: its password |

Repository **variables**:

| Variable | Value |
|---|---|
| `DAYBOOK_TEAM_ID` | `48H7CLBV8Y` |
| `DAYBOOK_BUILD_NUMBER_OFFSET` | `1000` (added to the run number; see [Versions](#versions)) |
| `DAYBOOK_TESTFLIGHT_GROUP` | optional: the beta group each build joins, e.g. `Daybook team` |
| `DAYBOOK_RELEASE_XCODE_BUILD` | optional: the exact Xcode build releases must use; unset means `27A9275` (see [Runner and Xcode](#runner-and-xcode)) |
| `DAYBOOK_DEVELOPMENT_CERTIFICATE_ID` | the pipeline's development certificate, which `asc-certificates.sh` never revokes; set by `asc-development-certificate.sh` |

The `release` environment has required reviewers (the owner) and deployment policies for branch `main` and tags `v*`.

`scripts/ci/setup-github.sh` creates all of this from local files. It also sets the repository's Actions and security settings: read-only workflow tokens, required SHA pinning, approval before outside contributors' pull requests run workflows, secret scanning with push protection, and Dependabot alerts and security updates. With `--protect-tags` it adds a ruleset so only admins create, move, or delete `v*` tags. **It prints the plan and changes nothing unless `--apply` is passed.**

## One-time setup

In order, by the owner or their delegate. Steps 1 to 8 were done for the bundle IDs before the one bundle ID (`local.daybook.app` on the Mac, `local.daybook.phone` on the iPhone) and stay as the record; [One bundle ID](#one-bundle-id) redoes the parts that name an ID.

1. **Mac provisioning** (pending). On the owner's Mac, signed in to Xcode with the team, run `DAYBOOK_TEAM_ID=48H7CLBV8Y ./scripts/build-app.sh --allow-provisioning-updates` (README.md, "First-time provisioning"). It registers `local.daybook.app` with iCloud and `iCloud.local.daybook`, and the Developer ID profile. The iOS identifiers and profiles already exist.
2. **The iOS app record.** In App Store Connect › Apps › + › New App:
   - Platform iOS.
   - A **name that's unique on the App Store**. "Daybook" alone is likely taken; something like "Daybook: Conversation Notebook" works. The name can change before release; the bundle ID can't.
   - Primary language English (U.S.).
   - Bundle ID `local.daybook.phone`.
   - A SKU such as `daybook-phone`.

   The Mac app ships outside the App Store and needs no app record.
3. **A beta group.** In the app's TestFlight tab, create an **internal** group, e.g. "Daybook team", and add testers who are App Store Connect users. Internal testers get processed builds at once.

   An **external** group needs Test Information filled in once: beta app description, feedback email, contact, and privacy policy URL. Each build then passes Beta App Review, which `asc-testflight.sh` submits automatically.
4. **The API key.** In App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys:
   - Generate a key named e.g. "GitHub Actions" with **Admin** access. The first time, the Account Holder requests API access.
   - Download `AuthKey_<KeyID>.p8`; it can be downloaded only once.
   - Note the Key ID and the Issuer ID.
5. **Optional:** export the Developer ID `.p12` ([Fallback](#fallback-a-developer-id-p12)).
6. **GitHub.** Make the repository **public** first. Required reviewers on an environment need a public repository on GitHub Free, and macOS runners are free only for public repositories. Then:

   ```sh
   scripts/ci/setup-github.sh --asc-key ~/Downloads/AuthKey_ABC123DEFG.p8 \
       --asc-issuer-id 69a6de70-0000-0000-0000-000000000000 \
       --testflight-group "Daybook team" --protect-tags          # prints the plan
   scripts/ci/setup-github.sh … --apply                          # makes the changes
   ```

   Add `--developer-id-p12 …` for the fallback; the password comes from `$DEVELOPER_ID_P12_PASSWORD` or a prompt. Delete the local `.p8` and `.p12` copies afterwards, or keep them only in a password manager.
7. **The CloudKit courier** (done: a and b before 0.3.0, c on 2026-10-28; d with the first install of 0.4.1). The apps ask for CloudKit and push, so a signed export fails until a and b are done, and the courier stays off in TestFlight and Developer ID builds until c is.

   a. **Capabilities on both App IDs.** developer.apple.com › Account › Certificates, IDs & Profiles › Identifiers:
      - Open **`local.daybook.app`**. Under Capabilities, tick **Push Notifications**. For **iCloud**, choose **Include CloudKit support** (not "Compatible with Xcode 5"), then click **Edit** beside iCloud and check that **`iCloud.local.daybook`** is selected. Click **Save**, then **Confirm** in "Modify App Capabilities".
      - Open **`local.daybook.phone`** and do the same: Push Notifications, iCloud with CloudKit support, `iCloud.local.daybook`. Leave App Groups as they are. `local.daybook.phone.widgets` doesn't change.
      - Don't create an APNs key or push certificate; CloudKit doesn't use them.

   b. **Profiles.** Changing an App ID's capabilities invalidates its profiles.
      - The manually managed Mac profile: Profiles › **Daybook Developer ID** (Developer ID, `local.daybook.app`; now shown as Invalid) › **Edit** › keep the **Developer ID Application (G2)** certificate › **Save**. There's nothing to download: `scripts/ci/asc-profile.sh` installs the newest active one on every run. To check it, download it and run `security cms -D -i "Daybook_Developer_ID.provisionprofile" | plutil -p - | grep -A3 -E "aps-environment|icloud-services"`: it lists `production` and `CloudKit`.
      - Xcode-managed profiles (the iPhone's development and App Store profiles, the Mac's development profile) are regenerated by the release jobs' automatic signing, which already runs with the Admin key and `-allowProvisioningUpdates`. For signed builds on the owner's Mac, the owner runs `DAYBOOK_TEAM_ID=48H7CLBV8Y ./scripts/build-app.sh --debug --allow-provisioning-updates` once (README.md, "First-time provisioning"); apart from the release pipeline (see [How it works](#how-it-works)), no one else passes that flag.

   c. **The CloudKit schema.** icloud.developer.apple.com › CloudKit Console › CloudKit Database › container **`iCloud.local.daybook`**:
      - Choose the **Development** environment › **Schema** › **Record Types** › **+**. Name the type **`CourierFile`** and add these fields: `path` (String), `sha256` (String), `size` (Int(64)), `deviceID` (String), `libraryID` (String), `createdAt` (Date/Time), `asset` (Asset). Save. A development-signed build that sends one recording creates the same type in Development by itself; check that its fields match.
      - Add no indexes: the courier never queries. The `Courier` zone is created by the app at run time; zones aren't part of the schema.
      - Click **Deploy Schema Changes…** (bottom of the sidebar), check that it adds record type `CourierFile`, and **Deploy**. TestFlight and Developer ID builds use **Production**, where an app can't create record types. Until it's deployed, their saves are refused, and the courier turns itself off after three, leaving everything to iCloud Drive.

   d. **Check the first release.**
      - Mac: `codesign -d --entitlements - --xml /Applications/Daybook.app | plutil -p -` lists `CloudKit` under `com.apple.developer.icloud-services`, `com.apple.developer.aps-environment` as `production`, and `com.apple.developer.icloud-container-environment` as `Production`.
      - Both: record on the iPhone with the Mac open. In CloudKit Console › **Production** › **Records** (Private Database, signed in with **Act as iCloud Account** as the test account), zone `Courier`, a `CourierFile` record appears when the recording is filed and is gone once the Mac has stored it.

8. **The pipeline's development certificate** (done 2026-10-28: `JG37U8P26Q`, expires 2027-10-29; renew before then). With the Admin key's variables set ([Development certificates](#development-certificates)), run `scripts/asc-development-certificate.sh`, then `scripts/asc-certificates.sh --older-than 0` and, after reading the list, `--revoke` for the certificates earlier runs made. Release runs then sign their archives with this one. Again each year, before it expires.
9. **One bundle ID** (not done): the steps in [One bundle ID](#one-bundle-id).

## Dependency updates

Dependabot (`.github/dependabot.yml`) opens pull requests every Monday:

- **GitHub Actions**, all in one grouped pull request. It moves each pinned SHA and its version comment together, so pinning (which the repository enforces) stays intact. Check the release notes of anything that runs in the `release` jobs (checkout, the artifact actions, `attest-build-provenance`) before merging.
- **Swift packages.** `Package.swift` pins each one exactly, so every bump is a pull request that changes `Package.swift` and `Package.resolved` together; CI builds and tests it with the new versions. MLX, WhisperKit, FluidAudio, and swift-transformers change model behavior, so check `docs/validation.md` before merging one.

Security updates (for a published advisory) come the same way, outside the weekly schedule.

## Export compliance

App Store Connect asks every iOS build whether it uses encryption.

**The owner has decided:** Daybook uses only **exempt** encryption.

- DaybookLink uses standard TLS, with a pre-shared key from pairing, through Network.framework.
- Everything else uses CryptoKit and Apple's system frameworks. That includes the encrypted library in iCloud
  (`docs/icloud-sync.md`, "Encryption"): AES-256-GCM, HKDF-SHA256, and HMAC-SHA256 from CryptoKit, keys in iCloud
  Keychain. It's standard algorithms from the operating system, not an implementation of Daybook's own, so the answer
  stays exempt; **the owner re-confirms this before the first release that lets people turn encryption on** (App Store
  Connect's questions: proprietary algorithms, no; standard algorithms instead of or beside the OS's, no).
- Nothing implements its own encryption.

The answer is recorded in the app: `Apps/iOS/project.yml` sets `ITSAppUsesNonExemptEncryption: false`, which becomes the key in `DaybookPhone/Resources/Info.plist`. App Store Connect then doesn't ask, and builds never wait at "Missing Compliance".

`scripts/ci/check-ios-archive.sh` **fails a release** if the archived app's Info.plist lacks the key or has anything but boolean `false`. After processing, `asc-testflight.sh` logs the build's `usesNonExemptEncryption`, and warns if App Store Connect is still waiting for an answer.

If Daybook ever adds non-exempt encryption (its own algorithms, or encryption beyond authentication and standard protocols), the owner revisits the answer before the next upload:

- Set `ITSAppUsesNonExemptEncryption` to `true`.
- Provide the export compliance documentation in App Store Connect (App Information › App Encryption Documentation).
- Add the `ITSEncryptionExportComplianceCode` it issues.
- Update the check in `check-ios-archive.sh`.

The Mac's Info.plist (`Resources/Info.plist`) carries the same key: App Store Connect asks the Mac App Store build too, and a Developer ID build ignores it.

## Cutting a release

From an up-to-date `main` whose CI is green. The tag must point at a commit that's on `main`: `prepare` checks it with `git merge-base --is-ancestor` and refuses anything else, so a tag on an unmerged branch never releases. (That guards against mistakes; the tag ruleset and the approval guard against people, because a tag's run uses the workflow files at that tag.)

```sh
git tag -a v1.4.0 -m "Daybook 1.4.0: two-page reading on iPhone Duo"
git push origin v1.4.0
```

Then approve the run: Actions › Release › Review deployments › `release` › Approve. One approval covers both the iPhone and Mac jobs.

- The tag's message opens the GitHub Release notes and What to Test, followed by the commits since the previous tag.
- The iPhone build appears in TestFlight, in `DAYBOOK_TESTFLIGHT_GROUP`, once processed. "Daybook Internal" is an internal group with access to every build, so each build reaches it by itself; `asc-testflight.sh` only adds builds to groups without that access (App Store Connect refuses it otherwise: 422 "Builds cannot be assigned to this internal group").
- The Mac ZIP (and DMG), with `SHA256SUMS.txt`, are attached to a **draft** GitHub Release as soon as the Mac job finishes. The release is published, and becomes "Latest" unless it's a prerelease, only after the iPhone build is on TestFlight. If the iPhone job fails, the release stays a draft: re-run the failed job, and `publish` runs after it. To ship the Mac app without the iPhone one, publish the draft by hand (Releases › the draft › Edit › Publish release).
- A tag run with `apps: mac` publishes as soon as the draft is ready. With `apps: iphone` there are no Mac files, so there's no GitHub Release.

A tag such as `v1.4.0-rc.1` releases marketing version 1.4.0 and marks the GitHub Release as a prerelease.

A manual run, for example a TestFlight build from `main` without a tag:

```sh
gh workflow run release.yml --ref main -f apps=iphone -f version=1.4.0 \
    -f testflight_group="Daybook team" -f testflight_notes="Try two-page reading with the phone open."
```

- `apps` is `both`, `iphone`, or `mac`.
- From `main`, `version` is required.
- On a tag (`--ref v1.4.0`), the tag sets the version.
- `testflight_group` overrides the variable, and `none` skips adding the build to a group.
- `sandbox` (default off) builds the Mac app in the App Sandbox with the container migration manifest, and makes the GitHub Release a prerelease whatever the tag says. Its first launch moves the library into the app's container: see [Shipping the sandboxed build](sandbox.md#shipping-the-sandboxed-build) for the owner's steps (a pushed tag's own run is rejected, then the tag is released by hand with `-f apps=mac -f sandbox=true`).
- A manual Mac run from `main` produces the notarized artifacts on the run's page, with no GitHub Release; releases come only from tags.

### Re-running

- **Re-run failed jobs** re-runs the failed jobs and the jobs after them, after a new approval. Each re-run job works out its own build number (`1057.2`; see [Versions](#versions)).
- A re-run Mac job picks up an app notarization its previous attempt left pending (see [How it works](#how-it-works)), so it keeps that attempt's build number.
- The `draft` job updates its own draft: title, notes, and prerelease flag again, files that this attempt didn't produce (a DMG, say) deleted, the rest replaced.
- A **published** release is never changed. `draft` fails instead of swapping files people may already have downloaded, and its `SHA256SUMS.txt` would no longer match them. Cut a new version, or roll back first.

### Rolling back

If a release turns out to be broken:

1. **Unpublish the GitHub Release** so nobody else downloads it: `gh release edit v1.4.0 --draft=true` (or Releases › Edit › "Save as draft"). To keep it visible but out of "Latest", mark it a prerelease instead: `gh release edit v1.4.0 --prerelease`. Make the previous good release "Latest" again with `gh release edit v1.3.2 --latest`.
2. **Expire the TestFlight build**: App Store Connect › the app › TestFlight › the build › Expire Build. Testers can't install it any more, and the expired build stops opening; they can go back to an earlier build under Previous Builds in the TestFlight app.
3. **Ship the fix as a new version** (`v1.4.1`). Don't move or reuse the tag: the tag ruleset blocks it, App Store Connect never takes a build number twice, and people may have the old files. If you'd rather redo the same version, delete the draft or unpublished release and its tag (an admin), then tag again: the new run gets a new run number, so a new build number.

### Versions

- `MARKETING_VERSION` (`CFBundleShortVersionString`) comes from the tag: `vX.Y.Z` gives `X.Y.Z`. `scripts/ci/version.sh` rejects anything else, because App Store Connect accepts three integers at most.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is `DAYBOOK_BUILD_NUMBER_OFFSET + github.run_number`, e.g. `1057`. The run number belongs to `release.yml` and only grows. The offset keeps CI builds above anything uploaded by hand from Xcode.
- Attempt 2 of a run becomes `1057.2`, attempt 3 `1057.3`. That still sorts above `1057` and below `1058`, so a re-run never collides with a build already uploaded.
- The `iphone` and `mac` jobs each work the number out themselves (`scripts/ci/version.sh`) from their own `github.run_attempt`. "Re-run failed jobs" doesn't re-run `prepare`, so a number from there would repeat attempt 1's; that's how v0.2.2's re-run (run 40128648407, attempt 2) uploaded build 1004 a second time.
- Before archiving, and again before uploading, the iPhone job asks App Store Connect for this run's builds of the version: every number the run has used so far (`1057`, `1057.2`, …). If one is there and didn't fail processing, the job skips the archive and the upload and goes straight to `asc-testflight.sh` with it. So re-running a job whose upload went through (it then failed waiting for processing, or adding the build to a group) finishes that build instead of uploading another.
- A build with one of those numbers that was uploaded *before* the run was created can't be this run's: the number collided with an older upload (the offset went down, or `release.yml` was recreated). The job fails and says to raise the offset.
- Both apps and the widget extension get the same pair, set as build settings on the xcodebuild command line, so neither `project.yml` changes. If only one app's job is re-run, its build number moves on (`1057.2`) and the other's stays `1057`.
- If `release.yml` is ever renamed or recreated, its run number restarts. Raise the offset above the last uploaded build number first.

### Verifying a download

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify Daybook-1.4.0-macOS-arm64.zip --repo vladzaharia/daybook \
    --signer-workflow vladzaharia/daybook/.github/workflows/release.yml
spctl -a -vv /Applications/Daybook.app      # "source=Notarized Developer ID"
xcrun stapler validate /Applications/Daybook.app
```

The Mac job attests every file in `SHA256SUMS.txt` with `actions/attest-build-provenance`: a Sigstore-signed SLSA provenance statement naming the repository, `release.yml`, the commit, and the run that built it. `gh attestation verify` checks the file's digest against it, so a download that didn't come from this workflow fails. The attestations are listed under the repository's Actions › Attestations.

## One bundle ID

The iPhone app and the Mac app are one app in App Store Connect, `local.daybook`, so TestFlight and the App Store can carry both, and one purchase covers both (universal purchase). Apple requires one bundle ID for every platform of a record ([App Store Connect Help: Add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/); docs/research/one-bundle.md has the rest).

| Build | Bundle ID | Sandboxed | Ships through |
|---|---|---|---|
| iPhone | `local.daybook`, widgets `local.daybook.widgets`, tests `local.daybook.tests` | yes (iOS) | TestFlight, then the App Store |
| Mac, Developer ID (the default) | `local.daybook` | no | the GitHub Release, notarized |
| Mac, App Store (`--app-store`) | `local.daybook` | yes | TestFlight, then the Mac App Store |
| Mac, Developer ID with `--sandbox` (`sandbox` input) | `local.daybook` | yes | a GitHub prerelease |
| Mac, ad hoc / rehearsal | `local.daybook.adhoc` / `local.daybook.rehearsal…` | yes | nowhere |
| Before: Mac / iPhone / widgets | `local.daybook.app` / `local.daybook.phone` / `local.daybook.phone.widgets` | | retired |

The app group is `group.local.daybook` (it was `group.local.daybook.phone`; it holds only the widgets' recording state). The iCloud container, `iCloud.local.daybook`, and the shared keychain group, `<team>.local.daybook.shared`, don't change.

### What carries over

- **The Mac, in place** (an update from a `local.daybook.app` release): the library (`~/Library/Application Support/Daybook`, whose path doesn't depend on the bundle ID); the preferences, copied once at launch from the `local.daybook.app` domain, which stays as it was (`PreferencesCarryOver`: devices, model choices, sync's device ID and installation, the recorded iCloud account, every setting); keychain items, read through `<team>.local.daybook.app`; the iCloud account, which sync recognizes by the container holding this library's journal (iCloud's token is per app; docs/icloud-sync.md); and the sync identity, so the iPhone reconnects without pairing again. macOS asks again for the microphone, System Audio Recording, Bluetooth, the local network, and notifications: they belong to the bundle ID. An App Store build that takes over a Developer ID install moves the library and both preferences files into its container (docs/sandbox.md, "One bundle ID"). Going back to a `local.daybook.app` release works for the library and preferences, which stay where they were or are left untouched; pairings made since, and a sync identity rewritten since, are in `<team>.local.daybook`, which an earlier release can't read.
- **The iPhone** gets a new app: iOS keeps each app's files in its own sandbox, and the new one can't read the old one's. The library comes back through iCloud, conversations at once and audio on demand. Library and cloud keys come through the shared group and iCloud Keychain, and the old app's pairing keys and sync identity through `<team>.local.daybook.phone`, so the Mac recognizes the new app as the same iPhone, without pairing again. What doesn't carry over: recordings the old app hasn't synced yet; live captions (never synced); recordings brought in on the old app, which the new one won't transcribe itself (a Mac will); the iPhone's own settings (recording, live captions, Transcribe on This iPhone, backups, cloud preferences; keys stay); downloaded models (download again, on Wi‑Fi); and widgets and controls added to the Home Screen, Lock Screen, or Control Center (add them again).
- **For testers:** open the old app until Settings says it's up to date, so every recording has reached iCloud, then delete it, and install the new one from TestFlight. Don't run both: they would sync as the same iPhone.

### Building and uploading

```sh
scripts/build-ios.sh --archive --export upload          # the iPhone app, as local.daybook
scripts/build-app.sh --app-store --archive-only         # the Mac's App Store archive, sandboxed
scripts/build-app.sh --app-store --upload               # archives and uploads it to App Store Connect
scripts/ci/asc-testflight.sh --bundle-id local.daybook --platform MAC_OS --version 1.4.0 --build 1057 --group "Daybook team"
```

`--app-store` is a signed Release build only (it refuses `--debug` and ad hoc builds, like `--sandbox`), and is never launched on a development Mac: the first sandboxed launch as `local.daybook` creates that Mac's container, and macOS runs the migration manifest only then. `scripts/ci/check-mac-app.sh --kind signed-sandbox` checks the archived app. Each platform has its own versions and builds in the record, so the Mac can use the same marketing version and build number as the iPhone.

`release.yml` still names `local.daybook.phone` in the iPhone job and has no Mac TestFlight job: the exact changes are in docs/research/one-bundle.md, "release.yml", for the owner to apply.

### The owner's steps

In order, by the account owner; nothing here is done by a script.

1. **Register the identifiers.** developer.apple.com › Account › Certificates, IDs & Profiles › Identifiers › **+** › App IDs › App: `local.daybook` (description "Daybook"), then `local.daybook.widgets` ("Daybook Widgets"). Under App Groups › **+**, register `group.local.daybook`.
2. **Capabilities.** On `local.daybook`: **iCloud** with **Include CloudKit support**, then **Edit** and select `iCloud.local.daybook`; **Push Notifications**; **App Groups**, **Edit**, `group.local.daybook`; **Hotspot**; **Increased Memory Limit** and **Background GPU Access** (for the iPhone's summaries; docs/iphone.md, "Processing on this iPhone"). On `local.daybook.widgets`: **App Groups** with `group.local.daybook`. Don't create an APNs key: CloudKit doesn't use one.
3. **The App Store Connect record.** Apps › **+** › New App: platforms **iOS** and **macOS**, a name that's unique on the App Store (the current record's name can be freed by renaming it first), primary language English (U.S.), bundle ID `local.daybook`, a new SKU such as `daybook`. Then Pricing and Availability › iPhone and iPad Apps on Apple Silicon Mac: clear **Make this app available** (the Mac app is the Mac's). A platform can be deleted only until a build is uploaded for it, and once App Review approves two platforms the app is a universal purchase for good. Fill in the export compliance answer as before ([Export compliance](#export-compliance)).
4. **The Developer ID profile.** Profiles › **+** › Developer ID › `local.daybook` › the **Developer ID Application (G2)** certificate › name it "Daybook Developer ID (local.daybook)". `scripts/ci/asc-profile.sh` finds it by the archived app's bundle ID. Then, on the owner's Mac: `DAYBOOK_TEAM_ID=48H7CLBV8Y ./scripts/build-app.sh --debug --allow-provisioning-updates` (development profiles for `local.daybook`), and `DAYBOOK_TEAM_ID=48H7CLBV8Y ./scripts/build-app.sh --app-store --allow-provisioning-updates`, which makes the Mac App Store profile and, if the team has none, the Mac Installer Distribution certificate that signs the `.pkg` (unverified: if Xcode doesn't offer it, create one in Xcode › Settings › Accounts › Manage Certificates). Check the profiles: `security cms -D -i <profile> | plutil -p -` lists `48H7CLBV8Y.*` under `keychain-access-groups`, `iCloud.local.daybook`, and CloudKit.
5. **`release.yml`.** Apply the changes in docs/research/one-bundle.md, "release.yml".
6. **TestFlight groups.** In the new record's TestFlight tab, create the internal group (the name `DAYBOOK_TESTFLIGHT_GROUP` says, e.g. "Daybook team") and add the testers; an external group needs Test Information filled in once. Run a release (`gh workflow run release.yml --ref main -f apps=both -f version=…`), and for the Mac's first build `-f mac_testflight=true` once the job is there. Testers follow "For testers", above.
7. **Retire `local.daybook.phone`.** Once testers are on the new app: in the old record's TestFlight tab, expire its builds and remove its groups' testers; if App Store Connect offers it (App Information › **Remove App**, for an app never released), remove the record. Leave the old identifiers registered: deleting an App ID frees nothing, and keeping it keeps the keychain group `<team>.local.daybook.phone` meaningful. The CloudKit container and its Production schema don't change.

What the first builds should be checked for: on the Mac, the library, devices, and models arrive without Welcome, sync carries on without "the iCloud account changed", and the iPhone reconnects without pairing again; on the iPhone, the library arrives through iCloud and the Mac recognizes it; on the Mac's TestFlight build, also process taps or ScreenCaptureKit for a call, and Settings › Library showing the container's path. The App Sandbox's own checks are in docs/sandbox.md.

## Known blockers

- **The iPhone app has no app icon.** `ASSETCATALOG_COMPILER_APPICON_NAME` is empty and the asset catalog has no AppIcon, so App Store Connect would reject the upload (ITMS-90713 / ITMS-90022). The release job stops at the archive check until there is one: add an AppIcon to `DaybookPhone/Resources/Assets.xcassets` and set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `Apps/iOS/project.yml`.
- **Mac provisioning** (step 1 of One-time setup) must be done before the Mac export can get its Developer ID profile with iCloud.
- **One bundle ID.** The next tagged release fails until the owner's steps in [One bundle ID](#one-bundle-id) are done. With `release.yml` as it is, CI passes, then both signing jobs fail and nothing is released (`draft` and `publish` never run). The `iphone` job fails at **Archive DaybookPhone with its widget extension** if automatic signing can't register `local.daybook` and `local.daybook.widgets` with their capabilities through the API key (unverified whether it can), and otherwise at **Export and upload to App Store Connect**, which finds no app record for `local.daybook`. The `mac` job fails at **Export with Developer ID**, where `asc-profile.sh` finds no Developer ID profile for `local.daybook` (or at **Archive**, for the same reason as the iPhone's). With the `release.yml` changes applied and no record yet, the `iphone` job's first step that asks App Store Connect, **Look for this run's build**, fails first, before anything is archived.
- **The Mac on TestFlight** also needs the App Sandbox's hardware checks (docs/sandbox.md) before its first upload.
- **The CloudKit courier** (step 7 of One-time setup): until Push Notifications and CloudKit are on both App IDs and the "Daybook Developer ID" profile is regenerated, both exports fail, because the apps' entitlements now include them. Until the schema is deployed to Production, released apps sync through iCloud Drive alone.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Jobs on `xcode-27` wait in the queue for a long time | The image is a preview with limited capacity (#14404). Wait, or re-run later. |
| `Xcode_27.1.app isn't installed on this runner`, or `expected Xcode 27.1` | The image changed. Check the readme's Xcode table and update `DAYBOOK_XCODE` in both workflows (and `--expect` if the version moves on). |
| Release: "Xcode 27.1 … is build 27A…, not 27A9275" | The image moved to another Xcode build. Once CI has passed with it, set the `DAYBOOK_RELEASE_XCODE_BUILD` repository variable to the new build and re-run. |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | The download in `select-xcode.sh --metal` failed or was skipped. Re-run; it retries three times. |
| `Unable to find a device matching the provided destination specifier` | The simulator set changed. `pick-simulator.sh` prints what it chose; run `xcrun simctl list devices available` in a step to see what's there. |
| "Passed on retry" warning | A timing-sensitive test (the package's budget test, or one of the iPhone encoder tests) failed once on a slow VM and passed on its retry. Occasional is expected. Every run means a real slowdown: compare the timings in the log with `docs/validation.md`, and the nightly CI under load run. |
| CI is slow after a dependency or Xcode change | The cache key changed. The first push to `main` saves a new cache, and its `caches` job then deletes the superseded one. |
| Archive: "No signing certificate 'iOS Development' found" or "No Account for Team" | The API key isn't being used or lacks the role. Check the three `ASC_*` secrets and that the key is a **team** key with **Admin** access. |
| Mac export: cloud signing permission error, or no "Developer ID Application" certificate | Cloud-managed Developer ID isn't available to the key. Add the [.p12 fallback](#fallback-a-developer-id-p12). |
| `secrets.sh`: "the .p12 has no valid Developer ID Application identity" | The `.p12` lacks the certificate or the key. Export from Keychain Access › My Certificates, selecting the **certificate** row (not the key); the file is about 3 KB. |
| Upload: "exportArchive The request timed out" (or another network error) | The runner lost the network. `build-ios.sh` tries the upload three times on network errors only; if all fail, re-run the failed iPhone job (Actions › the run › Re-run failed jobs, then approve). If one of the uploads did reach App Store Connect, the re-run finds that build and finishes it without uploading again; otherwise it archives and uploads with the next attempt's build number (`1057.2`). An abandoned upload stays "awaiting upload" in App Store Connect without blocking anything. |
| The upload succeeds but the build never appears in TestFlight | Processing rejected it after the upload; the Account Holder gets an email, and `GET /v1/apps/{id}/buildUploads` shows the errors. ITMS-90626 ("Invalid Siri Support", an App Intent string naming an Apple product such as iPhone) is caught by `check-ios-archive.sh` before the upload. |
| Upload rejected: "you need to include all of the … orientations to support iPad multitasking" | The app was built for iPad too. Every target in `Apps/iOS/project.yml` keeps `TARGETED_DEVICE_FAMILY: "1"` (XcodeGen's presets set "1,2"); `check-ios-archive.sh` checks `UIDeviceFamily`. |
| "requires a provisioning profile with the iCloud feature", or the container can't be assigned | Mac provisioning hasn't been done (One-time setup, step 1). |
| `package-mac.sh`: lacks the `iCloud.local.daybook` entitlement | The export signed without the Developer ID profile. Same fix as above. |
| Mac export: the "Daybook Developer ID" profile doesn't include `com.apple.developer.aps-environment` or the CloudKit service | The profile predates the courier's capabilities. Enable them and regenerate the profile (One-time setup, step 7a–b). |
| Archive: the profile doesn't support Push Notifications, or doesn't include the `aps-environment` entitlement | Push Notifications isn't on the App ID yet (One-time setup, step 7a). |
| Signing: "the provisioning profile grants it (`aps-environment`) for the value 'development'" | Something set `DAYBOOK_APS_ENVIRONMENT` to `production`. Keep `development`; the export re-signs it `production` (see [Capabilities and entitlements](#capabilities-and-entitlements)). |
| TestFlight or Developer ID: recordings reach the Mac only at iCloud Drive's pace | The courier is off. Usually the schema isn't deployed to Production (step 7c); also check the entitlements (step 7d) and that the person is signed in to iCloud. `LibrarySyncController.courierStatus.availability` and `lastError` say why. |
| Notarization `Invalid` | `package-mac.sh` prints Apple's log; it names each file and the problem (unsigned code, missing hardened runtime, no secure timestamp). |
| "Notarization still in progress" (exit 75) | Apple took longer than the 45-minute wait. Re-run the failed job within 7 days: it resumes that submission (the run summary has its ID). `xcrun notarytool info <id>` shows its status meanwhile. |
| Upload rejected: ITMS-90713 or ITMS-90022 (icon) | See [Known blockers](#known-blockers). `check-ios-archive.sh` catches this before the upload. |
| Upload rejected: the bundle version must be higher, or a redundant binary; or `asc-testflight.sh`: "… was uploaded at …, before this run started" | That build number belongs to an older upload: the offset went down, or `release.yml` was recreated. Raise `DAYBOOK_BUILD_NUMBER_OFFSET` above the highest build number in App Store Connect and run the release again. |
| `no App Store Connect app has the bundle ID local.daybook` (or `local.daybook.phone`) | Create the app record ([One bundle ID](#one-bundle-id), step 3), and check that `release.yml` names `local.daybook`. |
| `no beta group named …` | The message lists the app's groups. Fix `DAYBOOK_TESTFLIGHT_GROUP` or the `testflight_group` input. |
| Beta App Review submission fails | An external group needs the app's Test Information filled in once in TestFlight. |
| Build not processed within the timeout | App Store Connect is slow. The build usually finishes later; set What to Test and the group in App Store Connect. |
| An archive fails: "Your account has reached the maximum number of certificates" | Archives have been creating development certificates: the pipeline's isn't set up, or has expired. Run `scripts/asc-certificates.sh --older-than 0`, then `--revoke`, and set up the pipeline's certificate with `scripts/asc-development-certificate.sh` ([Development certificates](#development-certificates)). Then re-run the failed jobs. |
| `secrets.sh` warns: "the development .p12 has no valid Apple Development identity" | The pipeline's certificate expired or was revoked. The release goes on, creating a certificate; run `scripts/asc-development-certificate.sh` for a new one. |
| `build-app.sh` or `build-ios.sh`: "The App Store Connect API key is for the release pipeline only" | The `DAYBOOK_ASC_*` variables are set outside `release.yml` on GitHub Actions. Unset them; build with your Xcode account and existing profiles. |
| The tag was pushed and nothing ran | Check Actions › Release: the run is waiting for approval in `release`. A tag that isn't `vX.Y.Z[-suffix]` fails in `prepare`. |
| `prepare`: "v1.4.0 points at …, which isn't on main" | The tag is on a commit that isn't merged. Delete the tag (an admin, with the ruleset), merge, and tag the merged commit. |

## Checking the pipeline locally

None of these uses a team, a secret, or the network beyond package checkouts:

```sh
actionlint                                       # uses .github/actionlint.yaml
scripts/ci/tests/run-tests.sh --require-all      # every group on macOS (Linux skips the macOS-only ones): version, JWT, App Store Connect calls (mock), notes, ref checks, GitHub Release (fake gh), archive checks, setup dry run, secrets, build scripts (stand-in Xcode tools)
scripts/ci/version.sh --ref refs/tags/v1.2.3 --run-number 42
scripts/build-ios.sh --archive --no-sign --marketing-version 1.2.3 --build-number 1042
scripts/ci/check-ios-archive.sh Apps/iOS/build/DaybookPhone.xcarchive --version 1.2.3 --build 1042
scripts/build-app.sh --ad-hoc --marketing-version 1.2.3 --build-number 1042
scripts/ci/package-mac.sh --app dist/Daybook.app --version 1.2.3 --build 1042 --output /tmp/daybook-release   # no --notarize: nothing is sent
scripts/ci/setup-github.sh --asc-key AuthKey_ABC123DEFG.p8 --asc-issuer-id <uuid>               # dry run
```
