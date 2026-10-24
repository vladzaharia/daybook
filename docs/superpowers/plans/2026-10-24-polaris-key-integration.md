# Daybook on Polaris Key: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Daybook activates through Polaris Key (Polaris account or license key), updates itself on the Mac through Sparkle from Key's feed, and publishes every release to Key. Without a usable license it runs in Limited mode.

**Architecture:** One new package target, `DaybookAccount`, is the only code that imports Polaris Key. It wraps the SDK client behind Daybook-owned types and draws the kit's activation views. It also owns the Mac updater, which uses Sparkle through the SDK's feed with a delegate that holds back a relaunch while Daybook is busy. Capture code in the apps consults a vendor-free `CaptureAuthorization` from DaybookKit. Part A (Tasks 1–6) ships first: the SDK, the updater and publishing, with no enforcement. Part B (Tasks 7–11) ships second: activation and Limited mode.

**Tech Stack:** Swift 6.2 toolchain in Swift 5 language mode; SwiftUI/AppKit/UIKit; Polaris Key Swift SDK 0.9.16 from the `polaris-key` Swift registry; Sparkle 2; GitHub Actions; XcodeGen; XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-polaris-key-integration-design.md`. Read it first; this plan argues from it.

## Global Constraints

- **SDK pin:** `.package(id: "polaris-key.PolarisKey", exact: "0.9.16")`. Sparkle is pinned `exact` to the version Package.resolved resolves for it (2.10.0 at the time of writing; at least 2.9.6). Every other pin stays as it is.
- **Registry:** `https://pkg.plrs.im/swift/polaris-key`, scope `polaris-key`.
- **Where Polaris code lives:** `import PolarisKey*` and `import Sparkle` appear only in `Sources/DaybookAccount` and `Tests/DaybookAccountTests`. The apps import `DaybookAccount`. DaybookCore, DaybookDevices, DaybookLink, DaybookCaptions, DaybookIntelligence and DaybookDesign never import either.
- **Swift version:** the package stays in Swift 5 language mode (`swiftLanguageModes: [.v5]`).
- **Platforms:** macOS 15 and iOS 26 (the package floors). The SDK needs macOS 15 and iOS 18.
- **Product settings:** slug `daybook`. Tiers `standard` (`stable`, 5 devices) and `beta` (`beta`, `stable`, 5 devices). No expiry. `defaultMaxOfflineDays: 30`.
- **Never sent to Key:** audio, transcripts, notes, titles, speaker names, summaries or vocabulary. Never call `report(extras:)`.
- **UI copy:** status, actions and fixes only. No sentences explaining sync, licensing or update mechanics.
- **Tests:** ordinary tests make no network calls and touch no Keychain. Use fakes, or the SDK's `InMemoryStore` with `NoNetworkTransport`.
- **Never interrupt work:** a license change, sign-out or update never stops a recording or a running processing job. Checks happen only when work starts.
- **First processing always runs:** `ProcessingRequest.Mode.newAudio` runs in any mode. `.summaryOnly`, `.speakerRefresh` and `.fullRetranscription` need Full mode.
- **Workflows:** every action is pinned by full SHA with a version comment. Permissions stay minimal. Secrets go to the `release` environment through `scripts/ci/setup-github.sh`, on stdin.
- **Dev builds:** DEBUG builds honour `-DaybookSkipActivation YES`. A build with no `CFBundleShortVersionString` (`swift run Daybook`) runs with no account at all. Release builds always create one.

## Review Focus

1. **An update offered while recording or processing.** Accepting it must not relaunch until the work finishes. Task 4 tests the relaunch gate.
2. **The credential store unavailable at launch** (a locked Keychain, so `create` throws). The library still opens, capture shows "License unavailable · Try Again", and Try Again recovers. Tested in Task 3 and Task 7.
3. **The license lapsing, or Sign Out, during a recording.** The recording continues and saves, and its first processing runs. Task 7 tests this.
4. **A recorder auto-transfer or watched-folder import while Limited.** The recordings stay on the device or in the folder and import after activation. Task 7 tests this, in DaybookDevicesTests.
5. **An existing library opened after the Part B update.** Every conversation stays readable, playable and editable, and the Welcome window isn't shown again. Task 7 tests this.

---

## Part A — SDK, updates, publishing (release 1)

### Task 1: Key product manifests (owner steps included)

**Files:**
- Create: `.pkey/product.yaml`, `.pkey/schema.yaml`, `.pkey/release.yaml`, `.pkey/distribution.yaml`
- Modify: `.github/workflows/ci.yml` (lint job: validate `.pkey/`)

**Interfaces:**
- Produces:
  - product `daybook` with License, Identity, Release, Distribution and Update on, and Config and Cloud Sync off;
  - artifact id `macos-arm64-zip`;
  - the trusted publisher `.github/workflows/release.yml` in environment `release`;
  - after the owner steps: the Sparkle public key, the release key pair, the console's customer-portal URL and the generated `PolarisConfig.swift` (all used by Tasks 2, 4, 5 and 8).

- [ ] **Step 1: Write `.pkey/product.yaml`**

Use the canonical shape: `apiVersion: pkey.dev/v1`, a `product:` block (`slug: daybook`, `name: Daybook`) and `modules:` with `license`, `identity`, `release`, `distribution` and `update` enabled and `config` disabled. Add `oidc:` with `provider: platform`, `redirectUris: ["https://key.plrs.im/daybook/identity/auth/callback"]` and `groupRoleMap` mapping `family` and `friends` to `{ role: user, tier: standard }` and `admins` to `{ role: admin }`. Add `licensing:` with `defaultMaxOfflineDays: 30`, `defaultDeviceLimit: 5` and `tiers` (`standard`: label "Standard", `policyDeviceLimit: 5`, `policyExpiryDays: null`, `channels: [stable]`; `beta`: label "Beta", 5 devices, `channels: [beta, stable]`). Do not write `devices.registration`: the validator rejects it, and License on derives `requires-license`.

- [ ] **Step 2: Write `.pkey/schema.yaml`** as `apiVersion: pkey.dev/v1`, `schemaVersion: 1`, `entries: []`. Ingest requires the file even with Config off.

- [ ] **Step 3: Write `.pkey/release.yaml`** following djdl's (`../djdl/.pkey/release.yaml`):
  - `provider: { type: github, owner: vladzaharia, repo: daybook }`;
  - `deliverables.app` with `kind: app`, `versioning: { scheme: semver, stableTagPattern: "v\\d+\\.\\d+\\.\\d+", buildNumber: descriptor }` and a single artifact `{ id: macos-arm64-zip, platform: macos, arch: arm64, format: zip, match: "Daybook-*-macOS-arm64.zip" }`;
  - `publishing.trustedPublisher: { workflow: .github/workflows/release.yml, environment: release }`;
  - `sparkleEd25519Pub` and `releaseKeys` as placeholders, filled in Step 5.

  Keep a single macOS payload: the feed tries only the first build per release. The `.zip.sig` sidecar joins that build without its own entry.

