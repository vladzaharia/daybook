# Releases and CI

Two GitHub Actions workflows build Daybook on GitHub-hosted Macs:

- **CI** (`.github/workflows/ci.yml`) builds and tests every push to `main`, every pull request, and manual runs.
- **Release** (`.github/workflows/release.yml`) ships a `v*` tag, or a manual run from `main`. The iPhone app goes to TestFlight. The Mac app is signed with Developer ID, notarized, and attached to a GitHub Release.

Signing uses an App Store Connect API key with Xcode's cloud-managed signing. A Developer ID `.p12` is an optional fallback for the Mac app.

## Pipeline

| Workflow | Job | Runner | What it does |
|---|---|---|---|
| CI | `lint` | `ubuntu-24.04` | actionlint (pinned, checksum-verified, with shellcheck on every `run:` block), shellcheck on the scripts, and `scripts/ci/tests/run-tests.sh` |
| CI | `package` | `xcode-27` | `swift build --build-tests` once, then `swift test --skip-build` per test-target group, then the timing-budget test alone (see below) |
| CI | `iphone` | `xcode-27` | `scripts/build-ios.sh --test` on a simulator (iPhone Duo if the image has one, otherwise iPhone 18 Pro), the crash-recovery test alone, then an unsigned Release device archive checked the way a release would be |
| CI | `mac` | `xcode-27` | `scripts/build-app.sh --debug --ad-hoc` (Release with the `mac_configuration` input), then the bundle is checked for its signature, icon, and MLX `default.metallib` |
| Release | `prepare` | `ubuntu-24.04` | checks the ref, works out the version and build number (`scripts/ci/version.sh`), and writes release notes and What to Test (`scripts/ci/release-notes.sh`) |
| Release | `iphone` | `xcode-27`, environment `release` | archives `DaybookPhone` with `DaybookPhoneWidgets` (`build-ios.sh --archive`), checks the archive (`check-ios-archive.sh`), exports with `app-store-connect` and uploads it (`build-ios.sh --export upload`), then waits for processing, sets What to Test, and adds the build to the beta group (`asc-testflight.sh`) |
| Release | `mac` | `xcode-27`, environment `release` | archives and exports with `developer-id` (`build-app.sh`), then notarizes, staples, and writes the ZIP, a DMG when possible, and `SHA256SUMS.txt` (`package-mac.sh`) |
| Release | `publish` | `ubuntu-24.04` | tags only: verifies the checksums and creates (or updates) the GitHub Release. It's the only job with `contents: write`, and it holds no Apple secrets |

Hardening:

- Every workflow starts from `permissions: {}`, and each job asks for `contents: read` (or `write` in `publish` only).
- Actions are pinned to commit SHAs, with the version in a comment. Checkouts don't persist credentials.
- Nothing uses `pull_request_target`.
- Concurrency groups cancel superseded pull request runs and never cancel a release.
- Secrets are environment secrets in `release`. Only jobs that a reviewer approved can read them, and only from `main` or a `v*` tag. Each secret is passed to the one step that needs it.
- Secrets become files only in `$RUNNER_TEMP/daybook-secrets` (mode 700, files 600). A temporary keychain holds the `.p12`. `scripts/ci/secrets.sh cleanup` deletes both in an `always()` step.
- Runners are GitHub-hosted only. The repository's `.github/actionlint.yaml` lists `xcode-27` under actionlint's `self-hosted-runner` key only because actionlint 1.7.12 predates the label. It's GitHub-hosted.

## Runner and Xcode

