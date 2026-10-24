# Daybook on Polaris Key: activation, accounts, and updates

Status: design, 2026-10-24. Not yet planned or built.

## Intent

Daybook joins the Polaris ecosystem. Like Polaris Key's other products, it uses Key for who may use it (accounts and licenses) and how it reaches people (Mac updates, downloads, release records). The reason is long-term: other platforms eventually, and one Polaris account across the owner's apps. A Polaris account is what Key Cloud Sync will need once it ships.

A copy of Daybook has to be activated before it can make new recordings. Everything else Daybook stands for stays: inference is local, the library is the person's own, and sync goes through their own iCloud.

Decided by the owner (this conversation):

- Integrate the Polaris Key Swift SDK: accounts, licensing, updates and the rest of the release side.
- A person activates their copy before using it.
- Cloud Sync is deferred. iCloud stays the only sync transport.
- The motivation is other platforms eventually, and integration into the Polaris ecosystem.

Everything marked **Call** below is the designer's choice, made because the owner asked for a design without further questions. Those are the places to push back.

## Goals

1. Each Mac and iPhone activates by signing in with a Polaris account or entering a license key.
2. An activated device works with no network until its offline window runs out.
3. The Mac app updates itself through Sparkle, from Key's feed, on the channels the license allows.
4. Every release is published to Key (Mac artifacts, release record, download page) from the existing release workflow.
5. Key knows about the TestFlight build for the iPhone app, as an outlet, without taking over the TestFlight steps.

## Non-goals (this phase)