- [ ] **Step 4: Write `.pkey/distribution.yaml`** with outlets:
  - `direct: { platforms: [macos] }`;
  - `testflight: { appleId: 6826636947, bundleId: local.daybook.phone }`.

  Set `transports: { default: pkey-cdn }`. No `listing` yet.

- [ ] **Step 5 (owner — stop and ask): generate keys and link the product**
  1. Sparkle keys: run `generate_keys` from the Sparkle 2 release tarball. The private key stays in the owner's login Keychain; export it once with `generate_keys -x <file>` for Task 5's secret. Put the public key in `sparkleEd25519Pub`.
  2. Release key: `pkey release keys generate`. Put `{ kid: daybook-release-2026, publicKey: … }` under `releaseKeys` and keep the private half for Task 5's `PKEY_RELEASE_KEY`. It must not be the Sparkle key.
  3. Console: Products › New product › A GitHub repository › `vladzaharia/daybook` › Link repository. Record the customer-portal URL the console shows for the product.
  4. Run `pkey sdk --lang swift --write` for `daybook`. Keep the generated `PolarisConfig.swift` for Task 2.
  5. If the tag ruleset isn't on yet, run `scripts/ci/setup-github.sh … --protect-tags --apply`. The trusted publisher only accepts protected tag refs.

- [ ] **Step 6: Validate locally**

Run: `d="$(mktemp -d)"; git -C ../polaris-key archive v0.9.16 actions/publish | tar -x -C "$d"; node "$d/actions/publish/dist/index.js" validate`
Expected: no errors and no `deprecated_spelling` warnings. If it reports spellings, run `validate --fix` the same way and keep the result.

- [ ] **Step 7: Validate in CI**

Add a step to the `lint` job in `ci.yml`, copied from djdl's `ci.yml` `pkey` steps:
1. Check out `vladzaharia/polaris-key` at the full SHA of tag `v0.9.16` (`git -C ../polaris-key rev-parse v0.9.16`) into `.polaris-key`, with `persist-credentials: false`.
2. Run `node .polaris-key/actions/publish/dist/index.js validate`.

Then run `actionlint`. Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add .pkey .github/workflows/ci.yml
git commit -m "Declare Daybook as a Polaris Key product"
```

### Task 2: The SDK dependency and the `DaybookAccount` target

**Files:**
- Modify: `Package.swift`, `Package.resolved`, `.gitignore`, `Apps/macOS/project.yml` (dependency and notices phase), `Apps/iOS/project.yml`, `THIRD_PARTY_NOTICES.md`, `README.md` (Build section)
- Modify: `.github/workflows/ci.yml` and `.github/workflows/release.yml` (registry step in every Xcode job)
- Create: `.swiftpm/configuration/registries.json`, `scripts/ci/swift-registry.sh`, `Sources/DaybookAccount/PolarisConfig.swift` (the generated file from Task 1)
- Test: `Tests/DaybookAccountTests/SDKLinkTests.swift`

**Interfaces:**
- Consumes: `PolarisConfig` (generated in Task 1, Step 5).
- Produces:
  - library product `DaybookAccount` (macOS and iOS), depending on `DaybookKit`, `PolarisKey`, `PolarisKeyUI`, plus macOS-only `PolarisKeyUpdate` and `Sparkle`;
  - test target `DaybookAccountTests`;
  - `scripts/ci/swift-registry.sh --install`.

- [ ] **Step 1: Write the failing test** `testClientStartsOfflineAndNeedsActivation`

```swift
let client = try await PolarisKeyClient.create(options: PolarisKeyClientOptions(
    productSlug: PolarisConfig.productSlug, baseUrl: PolarisConfig.baseUrl, version: "1.0.0",
    pinnedKeys: PolarisConfig.pinnedKeys, trustRefresh: false, store: InMemoryStore(),
    transport: NoNetworkTransport(), expectedServices: PolarisConfig.expectedServices, fingerprint: false))
let state = await client.status()
XCTAssertEqual(state.status, .needsActivation)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `swift test --filter DaybookAccountTests`
Expected: FAIL. There is no such target, and the SDK isn't a dependency yet.

- [ ] **Step 3: Set up the registry**
  1. Create `.swiftpm/configuration/registries.json` as Key documents it: `version 1`; `registries.polaris-key.url` set to the registry URL; `security.default.signing` set to `onUnsigned: error` and `onUntrustedCertificate: error`.
  2. In `.gitignore`, replace the `.swiftpm/` line with `.swiftpm/*`, `!.swiftpm/configuration/`, `.swiftpm/configuration/*` and `!.swiftpm/configuration/registries.json`.
  3. Write `scripts/ci/swift-registry.sh --install`. It copies the file to `~/.swiftpm/configuration/registries.json` when that file is absent or identical, and otherwise fails, naming the difference. This is for CI and developer machines, so Xcode resolves the scope.

- [ ] **Step 4: Add the dependency and the target to `Package.swift`**
  - Dependencies: add the SDK pin and `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "<resolved>")`.
  - Product: `.library(name: "DaybookAccount", targets: ["DaybookAccount"])`.
  - Target: `.target(name: "DaybookAccount", dependencies: ["DaybookKit", PolarisKey, PolarisKeyUI, PolarisKeyUpdate when macOS, Sparkle when macOS])`, using `condition: .when(platforms: [.macOS])`.
  - Test target: `.testTarget(name: "DaybookAccountTests", dependencies: ["DaybookAccount", "DaybookKit", PolarisKey])`.
  - Add `"DaybookAccount"` to the `Daybook` executable and the `DaybookTests` dependencies.
  - Add a header-comment line for the new layer, in the existing style.

  Move the generated `PolarisConfig.swift` into `Sources/DaybookAccount/`.

- [ ] **Step 5: Resolve, and fix trust if needed**

Run: `swift package resolve`
Expected: it resolves `polaris-key.PolarisKey` 0.9.16 and Sparkle.

If it reports an untrusted signing certificate:
1. Ask the owner for the root certificate. It's the last entry of `SWIFT_REGISTRY_CERT_CHAIN`, in DER.
2. Commit it as `.swiftpm/configuration/polaris-registry-root.cer` (un-ignore it the same way as `registries.json`).
3. Add `trustedRootCertificatesPath` for it under `security.default.signing`.

Never loosen `onUntrustedCertificate`.

- [ ] **Step 6: Run the test**

Run: `swift test --filter DaybookAccountTests`
Expected: PASS.

- [ ] **Step 7: Wire the apps and CI**
  - Add `- package: Daybook` / `product: DaybookAccount` to the app targets in both `project.yml` files.
  - Add a "Configure the Swift registry" step (`scripts/ci/swift-registry.sh --install`) to `ci.yml`'s `iphone` and `mac` jobs and `release.yml`'s `iphone` and `mac` jobs, before any build.
  - Add the same command to README's Build section, as a one-time setup.
  - In `THIRD_PARTY_NOTICES.md`, add table rows `| Sparkle <ver> | Mac app updates | MIT · https://github.com/sparkle-project/Sparkle |` and `| Polaris Key Swift SDK 0.9.16 | Activation, accounts, update feed | MIT · https://github.com/vladzaharia/polaris-key |`.
  - Extend the Mac notices build phase so it also copies LICENSE files from the registry download directory under `SourcePackages`. Find the real path with `find build/macOS/SourcePackages -maxdepth 6 -iname 'LICENSE*' | grep -i polaris`.

