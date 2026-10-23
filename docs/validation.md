# Validation record

Run on 2026-10-23 on Apple silicon, macOS 27.0, Xcode 27.1 / Swift 6.4, 64 GB memory. The deployment target is macOS 15; earlier supported OS releases have not been exercised on separate hardware.

## Automated tests

`swift test` passed 157 XCTest cases: 86 core and 71 application tests. Swift Testing reports zero tests separately because these suites use XCTest; that does not replace the XCTest results.

Coverage includes:

- Durable metadata round trips, atomic recovery copies, corrupt and newer-schema handling, digest deduplication, altered/missing original recovery, path and symlink rejection, highlight schema, trash and stale-save rejection.
- Offset and clock-drift estimation, stable timeline origin, explicit/negative offsets, insufficient/repeated anchors, short replies, contradictory variants, retained provenance, and user corrections after source preference changes.
- Two independent app libraries exchanging byte-identical recordings, folder/tag/template/vocabulary data, concurrent offline edits, paired transcript/alignment and note/timestamp conflicts, deletion tombstones, interrupted apply/acknowledgment, account-change invalidation, idle-loop prevention, and damaged sync objects.
- Note paragraph anchors, exact timeline-to-source seeking, model/configuration snapshots, speaker embedding compatibility, and conservative correction transfer.
- Original Bluetooth packet/checksum fixtures, P-256/HKDF/AES-CTR vectors, and native Opus encode/decode with generated audio.
- Actual synthetic PCM writing, gap padding, clock discontinuity handling, interrupted capture recovery, start/end debounce, manual-stop suppression, and conservative browser starts.
- Speaker-turn to word assignment, whitespace preservation, unknown speakers, source-scoped identities, audio resampling, incomplete model installation, structured output and grounded action parsing.
- Concurrent source imports with note/highlight edits, duplicate imports under different names, restart persistence, preventing trash during recording startup, and preventing recovery from resurrecting a trashed conversation.

## Real local inference

The diagnostic generates a 19.75-second spoken planning meeting using macOS speech synthesis, then calls the same embedded runtime APIs as the application. It checks recognized fixture words, nonempty speaker turns, structured notes, the Friday milestone, and the explicitly assigned Alex/onboarding-checklist action.

Whisper Base, Community-1, and Qwen 1.5B completed this stronger diagnostic successfully with network access denied by `sandbox-exec`. One measured debug run completed in 12.56 seconds. This validates offline model and tokenizer loading, not general transcription or diarization accuracy. The synthetic fixture contains a single voice, so it does not validate multi-speaker separation quality.

Qwen 7B also passed. The installed Developer ID signed app completed the full pipeline with network access denied in 30.78 seconds, using the default 7B model and preserving Alex's assigned checklist action. Two summary models, Whisper Base, Community-1, and both Sortformer variants are installed locally (about 5.3 GB total). These single-fixture timings are observations, not a comparative benchmark.

With the expanded template/highlight instructions, Qwen 1.5B failed the strict milestone-prose check despite producing an appropriate title and assigned action. Qwen 7B passed the richer test with networking denied, using the actual Planning template, timed-note context, and highlighted speaker-detection blocker. The last debug run took 20.70 seconds and used the requested planning section names. It also emitted a low-value section saying no alternatives were discussed; template compliance and factual usefulness still need review.

Both Sortformer variants completed real local inference. The compact variant plus 7B passed offline in 12.30 seconds on the single-speaker fixture. Community-1 with detailed settings produced finite 256-dimensional voice embeddings; Sortformer correctly returns no reusable voice profiles. These checks do not establish comparative multi-speaker accuracy.

Initial testing found that the compact model omitted an explicit assignment. The summary pipeline now separately extracts commitments and checks supporting quotes against source text before accepting the action list. Timestamp normalization is tested without relaxing the requirement for matching spoken words. This improves the tested behavior but does not guarantee semantic accuracy on arbitrary conversations.

## Release packaging

`scripts/build-app.sh` builds a native arm64 release executable, includes the required SwiftPM resource bundles and Metal library, embeds the Swift compatibility dylib needed for older target systems, creates an icon and license notices, signs the app, verifies its signature, and creates a ZIP. Compiler installation paths are removed from the executable's runtime search paths. The delivered preview uses the existing Developer ID Application identity with hardened runtime and a timestamp. No new signing account or certificate was created.

Notarization has not been performed: a configured `notarytool` credential profile was not supplied. The build script supports `DAYBOOK_NOTARY_PROFILE` and will submit, staple, and regenerate the archive when that profile and a Developer ID identity are supplied.

The standalone signed release passed the expanded notes/highlights diagnostic in 12.57 seconds with both networking and access to the repository's build products, Xcode, and developer toolchain directories denied. This checks that the packaged Metal resources and Swift compatibility library work without a developer installation. The [diagnostic report](validation/standalone-offline.json) contains only synthetic fixture data.

The installed app launched and remained running. Visual review covered the empty library, new-conversation detail, model selection, recording/import settings, sync settings, and the floating notes panel. The panel appeared at the right edge at 370 × 660 points. Review found and corrected an oversized processing-menu control. Bluetooth Scan reached “Waiting for Bluetooth”; a physical Soundcore connection was not established. Full-screen call behavior and actual note entry during capture remain live-use checks.

## Acceptance checks still requiring live use

- Grant microphone and Screen & System Audio Recording permissions, then verify both voices in a real Zoom/Meet/Teams call, including headphones and muted microphones.
- Check automatic starts/ends, browser tab ambiguity, localized window titles, unsupported applications, and manual-stop suppression.
- Exercise full-screen calls with the notes panel, multi-monitor arrangements, device switching, sleep/wake, permission revocation, and long sessions.
- Export actual Soundcore MP3s and any available highlight metadata; verify import, playback, timing, and overlapping computer/wearable recordings. The experimental direct BLE path must be verified for the device’s firmware, encrypted transfers, controls, battery, and live reception. Double-tap marker extraction is not implemented.
- Evaluate recognition and speaker error rates on representative multi-speaker and multilingual recordings; review template choices and summaries for nuanced personal/therapy conversations.
- Connect the same iCloud Drive folder on two physical Macs; exercise eviction, quota/full disk, offline edits, account changes, large audio, and simultaneous initial setup. Tests use shared local filesystem transport, not Apple’s remote service.
- Confirm Gatekeeper behavior after notarization on a separate Mac before broad distribution.

No real meetings, therapy sessions, or ambient microphone recordings were collected during automated testing. Diagnostic reports contain only generated fixture text. Normal tests use temporary libraries and do not install weights.