- Key Cloud Sync, or any Key-side storage of library data.
- Purchasing: StoreKit, the commerce bridge, prices, trials.
- Remote config (Key's Config service stays off).
- Requiring App Attest.
- Moving TestFlight steps (groups, What to Test, beta review) into Key. `scripts/ci/asc-testflight.sh` keeps doing them.
- Clients for other platforms.
- In-app changelog or update prompts on the iPhone. TestFlight already handles those.

## Anti-goals (failures even if everything "works")

- **Locking someone out of what they already have.** No license state hides, deletes, or blocks reading, playing, searching, editing, exporting or syncing the library.
- **Interrupting work in flight.** A license change never stops a recording or a running processing job.
- **Library content reaching Key.** Audio, transcripts, notes, titles, speaker names, summaries and vocabulary never go to Key, not even as report extras.
- **Needing the network to launch.** An activated device inside its offline window launches and records with networking denied. The existing `sandbox-exec … (deny network*)` smoke run still passes.
- **Polaris leaking into the domain.** DaybookCore, DaybookDevices, DaybookLink, DaybookCaptions, DaybookIntelligence and DaybookDesign never import Polaris Key.

## The Key product

A `.pkey/` manifest in this repository declares the product. It is linked with the `pkey` CLI, as djdl's is (`../djdl/.pkey/`).

| Setting | Value |
| --- | --- |
| Slug, name | `daybook`, Daybook |
| Services | License, Identity, Release, Distribution, Update **on**. Config, Cloud Sync **off** |
| Identity | The platform OIDC provider: the shared Polaris account, same as djdl |
| Device registration | `requires-license` |
| Tiers | `standard`: channel `stable`, 5 devices. `beta`: channels `beta` and `stable`, 5 devices. No expiry |
| Offline window | `defaultMaxOfflineDays: 30` |
| Group mapping | `family`, `friends` → `standard`; `admins` → admin role (djdl's map) |
| Channels | `vX.Y.Z` tags → `stable`; `vX.Y.Z-suffix` prerelease tags → `beta` |
| Outlets | Polaris Key direct download (Mac ZIP); `testflight` (Apple ID 6826636947, bundle `local.daybook.phone`) |

**Call:** licenses come from Polaris group membership, or from keys the owner issues in the console. There is no purchase path. Config stays off until something reads it. Cloud Sync will need Config turned on later, and that is a manifest change with no app release.

## Activation

There are two ways to activate. The SDK's kit draws both.

1. **Sign in with Polaris** (primary): device-code sign-in in a web authentication session. A signed-in account whose groups map to a tier gets a license, and this device takes one of its seats.
2. **Enter a license key**: for someone without an account, or a key the owner handed out.

Each Mac and each iPhone is one device against the tier's limit. When the limit is reached, the kit shows Key's refusal with its "Replace a device" link (the `manageUrl`).

**Call:** activation is the first step of first-run onboarding on both apps (the Mac's Welcome window, the iPhone's onboarding), before model downloads or permissions. Signing out (Settings › Account) deactivates the device, which frees its seat and wipes the local credential. The library is untouched.

## What activation unlocks

There are two modes: **Full** and **Limited**.

- **Limited** turns off starting a recording, importing (files and recorder transfers), automatic recording, and user-requested reprocessing (re-transcribe, re-summarize, relabel speakers).
- **Limited** leaves everything else working: browsing, playback, search, editing notes and text, export, deletion, sync, settings and model management.

| SDK `LicenseStatus` | Mode | What the person sees |
| --- | --- | --- |
| `ok`, `notApplicable` | Full | Nothing |
| `grace` (offline, inside the window) | Full | Settings › Account: "Offline · checked <date>" |
| `needsActivation` | Limited | "Not activated" · Activate |
| `expired` | Limited | "License expired" · Manage |
| `revoked` | Limited | "License revoked" · Manage |
| `versionTooOld` | Limited | "Update required" · Check for Updates (Mac) / Open TestFlight (iPhone) |
| `versionTooNew`, `channelNotEntitled` | Limited | "This version isn't in your license" · Check for Updates / Manage |

Rules:

- **Checked at start only.** A recording or job that started in Full mode finishes, whatever happens to the license meanwhile.
- **First processing always runs** (**Call**). A recording that exists gets its first transcript and summary, on whichever device processes it. This avoids a recording stuck untranscribed because the license changed between capture and processing, including phone recordings processed by a Mac.
- **One check, every entry point.** All of these go through the same authorization:
  - the record buttons;
  - the menu bar and `DaybookCommands`;
  - automatic recording;
  - imports and recorder transfers;
  - App Intents and Shortcuts;
  - the iPhone's Control Center control and Live Activity;
  - a recording started from the phone over DaybookLink. Here the Mac checks its own mode and answers with a reason the phone shows ("Your Mac isn't activated").
- **No first-frame flash.** An activated device never shows the activation screen while its cached status loads. The SDK answers status from its verified cache with no network.

**Call:** Daybook does **not** wrap its windows in the kit's drop-in `.polarisKeyGate`. That modifier replaces the app's content whenever the license is unusable, which breaks the first anti-goal. Daybook holds a `PolarisKeyGateModel` and uses the kit's views (`PolarisKeyGate(model:)`, `polarisKeySignIn`) only where activation is shown.

## Architecture

### Targets

- **New package target `DaybookAccount`** (macOS and iOS), with a library product of the same name. It depends on `PolarisKey` and `PolarisKeyUI`, plus `PolarisKeyUpdate` with `condition: .when(platforms: [.macOS])`. It holds:
  - `AccountController` (`@MainActor`, observable). It owns the `PolarisKeyClient`: creation, the `events` stream, sync on foreground, sign-in, key activation and sign-out. It publishes the current mode and the reason.
  - The status → mode mapping (the table above), as a pure function.
  - The activation and account views: kit views themed with Daybook's accent and icon.
  - `#if os(macOS)` `UpdaterController`, a wrapper over `PolarisSparkle.start(client:)` that also exposes "Check for Updates" and the channel.
  - `PolarisConfig.swift`, written by `pkey sdk --lang swift --write` and committed. It holds the product slug, the pinned public signing keys and the expected services. It contains no secrets.
- **DaybookKit gains a vendor-free `CaptureAuthorization`** value (allowed, or denied with a reason). AppState on the Mac and the phone's state set it from `AccountController`. Capture code consults it without importing Polaris Key.
- **The Mac app** (`Sources/Daybook`, both the SwiftPM executable and `Apps/macOS/project.yml`) and **the iPhone app** (`Apps/iOS/project.yml`) depend on `DaybookAccount`. The widget extension does not. The phone app mirrors the authorization into the existing app group (`group.local.daybook.phone`) so controls and widgets can show a disabled state. Enforcement stays in the app.

### Consuming the SDK

- Add `.package(id: "polaris-key.PolarisKey", exact: "<latest published>")`; v0.9.16 is the newest tag today. This keeps the package's exact-pin rule. Sparkle comes in through the SDK (floor 2.9.6) and is pinned by `Package.resolved`.
- The SDK's targets use the Swift 6 language mode. Daybook stays in Swift 5 mode. These mix per module.
- Every build has to resolve the registry scope: `swift build`, Xcode for both apps, and CI (`swift package-registry set --scope polaris-key https://pkg.plrs.im/swift/polaris-key`). `.swiftpm/` is ignored today. Either un-ignore `.swiftpm/configuration/registries.json` and commit it, or add a CI step and document the one-time developer command. The builder confirms which one Xcode honours for a local package.
- `THIRD_PARTY_NOTICES.md` gains Sparkle and the Polaris Key SDK. The Mac app's notices build phase reads only `SourcePackages/checkouts`, so it has to learn the registry download location too.

### Tests

The SDK exposes `store:` (an in-memory `Store`) and `transport:` (a scripted `PolarisTransport`) on client creation. `DaybookAccountTests` uses both, so ordinary tests touch neither the network nor the Keychain. The suite covers:

- every `LicenseStatus` → mode;
- every capture entry point honouring a denied `CaptureAuthorization`;
- a recording that started in Full mode surviving a status change;
- first processing running in Limited mode;
- sign-out leaving the library untouched;
- launch with a cached `ok` reaching Full mode with the transport refusing every request.

### Development builds

`swift run Daybook` and ad hoc builds have no provisioning. **Call:** DEBUG builds accept `-DaybookSkipActivation YES`, which forces Full mode with no client. This follows the existing `-DaybookDevelopmentFolderSync` pattern. Release builds ignore it. `--smoke-test`, `--evaluate` and `--library` behave as today. The CLI paths run before the app and never create a client.

## UI

The rule from earlier copy passes still holds: show status, actions and fixes; don't explain mechanics. The kit's copy catalog may carry explanatory lines. Override them where `KitGateOptions` allows; anything that can't be overridden is accepted on the activation screen only.

**Mac**

- **Welcome window:** the activation step comes first.
- **Library window in Limited mode:** one status line with its action ("Not activated · Activate"). Record controls are disabled, never hidden, with the reason as help text.
- **Settings › Account:**
  - the account (from `identity.current()`) or "License key";
  - the tier label;
  - the offline status when in grace;
  - Manage (opens the Polaris account page) and Sign Out.
- **Settings › Updates:**
  - automatic checks;
  - a channel picker, shown only when the license grants `beta`;
  - Check Now.
- **App menu:** Daybook › Check for Updates….
- **Menu bar extra:** shows "Not activated" in place of the record item.

**iPhone**

- **Onboarding:** activation comes first.
- **Settings › Account:** the same content as the Mac.
- **Recording entry points:** the record button, the Control Center control and Shortcuts show the denied reason.

## Mac updates and publishing

- `PolarisSparkle.start(client:)` reads the feed URL from Key's discovery and adds the license's bearer token and allowed channels. It re-derives all three on every license change.
- `Info.plist` carries `SUPublicEDKey`. The SDK refuses to start without it.
- Daybook is not sandboxed, so Sparkle needs no installer XPC setup.
- **Signing key:** an EdDSA key pair made with Sparkle's `generate_keys`.
  - The private half lives in the owner's Keychain, and in the `release` environment as `SPARKLE_ED_PRIVATE_KEY`, loaded with `scripts/ci/setup-github.sh` on stdin.
  - The public half goes in `Info.plist` and in `.pkey/release.yaml` (`sparkleEd25519Pub`).
- **Release workflow:**
  1. The `mac` job signs the notarized ZIP with Sparkle's `sign_update` and writes a bare-base64 `<zip>.sig` sidecar, as djdl does for its DMG.
  2. `SHA256SUMS.txt` covers it.
  3. The `publish` job attaches the sidecar to the GitHub Release, then runs `polaris-key/publish`.
     - The action is pinned by commit SHA, as every action in the workflows is.
     - It authenticates with the job's OIDC token (`id-token: write`, trusted publisher declared in `.pkey/release.yaml`). No new secret.
     - It is gated on `vars.PKEY_PUBLISH` for the first runs.
- **Build numbers:** `CFBundleVersion` is already the increasing number `scripts/ci/version.sh` derives, which Sparkle compares.
- **ZIP vs DMG:** cloud-signed releases ship a ZIP only. Key's older appcast code expects a `<dmg>.sig`, while its manifest code does recognize `zip` as a Mac format. Verify with the publish action's dry run. If the feed can't carry a ZIP enclosure, fix that in Key, which the owner also maintains, rather than adding a DMG step here.

## iPhone distribution

Nothing changes in the pipeline: upload with `build-ios.sh --export upload`, then `asc-testflight.sh`. On Key's side:

- the `testflight` outlet is declared;
- the "Polaris Daybook" app record is linked to the product in Platform › Store connections, so Key tracks build states and links builds to its releases.

## Privacy

What leaves the device for `key.plrs.im`:

- **Activation:** the device ID, a device name, the license key or sign-in flow.
- **License refreshes.**
- **Update checks** (Mac).
- **The SDK's device report after each sync:** OS name, version and build; CPU model, core count, RAM and machine model; runtime; locale; time zone; app and SDK version; platform and architecture; license gate state and entitlements.

Daybook passes no `report(extras:)`.

Changes to existing documents:

- **README "Privacy" and `docs/product.md`:** replace "No Daybook account … or telemetry" with a short statement of exactly the list above, and that library content never goes to Key. Inference stays local, and sync stays in the person's iCloud.
- **AGENTS.md "Privacy & Configuration":** "Never send library content to Polaris Key; Daybook's only Polaris traffic is activation, license refresh, the device report, and update checks."
- **New `docs/accounts.md`:** activation, the mode table, the entry points, and the offline behaviour, in the style of `docs/icloud-sync.md`.
- **`docs/release.md`:** Sparkle signing and Key publishing.
- **`docs/validation.md`:** the device checks below.

## Rollout

**Call:** two releases.

1. **Updates first.** Ship Sparkle and Key publishing with no activation, then prove an update from that release to the next on a real Mac. Check the signature, Gatekeeper, the iCloud entitlement and the library after the update. Existing installs need one manual install to get the updater.
2. **Then activation.** It arrives on Macs through the updater. Existing libraries open in Limited mode until the person activates. Nothing in them changes.

**Key-side setup** (owner, once):

1. Link the product.
2. Generate the product signing key.
3. Set the OIDC redirect.
4. Declare the trusted publisher.
5. Link the App Store record.
6. Issue the first licenses.

## Validation on real devices (`docs/validation.md`)

- **Sign-in:** works on a Mac and on an iPhone with a real account. A key activates on a second Mac.
- **Device limit:** reaching it shows "Replace a device".
- **Offline:** a Mac with networking denied stays Full through `grace` and turns Limited after the window, without interrupting a recording in progress. It recovers when it reaches Key again.
- **Revocation in the console:** reaches a running Mac on its next sync.
- **Updates:** Sparkle installs on stable, beta is offered only to a `beta` license, and an update completes mid-library without data loss.
- **Phone remote start:** a phone asking a Limited Mac to record gets the reason.

## Left to the builder

- **SDK setup details:** exact kit theming, and which kit copy can be overridden.
- **Keychain entitlement:** whether the SDK's Keychain store needs a `keychain-access-groups` entitlement on the Developer ID Mac build.
- **Registry configuration:** how the registry setup reaches Xcode and CI.
- **Notices:** extending the notices build phase to registry packages.
- **The publish path:** the ZIP sidecar's file name and the artifact map in `.pkey/release.yaml`.
- **Code placement:** where `CaptureAuthorization` is consulted in AppState and the phone's recording paths.

## Later, not now

- **Public App Store release of the iPhone app:**
  - an activation that unlocks features has to be purchasable in-app (Key's commerce bridge does StoreKit 2);
  - an app that lets people create accounts must offer account deletion in-app.
  Both are App Review rules to settle before submission.
- **Key Cloud Sync**, once its routes exist and end-to-end encryption lands. The journal redesign it needs is described in the 2026-10-24 sync discussion.

## Calls made in this design

1. Sign-in first, keys second; registration `requires-license`.
2. Licenses from Polaris groups and console keys; no purchase.
3. Tiers `standard` and `beta`, 5 devices each, no expiry, 30 offline days.
4. Limited mode instead of a full block, and first processing always runs.
5. The kit's views without its drop-in gate.
6. Config, Cloud Sync, commerce and App Attest off.
7. Accept the SDK's device report and list it in the privacy text.
8. Updates ship one release before activation.
9. TestFlight steps stay in CI; Key gets the outlet and the app link.
10. Polaris Key lives only in the new `DaybookAccount` target, behind a vendor-free `CaptureAuthorization` in DaybookKit.
11. A DEBUG-only `-DaybookSkipActivation` launch argument.