- [ ] **Step 8: Verify both apps build**

Run: `swift build && scripts/build-app.sh --ad-hoc --debug && scripts/build-ios.sh --test --test-arg -only-testing:DaybookPhoneTests/ShellTests`
Expected:
- all three succeed;
- `dist/Daybook.app/Contents/Frameworks/Sparkle.framework` exists;
- `codesign --verify --deep --strict dist/Daybook.app` passes;
- `dist/Daybook.app/Contents/Resources/Licenses/` contains a Polaris Key license file;
- the iOS app has no `Sparkle.framework`.

- [ ] **Step 9: Run the full suite, then commit**

Run: `swift test`. Expected: PASS, with no change in other suites.

```bash
git add Package.swift Package.resolved .gitignore .swiftpm/configuration scripts/ci/swift-registry.sh Sources/DaybookAccount Tests/DaybookAccountTests Apps/macOS/project.yml Apps/iOS/project.yml THIRD_PARTY_NOTICES.md README.md .github/workflows
git commit -m "Add the DaybookAccount target on the Polaris Key SDK"
```

### Task 3: Account core: authorization, snapshot, controller

**Files:**
- Create: `Sources/DaybookKit/CaptureAuthorization.swift`
- Create: `Sources/DaybookAccount/LicenseMapping.swift`, `AccountSnapshot.swift`, `AccountService.swift`, `PolarisAccountService.swift`, `AccountController.swift`
- Test: `Tests/DaybookKitTests/CaptureAuthorizationTests.swift`, `Tests/DaybookAccountTests/LicenseMappingTests.swift`, `AccountControllerTests.swift`, `PolarisAccountServiceTests.swift`

**Interfaces:**
- Produces, in DaybookKit (no Polaris import):
  ```swift
  public enum CaptureDenial: String, CaseIterable, Sendable {
      case notActivated, expired, revoked, updateRequired, versionNotLicensed, unavailable
      public var title: String
  }
  public enum CaptureAuthorization: Equatable, Sendable {
      case allowed, denied(CaptureDenial)
      public var isAllowed: Bool
      public var denial: CaptureDenial?
      public func permits(_ mode: ProcessingRequest.Mode) -> Bool
  }
  public struct CaptureDeniedError: LocalizedError, Equatable { public let denial: CaptureDenial }
  @MainActor public protocol CaptureAuthorizing: AnyObject {
      var authorization: CaptureAuthorization { get }
      func start() async          // cached state only, no network; idempotent
      func observe(_ handler: @escaping @MainActor (CaptureAuthorization) -> Void)
  }
  ```
- Produces, in DaybookAccount:
  ```swift
  public enum LicenseMapping { public static func authorization(for status: LicenseStatus) -> CaptureAuthorization }
  public struct AccountSnapshot: Equatable, Sendable {
      public var authorization: CaptureAuthorization
      public var name: String?; public var email: String?; public var tierLabel: String?
      public var lastVerified: Date?; public var isOffline: Bool; public var entitledChannels: [String]
      public static let notActivated: AccountSnapshot
  }
  public protocol AccountService: Sendable {
      func snapshot() async -> AccountSnapshot
      func refresh() async -> AccountSnapshot
      func changes() -> AsyncStream<Void>
      func signOut() async throws
  }
  public final class PolarisAccountService: AccountService {
      public let client: PolarisKeyClient
      public static func connect(options: PolarisKeyClientOptions) async throws -> PolarisAccountService
  }
  @MainActor @Observable public final class AccountController: CaptureAuthorizing {
      public init(connect: @escaping @Sendable () async throws -> any AccountService)
      public static func live(version: String) -> AccountController
      public private(set) var snapshot: AccountSnapshot        // .notActivated until start()
      public private(set) var hasStarted: Bool
      public var authorization: CaptureAuthorization { get }
      public var client: PolarisKeyClient? { get }
      public func start() async; public func refresh() async; public func retry() async
      public func signOut() async throws
      public func observe(_ handler: @escaping @MainActor (CaptureAuthorization) -> Void)
  }
  ```

- [ ] **Step 1: Write the failing tests**
  - **`CaptureAuthorizationTests.testDeniedPermitsOnlyFirstProcessing`:** `.denied(.notActivated).permits(.newAudio)` is true. `.summaryOnly`, `.speakerRefresh` and `.fullRetranscription` are false. `.allowed` permits all four.
  - **`CaptureAuthorizationTests.testTitles`:** exact copy, in order: "Not activated", "License expired", "License revoked", "Update required", "This version isn't in your license", "License unavailable".
  - **`LicenseMappingTests.testEveryStatus`:** a table over all nine `LicenseStatus` cases:
    - `ok`, `grace`, `notApplicable` → `.allowed`;
    - `needsActivation` → `.notActivated`; `expired` → `.expired`; `revoked` → `.revoked`; `versionTooOld` → `.updateRequired`;
    - `versionTooNew`, `channelNotEntitled` → `.versionNotLicensed`.
  - **`AccountControllerTests`**, with a `FakeAccountService` actor (scripted snapshots, a continuation for `changes()`, and a counter for refresh calls):
    - `testStartReadsTheCachedSnapshotOnce`: `start()` twice calls `snapshot()` once and sets `hasStarted`.
    - `testChangesUpdateAuthorizationAndNotifyObservers`: a change event with the fake now `.denied(.revoked)` updates `authorization` and calls the observer once.
    - `testConnectFailureIsUnavailableAndRetryRecovers`: `connect` throws, so authorization is `.denied(.unavailable)`. The next `connect` succeeds with `.allowed`; after `retry()`, authorization is `.allowed`.
    - `testSignOutRefreshesTheSnapshot`.
  - **`PolarisAccountServiceTests.testOfflineFreshInstall`:** `connect` with `InMemoryStore()` and `NoNetworkTransport()` gives a snapshot of `.denied(.notActivated)`. `refresh()` returns the same and doesn't throw.

- [ ] **Step 2: Run them to make sure they fail**

Run: `swift test --filter 'DaybookAccountTests|CaptureAuthorizationTests'`
Expected: FAIL, because the types are undefined.

- [ ] **Step 3: Implement the DaybookKit types**

`permits(_:)` is `isAllowed || mode == .newAudio`.

- [ ] **Step 4: Implement `LicenseMapping` and `AccountSnapshot`**

`isOffline` is `status == .grace`. `lastVerified` comes from `LicenseState.lastVerifiedAt` (epoch ms).

- [ ] **Step 5: Implement `PolarisAccountService`**
  - `connect` runs `PolarisKeyClient.create(options:)` (no network), then `syncOnForeground()`, then a detached `sync()`.
  - `snapshot` combines `status()`, `licenseInfo()` and `identity.current()`.
  - `refresh` runs `sync()`, then `snapshot()`.
  - `changes` maps `client.events` cases `.license` and `.entitlement` to `Void`.
  - `signOut` calls `client.signOut()`.

