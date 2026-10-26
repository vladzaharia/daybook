# Releases and CI

Two GitHub Actions workflows build Daybook on GitHub-hosted Macs:

- **CI** (`.github/workflows/ci.yml`) builds and tests every push to `main`, every pull request, and manual runs.
- **Release** (`.github/workflows/release.yml`) ships a `v*` tag, or a manual run from `main`. The iPhone app goes to TestFlight. The Mac app is signed with Developer ID, notarized, and attached to a GitHub Release.

Signing uses an App Store Connect API key with Xcode's cloud-managed signing. A Developer ID `.p12` is an optional fallback for the Mac app.

## Pipeline

| Workflow | Job | Runner | What it does |
|---|---|---|---|
| CI | `lint` | `ubuntu-24.04` | actionlint (pinned, checksum-verified, with shellcheck on every `run:` block), shellcheck on the scripts (`build-app.sh` and `build-ios.sh` too; every script is bash), and `scripts/ci/tests/run-tests.sh` |
| CI | `package` | `xcode-27` | `swift build --build-tests` once, then `swift test --skip-build` per test-target group, then the timing-budget test alone (see below) |
| CI | `iphone` | `xcode-27` | `scripts/build-ios.sh --test` on a simulator (iPhone Duo if the image has one, otherwise iPhone 18 Pro), the crash-recovery test alone, then an unsigned Release device archive checked the way a release would be |
| CI | `mac` | `xcode-27` | `scripts/ci/tests/run-tests.sh --require-all` (every group, including the macOS-only ones: CryptoKit's JWT check, the archive checks, the upload retry, the build scripts, and the keychain), then `scripts/build-app.sh --debug --ad-hoc` (Release with the `mac_configuration` input), then the bundle is checked for its signature, icon, and MLX `default.metallib` |
| Release | `prepare` | `ubuntu-24.04` | checks the ref (`scripts/ci/check-ref.sh`: a `v*` tag must point at a commit on `main`), works out the version (`scripts/ci/version.sh`) and when the run was created, and writes release notes and What to Test (`scripts/ci/release-notes.sh`) |
| Release | `iphone` | `xcode-27`, environment `release` | works out its build number (see [Versions](#versions)), looks for this run's build in App Store Connect, archives `DaybookPhone` with `DaybookPhoneWidgets` (`build-ios.sh --archive`), checks the archive (`check-ios-archive.sh`), exports with `app-store-connect` and uploads it (`build-ios.sh --export upload`), then waits for processing, sets What to Test, and adds the build to the beta group (`asc-testflight.sh`) |
| Release | `mac` | `xcode-27`, environment `release` | works out its build number, fetches the packages, archives (`build-app.sh --archive-only`), exports with `developer-id` (`mac-export.sh`, which runs `build-app.sh --export-only`), then notarizes, staples, and writes the ZIP, a DMG when possible, and `SHA256SUMS.txt` (`package-mac.sh`) |
| Release | `draft` | `ubuntu-24.04` | tags only, after `mac`: verifies the checksums and creates the GitHub Release as a **draft** with the Mac files (`scripts/ci/github-release.sh draft`). A re-run updates its own draft; it never touches a published release |
| Release | `publish` | `ubuntu-24.04` | tags only, after `draft` and, when the run releases the iPhone app, after `iphone` succeeded: publishes the draft (`github-release.sh publish`). `draft` and `publish` are the only jobs with `contents: write`, and they hold no Apple secrets |

Hardening:

- Every workflow starts from `permissions: {}`, and each job asks for `contents: read` (or `write` in `draft` and `publish` only).
- Actions are pinned to commit SHAs, with the version in a comment. Checkouts don't persist credentials.
- Nothing uses `pull_request_target`.
- Concurrency groups cancel superseded pull request runs and never cancel a release. CI's group includes the workflow's name, which is "Release" when `release.yml` calls it, so a push to `main` can't queue behind or replace a release's validation.
- Secrets are environment secrets in `release`. Only jobs that a reviewer approved can read them, and only from `main` or a `v*` tag. Each secret is passed only to the steps that need it, and becomes a file only while such a step runs: see [Secrets on the runner](#secrets-on-the-runner).
- Runners are GitHub-hosted only. The repository's `.github/actionlint.yaml` lists `xcode-27` under actionlint's `self-hosted-runner` key only because actionlint 1.7.12 predates the label. It's GitHub-hosted.

## Runner and Xcode

- **Label:** `runs-on: xcode-27`, the Xcode 27 image, a public preview announced in [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404). The readme is [`images/macos/xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md); image 20261012.0260.1 runs macOS 27.0.1 on arm64. That label is the standard size, free for public repositories. `xcode-27-xlarge` is a paid larger runner and isn't used.
- **Xcode:** 27.1 (27A9275, the same build as the development Macs), selected with `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer` by `scripts/ci/select-xcode.sh`. That script fails if the version isn't 27.1 or a required SDK is missing. On this image `Xcode.app` is 27.0, and `Xcode_27.1.app` links to `Xcode_27.1_Release_Candidate.app`. The image's next rollout ([#15011](https://github.com/actions/runner-images/pull/15011)) installs the 27.1 release at the same path and makes it the default.
- **SDKs and simulators:** the iOS 27.1 SDK is there; it has the iPhone Duo hinge APIs. The image preinstalls only the iOS 27.0 simulator runtime: iPhone 17, 17e, 18 Pro, 18 Pro Max, Air, and iPads, with **no iPhone Duo**. Apple's iOS 27.1 simulator runtime supports only the iPhone Duo device type ([#15000](https://github.com/actions/runner-images/issues/15000)). So CI tests on **iPhone 18 Pro with iOS 27.0**, built with the 27.1 SDK. The `#available(iOS 27.1, *)` hinge code compiles there but doesn't run. `scripts/ci/pick-simulator.sh` prefers an iPhone Duo, so CI moves to one with no change once an image ships it. Exercising the Duo on CI today would mean downloading the runtime in the job (`xcodebuild -downloadPlatform iOS`, several GB). The Duo checks stay local, as in `docs/iphone.md`.
- **Metal toolchain:** the image doesn't include it, so `select-xcode.sh --metal` runs `xcodebuild -downloadComponent MetalToolchain` (with retries) in the jobs that build MLX.
- **Packages:** every build uses only the versions `Package.resolved` pins. `swift build` runs with `--force-resolved-versions`, and CI then checks `git diff --exit-code -- Package.resolved`. `build-app.sh` and `build-ios.sh` copy the file into the generated project, resolve with `-onlyUsePackageVersionsFromResolvedFile` (as every build, test, and archive does), and fail if Xcode would change it. `build-app.sh --resolve-only` and `build-ios.sh --resolve` only fetch the packages.
- **XcodeGen:** 2.45.4, the version the projects are developed with, installed by `scripts/ci/install-xcodegen.sh`. It downloads the release ZIP and checks its SHA-256.

## CI details

**Caches.** MLX, WhisperKit, and FluidAudio dominate the build.

- `package` caches `.build`.
- `iphone` caches its derived data, without logs and the index.
- `mac` caches its derived data and `SourcePackages`, per configuration.

Keys combine the Xcode build with a hash of `Package.resolved`, `Package.swift`, and the project spec. Only pushes to `main` save a cache, and only when the key is new. Pull requests restore from the base branch and never save, so they can't fill or poison the 10 GB cache quota. A dependency or Xcode change starts a new cache. Older ones age out. Run CI manually with `clean` ticked to build without caches.

**Timing-sensitive tests.** Two tests have time budgets that an overloaded machine can miss:

- `AudioAlignerTests.testThirtyMinutePairAlignsWithinBudget` must align a 30-minute pair within 15 s. On a development Mac at load average 50 it takes 1 to 4 s.
- The iPhone test `testCrashRecoveryProducesAudioNotesAndBookmarks` waits up to 30 s for the encoder's utility queue to reach the disk.

Neither test is disabled. Hosted runners are small shared VMs, so CI runs each one **on its own, after everything else has built and run, with one retry**:

- The package test runs through `scripts/ci/retry.sh 2`. A pass on the second attempt leaves a "Passed on retry" warning on the run.
- The iPhone test runs with `-retry-tests-on-failure -test-iterations 2`, which reruns only a failed test and records both attempts in the result bundle.

The main runs skip just these tests (`--skip` and `-skip-testing`), and the iPhone tests run with `-parallel-testing-enabled NO`. A real regression fails twice and fails the job. A retry warning that keeps coming back means the budget needs a look.

**Artifacts.** On failure, CI uploads the swift test logs, the iPhone `.xcresult` bundles and Xcode logs, or the Mac build logs. They're kept for 14 days.

**The release check in CI.** The `iphone` job runs `check-ios-archive.sh` on an unsigned archive with `continue-on-error`. Problems that would block a release then show up on every run without failing it. Today it reports the missing app icon (see [Known blockers](#known-blockers)).

## Signing

### How it works

Every release job authenticates Xcode with the App Store Connect API key. The key goes to xcodebuild as `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID`, together with `-allowProvisioningUpdates`. The release jobs never pass `-allowProvisioningDeviceRegistration`, so runners are never registered as devices.

That's the one exception to "nothing but the owner's first-time provisioning passes `-allowProvisioningUpdates`" (AGENTS.md): the release pipeline, authenticated by the key in the approval-gated `release` environment. `build-app.sh` and `build-ios.sh` refuse the key unless they run on GitHub Actions under `release.yml`, so a local build or an agent can't reach that path by setting the variables.

- **Archive** (`build-ios.sh --archive`, `build-app.sh`): automatic signing with Apple Development.
  - A fresh runner has no development certificate, so Xcode creates one through the key. It appears in the account as *Apple Development: Created via API*.
  - Xcode fetches or creates the development profiles for the existing identifiers.
  - These certificates sign nothing that ships, and revoking old ones is harmless: see [Development certificates](#development-certificates).
- **Export** (`-exportArchive`): the archive is re-signed for distribution with a **cloud-managed** certificate. The private key stays with Apple, so no certificate or `.p12` is exported anywhere.
  - The iPhone export uses Apple Distribution with the App Store profiles.
  - The Mac export uses Developer ID Application with the Developer ID profile that carries the iCloud container.
  - The iPhone export uses `destination: upload`, which sends the build straight to App Store Connect.
- **Notarization:** `xcrun notarytool submit --key --key-id --issuer --wait` with the same key. Then `xcrun stapler staple` runs, and `spctl` assesses the result.

### Development certificates

Each release run's archives add an *Apple Development: Created via API* certificate to the team. `scripts/asc-certificates.sh` lists them and revokes old ones; it's for the owner, with the Admin key:

```sh
export DAYBOOK_ASC_KEY_PATH=~/keys/AuthKey_ABC123DEFG.p8 DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID=<issuer uuid>
scripts/asc-certificates.sh                      # dry run: lists them, with their age; changes nothing
scripts/asc-certificates.sh --revoke             # revokes the ones older than 30 days (--older-than N)
```

- It considers only development certificates (Apple, iOS, or Mac Development) named "Created via API". Distribution and Developer ID certificates, and people's own development certificates, are never touched.
- Age comes from the expiration date (development certificates last a year). The 30-day default keeps the certificate of any release run that might still be going.
- When: every few months, after a run of releases, or when Certificates, Identifiers & Profiles lists more than a handful, or Xcode reports that the team has reached its certificate limit. Run the dry run first and read the list.
- Nothing shipped depends on these certificates: TestFlight and Developer ID builds are re-signed for distribution at export.

### Capabilities and entitlements

| App ID | Capabilities on the account | Signed entitlements |
|---|---|---|
| `local.daybook.app` (Mac) | iCloud with iCloud Documents and CloudKit, container `iCloud.local.daybook`; Push Notifications | `Resources/Daybook.entitlements`: audio input; `com.apple.developer.icloud-services` = `CloudDocuments`, `CloudKit`; the container in `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.ubiquity-container-identifiers`; `com.apple.developer.aps-environment` |
| `local.daybook.phone` (iPhone) | App Groups (`group.local.daybook.phone`); iCloud with iCloud Documents and CloudKit, container `iCloud.local.daybook`; Push Notifications | `Apps/iOS/project.yml`: the same iCloud keys, `aps-environment`, the app group. Info.plist's `UIBackgroundModes` adds `remote-notification` (not a capability) |
| `local.daybook.phone.widgets` | App Groups | the app group only |

- CloudKit and push serve the courier (`docs/icloud-sync.md`, "Courier (CloudKit)"). `CKSyncEngine` needs both; CloudKit sends its own pushes, so there's no APNs key or certificate.
- **Push is `development` in the files and `production` in what ships.** `DAYBOOK_APS_ENVIRONMENT` in each `Config/Signing.xcconfig` is `development`, which is what Apple Development profiles grant, and archives are signed that way. The exports re-sign with the distribution profile, so TestFlight (App Store profile) and Developer ID builds carry `production` and use CloudKit's **Production** environment, Xcode setting `com.apple.developer.icloud-container-environment` to `Production`. Writing `production` into the files instead fails development signing: "the provisioning profile grants it for the value 'development'". Apple's guidance is the same: keep `development` and let the export re-sign it.
- Ad hoc and local builds (`build-app.sh --ad-hoc`, `Resources/Daybook-Local.entitlements`, `swift run`), simulator builds, and CI's unsigned builds carry neither CloudKit nor push, create no courier, and need no profile.

### Secrets on the runner

Third-party code runs on the release runners: package manifests, swift-syntax macros, and the compilers' work on MLX, WhisperKit, FluidAudio, swift-transformers, and swift-jinja. So the signing material exists only in the steps that use it:

- Each such step gets the secrets in its environment and runs its command inside `scripts/ci/secrets.sh run -- …`. That writes the API key as `$RUNNER_TEMP/daybook-secrets/AuthKey_<id>.p8` (directory 700, file 600) and, when the step has the `.p12`, creates a temporary keychain with it; runs the command; and deletes both when the command ends, however it ends (including SIGINT and SIGTERM). Nothing reaches `$GITHUB_ENV`, so later steps don't even see the paths.
- Packages are fetched (`build-ios.sh --resolve`, `build-app.sh --resolve-only`) before any secret is written, so package manifests never run next to one.
- **The archive steps need the API key while third-party code compiles.** Archiving signs for development with automatic signing, which creates the runner's development certificate and profiles through the key (`-allowProvisioningUpdates`). That's the constraint: an unsigned archive would lose its entitlements at export. The key exists for that step only, and the `.p12` isn't on the runner yet.
- The Developer ID `.p12` is imported only for the Mac export and the notarize-and-package step, after everything has compiled, and its keychain is deleted at the end of each. Its password and the keychain's reach `security` on standard input, never a command line.
- The steps that only talk to App Store Connect (looking for an earlier upload, the upload itself, TestFlight) get the key the same way, one command at a time.
- A final `always()` step runs `secrets.sh cleanup` as a backstop, for a step that was killed before it could clean up.

| Step | API key | Developer ID `.p12` | Compiles third-party code |
|---|---|---|---|
| Fetch the packages | | | manifests only |
| Look for this run's build (iPhone) | yes | | |
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

1. It runs `scripts/ci/asc-profile.sh`. It downloads the newest active, **manually managed** Developer ID (`MAC_APP_DIRECT`) profile for `local.daybook.app` through the API, checks that the profile contains the certificate of the keychain's Developer ID identity, installs it, and sets `DAYBOOK_DEVELOPER_ID_PROFILE` to its UUID. It only reads. Xcode refuses its own managed profiles ("Mac Team Direct Provisioning Profile: …") for a manual export, so the team has a separate one, **"Daybook Developer ID"**, created once through the API on 2026-10-24 with the Developer ID Application (G2) certificate; it expires with that certificate in 2031.
2. `build-app.sh --export-only` sees `DAYBOOK_DEVELOPER_ID_PROFILE` and exports with `signingStyle` manual, the "Developer ID Application" certificate, and that profile, leaving the API key out of the export. The archive step still uses the key for development signing.

If the certificate is replaced, step 1 fails with that message: create a new manually managed Developer ID profile for `local.daybook.app` with the new certificate (Certificates, Identifiers & Profiles, or `POST /v1/profiles` with the Admin key), and export the new certificate's `.p12`. With a local identity, `package-mac.sh` can also sign, notarize, and staple a **DMG**; cloud signing only works inside `-exportArchive`, so a cloud-signed release ships the ZIP alone. When the step's command ends, `secrets.sh` deletes the keychain and restores the keychain search list.

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

Repository **variables**:

| Variable | Value |
|---|---|
| `DAYBOOK_TEAM_ID` | `48H7CLBV8Y` |
| `DAYBOOK_BUILD_NUMBER_OFFSET` | `1000` (added to the run number; see [Versions](#versions)) |
| `DAYBOOK_TESTFLIGHT_GROUP` | optional: the beta group each build joins, e.g. `Daybook team` |

The `release` environment has required reviewers (the owner) and deployment policies for branch `main` and tags `v*`.

`scripts/ci/setup-github.sh` creates all of this from local files. It also sets two Actions defaults: read-only workflow tokens, and approval before outside contributors' pull requests run workflows. With `--protect-tags` it adds a ruleset so only admins create, move, or delete `v*` tags. **It prints the plan and changes nothing unless `--apply` is passed.**

## One-time setup

In order, by the owner or their delegate:

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
7. **The CloudKit courier** (pending; before the first release that includes it). The apps now ask for CloudKit and push, so a signed export fails until a and b are done, and the courier stays off in TestFlight and Developer ID builds until c is.

   a. **Capabilities on both App IDs.** developer.apple.com › Account › Certificates, IDs & Profiles › Identifiers:
      - Open **`local.daybook.app`**. Under Capabilities, tick **Push Notifications**. For **iCloud**, choose **Include CloudKit support** (not "Compatible with Xcode 5"), then click **Edit** beside iCloud and check that **`iCloud.local.daybook`** is selected. Click **Save**, then **Confirm** in "Modify App Capabilities".
      - Open **`local.daybook.phone`** and do the same: Push Notifications, iCloud with CloudKit support, `iCloud.local.daybook`. Leave App Groups as they are. `local.daybook.phone.widgets` doesn't change.
      - Don't create an APNs key or push certificate; CloudKit doesn't use them.

   b. **Profiles.** Changing an App ID's capabilities invalidates its profiles.
      - The manually managed Mac profile: Profiles › **Daybook Developer ID** (Developer ID, `local.daybook.app`; now shown as Invalid) › **Edit** › keep the **Developer ID Application (G2)** certificate › **Save**. There's nothing to download: `scripts/ci/asc-profile.sh` installs the newest active one on every run. To check it, download it and run `security cms -D -i "Daybook_Developer_ID.provisionprofile" | plutil -p - | grep -A3 -E "aps-environment|icloud-services"`: it lists `production` and `CloudKit`.
      - Xcode-managed profiles (the iPhone's development and App Store profiles, the Mac's development profile) are regenerated by the release jobs' automatic signing, which already runs with the Admin key and `-allowProvisioningUpdates`. For signed builds on the owner's Mac, the owner runs `DAYBOOK_TEAM_ID=48H7CLBV8Y ./scripts/build-app.sh --debug --allow-provisioning-updates` once (README.md, "First-time provisioning"); no one else passes that flag.

   c. **The CloudKit schema.** icloud.developer.apple.com › CloudKit Console › CloudKit Database › container **`iCloud.local.daybook`**:
      - Choose the **Development** environment › **Schema** › **Record Types** › **+**. Name the type **`CourierFile`** and add these fields: `path` (String), `sha256` (String), `size` (Int(64)), `deviceID` (String), `libraryID` (String), `createdAt` (Date/Time), `asset` (Asset). Save. A development-signed build that sends one recording creates the same type in Development by itself; check that its fields match.
      - Add no indexes: the courier never queries. The `Courier` zone is created by the app at run time; zones aren't part of the schema.
      - Click **Deploy Schema Changes…** (bottom of the sidebar), check that it adds record type `CourierFile`, and **Deploy**. TestFlight and Developer ID builds use **Production**, where an app can't create record types. Until it's deployed, their saves are refused, and the courier turns itself off after three, leaving everything to iCloud Drive.

   d. **Check the first release.**
      - Mac: `codesign -d --entitlements - --xml /Applications/Daybook.app | plutil -p -` lists `CloudKit` under `com.apple.developer.icloud-services`, `com.apple.developer.aps-environment` as `production`, and `com.apple.developer.icloud-container-environment` as `Production`.
      - Both: record on the iPhone with the Mac open. In CloudKit Console › **Production** › **Records** (Private Database, signed in with **Act as iCloud Account** as the test account), zone `Courier`, a `CourierFile` record appears when the recording is filed and is gone once the Mac has stored it.

## Export compliance

App Store Connect asks every iOS build whether it uses encryption.

**The owner has decided:** Daybook uses only **exempt** encryption.

- DaybookLink uses standard TLS, with a pre-shared key from pairing, through Network.framework.
- Everything else uses CryptoKit and Apple's system frameworks.
- Nothing implements its own encryption.

The answer is recorded in the app: `Apps/iOS/project.yml` sets `ITSAppUsesNonExemptEncryption: false`, which becomes the key in `DaybookPhone/Resources/Info.plist`. App Store Connect then doesn't ask, and builds never wait at "Missing Compliance".

`scripts/ci/check-ios-archive.sh` **fails a release** if the archived app's Info.plist lacks the key or has anything but boolean `false`. After processing, `asc-testflight.sh` logs the build's `usesNonExemptEncryption`, and warns if App Store Connect is still waiting for an answer.

If Daybook ever adds non-exempt encryption (its own algorithms, or encryption beyond authentication and standard protocols), the owner revisits the answer before the next upload:

- Set `ITSAppUsesNonExemptEncryption` to `true`.
- Provide the export compliance documentation in App Store Connect (App Information › App Encryption Documentation).
- Add the `ITSEncryptionExportComplianceCode` it issues.
- Update the check in `check-ios-archive.sh`.

The Mac app is distributed outside the App Store, so the key doesn't apply to it.

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
- A manual Mac run from `main` produces the notarized artifacts on the run's page, with no GitHub Release; releases come only from tags.

### Re-running

- **Re-run failed jobs** re-runs the failed jobs and the jobs after them, after a new approval. Each re-run job works out its own build number (`1057.2`; see [Versions](#versions)).
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
spctl -a -vv /Applications/Daybook.app      # "source=Notarized Developer ID"
xcrun stapler validate /Applications/Daybook.app
```

## Known blockers

- **The iPhone app has no app icon.** `ASSETCATALOG_COMPILER_APPICON_NAME` is empty and the asset catalog has no AppIcon, so App Store Connect would reject the upload (ITMS-90713 / ITMS-90022). The release job stops at the archive check until there is one: add an AppIcon to `DaybookPhone/Resources/Assets.xcassets` and set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `Apps/iOS/project.yml`.
- **Mac provisioning** (step 1 of One-time setup) must be done before the Mac export can get its Developer ID profile with iCloud.
- **The CloudKit courier** (step 7 of One-time setup): until Push Notifications and CloudKit are on both App IDs and the "Daybook Developer ID" profile is regenerated, both exports fail, because the apps' entitlements now include them. Until the schema is deployed to Production, released apps sync through iCloud Drive alone.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Jobs on `xcode-27` wait in the queue for a long time | The image is a preview with limited capacity (#14404). Wait, or re-run later. |
| `Xcode_27.1.app isn't installed on this runner`, or `expected Xcode 27.1` | The image changed. Check the readme's Xcode table and update `DAYBOOK_XCODE` in both workflows (and `--expect` if the version moves on). |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | The download in `select-xcode.sh --metal` failed or was skipped. Re-run; it retries three times. |
| `Unable to find a device matching the provided destination specifier` | The simulator set changed. `pick-simulator.sh` prints what it chose; run `xcrun simctl list devices available` in a step to see what's there. |
| "Passed on retry" warning | A timing-budget test missed once on a slow VM. Occasional is expected. Every run means a real slowdown: compare the timings in the log with `docs/validation.md`. |
| CI is slow after a dependency or Xcode change | The cache key changed. The first push to `main` saves a new cache. |
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
| Upload rejected: ITMS-90713 or ITMS-90022 (icon) | See [Known blockers](#known-blockers). `check-ios-archive.sh` catches this before the upload. |
| Upload rejected: the bundle version must be higher, or a redundant binary; or `asc-testflight.sh`: "… was uploaded at …, before this run started" | That build number belongs to an older upload: the offset went down, or `release.yml` was recreated. Raise `DAYBOOK_BUILD_NUMBER_OFFSET` above the highest build number in App Store Connect and run the release again. |
| `no App Store Connect app has the bundle ID local.daybook.phone` | Create the app record (One-time setup, step 2). |
| `no beta group named …` | The message lists the app's groups. Fix `DAYBOOK_TESTFLIGHT_GROUP` or the `testflight_group` input. |
| Beta App Review submission fails | An external group needs the app's Test Information filled in once in TestFlight. |
| Build not processed within the timeout | App Store Connect is slow. The build usually finishes later; set What to Test and the group in App Store Connect. |
| The account fills with "Apple Development: Created via API" certificates | Each fresh runner's archive creates one. Run `scripts/asc-certificates.sh`, then `--revoke` ([Development certificates](#development-certificates)); nothing shipped depends on them. |
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
scripts/ci/package-mac.sh --app dist/Daybook.app --version 1.2.3 --output /tmp/daybook-release   # no --notarize: nothing is sent
scripts/ci/setup-github.sh --asc-key AuthKey_ABC123DEFG.p8 --asc-issuer-id <uuid>               # dry run
```
