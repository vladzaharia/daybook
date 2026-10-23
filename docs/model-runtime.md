# Embedded local models

Daybook's `LocalIntelligenceRuntime` runs speech recognition, speaker diarization, and summarization inside the Mac application process. There is no model server, subprocess inference bridge, cloud transcription request, or API key. Model downloads are the only intentional networking in this subsystem.

## Dependencies and models

The implementation is built against inspected source APIs at these exact versions:

| Component | Package version | Runtime |
| --- | --- | --- |
| Speech recognition | [WhisperKit 0.18.0](https://github.com/argmaxinc/WhisperKit/tree/v0.18.0) | Core ML |
| Speaker detection | [FluidAudio 0.17.7](https://github.com/FluidInference/FluidAudio/tree/v0.17.7) | Core ML Community-1 / WeSpeaker / VBx, or Sortformer v2.1 |
| Summaries | [mlx-swift-lm 2.29.3](https://github.com/ml-explore/mlx-swift-lm/tree/2.29.3) | MLX on Apple Silicon |
| Local tokenizers and model downloads | [swift-transformers 1.1.6](https://github.com/huggingface/swift-transformers/tree/1.1.6) | Swift |

MLX LM 2.29.3 and WhisperKit 0.18.0 share a compatible swift-transformers dependency. FluidAudio's optional NeMo text normalization binary is disabled with package `traits: []`; diarization is included in this release without a trait. Xcode requires the Metal compiler component to compile MLX: `xcodebuild -downloadComponent MetalToolchain` installs it if absent. If `xcrun metal --version` still reports it missing after installation, refresh the lookup cache with `xcrun --kill-cache`.

Available downloads are Whisper Base, Small, and compressed Large v3 Turbo; Qwen 2.5 Instruct at 1.5B, 3B, and 7B parameters in 4-bit MLX form; Community-1 speaker models; and full-precision or compact Sortformer v2.1. See [the catalog](../Sources/Daybook/Intelligence/ModelCatalog.swift) for immutable Hugging Face revisions, size estimates, and suggested memory. Download sizes and resident memory are different. Model license terms are published in their upstream repositories: [Qwen 3B uses Qwen Research](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct), while [1.5B](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit) and [7B](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct) use Apache 2.0. The catalog calls out the 3B license so users can choose appropriately.

The recommended summary default is 7B on Macs with at least 16 GiB of physical memory and 1.5B on smaller machines. The 1.5B option is useful for speed and a compact download, but the larger model is preferable for nuanced conversations. These are configurable defaults, not automatic downloads.

### Speaker quality choices

| Download | Approximate size | Intended use and limitations |
| --- | --- | --- |
| Community-1 | 25 MB | Recommended for complete recordings, editable reusable voice profiles, and an optional expected speaker count. Uses whole-file segmentation, embedding extraction, and VBx clustering. |
| Sortformer 2.1 Compact | 92 MB | Real 6-bit palettized weights. Smaller download and memory footprint; can lose detail compared with FP16. Maximum four speaker slots; no reusable voice profiles. |
| Sortformer 2.1 Full Precision | 242 MB | Real FP16 weights. An alternative for noisy small-group conversations. Maximum four speaker slots; no reusable voice profiles. Can miss quiet or distant speech. |

The Sortformer conversions are pinned at `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`, specifically the `v3` fixed model exports. The [conversion model card](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/blob/ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1/README.md) declares CC-BY-4.0; the [underlying NVIDIA model](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1) uses the NVIDIA Open Model License. The Community-1 [artifact provenance and scoped license](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/NOTICE.md) apply to its supported files. Legacy `wespeaker_v2` downloads were deliberately excluded because that provenance/license scope does not cover them.

Fast, Balanced, and Detailed are **processing presets using the selected weights**, not extra model downloads. Community-1 Fast reuses embeddings for masks with at least 0.95 cosine similarity; Balanced uses upstream defaults; Detailed doubles segmentation overlap (step ratio 0.1 instead of 0.2), lowers the minimum embedded speech span to 0.5 seconds, permits 40 VBx iterations, and re-embeds zero-vote spans. Sortformer uses 4, 8, or 16 seconds of window overlap. More analysis is a compute tradeoff, not a guarantee of improved accuracy. An expected speaker count is a Community-1 clustering target, not a guarantee or a supported Sortformer control. These behaviors use the [pinned FluidAudio configuration API](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift).

Community-1 returns the stable embedding identity `fluid-community1-embedding-df2625ac79a7ac6b` for all presets. Profiles from unknown or incompatible embedding spaces must never be compared automatically. Sortformer returns an empty embedding dictionary and a nil identity, and reports its limits in warnings. Within-recording clustering and cross-recording matching are separate operations: the app's matching threshold controls whether a compatible voice profile is sufficiently similar to propose an existing identity.

## Download and offline boundary

Downloads are explicit `download(modelID:progress:)` calls. An installation marker is written atomically only after all weights and tokenizer files have arrived. The marker records the catalog revision and each installed file's byte length. Incomplete or modified-length installations are rejected before model loading. Deleting a model releases references and removes only that model's dedicated directory; partial downloads can also be removed.

Inference checks that marker and then uses local directory URLs. `OfflineWhisperKit` replaces the upstream tokenizer loader because WhisperKit's normal `download: false` flag does not prevent its tokenizer fallback from contacting Hugging Face. The replacement reads local tokenizer JSON directly and fails on missing tokens. MLX is loaded from a `ModelConfiguration(directory:)` with `HubApi(useOfflineMode: true)`. Speaker models are loaded directly through `MLModel(contentsOf:)`, bypassing FluidAudio's automatic cache-repair/download path.

The inventory detects incomplete downloads and accidental file length changes, not malicious same-length modifications. Distribution hardening should add model-file cryptographic digests and signed catalog metadata. Model registry locations are fixed in source; recording contents are never used in URLs. Network blocking at the process or OS level remains a useful independent verification of offline behavior.

## Processing

One application-owned runtime actor serializes expensive operations and prevents deletion during active work. It releases speech and speaker models before loading the language model, and releases the language model before speech processing. MLX's retained allocation cache is capped at 256 MB and cleared when the language model is released. `unload()` releases all retained model references. A cancelled task is checked between downloads, speech slabs, synthesis passes, and output tokens. Native Core ML prediction and clustering may finish their current operation before cancellation returns.

Speech recognition uses word timestamps and five-minute PCM slabs with one second of context at each edge. Small streaming conversion buffers and 64-bit source frame positions avoid loading the original file into memory or overflowing a 32-bit frame count on very long recordings. Midpoint ownership assigns overlap words to one slab, bounding decoded-audio memory and reducing boundary loss. The approved glossary conditions Whisper's decoder prompt. Whisper's built-in VAD chunking runs within each slab. Word probabilities are model estimates, not calibrated certainty. Speaker detection uses FluidAudio's disk-backed file API and returns anonymous speaker turns plus embeddings. It does not claim that a cluster is a named person or automatically merge identities across unrelated recordings.

Sortformer reads 30.72-second windows with surrounding STFT context and aligns its four output columns using overlapping activity. Decoded PCM and mel features stay bounded; the four final probability tracks use approximately 0.72 MB per hour. A silent overlap cannot prove identity continuity and can cause a speaker swap. This mode exposes that limitation and does not fabricate reusable voice embeddings. Both speaker pipelines create fresh per-run processing state so changing presets cannot reuse a previous run's clustering settings.

Summarization uses the selected local Qwen model and a fresh chat session for each pass. It counts model tokens, extracts evidence from long transcript and note chunks, and recursively compresses evidence until the final prompt fits a conservative context budget. This processes the entire input instead of truncating the end. Multi-pass summaries carry an explicit detail-loss warning. Transcript text, notes, and glossary are serialized as source data, and system instructions reject commands embedded inside them. This reduces prompt injection risk but is not a formal guarantee against model error.

The model selects the meeting kind when the user chose Automatic, then emits a title, overview, sections, explicit actions, and proposed glossary terms. A focused second generation pass extracts assignments with supporting source quotes; quotes are matched against the original conversation with whitespace, case, and timestamp formatting normalized. Ungrounded quotes are rejected, and names absent from the supporting quote are not assigned as owners. This does not prove that a model's interpretation is correct, and users should review their actions. A user-selected kind is preserved. Terms absent from the transcript or notes are filtered out. Model output is never executable. Therapy guidance is limited to reporting the conversation: no invented diagnoses, advice, or commitments. Structured parsing failures preserve the real model response with a warning, allowing the user to review it or retry with a larger model.

Custom template instructions affect focus and section structure while preserving the output schema and faithful-source rules. Their first 700 model tokens are used, with a warning if truncated. Highlight evidence is carried as separately labeled source data through long-recording extraction, compression, and final generation, with instructions to preserve extra supported detail. Written notes, even timestamped notes, remain user context rather than spoken quotations. The final action verification pass accepts source quotes only from the recorded transcript.

## API

```swift
let runtime = LocalIntelligenceRuntime(modelsDirectory: modelsURL)
let installed = await runtime.installedModels()
try await runtime.download(modelID: "whisper-base") { update in
    // update.fraction and update.message; hop to MainActor for UI changes.
}
let speech = try await runtime.transcribe(url: audioURL, modelID: "whisper-base", glossary: ["Daybook"])
let speakers = try await runtime.diarize(url: audioURL, modelID: "speaker-community-1",
    options: .init(quality: .accurate, expectedSpeakerCount: 2))
let notes = try await runtime.summarize(
    transcript: timestampedTranscript,
    notes: handwrittenNotes,
    template: .auto,
    glossary: approvedTerms,
    modelID: "qwen-1.5b",
    templateInstructions: "Use a Reflections section when supported.",
    highlightEvidence: highlightedTranscriptExcerpts
)
try await runtime.remove(modelID: "whisper-base")
```

`RecognitionResult` retains timed segments, words, confidence estimates, language, and duration. `SpeakerAnalysis` contains turns, embeddings, their optional model-space identity, and warnings. `GeneratedMeetingNotes` contains the `MeetingSummary`, proposed terms, raw response, and warnings. The application layer owns persistence, corrected transcript history, cross-recording fusion, speaker names, and approval of learned terms. The runtime does not modify model weights or silently learn from sensitive conversations.

## Verification

Normal unit tests must not download model weights. Test missing/corrupt installation rejection and structured-output parsing without inference. A separately invoked smoke test should explicitly download the smallest models, transcribe a known local fixture, run speaker detection, and generate a summary through these same APIs. Repeat that smoke test with network access denied after installation to verify offline loading. Accuracy, overlapping speech, diarization error, very long sessions, multilingual audio, and machine sleep require representative recordings beyond a basic smoke test.

The implemented diagnostic runs without creating a meeting in the library:

```sh
swift test --filter IntelligenceTests
swift run Daybook --smoke-test --summary-model qwen-1.5b --download-models --output /tmp/daybook-smoke.json
swift run Daybook --smoke-test --summary-model qwen-1.5b --output /tmp/daybook-offline-smoke.json
```

`--download-models` explicitly installs the default Whisper, selected Qwen, and speaker models in the application's normal Models folder. Omit it to require an existing installation. `--summary-model qwen-7b` tests the stronger model; without that flag, the machine's recommended default is used. `--models /path/to/models` overrides that folder; `--audio /path/to/meeting.wav` replaces the synthetic fixture. Without `--audio`, the diagnostic uses macOS `say` to generate an audio file in a temporary directory, then runs the actual embedded inference pipeline. Exit code 0 requires recognizable fixture words, detected speech turns, and a structured summary with the core milestone and correctly assigned checklist task. This system speech subprocess exists only in diagnostics; it does not perform app transcription, diarization, or summarization.

`--speaker-model speaker-sortformer-v2.1` or `--speaker-model speaker-sortformer-v2.1-compact` selects a different speaker download. `--speaker-quality fast|balanced|accurate` exercises the processing presets and `--expected-speakers 2` requests a Community-1 clustering target. The report records speaker model, quality, and embedding identity/count. Community-1 diagnostics additionally require finite 256-dimensional voice embeddings.

`--notes-highlights` adds the actual built-in Planning template, a timestamped private note, and highlighted recorded evidence to the generated fixture. It requires the speaker-detection blocker as well as the milestone and Alex's assignment in the model output, and rejects repeating the private note instruction as conversation content. The flag is ignored for external `--audio` fixtures.

### Verified on October 23, 2026

Ten model-free intelligence tests passed, covering missing/corrupt installation rejection for every speaker pipeline, summary schema fallback, forced-template preservation, unobserved-term filtering, source evidence and owner verification, actual quality configuration changes, speaker-column permutation recovery, template/highlight source separation, and stereo-to-mono resampling. A 40-second generated audio fixture also verifies bounded Sortformer mel features against whole-recording preprocessing at an interior window.

The application executable successfully transcribed a 19.75-second synthetic meeting, detected one speaker, and generated structured notes with Alex assigned the onboarding checklist using both Qwen 1.5B and 7B in the initial pipeline. The initial strict 1.5B run completed in 12.56 seconds with all process networking denied by `sandbox-exec`, including local model and tokenizer loading. The 7B run also passed; its 430.96-second elapsed time includes the initial 4.3 GB model download and is not an inference benchmark.

After adding custom-template and highlight instructions, Sortformer Compact plus Qwen 7B passed the full diagnostic with networking denied in 12.30 seconds (`/tmp/daybook-sortformer-compact-offline.json`). Sortformer FP16 in Detailed mode plus 7B also passed (39.80 seconds including the first model download; `/tmp/daybook-sortformer-full-smoke.json`). Both detected one speaker and correctly returned no voice profiles. The expanded prompt caused 1.5B to omit the milestone from its summary prose in one strict smoke test, even though its title and Alex's assignment were correct. That test remains recorded as a failure; the larger recommended model is materially more reliable on this fixture.

Community-1 Detailed with an expected speaker count of one and Qwen 7B passed with networking denied in 18.18 seconds (`/tmp/daybook-community-detailed-offline.json`), returning one finite 256-dimensional embedding in the declared compatible space.

The final built-in Planning template plus timed private notes and highlighted blocker fixture passed with Qwen 7B and all networking denied in 20.70 seconds (`/tmp/daybook-notes-highlights-offline.json`). It retained the prototype milestone, Alex's assignment, and speaker-detection blocker and used the requested planning section names. The model still included an unhelpful section stating that other options were not discussed and inferred a deadline risk from the blocker; this remains a reason to review generated notes rather than treating template compliance as proof of factual accuracy.

These checks establish a working embedded pipeline, not accuracy on real conversations. Multi-speaker accuracy, overlapping speech, real therapy recordings, and end-to-end multi-hour capture still require representative user-authorized fixtures. The smallest model omitted assignments in an initial combined summary pass, which led to the separate, source-grounded action pass and stronger diagnostic assertions now in the implementation.