- [ ] **Step 6: Implement `AccountController`**
  - `live(version:)` connects with `PolarisConfig.clientOptions(version:)`.
  - `start()` connects, reads the snapshot, then iterates `changes()` in a Task that calls `snapshot()` and notifies observers only when `authorization` changes.
  - When `connect` throws, the snapshot becomes `.denied(.unavailable)`.

- [ ] **Step 7: Run the tests**

Run: `swift test --filter 'DaybookAccountTests|CaptureAuthorizationTests'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/DaybookKit/CaptureAuthorization.swift Sources/DaybookAccount Tests/DaybookAccountTests Tests/DaybookKitTests/CaptureAuthorizationTests.swift
git commit -m "Map Polaris Key license states to capture authorization"
```

### Task 4: Mac updater with a relaunch gate

**Files:**
- Create: `Sources/DaybookAccount/Updates/UpdateChannel.swift`, `RelaunchGate.swift`, `UpdaterController.swift`, `DaybookUpdaterDelegate.swift` (each inside `#if os(macOS)`)
- Modify: `Resources/Info.plist`, `Sources/Daybook/App/DaybookApp.swift`, `Sources/Daybook/UI/SettingsView.swift`, `README.md` (Privacy: update checks), `docs/product.md` (line 10)
- Test: `Tests/DaybookAccountTests/UpdaterTests.swift`

**Interfaces:**
- Consumes: `AccountController.live(version:)` and `.client` (Task 3).
- Produces:
  ```swift
  public enum UpdateChannel: String, CaseIterable, Sendable {
      case stable, beta
      public static func available(entitled: [String]) -> [UpdateChannel]
  }
  public struct RelaunchGate {
      public init()
      public mutating func shouldPostpone(busy: Bool, install: @escaping () -> Void) -> Bool
      public mutating func resume(busy: Bool)
  }
  @MainActor @Observable public final class UpdaterController {
      public enum State: Equatable { case idle, running, unavailable(String) }
      public init(client: PolarisKeyClient, defaults: UserDefaults, isBusy: @escaping @MainActor () -> Bool)
      public private(set) var state: State
      public private(set) var channels: [UpdateChannel]
      public var channel: UpdateChannel          // stored under "updateChannel"
      public var automaticallyChecks: Bool       // Sparkle's automaticallyChecksForUpdates
      public func start() async
      public func checkForUpdates()
      public func busyStateChanged()
  }
  ```

- [ ] **Step 1: Write the failing tests**
  - **`testAvailableChannels`:** `[]` and `["stable"]` give `[.stable]`. `["beta","stable"]` and `["staging"]` give `[.stable, .beta]`.
  - **`testRelaunchWaitsWhileBusy`:** `shouldPostpone(busy: true, install:)` returns true and the install closure isn't called. `resume(busy: true)` still doesn't call it. `resume(busy: false)` calls it exactly once, and a second `resume(busy: false)` doesn't.
  - **`testRelaunchProceedsWhenIdle`:** `shouldPostpone(busy: false, …)` returns false and stores nothing.
  - **`testMissingEDKeyIsUnavailable`:** an `UpdaterController` on a client from `InMemoryStore` and `NoNetworkTransport`, under the test bundle (which has no `SUPublicEDKey`). After `start()`, `state` is `.unavailable(_)` and nothing crashes.

- [ ] **Step 2: Run them to make sure they fail**

Run: `swift test --filter UpdaterTests`
Expected: FAIL, because the types are undefined.

- [ ] **Step 3: Implement `UpdateChannel` and `RelaunchGate`**

- [ ] **Step 4: Implement `DaybookUpdaterDelegate`**

An `NSObject, SPUUpdaterDelegate` holding `var inner: PolarisSparkleUpdaterDelegate` and a `RelaunchGate`:
- `responds(to:)` and `forwardingTarget(for:)` pass every selector to `inner`, except `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`.
- It implements that method itself, through the gate and `isBusy`.

- [ ] **Step 5: Implement `UpdaterController.start()`**

Follow the SDK README's manual path. Do not use `PolarisSparkle.start`, which owns the delegate.
1. `await client.discover()`.
2. Build `UpdateClient(core: client.core)`.
3. Get the feed: `update.feed(channel: channel.rawValue, entitlements: await client.license.entitlements())`.
4. Build `DaybookUpdaterDelegate(inner: PolarisSparkleUpdaterDelegate(feed:))`.
5. Create `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate:…, userDriverDelegate: nil)`.
6. `try PolarisSparkleUpdater.configure(updater, feed:, headers: await update.feedHeaders(channel:))`, then `try updater.start()`.
7. `SparkleAnchorError` and any other throw set `.unavailable(error.localizedDescription)`.

After that, iterate `client.events`. On `.license` or `.entitlement`, rebuild the feed, swap `inner`, call `configure` again, and recompute `channels`. If the stored channel isn't in `channels`, fall back to `.stable`.

Setting `channel` stores it and rebuilds the same way.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter UpdaterTests`
Expected: PASS.

- [ ] **Step 7: Wire the Mac app**
  - **Info.plist:** add `SUPublicEDKey` (from Task 1) and `SUEnableAutomaticChecks` = true. Add no `SUFeedURL`.
  - **`DaybookApp`:**
    - `@State var account: AccountController?` is `nil` under `#if DEBUG` when `LaunchOptions.defaults.bool(forKey: "DaybookSkipActivation")`, and `nil` when `Bundle.main` has no `CFBundleShortVersionString`. Otherwise it is `.live(version:)`.
    - `@State var updater: UpdaterController?`.
    - In the library window's `.task`: `await account?.start()`, then create and start the updater, with `isBusy` = `state.isRecording || state.isStartingRecording || state.processingID != nil`.
    - Call `updater?.busyStateChanged()` from `.onChange` of `state.isRecording` and `state.processingID`.
  - **`DaybookCommands`:** add a "Check for Updates…" item under `CommandGroup(after: .appInfo)`, disabled unless the updater is `.running`.
  - **`SettingsView`:** pass `updater` in. `GeneralSettings` gains `Section("Updates")`:
    - a Toggle "Check Automatically";
    - a Picker "Channel" over `updater.channels`, only when there is more than one;
    - a Button "Check Now".
    - **Call:** this is a section in General, not a separate pane.
  - **Docs:** README Privacy and `docs/product.md` line 10 add one sentence: the Mac app checks `key.plrs.im` for updates.

- [ ] **Step 8: Verify by hand**

Run: `scripts/build-app.sh --ad-hoc --debug && open dist/Daybook.app`
Expected: Daybook › Check for Updates… exists, and Settings › General shows Updates. An ad hoc build may report "unavailable" until Task 1's key is in Info.plist; it must not crash.

- [ ] **Step 9: Run the suite, then commit**

Run: `swift test`. Expected: PASS.

```bash
git add Sources/DaybookAccount/Updates Tests/DaybookAccountTests/UpdaterTests.swift Resources/Info.plist Sources/Daybook README.md docs/product.md
git commit -m "Update the Mac app through Sparkle from Polaris Key"
```

### Task 5: Release pipeline: sign the ZIP and publish to Key