- **Label:** `runs-on: xcode-27`, the Xcode 27 image, a public preview announced in [actions/runner-images#14404](https://github.com/actions/runner-images/issues/14404). The readme is [`images/macos/xcode-27-arm64-Readme.md`](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md); image 20261012.0260.1 runs macOS 27.0.1 on arm64. That label is the standard size, free for public repositories. `xcode-27-xlarge` is a paid larger runner and isn't used.
- **Xcode:** 27.1 (27A9275, the same build as the development Macs), selected with `DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer` by `scripts/ci/select-xcode.sh`. That script fails if the version isn't 27.1 or a required SDK is missing. On this image `Xcode.app` is 27.0, and `Xcode_27.1.app` links to `Xcode_27.1_Release_Candidate.app`. The image's next rollout ([#15011](https://github.com/actions/runner-images/pull/15011)) installs the 27.1 release at the same path and makes it the default.
- **SDKs and simulators:** the iOS 27.1 SDK is there; it has the iPhone Duo hinge APIs. The image preinstalls only the iOS 27.0 simulator runtime: iPhone 17, 17e, 18 Pro, 18 Pro Max, Air, and iPads, with **no iPhone Duo**. Apple's iOS 27.1 simulator runtime supports only the iPhone Duo device type ([#15000](https://github.com/actions/runner-images/issues/15000)). So CI tests on **iPhone 18 Pro with iOS 27.0**, built with the 27.1 SDK. The `#available(iOS 27.1, *)` hinge code compiles there but doesn't run. `scripts/ci/pick-simulator.sh` prefers an iPhone Duo, so CI moves to one with no change once an image ships it. Exercising the Duo on CI today would mean downloading the runtime in the job (`xcodebuild -downloadPlatform iOS`, several GB). The Duo checks stay local, as in `docs/iphone.md`.
- **Metal toolchain:** the image doesn't include it, so `select-xcode.sh --metal` runs `xcodebuild -downloadComponent MetalToolchain` (with retries) in the jobs that build MLX.
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

- **Archive** (`build-ios.sh --archive`, `build-app.sh`): automatic signing with Apple Development.
  - A fresh runner has no development certificate, so Xcode creates one through the key. It appears in the account as *Apple Development: Created via API*.
  - Xcode fetches or creates the development profiles for the existing identifiers.
  - These certificates sign nothing that ships, and revoking old ones is harmless.
- **Export** (`-exportArchive`): the archive is re-signed for distribution with a **cloud-managed** certificate. The private key stays with Apple, so no certificate or `.p12` is exported anywhere.
  - The iPhone export uses Apple Distribution with the App Store profiles.
  - The Mac export uses Developer ID Application with the Developer ID profile that carries the iCloud container.
  - The iPhone export uses `destination: upload`, which sends the build straight to App Store Connect.
- **Notarization:** `xcrun notarytool submit --key --key-id --issuer --wait` with the same key. Then `xcrun stapler staple` runs, and `spctl` assesses the result.

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

`secrets.sh setup` then works in this order:

1. It creates a temporary keychain with a random password and imports the `.p12`.
2. It deletes the `.p12` file.
3. It allows codesign to use the key without a prompt (`set-key-partition-list`).
4. It adds Apple's Developer ID G2 intermediate (downloaded, SHA-256 pinned), because macOS ships only the older intermediate.
5. It checks that a Developer ID Application identity is present.

Automatic export doesn't work even then: with a team key it still asks for cloud-managed Developer ID signing and fails before it looks for the profile. So the Mac job signs manually:

1. **Install the Developer ID profile** runs `scripts/ci/asc-profile.sh`. It downloads the newest active, **manually managed** Developer ID (`MAC_APP_DIRECT`) profile for `local.daybook.app` through the API, checks that the profile contains the certificate of the keychain's Developer ID identity, installs it, and sets `DAYBOOK_DEVELOPER_ID_PROFILE` to its UUID. It only reads. Xcode refuses its own managed profiles ("Mac Team Direct Provisioning Profile: …") for a manual export, so the team has a separate one, **"Daybook Developer ID"**, created once through the API on 2026-10-24 with the Developer ID Application (G2) certificate; it expires with that certificate in 2031.
2. `build-app.sh` sees `DAYBOOK_DEVELOPER_ID_PROFILE` and exports with `signingStyle` manual, the "Developer ID Application" certificate, and that profile, leaving the API key out of the export. The archive step still uses the key for development signing.

If the certificate is replaced, step 1 fails with that message: create a new manually managed Developer ID profile for `local.daybook.app` with the new certificate (Certificates, Identifiers & Profiles, or `POST /v1/profiles` with the Admin key), and export the new certificate's `.p12`. With a local identity, `package-mac.sh` can also sign, notarize, and staple a **DMG**; cloud signing only works inside `-exportArchive`, so a cloud-signed release ships the ZIP alone. The cleanup step deletes the keychain and restores the keychain search list.

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

From an up-to-date `main` whose CI is green:

```sh
git tag -a v1.4.0 -m "Daybook 1.4.0: two-page reading on iPhone Duo"
git push origin v1.4.0
```

Then approve the run: Actions › Release › Review deployments › `release` › Approve. One approval covers both the iPhone and Mac jobs.

- The tag's message opens the GitHub Release notes and What to Test, followed by the commits since the previous tag.
- The iPhone build appears in TestFlight, in `DAYBOOK_TESTFLIGHT_GROUP`, once processed.
- The Mac ZIP (and DMG), with `SHA256SUMS.txt`, are attached to the release.

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

### Versions

- `MARKETING_VERSION` (`CFBundleShortVersionString`) comes from the tag: `vX.Y.Z` gives `X.Y.Z`. `scripts/ci/version.sh` rejects anything else, because App Store Connect accepts three integers at most.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is `DAYBOOK_BUILD_NUMBER_OFFSET + github.run_number`, e.g. `1057`. The run number belongs to `release.yml` and only grows. The offset keeps CI builds above anything uploaded by hand from Xcode.
- A re-run (attempt 2) becomes `1057.2`. That still sorts above `1057` and below `1058`, so a re-run after a successful upload doesn't collide with the build already there.
- Both apps and the widget extension get the same pair, set as build settings on the xcodebuild command line, so neither `project.yml` changes.
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
| Upload rejected: "you need to include all of the … orientations to support iPad multitasking" | The app was built for iPad too. Every target in `Apps/iOS/project.yml` keeps `TARGETED_DEVICE_FAMILY: "1"` (XcodeGen's presets set "1,2"); `check-ios-archive.sh` checks `UIDeviceFamily`. |
| "requires a provisioning profile with the iCloud feature", or the container can't be assigned | Mac provisioning hasn't been done (One-time setup, step 1). |
| `package-mac.sh`: lacks the `iCloud.local.daybook` entitlement | The export signed without the Developer ID profile. Same fix as above. |
| Notarization `Invalid` | `package-mac.sh` prints Apple's log; it names each file and the problem (unsigned code, missing hardened runtime, no secure timestamp). |
| Upload rejected: ITMS-90713 or ITMS-90022 (icon) | See [Known blockers](#known-blockers). `check-ios-archive.sh` catches this before the upload. |
| Upload rejected: the bundle version must be higher, or a redundant binary | That build number already exists. Re-run (the attempt number makes it unique) or raise `DAYBOOK_BUILD_NUMBER_OFFSET`. |
| `no App Store Connect app has the bundle ID local.daybook.phone` | Create the app record (One-time setup, step 2). |
| `no beta group named …` | The message lists the app's groups. Fix `DAYBOOK_TESTFLIGHT_GROUP` or the `testflight_group` input. |
| Beta App Review submission fails | An external group needs the app's Test Information filled in once in TestFlight. |
| Build not processed within the timeout | App Store Connect is slow. The build usually finishes later; set What to Test and the group in App Store Connect. |
| The account fills with "Apple Development: Created via API" certificates | Each fresh runner's archive creates one. Revoke old ones in Certificates, Identifiers & Profiles; nothing shipped depends on them. |
| The tag was pushed and nothing ran | Check Actions › Release: the run is waiting for approval in `release`. A tag that isn't `vX.Y.Z[-suffix]` fails in `prepare`. |

## Checking the pipeline locally

None of these uses a team, a secret, or the network beyond package checkouts:

```sh
actionlint                                       # uses .github/actionlint.yaml
scripts/ci/tests/run-tests.sh                    # version, JWT, App Store Connect calls (mock), notes, archive checks, setup dry run
scripts/ci/version.sh --ref refs/tags/v1.2.3 --run-number 42
scripts/build-ios.sh --archive --no-sign --marketing-version 1.2.3 --build-number 1042
scripts/ci/check-ios-archive.sh Apps/iOS/build/DaybookPhone.xcarchive --version 1.2.3 --build 1042
scripts/build-app.sh --ad-hoc --marketing-version 1.2.3 --build-number 1042
scripts/ci/package-mac.sh --app dist/Daybook.app --version 1.2.3 --output /tmp/daybook-release   # no --notarize: nothing is sent
scripts/ci/setup-github.sh --asc-key AuthKey_ABC123DEFG.p8 --asc-issuer-id <uuid>               # dry run
```
