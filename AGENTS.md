# Repository Guidelines

## Project Structure & Module Organization

Daybook is a native SwiftUI/AppKit app for Apple silicon Macs running macOS 15 or newer.

- `Sources/Daybook/`: application state, UI, audio capture, imports, embedded inference, and experimental Soundcore integration.
- `Sources/DaybookCore/`: persistence, sync, transcript fusion, speaker matching, templates, and shared models. Keep reusable domain logic here.
- `Tests/DaybookTests/` and `Tests/DaybookCoreTests/`: application and core XCTest suites.
- `Resources/`: app metadata and entitlements. `scripts/`: packaging, runtime bundling, and icon generation.
- `docs/`: architecture, research, and validation records. Generated `.build/`, `build/`, and `dist/` directories are ignored.

## Build, Test, and Development Commands

Use Xcode with Swift 6.2 or newer, the Metal compiler component, and XcodeGen (`brew install xcodegen`).

- `swift build`: compile a development build.
- `swift test`: run all unit and integration tests.
- `swift test --filter TranscriptFusionTests`: run a focused suite.
- `./scripts/build-app.sh`: generate the Mac Xcode project from `Apps/macOS/project.yml` (it compiles `Sources/Daybook` in place), archive, export with Developer ID, and package `dist/Daybook.app` and the ZIP; add `--debug` for a debug build, `--ad-hoc` to sign locally without a team (no iCloud), `--generate-only` to only regenerate the project.
- `DAYBOOK_TEAM_ID=… ./scripts/build-app.sh --allow-provisioning-updates`: first-time provisioning of the Mac app ID, iCloud, and profiles. Only the account owner runs it; nothing else may pass `-allowProvisioningUpdates`, with one exception: the CI release pipeline (`.github/workflows/release.yml`), whose signing jobs authenticate with the App Store Connect API key from the approval-gated `release` environment so Xcode can create each runner's development certificate and profiles. `build-app.sh` and `build-ios.sh` refuse the key anywhere else. Agents and local scripts still never pass the flag, set the key, or call App Store Connect (`scripts/asc-certificates.sh` is the owner's).
- `open dist/Daybook.app`: launch the packaged app.
- `swift run Daybook --smoke-test --download-models --output /tmp/daybook-smoke.json`: download weights and exercise real inference with synthetic speech.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Name files after their primary type or feature. Keep UI state on `@MainActor`; move expensive audio, inference, and file operations off the main actor. Preserve pinned dependency versions and the package's Swift 5 language mode. Match surrounding formatting; avoid unrelated reformatting.

## Testing Guidelines

Use XCTest classes named `FeatureTests` and descriptive `testBehavior...` methods. Use temporary libraries and synthetic audio; ordinary tests must not download models or record surroundings. Add regression coverage for meaningful persistence, sync, timing, and inference changes. No numeric coverage threshold is configured. Document hardware-dependent checks and limitations in `docs/validation.md`.

## Commit & Pull Request Guidelines

History currently has one imperative commit: `Build Daybook local-first macOS meeting workspace`. Use similarly concise, action-oriented subjects. PRs should explain the problem, resulting behavior, validation, and remaining limitations; link relevant issues and include screenshots for UI changes.

## Privacy & Configuration

Keep inference local. Never commit recordings, transcripts, model weights, or credentials. Store notarization credentials in Keychain; configure signing through `DAYBOOK_TEAM_ID` (or the ignored `Apps/*/Config/Signing.local.xcconfig`) and `DAYBOOK_NOTARY_PROFILE`. Preserve originals, provenance, corrections, and sync recovery history when changing processing or storage.