**Files:**
- Create: `scripts/ci/install-sparkle-tools.sh`, `scripts/ci/sign-update.sh`
- Modify: `scripts/ci/package-mac.sh`, `scripts/ci/secrets.sh`, `scripts/ci/setup-github.sh`, `scripts/ci/tests/run-tests.sh`, `.github/workflows/release.yml`, `docs/release.md`
- Test: new sections in `scripts/ci/tests/run-tests.sh`

**Interfaces:**
- Consumes: artifact id `macos-arm64-zip` and the trusted publisher (Task 1); the ZIP name `Daybook-<version>-macOS-arm64.zip` (`package-mac.sh:45`).
- Produces:
  - `<zip>.sig`: bare base64 of a 64-byte signature, next to the ZIP and listed in `SHA256SUMS.txt`;
  - secrets `SPARKLE_ED_PRIVATE_KEY` and `PKEY_RELEASE_KEY`, and variable `PKEY_PUBLISH`;
  - job `polaris-key` in `release.yml`.

- [ ] **Step 1: Write the failing script tests** in `run-tests.sh`, in its `# --- name ---` style:
  - **sign-update.sh:**
    - a stub `sign_update` on `PATH` echoes the base64 of 64 bytes, and the script writes exactly that to `<file>.sig`;
    - when the stub prints `sparkle:edSignature="…" length="…"`, the script fails and writes no `.sig`;
    - a missing `--key-file` fails.
  - **package-mac.sh** (no `--notarize`, `SIGN_UPDATE` = the stub, `DAYBOOK_SPARKLE_KEY_PATH` = a temp file): `SHA256SUMS.txt` lists `Daybook-1.2.3-macOS-arm64.zip` and `Daybook-1.2.3-macOS-arm64.zip.sig`. Without `DAYBOOK_SPARKLE_KEY_PATH` there is no `.sig` and the script still succeeds.
  - **setup-github.sh** dry run with `--sparkle-key <file> --pkey-release-key <file>`: the plan includes `gh secret set SPARKLE_ED_PRIVATE_KEY --env release`, `gh secret set PKEY_RELEASE_KEY --env release` and `PKEY_PUBLISH --body true`, and never prints either key's body.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/ci/tests/run-tests.sh`
Expected: the new checks FAIL, and the existing ones pass.

- [ ] **Step 3: Write `install-sparkle-tools.sh`**

It downloads `Sparkle-<ver>.tar.xz`, where `<ver>` is the Package.resolved Sparkle version, and checks a pinned SHA-256. Compute the SHA-256 once from the GitHub release asset and hard-code it, as `install-xcodegen.sh` does. It extracts the tools and exports `SIGN_UPDATE=<dir>/bin/sign_update` to `$GITHUB_ENV`.

- [ ] **Step 4: Write `sign-update.sh --key-file <path> <file>`**

It runs `"$SIGN_UPDATE" -p --ed-key-file <path> <file>`. It checks that the output decodes to exactly 64 bytes, then writes the output with no newline to `<file>.sig`. It never echoes the key.

- [ ] **Step 5: Extend `package-mac.sh` and `secrets.sh`**
  - `package-mac.sh`: after the ZIP is written (line 96), if `DAYBOOK_SPARKLE_KEY_PATH` is set, run `sign-update.sh`. Add `"$name.zip.sig"` to the checksum loop.
  - `secrets.sh setup`: decode `SPARKLE_ED_PRIVATE_KEY` with `decode_to` into the secrets dir, and `export_env DAYBOOK_SPARKLE_KEY_PATH`. Skip when the secret is empty. `cleanup` already removes the directory.

- [ ] **Step 6: Extend `setup-github.sh`**

Add these, following the existing `--developer-id-p12` pattern:
- options `--sparkle-key FILE` and `--pkey-release-key FILE`, with header lines and local checks that the files exist;
- `value_SPARKLE_ED_PRIVATE_KEY` and `value_PKEY_RELEASE_KEY`, both read from the file;
- `secret` calls for both;
- `run gh variable set PKEY_PUBLISH --body true --repo "$repo"`, only when `--pkey-release-key` is given.

- [ ] **Step 7: Run the script tests**

Run: `scripts/ci/tests/run-tests.sh && shellcheck scripts/ci/*.sh scripts/ci/tests/*.sh`
Expected: all checks pass, with no shellcheck findings.

- [ ] **Step 8: Change `release.yml`**
  - **`mac` job:**
    - add `SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}` to the "Write the API key…" step's `env`;
    - add a step `scripts/ci/install-sparkle-tools.sh` before "Notarize, staple, and package".
  - **New job `polaris-key`:**
    - `name: Polaris Key`, `needs: [prepare, publish]`;
    - `if: needs.prepare.outputs.is_tag == 'true' && needs.publish.result == 'success' && vars.PKEY_PUBLISH == 'true'`;
    - `runs-on: ubuntu-24.04`, `timeout-minutes: 15`, `environment: release`, `permissions: { contents: read, id-token: write }`.
  - **Its steps:**
    1. Checkout with `persist-credentials: false`.
    2. Download `mac-release` to `dist`.
    3. Copy only the ZIP and its `.sig` into `pkey/`.
    4. Write `pkey-builds.json` as `{"macos-arm64-zip": {"buildNumber": "<build_number>", "minOS": "15.0"}}` from `needs.prepare.outputs.build_number`.
    5. Run `uses: vladzaharia/polaris-key/actions/publish@<full SHA of v0.9.16> # v0.9.16` with:
       - `product: daybook`;
       - `tag: ${{ needs.prepare.outputs.tag }}`;
       - `channel:` `beta` when `needs.prepare.outputs.prerelease == 'true'`, else `stable`;
       - `dir: pkey`, `meta: pkey-builds.json`;
       - `release-key: ${{ secrets.PKEY_RELEASE_KEY }}`.

  Then run `actionlint`. Expected: clean.

- [ ] **Step 9: Document it in `docs/release.md`**
  - Add rows for the `mac` signing and `polaris-key` jobs to the Pipeline table.
  - Add `SPARKLE_ED_PRIVATE_KEY` and `PKEY_RELEASE_KEY` to the Secrets table, and `PKEY_PUBLISH` to the variables table.
  - Add the `.sig` to "Cutting a release".
  - Add a "Publishing to Polaris Key" section: what the job sends, the trusted publisher and protected tags, and how to dry-run with the Action's `dry-run: true`.

- [ ] **Step 10: Commit**

```bash
git add scripts/ci .github/workflows/release.yml docs/release.md
git commit -m "Sign the Mac ZIP for Sparkle and publish releases to Polaris Key"
```

### Task 6 (owner + agent): Ship release 1 and prove an update

**Files:**
- Modify: `docs/validation.md`

- [ ] **Step 1 (owner):** run `scripts/ci/setup-github.sh … --sparkle-key <exported key> --pkey-release-key <key> --apply`.
- [ ] **Step 2 (owner):** tag `vX.Y.Z-rc.1`.
  - Expected:
    - the `polaris-key` job succeeds;
    - `https://key.plrs.im/daybook/update/appcast.xml?arch=arm64` (beta channel) lists the build with `sparkle:edSignature` and a `.zip` enclosure.
  - If the feed is empty: Key's legacy DMG-only path is serving. Check with `pkey doctor --product daybook` that release records exist.
