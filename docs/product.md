# Daybook product and delivery plan

Daybook is a personal macOS library for conversations. It records computer and microphone audio, imports wearable recordings, and processes those files on the Mac. The intended experience is one place for work meetings, therapy, and everyday conversations, with editable notes and durable source audio.

Current delivery: a runnable Developer ID signed preview, installed locally, with real offline inference verified and automated integration tests passing. The remaining release gates are live-call/device acceptance, visual interface inspection after the Mac is unlocked, and Apple notarization. See [validation](validation.md) for the exact evidence and limits.

## Design commitments

- Native SwiftUI interface, Apple silicon, macOS 15 or newer.
- No Daybook account, inference service, or telemetry. Model weights download on request. Optional iCloud Drive sync uses the user’s Apple Account and stores the library remotely while all inference remains local.
- Raw audio and per-source transcripts remain available after unification. Uncertain alignment must be visible rather than silently presented as fact.
- Notes entered during a conversation influence the summary. Edits and summary revisions preserve earlier output.
- Meeting type controls the summary template. Therapy summaries reflect the conversation without adding diagnoses, treatment advice, or invented conclusions.
- Learning means persistent corrections and an approved vocabulary. It does not silently train a model or move personal details from one meeting into another.
- Recording has an always-visible indicator and stop control. Automatic recording is an explicit preference; detection requires evidence of a call rather than merely a running application.

## Delivery slices

1. Durable local library: import audio, notes, transcript edits, speaker labels, summaries, glossary, and export.
2. In-process inference: model downloads, Whisper transcription, Core ML speaker diarization, MLX summarization, long-input processing, and offline reuse.
3. Capture: separate microphone and system tracks, automatic start/end detection, right-side notes panel, and crash recovery.
4. Multi-source synthesis: attach wearable audio to an existing meeting, align repeated speech, deduplicate agreed spans, preserve provenance and unmatched source transcripts.
5. Organization and sync: folders, tags, twelve editable templates, immutable iCloud Drive journal, source blobs, causal conflict merging, deletion tombstones, and local recovery.
6. Quality and direct hardware: independently selectable models, configurable speaker effort and matching, explicit reprocessing modes, and direct Soundcore Work over Bluetooth through a hardware-agnostic device layer (direct, files, and account methods per device).
7. Release validation: build and test on Apple silicon; package a runnable app; exercise inference with generated speech; document hardware and permission checks requiring live recordings.

## Follow-on work requiring evidence or external access

- Direct Soundcore synchronization: Bluetooth is the recommended connection, with files as the fallback ([devices.md](devices.md)). It is verified against a simulated recorder and protocol fixtures; physical-firmware validation, complete marker extraction, Wi-Fi, and MFi acceptance are still pending.
- Longitudinal speaker identity: a user-controlled voice enrollment flow and evaluation set before making persistent identity claims.
- Distribution: a Developer ID and notarization credentials are needed for a broadly distributed trusted release. An ad-hoc signed local app can be built without those credentials.
- Real-call acceptance: Zoom, Meet, Teams, muted microphones, headphones, device changes, sleep/wake, long sessions, overlapping voices, and partial recordings need recordings on actual devices.

## Acceptance criteria

Imported audio never leaves the machine for inference. Restarting preserves notes, sources, transcripts, and prior summaries. A recording produces separate tracks with a common time base. Model errors leave sources intact and allow retry. Manual and automatic captures both have a stop control. Unification retains provenance and exposes unresolved alignment. Summaries use the selected template and the user's notes. Model download and live hardware validation are reported separately from unit test success.