- [ ] **Step 3 (owner):** install that build on a Mac with a library, then tag `vX.Y.(Z+1)-rc.1`.
  - Expected: Check for Updates installs it.
  - Then check the result:
    - `spctl -a -vv /Applications/Daybook.app` says Notarized Developer ID;
    - iCloud sync still resolves;
    - the library is intact.
  - Repeat with a recording running. Expected: the relaunch waits until the recording is stopped.
- [ ] **Step 4:** record the results under a new "Updates (Polaris Key)" heading in `docs/validation.md`, then commit with `git commit -m "Record Sparkle update validation"`.

---

## Part B — activation and Limited mode (release 2)

### Task 7: Enforce authorization on the Mac

**Files:**
- Modify:
  - `Sources/Daybook/App/AppState.swift` (init, `initialize`, `startRecording`, `chooseImport`, `importFiles`, `enqueue`);
  - `AppState+Devices.swift` (`importFromDevice`, and wiring `capturePermitted`);
  - `AppState+Phone.swift` (`answerPhone`);
  - `AppState+Requests.swift` (`mayRun`);
  - `Sources/DaybookDevices/DeviceSession.swift` (`capturePermitted`);
  - `Sources/DaybookLink/LinkMessages.swift` (refusal reason);
  - `Sources/Daybook/App/DaybookApp.swift` (pass the authorizer);
  - `docs/link.md`, `README.md`, `docs/product.md`, `AGENTS.md`.
- Create: `docs/accounts.md`
- Test: `Tests/DaybookTests/CaptureAuthorizationEnforcementTests.swift`, `Tests/DaybookDevicesTests/DeviceSessionCaptureTests.swift`, and an addition to `Tests/DaybookTests/PhoneLinkTests.swift`

**Interfaces:**
- Consumes: `CaptureAuthorization`, `CaptureAuthorizing`, `CaptureDeniedError` (Task 3).
- Produces:
  - `AppState.init(libraryURL:defaults:authorizer: (any CaptureAuthorizing)? = nil)`;
  - `@Published private(set) var authorization: CaptureAuthorization` (`.allowed` when there is no authorizer);
  - `DeviceSession.capturePermitted: Bool` (default true; `didSet` true re-evaluates);
  - `LinkRecordRefusal.Reason.notActivated`, added in the same style as the existing reasons.

- [ ] **Step 1: Write the failing tests**

Use a `FakeAuthorizer: CaptureAuthorizing` with a settable `authorization`, an observer list and a start counter, plus the `AppStateTests.makeState()` pattern extended with `authorizer:`.
- **`testInitializeWaitsForTheAuthorizer`:** `isReady` is true only after the fake's `start()` returns; it's called once.
- **`testDeniedBlocksStartingARecording`:** `.denied(.notActivated)`, then `await startRecording()` leaves `recordingID` nil.
- **`testAutomaticRecordingDoesNotStartWhenDenied`:** `startRecording(automatic: true)` with `automaticRecording = true` and Limited leaves `recordingID` nil.
- **`testRevocationDuringARecordingKeepsRecording`** (Review Focus 3):
  1. Start allowed, then flip the fake to `.denied(.revoked)`.
  2. `isRecording` stays true.
  3. `stopRecording()` saves the meeting.
  4. A `.newAudio` job is queued for it, using the `MultiSourceRig` fake inference.
- **`testImportsAreRefusedWhenDenied`:** `importFiles` throws `CaptureDeniedError(denial: .notActivated)` and the library is unchanged.
- **`testReprocessingIsRefusedButFirstProcessingRuns`:** under Limited, `enqueue(id, mode: .summaryOnly)` queues nothing and sets `errorMessage` to "Not activated"; `enqueue(id, mode: .newAudio)` queues.
- **`testPhoneReprocessingRequestStaysOpenWhenDenied`:** in `ProcessingRequestQueueTests` style, a `.speakerRefresh` request from the phone isn't claimed under Limited. It's claimed after the fake flips to `.allowed` and `pickUpRequests()` runs.
- **`testExistingLibraryStaysEditableWhenDenied`** (Review Focus 5): a library with one meeting, opened Limited. The meeting loads, editing its notes saves, and `onboardingCompleted` stays true.
- **`testUnavailableAuthorizerStillOpensTheLibrary`** (Review Focus 2): with `.denied(.unavailable)`, `isReady` becomes true and meetings load.
- **`PhoneLinkTests.testTheMacRefusesARecordRequestWhenNotActivated`:** the phone's request gets `.refused` with reason `.notActivated` and message "This Mac isn't activated."
- **`DeviceSessionCaptureTests.testAutomaticImportsWaitWhileCaptureIsNotPermitted`** (Review Focus 4): with `capturePermitted = false`, `evaluate()` calls the importer zero times. Setting it to true imports the pending recording once.

- [ ] **Step 2: Run them to make sure they fail**

Run: `swift test --filter 'CaptureAuthorizationEnforcementTests|DeviceSessionCaptureTests|PhoneLinkTests'`
Expected: the new tests FAIL, because there is no `authorizer:` parameter and no gate.

- [ ] **Step 3: Gate AppState**
  - **`initialize()`:** before `isReady`, run `await authorizer?.start()`, copy `authorization`, and register an observer. The observer sets `authorization`, sets `sources`/device sessions `capturePermitted`, and calls `pickUpRequests()` when it becomes allowed.
  - **`startRecording`:** add `guard authorization.isAllowed else { return }` after the existing guards.
  - **Imports:** `chooseImport`, `importFiles` and `importFromDevice` throw `CaptureDeniedError` before doing anything. `chooseImport` shows it through `errorMessage`. `importAudio` itself is not gated, because it also moves existing audio.
  - **Processing:** `enqueue` returns early unless `authorization.permits(mode)`, setting `errorMessage = denial.title`. `mayRun(_:)` returns false unless `authorization.permits(job.mode)`.

- [ ] **Step 4: Gate the phone path**

In `answerPhone`, check `authorization` first and return `.refused(LinkRecordRefusal(reason: .notActivated, message: "This Mac isn't activated."))`.

- [ ] **Step 5: Gate `DeviceSession`**

Add `capturePermitted`, checked next to `libraryReady` in `evaluate()` (~:467) and the queue start (~:333).

- [ ] **Step 6: Pass the authorizer**

`DaybookApp` creates `account` before `state`, in `init`, and passes `authorizer: account` to `AppState`.

- [ ] **Step 7: Run the tests**

Run: `swift test`
Expected: PASS, including every existing suite. With no authorizer, everything is allowed.

- [ ] **Step 8: Write the docs**
  - **`docs/accounts.md`:** activation paths, the mode table from the spec, every entry point, first processing, offline grace, sign-out, and the DEBUG flag. Use the style of `docs/icloud-sync.md`.
  - **`docs/link.md`:** add the `notActivated` refusal.
  - **README "Privacy", `docs/product.md` line 10, and `AGENTS.md` "Privacy & Configuration":** use the spec's Privacy text. List exactly what goes to `key.plrs.im` and say that library content never does. Replace "No Daybook account … or telemetry".

- [ ] **Step 9: Commit**

```bash
git add Sources Tests docs README.md AGENTS.md
git commit -m "Hold new captures and reprocessing until Daybook is activated"
```

### Task 8: Mac activation and account UI

**Files:**
- Create: `Sources/DaybookAccount/AccountPresentation.swift`, `AccountLinks.swift`, `ActivationView.swift`, `PolarisKeyTheme+Daybook.swift`, `Sources/Daybook/UI/SettingsAccountPane.swift`
- Modify: `Sources/DaybookAccount/AccountController.swift` (`gateModel`), `Sources/Daybook/UI/WelcomeWindow.swift`, `ConversationList.swift` (`LibraryNotice`), `LibraryView.swift` and `MenuBarView.swift` (disabled controls), `DaybookApp.swift` (commands, Dock menu, `--open-settings account`), `SettingsView.swift` (pane), `DevicePage.swift` (disable "Start Recording on …")
- Test: `Tests/DaybookAccountTests/AccountPresentationTests.swift`

**Interfaces:**
- Consumes: `AccountController`, `AccountSnapshot`, `CaptureAuthorization` (Task 3); `AppState.authorization` (Task 7).
- Produces:
  ```swift
  public enum AccountAction: Equatable { case activate, manage, checkForUpdates, openTestFlight, tryAgain }
  public struct AccountNotice: Equatable { public let title: String; public let action: AccountAction }
  public struct AccountRow: Equatable { public let label: String; public let value: String }
  public enum AccountPresentation {
      public enum Platform { case mac, phone }
      public static func notice(for: CaptureAuthorization, platform: Platform, canManage: Bool) -> AccountNotice?
      public static func rows(for: AccountSnapshot, now: Date) -> [AccountRow]
  }
  public enum AccountLinks { public static let manage: URL? }   // the console's portal URL (Task 1); nil hides Manage
  public struct ActivationView: View { public init(account: AccountController, onActivated: @escaping @MainActor () -> Void) }
  // AccountController gains: public private(set) var gateModel: PolarisKeyGateModel?  (created with the client)
  ```

- [ ] **Step 1: Write the failing tests**
  - **`testNoticeForEachDenial`:**
    - `.allowed` → nil;
    - `.notActivated` → ("Not activated", `.activate`);
    - `.expired` with `canManage` → ("License expired", `.manage`); without it → `.activate`;
    - `.revoked` follows the same rule;
    - `.updateRequired` → `.checkForUpdates` on Mac, `.openTestFlight` on phone;
    - `.versionNotLicensed` → `.checkForUpdates` (Mac) and `.manage` or `.activate` (phone);
    - `.unavailable` → ("License unavailable", `.tryAgain`).
  - **`testRowsForASignedInAccount`:** name "Vlad", email "v@example.com", tier "Standard", allowed → `[("Account","Vlad"), ("Email","v@example.com"), ("Plan","Standard"), ("Status","Active")]`.
  - **`testRowsForAKeyActivation`:** no name or email → `("Account","License key")`.
  - **`testRowsWhileOffline`:** `isOffline`, `lastVerified` two days before `now` → Status "Offline · checked 2 days ago". Use `RelativeDateTimeFormatter` with the `.full` style and the `en_US_POSIX` locale in the test.

- [ ] **Step 2: Run them to make sure they fail**

Run: `swift test --filter AccountPresentationTests`
Expected: FAIL.

- [ ] **Step 3: Implement `AccountPresentation` and `AccountLinks`**

`AccountLinks.manage` is the portal URL recorded in Task 1, Step 5.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AccountPresentationTests`
Expected: PASS.

- [ ] **Step 5: Build the activation views**
  - **`AccountController`:** creates `gateModel = PolarisKeyGateModel(client:options: KitGateOptions(keyEntry: true))` once the client exists.
  - **`ActivationView`:**
    - when there is a `gateModel`: `PolarisKeyGate(model:) { ActivatedConfirmation(onContinue: onActivated) }.polarisKeyTheme(.daybook)`;
    - when the controller is `.denied(.unavailable)`: the title plus Try Again (`account.retry()`).
  - **`PolarisKeyTheme.daybook`:**
    - `product.name` is "Daybook";
    - `accent: .color(<AccentColor light hex>, dark: <dark hex>)`, read from `Resources/Assets.xcassets/AccentColor.colorset`;
    - `copy` overrides every `en` kit-copy string that explains mechanics with a status or action phrase. Find them in the SDK's `kit-copy.json`; an example is `welcome.lede`.

- [ ] **Step 6: Wire the Mac UI**
  - **Welcome window:** steps become 0 Intro, 1 Activate (`ActivationView`; `onActivated` advances), 2 Quality, 3 Ready. Update `ForEach(0..<4)`, "of 4" and the `initialStep` clamp to 3.
  - **`LibraryNotice`:** when `account.hasStarted` and `AccountPresentation.notice` isn't nil, show the title and the action button (Activate opens a sheet with `ActivationView`). This takes precedence over `state.notice`.
  - **Record controls:** every record and import control (toolbar `RecordControl`, `EmptyLibraryView`, File menu items, Dock menu, `MenuBarView`, Floating Notes `RecordButton`, `SummaryPage`, `MeetingInspector`, `DevicePage` "Start Recording on …") gets `.disabled(!state.authorization.isAllowed)` and `.help(denial.title)`. Disable controls; never hide them.
  - **`MenuBarView`:** shows the notice title as its first line, plus "Activate…".
  - **Settings:** add `SettingsPane.account` with `Tab("Account", systemImage: "person.crop.circle", …)` showing `SettingsAccountPane`:
    - `AccountPresentation.rows`;
    - Manage, when `AccountLinks.manage` is set (opens it with `NSWorkspace`);
    - Sign Out, after a `.confirmationDialog`; it calls `account.signOut()`;
    - Try Again, when unavailable.
    - Add `account` to the DEBUG `--open-settings` mapping.

- [ ] **Step 7: Verify with screenshots**

Run: `scripts/build-app.sh --ad-hoc --debug`, then `open dist/Daybook.app --args --open-settings account --snapshot /tmp/daybook-account`, and the same with `--show-setup`.
Expected:
- the Account pane and the Welcome Activate step render in light and dark;
- no copy explains mechanics;
- the record controls are disabled with help text when not activated.

- [ ] **Step 8: Run the suite, then commit**

Run: `swift test`. Expected: PASS.

```bash
git add Sources Tests
git commit -m "Add activation and account settings to the Mac app"
```

### Task 9: Enforce authorization on the iPhone

**Files:**
- Modify:
  - `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift` (init, `startRecording(into:title:multipoint:)`, `answer`, new `requestProcessing`, `publish()`);
  - `Apps/iOS/DaybookPhone/App/DaybookPhoneApp.swift`;
  - `Apps/iOS/Shared/SharedRecordingState.swift`;
  - `Apps/iOS/DaybookPhoneWidgets/RecordConversationControl.swift` and `RecorderWidget.swift`;
  - the reprocessing call sites in `ConversationScreen.swift`, `SummaryPage.swift` and `ConversationInfo.swift`;
  - the import paths in `PhoneLibrary.swift` callers.
- Test: `Apps/iOS/DaybookPhoneTests/ActivationTests.swift`

**Interfaces:**
- Consumes: `CaptureAuthorizing`, `CaptureAuthorization`, `CaptureDeniedError` (Task 3); `AccountController.live(version:)`.
- Produces:
  - `PhoneAppModel.init(…, authorizer: (any CaptureAuthorizing)? = nil)`;
  - `private(set) var authorization: CaptureAuthorization`;
  - `func requestProcessing(_ id: UUID, mode: ProcessingRequest.Mode, templateID: String? = nil) -> Bool`;
  - `SharedRecordingState.captureDenial: String?` (optional, so old JSON still decodes).

- [ ] **Step 1: Write the failing tests**

Use the `LinkServicesTests.makeModel` pattern plus a `FakeAuthorizer` (copy the Task 7 fake into the iOS test target).
- **`testStartRecordingIsRefusedWhenNotActivated`:** it throws `RecordingCommandError.failed`, `notice` is "Not activated", and nothing records.
- **`testMacRecordRequestIsRefusedAsNotActivated`:** `answer(mac, request)` returns `.refused` with reason `.notActivated`.
- **`testReprocessingIsNotFiledWhenDenied`:** `requestProcessing(id, mode: .fullRetranscription)` returns false and files no request; `.newAudio` returns true and files one.
- **`testRecordingContinuesWhenTheLicenseLapses`:** start allowed, flip to `.denied(.expired)`, and the recording is still running.
- **`testDenialIsMirroredToSharedState`:** after the flip, the encoded `SharedRecordingState` has `captureDenial == "License expired"`. Old JSON without the field still decodes.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/build-ios.sh --test --test-arg -only-testing:DaybookPhoneTests/ActivationTests`
Expected: FAIL.

- [ ] **Step 3: Implement**
  - **The authorizer:** start it in the model's startup before the first `publish()`, and observe it.
  - **`startRecording(into:title:multipoint:)`:** guard first. Set `notice` to the title and throw `RecordingCommandError.failed(title)`. This one guard covers buttons, the Control Center control, the widget, Shortcuts and Siri.
  - **`answer`:** checks before `acceptsMacRecordRequests`.
  - **`requestProcessing`:** wraps `library.requestProcessing` with `permits(mode)`. Route every reprocessing call site through it. `fileRecording`'s automatic `.newAudio` stays as it is.
  - **Imports:** `importFile` and `importDeviceRecording` throw `CaptureDeniedError`.
  - **`publish()`:** writes `captureDenial`.
  - **Widgets:** the control's title and the widget show the denial when it's set; the action still runs through the app, which refuses.
  - **`DaybookPhoneApp`:** creates `AccountController.live(version:)` unless DEBUG `-DaybookSkipActivation YES`, and passes it.

- [ ] **Step 4: Run the tests**

Run: `scripts/build-ios.sh --test`
Expected: PASS, including every existing `DaybookPhoneTests` suite.

- [ ] **Step 5: Commit**

```bash
git add Apps/iOS
git commit -m "Hold new captures on the iPhone until Daybook is activated"
```

### Task 10: iPhone activation and account UI

**Files:**
- Create: `Apps/iOS/DaybookPhone/Settings/AccountSection.swift`, `Apps/iOS/DaybookPhone/App/ActivationSheet.swift`
- Modify: `PhoneAppModel.swift` (`showsActivation`), `Settings/SettingsScreen.swift`, `Library/LibraryPage.swift` (present the sheet), `RecordingComponents.swift` (`RecordingNotice` action)
- Test: an addition to `Apps/iOS/DaybookPhoneTests/ActivationTests.swift`

**Interfaces:**
- Consumes: `ActivationView`, `AccountPresentation`, `AccountLinks` (Task 8); `PhoneAppModel.authorization` (Task 9).
- Produces: `PhoneAppModel.showsActivation: Bool` and `func dismissActivation()`.

- [ ] **Step 1: Write the failing tests**
  - **`testActivationSheetShowsOnceWhenNotActivated`:** after startup with `.denied(.notActivated)`, `showsActivation` is true. After `dismissActivation()` it is false and stays false through another authorization change to `.denied(.notActivated)` in the same launch.
  - **`testActivationSheetNotShownWhenActive`.**

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/build-ios.sh --test --test-arg -only-testing:DaybookPhoneTests/ActivationTests`
Expected: FAIL.

- [ ] **Step 3: Implement**
  - **`showsActivation`:** set it when the first authorization is `.denied(.notActivated)`.
  - **`ActivationSheet`:** wraps `ActivationView`, plus a "Not Now" toolbar button that calls `dismissActivation()`. It is presented from `LibraryPage`.
  - **`AccountSection`** (a `Section("Account")` in `SettingsScreen`'s `Form`, above `SyncSection`):
    - `AccountPresentation.rows`;
    - Manage (`openURL`), when set;
    - Sign Out, with a confirmation dialog;
    - Try Again, when unavailable;
    - Activate, when Limited (presents the sheet).
  - **`RecordingNotice`:** shows the notice's action button.
  - **`updateRequired`:** opens `https://testflight.apple.com` with `openURL`.

- [ ] **Step 4: Run the tests**

Run: `scripts/build-ios.sh --test`
Expected: PASS.

- [ ] **Step 5: Check by eye in the simulator**

Launch with `-DaybookSkipActivation NO` against a scratch library. Expected: the sheet shows once, Not Now leaves a usable library with recording disabled and the notice visible, and Settings shows the Account section.

- [ ] **Step 6: Commit**

```bash
git add Apps/iOS
git commit -m "Add activation and account settings to the iPhone app"
```

### Task 11 (owner + agent): Ship release 2 and validate on devices

**Files:**
- Modify: `docs/validation.md`

- [ ] **Step 1 (owner):** issue licenses: add people to the `family` or `friends` Polaris groups, and create keys in the console for anyone else.
- [ ] **Step 2 (owner):** tag a release. Expected: Macs on release 1 update through Sparkle to release 2, and the iPhone build reaches TestFlight.
- [ ] **Step 3 (owner): device checks.** Each item lists its expected result.
  - **Sign-in:**
    - Sign-in works on a Mac and on an iPhone.
    - A key activates a second Mac.
    - The sixth device sees "Replace a device".
  - **Offline:**
    - A Mac with networking denied (`sandbox-exec … (deny network*)`) stays Full while in grace.
    - With the clock advanced past 30 days it turns Limited without stopping a running recording.
    - It recovers when it reaches the network again.
  - **Revocation:** revoking in the console reaches a running Mac on its next sync.
  - **Updates:** a `beta` license sees the channel picker; `standard` doesn't.
  - **Phone:** a phone asking a Limited Mac to record shows "This Mac isn't activated."
  - **Existing installs:** an existing library opens Limited with everything readable. Activating restores recording.
  - **Offline smoke:** `swift run Daybook --smoke-test` with networking denied still passes.
- [ ] **Step 4:** record the results under "Activation (Polaris Key)" in `docs/validation.md`, then commit with `git commit -m "Record activation validation"`.
