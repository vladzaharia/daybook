# Models

Daybook's model system is modular. **Engines** are code that knows how to verify, load, and run one kind of model. **Models** are data, described in manifests and run by an engine. Updating a model never means editing the pipeline. A new quantization or revision of an existing model is a manifest change. A completely new model is a manifest entry, plus a new engine only when no existing engine can run it.

This page is the architecture as built. Where it differs from the plan agreed earlier, the difference and the reason are marked **Deviation**. [Embedded local models](model-runtime.md) covers what each engine does at run time, offline loading, and validation.

## Vocabulary

| Term | Meaning | Example |
| --- | --- | --- |
| **Role** | What the pipeline needs done | `transcription`, `diarization`, `speakerEmbedding`, `summarization`, `smallTasks`; for live captions, `liveTranscription` and `liveDiarization` |
| **Engine** | Code that runs models for one or more roles | `whisperKit`, `parakeet`, `community1`, `nemotronDiarizer`, `nemotronStreaming`, `sortformer`, `mlxLanguage`, `appleFoundationModels`; next: `mlxAudio` |
| **Family** | One model as people know it | `whisper` "Whisper", `gemma-4` "Gemma 4", `qwen2.5` "Qwen 2.5" |
| **Variant** | A distinct build people choose between: size, quantization, or format | `whisper/large-v3-turbo`, `gemma-4/12b-4bit` |
| **Revision** | One exact, immutable set of files for a variant | `mlx-community/Qwen2.5-7B-Instruct-4bit` at `c26a38f…`, with a digest per file |

- **An update to an existing model** (re-quantized weights, a fixed conversion) is a **new revision** of the same variant, or a **new variant** of the same family when people should be able to choose between the old and new builds.
- **A completely new model** is a **new family**. If an existing engine can run it (another MLX language model, another WhisperKit build), it's only data. Otherwise it also needs a new engine: one new type plus one registration line.

A variant is named everywhere by its **key**, `family/variant`. Selections, queued jobs, and new results store keys. Roles and engine IDs are open sets of strings (`ModelRole`, `ModelEngineID`), not enums, so a manifest that names a role or engine this build doesn't know still reads; the entry shows "Needs a newer Daybook".

## Where the code lives

| Target | Holds |
| --- | --- |
| `DaybookCore` | `ModelProvenance`, stored with results in `ProcessingSettings.model`; the evaluation harness's scoring (`Evaluation/`: WER, CER, cpWER, DER/JER, word-timing error) |
| `DaybookKit` (Mac and iPhone) | The manifest format (`ModelManifest`, `ModelManifestReader`), the built-in `Resources/ModelCatalog` folder, the merged `ModelCatalog` and `CatalogModel`, availability, `ModelSelections`, `ModelRecommendations` (presets, device tiers), `PhoneProcessingModels` and `PhoneTier` (the iPhone's processing models), `ModelRouting` (with speaker routing), `TranscriptionRouting` and `LanguageCheck` (language routing), `ModelAcknowledgements`, and the shared vocabulary (`ModelRole`, `ModelEngineID`, `ModelEngineDescriptor`, `ModelReference`, `ModelVersion`) |
| `DaybookModelStore` (Mac and iPhone) | `ModelStore` and legacy migration, `ModelInstallation` and receipts, `ModelFileDigest`, `ModelArtifactFetcher`, `HubSnapshotFetcher` (the Mac's downloads), and `BackgroundModelFetcher` (the iPhone's, in background sessions): downloads, verification, installs. Split out of DaybookIntelligence so the iPhone can download its live models without the Mac's engines; DaybookIntelligence re-exports it |
| `DaybookLive` (Mac and iPhone) | Live captions from local models ("Live models", below): the live engines' descriptors and install checks (`LiveEngines`), `LiveModelHost`, the captioners, `LiveLoadPolicy`, and `WeSpeakerEmbedder`, the voice-profile recipe the Mac's final pipeline shares. FluidAudio only: no MLX, no WhisperKit |
| `DaybookIntelligence` (Mac and iPhone) | The `ModelEngine` protocol, role protocols, `ModelEngineRegistry`, the engines, `TranscriptionRouter`, `MeetingSynthesis` and `SmallTasks`, `ModelHubClient`, `ModelUpdateChecker`, model addition, `LocalSummarizer`, and `LocalIntelligenceRuntime`, which coordinates them. On the iPhone without WhisperKit and MLXVLM (Package.swift): no Whisper, and no photo captions from Gemma |

The iPhone links all of these: DaybookKit names the model behind any result (Conversation Info) and lists acknowledgements, DaybookLive and DaybookModelStore download and run live captions' models, and DaybookIntelligence processes its own recordings ("iPhone processing", below).

Cloud models (Anthropic's and OpenAI's, for summaries only, with the person's own key) aren't manifest models: their catalog, keys, discovery, and requests are in `DaybookKit/Cloud`, and the summarizer is DaybookIntelligence's `CloudSummarizer` ("Cloud models", below; [cloud](cloud.md)).

## Engines

Every engine conforms to `ModelEngine`:

- **Identity:** a `ModelEngineDescriptor` with a stable ID, a name, an integer `version`, the runtime package underneath (`"argmax-oss-swift 1.1.1"`), the roles it serves, its platforms, its **residency**, and, for an engine that depends on the system, why it can't run here right now (`unavailableReason`, shown as the model's availability label).
- **Installs:** `validate(_:)` is a cheap check before every load (the Core ML bundles and tokenizer are there); `verifyNewInstallation(_:)` is the deeper check once, before a fresh download or migration counts (WhisperKit's tokenizer parses).
- **Adding models:** `proposeAddition(_:repository:)` turns a Hugging Face repository listing into artifacts and capabilities, or says why it can't run it.
- **Lifecycle:** `load(_:role:progress:)` returns a `LoadedModel` that conforms to the role's protocol: `Transcribing`, `Diarizing`, `EmbeddingVoices`, `Summarizing`, or `PerformingSmallTasks`. `Transcribing` also takes a language hint (`transcribe(url:glossary:language:progress:)`); its default ignores it, so only transcribers that can use one implement it (Parakeet and WhisperKit do). `unload()` releases what outlives the object. Cancellation is the task's, checked between slabs, windows, passes, and tokens as before.

**Capabilities** are declared per variant in the manifest (`ModelCapabilities`), never hard-coded: word timestamps and confidences, languages, vocabulary prompting, maximum speakers, voice embeddings (with the embedding space's identity), an expected speaker count, context length, structured output, streaming, memory, and real-time factor. The pipeline asks for a role and reads capabilities. It never compares model IDs: `modelID == diarization` became `capabilities.voiceEmbeddings != nil` (`ModelRouting.supportsVoiceMatching`).

**Residency** keeps today's memory behaviour as a rule instead of special cases: the runtime keeps at most one loaded model per role; an `exclusive` engine (MLX) releases every other model when it loads, and loading any other model releases it. A `system` engine (Apple Foundation Models) runs in the operating system, outside Daybook's memory: using it releases nothing and nothing releases it, so a summary-only queue keeps its language model loaded around the small-tasks step.

Engines register in `ModelEngineRegistry.standard`. Adding an engine means one type, one line there, and its tests.

| Engine | Version | Roles | Runtime | Residency | Notes |
| --- | --- | --- | --- | --- | --- |
| `whisperKit` | 2 | transcription | argmax-oss-swift 1.1.1 | shared | Artifacts `model` (the WhisperKit folder) and `tokenizer`; offline tokenizer loading through argmax's vendored tokenizer code; takes a language hint, and detects the language without one (WhisperKit itself would prefill English) |
| `parakeet` | 1 | transcription | FluidAudio 0.17.7 | shared | Parakeet TDT v3 family (`engineOptions.version`: `ultra`, `redux`, `v3`, `phonon2`); one `model` artifact with the four Core ML bundles and the vocabulary; loaded with `AsrModels.loadLocal`, never FluidAudio's downloader; takes a language hint |
| `community1` | 1 | diarization, speakerEmbedding | FluidAudio 0.17.7 | shared | Returns voice embeddings in the space its variant declares; as `EmbeddingVoices`, embeds another diarizer's turns in that same space |
| `nemotronDiarizer` | 1 | diarization, liveDiarization | FluidAudio 0.17.7 | shared | Nemotron 3 Diarization (`engineOptions.preset`: `offline`, or a split W8A8 build such as `c128-split-w8a8`); eight speakers, no embeddings. Its streaming preset `fast32-split-w8a8` serves live speakers, loaded by DaybookLive |
| `nemotronStreaming` | 1 | liveTranscription | FluidAudio 0.17.7 | shared | Nemotron 3.5 ASR Streaming bundles (`StreamingNemotronMultilingualAsrManager`): encoder, fused decoder and joint, `metadata.json`, `tokenizer.json`. Registered on the Mac so the manager downloads and checks it; loaded only by DaybookLive (`LiveEngines.streamingTranscription` on the iPhone) |
| `sortformer` | 1 | diarization | FluidAudio 0.17.7 | shared | `engineOptions.precision` (`palettized` or `fp16`); four speakers, no embeddings |
| `mlxLanguage` | 2 | summarization | mlx-swift-lm 3.32.3 (mlx-swift 0.32.3) | exclusive | Any `model_type` the pinned mlx-swift-lm registers (`LLMTypeRegistry`); `engineOptions.thinking`; constrained JSON when the variant declares `structuredOutput` |
| `appleFoundationModels` | 1 | smallTasks | Foundation Models (the OS version) | system | `systemProvided` variants; available on macOS 26 / iOS 26 and later with Apple Intelligence on |

Version 1 of `whisperKit` was WhisperKit 0.18.0 and version 1 of `mlxLanguage` was mlx-swift-lm 2.29.3. Results keep the engine version they recorded (`"1 (WhisperKit 0.18.0)"`) and still resolve to their variant, which is matched by family and variant, never by engine version.

**Deviation:** `appleFoundationModels` serves `smallTasks` only, not `summarization` as the plan suggested: its context is 8,192 tokens on macOS 27 (4,096 on 26), and in the October research it invented and misattributed an action item on a 6K-token meeting. It runs before the summary, from a bounded excerpt (below). **Deviation:** because Apple Intelligence can be turned on or off while Daybook runs, the AFM engine's descriptor is computed each time it's read, and `LocalIntelligenceRuntime.engines` reads the registry afresh rather than once at launch.

**Deviation:** the plan named one `fluidDiarization` engine. Community-1, Sortformer, and Nemotron load different artifacts, take different options, and have different capabilities, so they are three engines. **Deviation:** Community-1's voice embeddings come out of diarization, so it declares the `diarization` role and the `voiceEmbeddings` capability; it also serves `speakerEmbedding` (`EmbeddingVoices`) for diarizers without embeddings (Nemotron), see "Routing".

## Manifests

- **Built-in catalog:** `Sources/DaybookKit/Resources/ModelCatalog/`, a package resource of DaybookKit, shipped with each release. `Catalog.json` holds the presets, the recommended preset per tier, the initial selection (with the iPhone's processing models under `platforms` and `platformTiers`, "iOS"), and the live roles' defaults per platform and tier (`liveSelection`). `Families/<family>.json` holds one family each, as a complete manifest. Adding a model family is adding a file. Each file declares its own `minimumReaderVersion`, so a family that needs a newer reader is skipped with a warning while the rest load. Families load in file-name order; the interface sorts as it needs (acknowledgements are alphabetical).
- **The person's manifest:** `Models/UserModels.json`, beside the store, in the same format. It holds models added from Hugging Face ("Added by you") and revisions installed through update checks. `ModelCatalog` merges it into the built-in catalog: a family or variant with a built-in ID only gains variants or revisions; built-in metadata is never overridden. Presets come from the built-in manifest only.
- **Revision checks (opt-in):** `LocalIntelligenceRuntime.checkForUpdates(client:)` asks Hugging Face, through an injectable `ModelHubClient`, whether each installed variant's tracked branch (`artifact.track`, default `main`) moved, and whether the files its `include` patterns select actually changed. It returns `ModelUpdate`s with the changed files, the size, and the publication date. Daybook never installs one by itself; `installUpdate(_:)` records the revision in the person's manifest and downloads it.

### Format (schema 1)

```text
ModelManifest       schemaVersion, minimumReaderVersion, catalogVersion,
                    families[], presets[], recommendedPreset, initialSelection, liveSelection
ModelChoiceTable    roles{role: keys[]}, tiers{tier: {role: keys[]}}, platforms{"macOS"|"iOS": {role: keys[]}},
                    platformTiers{"iOS": {phone tier: {role: keys[]}}}
ModelFamilyEntry    id, name, maker, engine, roles[], summary, homepage, license, variants[]
ModelVariantEntry   id, name, detail, engine?, roles?, license?, homepage, releaseDate,
                    recommendedMemoryGB, quality{role: 0–100}, capabilities, engineOptions{},
                    minimumAppVersion, minimumEngineVersion, supersedes[], supersededBy,
                    systemProvided, revisions[]
ModelRevisionEntry  id, releaseDate, summary, artifacts[], legacy{ids[], artifactPaths{}}
ModelArtifact       name ("model", "tokenizer"), repository, revision (commit), include[],
                    root, track, files[]
ModelFile           path, size, sha256 (LFS files) | gitOID (small files)
ModelLicense        id, name, url, allowsCommercialUse, attribution
```

Every entry carries its license, release dates (the variant's upstream publication; each revision's commit date), `supersedes`/`supersededBy`, and the minimum app and engine versions. An entry the running app can't run reads "Needs a newer Daybook" (`ModelAvailability`) and is never offered: `minimumAppVersion` compares with the app's marketing version, and `minimumEngineVersion` with the registered engine's `version`. A development build (no bundle version) satisfies every app minimum.

**Reading is forgiving.** Unknown fields are ignored. An entry that can't be read (a wrong type, an unsafe identifier or path, a duplicate) is skipped with a warning and the rest loads; a capability field typed differently is dropped on its own. A newer `schemaVersion` is read as far as this build understands. Only `minimumReaderVersion` above `ModelManifest.readerVersion` rejects a file, for changes older readers would misread. A revision is strict inside: it is skipped whole if any artifact or file can't be read, because a partial file list can't be installed. Identifiers become folder names, so they're limited to letters, digits, and `._+-`.

**Deviation: digests.** Hugging Face publishes SHA-256 only for LFS files. For small files (configs, tokenizers, `model.mil`) it publishes the git blob ID, SHA-1 over `"blob <size>\0"` and the content. The store verifies whichever the manifest has, and refuses a file that has neither: size alone would let a swapped file of the same length through, so the install stops with “can’t be checked” instead. Listing a repository fails the same way for a file without a checksum. Both come from metadata alone; generate entries with `scripts/model-revision.py`.

**Licenses.** Daybook's code is MIT. Each model keeps its own license and declares it in its manifest entry; `allowsCommercialUse: false` is labelled "Non-commercial" wherever a model is chosen. The built-in entries: Whisper, MIT (OpenAI's release; Argmax's Core ML conversion is MIT too; the Hugging Face cards for base and small say Apache-2.0, for the Transformers port); Gemma 4, Apache-2.0 (Google's card links https://ai.google.dev/gemma/docs/gemma_4_license; mlx-community's E2B/E4B cards still carry stale "gemma" metadata, so the entry cites the upstream card); Qwen 3.5 and 3.6, Apache-2.0; Qwen 2.5 1.5B and 7B, Apache-2.0; Qwen 2.5 3B, the Qwen Research License (non-commercial); Apple Foundation Models, Apple's acceptable use requirements (a system model, nothing redistributed); Community-1, CC BY 4.0 as scoped by FluidInference's NOTICE.md; Sortformer 2.1, the NVIDIA Open Model License with NVIDIA's required notice, and CC BY 4.0 for the conversion; Parakeet Ultra and Redux, CC BY 4.0 (Moondream's post-trains of NVIDIA's parakeet-tdt-0.6b-v3), with the Core ML conversion named as the change; Nemotron 3 Diarization and Nemotron 3.5 ASR Streaming, the OpenMDW License 1.1, whose full text ships in `THIRD_PARTY_NOTICES.md` because the Hugging Face repositories have no LICENSE file. `ModelAcknowledgements.list(from:only:)` builds the acknowledgements from the manifests (the Mac's About Daybook panel and Settings › Models › Acknowledgements; the iPhone's Settings › About › Acknowledgements): one entry per family and license, with the license name, link, required attribution, and the non-commercial label.

## Selection, updates, and provenance

- **What a selection names:** per role, a variant key, never a raw revision (`ModelSelections`). It resolves to the newest verified installed revision (`ModelInventory.resolve`).
- **Presets:** Quick, Balanced, and Detailed per device tier, read from the manifest's `presets` through `ModelRecommendations`. Each role lists choices best first, with optional per-tier overrides; the first choice this build can run is the preset's model. `recommendedPreset` and `initialSelection` say what a tier starts with. **Deviation:** presets are manifest data rather than Swift, so a new default model is a manifest edit. Parakeet Ultra is every preset's first transcription choice (Whisper follows as the fallback). Balanced and Detailed tell speakers apart with Nemotron 3, Community-1 next, and every preset names Community-1 for `speakerEmbedding`. Quick keeps Community-1 first: it makes turns and voice profiles in one pass and one 22 MB download, and no real-recording evaluation yet shows Nemotron better for it. `initialSelection` starts with Parakeet Ultra and keeps Community-1 for speakers, so a first launch needs no second speaker model.
- **Summaries by tier** (catalog 2026.10.24, after the MLX 3 upgrade): Gemma 4 is every list's first choice, the Qwen 3.5/3.6 alternates follow, and the superseded Qwen 2.5 3B and 7B come last, so an installed one still stands in when another model is removed. Qwen 2.5 1.5B is in no list since catalog 2026.10.31 (below).

  | Tier | Quick | Balanced | Detailed | First launch |
  | --- | --- | --- | --- | --- |
  | compact (< 16 GB) | Gemma 4 E2B | Gemma 4 E4B | Gemma 4 E4B | E2B |
  | standard (16–31 GB) | Gemma 4 E4B | Gemma 4 12B | Gemma 4 12B | 12B |
  | large (32–63 GB) | Gemma 4 E4B | Gemma 4 26B A4B | Gemma 4 26B A4B | 26B A4B |
  | workstation (64 GB+) | Gemma 4 12B | Gemma 4 26B A4B | Gemma 4 31B 8-bit | 26B A4B |

  On long conversations (2026-10-31, [validation](validation.md)): Gemma 4 26B A4B keeps every topic and 36 of the 38 commitments of a 22-minute weekly, and every topic and commitment of a three-hour meeting (29 minutes to summarize on a loaded 64 GB Mac); 31B 8-bit every topic and 36 commitments of the weekly and everything in the three-hour meeting, with every note handled right, in 29 minutes for the weekly and 1 h 47 min for the meeting; Qwen 3.6 35B A3B every topic of both and every commitment of the three-hour meeting, but writes three of its notes as fact; 12B every topic of the weekly and 28 commitments; E4B 12 topics and 26 commitments; Qwen 3.5 9B every topic and 29 commitments, writing most of what only notes say as said; Qwen 3.5 4B 9 topics and 25 commitments; E2B, with `commitments: "brief"`, every topic and 18 commitments. Qwen 2.5 7B keeps 12 topics and 19 commitments; Qwen 2.5 1.5B misses most of both and writes no summaries any more. No preset changes.

  Small tasks start with Apple Foundation Models in every preset and in `initialSelection`. Where it isn't available, `ModelRecommendations` passes over it given the engines, and AppState only hands it to a job while it's usable (`installedModels`), so the summarizer keeps naming conversations as before.
- **A model retired from a role:** a variant whose entry stops serving a role (its `roles`) is no longer offered for it, and a choice that names it moves at launch to the preset's first installed choice, or its first choice, which waits for its download like any choice (`ModelSelections.replacingRetired`, `AppState.replaceRetiredChoices`), with a notice saying so and where to download it. A queued job that froze the retired model fails with "can't be used for summaries" rather than running it. Qwen 2.5 1.5B is the first (`roles: []`, catalog 2026.10.31): with every prompt and budget tried, it missed most topics and commitments of a 22-minute meeting and wrote a note's question as the launch date that was decided ([validation](validation.md), 2026-10-31). It was only ever a last fallback for people who had installed it, and it serves no other role: text only, it can't describe photos, and small tasks run on Apple Foundation Models or the summary model. Settings › Models lists it only while it's on the Mac, to be removed ("Used for: Nothing"); summaries made with it still name it.
- **Queued jobs freeze exact revisions** (`ProcessingJob.revisions`), so an update installed while they wait never changes what they run.
- **Updating a variant:** a new revision downloads beside the old one, is verified, and appears with one atomic rename; from then on selections resolve to it. The old revision stays until nothing selects, runs, queues, or pins it, then garbage collection removes it.
- **Removing a selected model** falls back to the preset's next installed choice, with a notice saying so, or keeps the choice and shows "Download" (`ModelSelections.removing`). Processing never silently switches models: a job whose frozen revision is gone fails with "Download … in Models" rather than running another one.
- **Provenance:** every transcript, speaker run, and summary records the exact family, variant, revision, engine, and engine version in `ProcessingSettings.model`, and the variant key in `modelID`. A model the catalog no longer lists, or one only another device had, is still named from the recorded provenance. A cloud summary records the provider as the family and the provider's model ID as the variant, with engine `cloud` and no revision ("anthropic/claude-sonnet-5-5"), and its tokens, estimated cost, and sending device in the parameters (`CloudProvenance`).
- **Migration:** before the model system, Daybook stored catalog IDs (`whisper-base`, `qwen-7b`, `speaker-community-1`, …). Each built-in revision's `legacy.ids` is the migration table: stored preferences map through it once at launch (`ModelSelections.migrating`; the old keys are left for an older build), and old results still resolve to their variant and exact revision (`ModelCatalog.provenance(of:modelID:)`, engine version "legacy").

## Quality ranks

Each variant ranks how good it is at each step it serves, 0–100, in its manifest entry (`quality`: `ModelRole.rawValue`
→ rank; `CatalogModel.quality(for:)`), for "Upgrade" offers ([multipoint](multipoint.md#upgrade)): a conversation whose
transcript, speakers, or summary a clearly better model within reach could redo says so on its page. Ranks compare
within a step only. Summaries share the cloud catalog's `summaryQuality` scale ([cloud](cloud.md#summary-quality)), so
a local summary and a cloud one compare. A model retired from a step keeps its rank there, so what it made still
compares (Qwen 2.5 1.5B). An unranked model (one the person added, or a rank outside 0–100, which reading drops) makes
no offer, and a result it made gets none. Ranks are data: a new model or a new measurement is a manifest edit, with
its basis here. `UpgradeRanks` reads both catalogs; a cloud model the catalog didn't measure ranks as its family's
newest measured one (Claude Sonnet 6 as Sonnet 5.5), and one whose family was never measured (GPT-6 Luna) is unranked.

Where nothing was measured the rank is conservative: no higher than the evidence supports, so an unmeasured model
is offered over another only when the catalog's own order puts it clearly ahead. How much higher "clearly" is, per
step, is the margin ([multipoint](multipoint.md#upgrade): 10 for each).

**Transcripts.** Nothing yet compares the recognizers on the same real meetings (docs/validation.md, "Speech models"),
so the ranks keep the catalog's order with room between.

| Model | Rank | Based on |
| --- | --- | --- |
| Parakeet Ultra | 90 | Every preset's first transcription model. Daybook's one check (2026-10-24): every word of a two-speaker synthetic meeting, 4 of 56 wrong with three voices overlapping |
| Whisper Large v3 Turbo | 85 | Detailed's second and the other-languages model, "most accurate on difficult audio and accents"; not measured here. Within the margin of Ultra, so neither is offered over the other |
| Parakeet Redux | 80 | Ultra's post-train with a ternary encoder (220 MB against 632); no published or local measurement. A 0.6B encoder squeezed that far loses words, so a margin below Ultra: a 4 GB iPhone's transcript is offered a Mac's Ultra |
| Whisper Small | 70 | "More accurate" than Base, after Large v3 Turbo; not measured |
| Whisper Base | 60 | "Fastest. Best for clear audio."; not measured |

A transcription model is offered only for recordings in languages it covers (`languages`), so a transcript Whisper made
because Parakeet doesn't know the language is never offered Parakeet.

**Speakers**, 100 less a published AMI diarization error rate where there is one:

| Model | Rank | Based on |
| --- | --- | --- |
| Nemotron 3 | 89 | NVIDIA's card: AMI-SDM DER 11.14 |
| Nemotron 3 · Compact | 88 | FluidInference: AMI DER 9.63 against 9.47 for the offline build in the same run; not verified here, so a point below |
| Community-1 | 85 | No AMI figure in Daybook's records. Balanced and Detailed put Nemotron 3 first, Quick keeps Community-1, and no real-recording evaluation shows either better, so within the margin of Nemotron 3, and above Sortformer (at most four speakers, no voice profiles). Also 85 for voice profiles (`speakerEmbedding`), the one model that makes them, so voice profiles never make an offer of their own: they're made again with the speakers |
| Sortformer 2.1 · Full Precision | 79 | NVIDIA, on Nemotron 3's card: AMI-SDM DER 21.42 |
| Sortformer 2.1 · Compact | 77 | The same weights palettized to 6 bits, "can lose detail"; unmeasured, so two below |

**Summaries**, on the cloud's scale: `35 × topics kept / 22 + 45 × commitments with the right owner / 66 + 10 × notes
handled right / 6 + 10 × right-owner commitments / commitments listed` on the three-hour offsite (docs/cloud.md,
"Summary quality"). Models not run on the offsite are placed from the 22-minute weekly (docs/validation.md,
2026-10-31) between the two measured on both, E4B (24 of the weekly's 38 commitments with their owners, 53) and the
26B A4B (36, 90): `53 + (commitments − 24) × 37 / 12`, rounded down to a multiple of five.

| Model | Rank | Based on |
| --- | --- | --- |
| Gemma 4 31B 8-bit | 94 | Offsite (2026-10-31): 22 topics, 66 commitments with their owners, every note right, 83 listed, which is 98. That run had the restated-commitments merge, which lifted the 26B A4B on the same fixture from 90 to about 94 (90 listed, one more note right), so 4 less keeps it on the scale the catalog's 26B A4B, E4B, and cloud models were scored on |
| Gemma 4 26B A4B | 90 | Offsite, measured (docs/cloud.md) |
| Qwen 3.6 35B A3B | 87 | Offsite (2026-10-31): 22 topics, 66 commitments, 2 notes right (three written as fact, one left out), 81 listed, which is 91; less the same 4 |
| Qwen 3.5 9B | 65 | Weekly: 13 of 13 topics, 29 commitments with their owners: 68. Writes most of what only notes say as said |
| Gemma 4 12B | 60 | Weekly: 13 topics, 27 commitments with their owners: 62 |
| Gemma 4 E4B | 53 | Offsite, measured (docs/cloud.md) |
| Qwen 3.5 4B | 45 | Weekly: 9 topics, 23 commitments with their owners: 49 |
| Qwen 2.5 7B | 30 | Weekly: 12 topics, 17 commitments with their owners: 31 |
| Gemma 4 E2B | 25 | Weekly (brief commitments): 13 topics, 16 commitments with their owners: 28 |
| Qwen 2.5 3B | 20 | Never run on the harness; superseded and smaller than the 7B, so below it |
| Qwen 2.5 1.5B | 10 | Serves no role since catalog 2026.10.31: it missed most topics and commitments; ranked for what it made |

## Routing

Jobs are routed when they're queued (`AppState.speechRoute`), and the result is frozen into the job like its models.

- **Language routing.** `ProcessingPreferences.transcriptionLanguage` is a BCP-47 code or nil for Automatic; `otherLanguagesModelID` is the model for languages the transcription model doesn't cover (nil picks one: the person's choice if it covers more, else the best model covering every language, installed first, in Detailed's order; today Whisper Large v3 Turbo). `TranscriptionRouting.route` reads the `languages` capability (nil or `["*"]` covers every language):
  - A chosen language the selected model covers runs that model with the language as a hint. One it doesn't cover runs the other-languages model instead (the job's `transcriptionModelID`), which then has to be installed.
  - Automatic with a model that covers some languages adds a language check (`ProcessingJob.languageFallbackModelID`, optional: it never blocks a job). `TranscriptionRouter` transcribes with the selected model, then reads the transcript's language with `NLLanguageRecognizer` (`TranscriptLanguageDetector`) and the mean word confidence (`LanguageCheck.verdict`). A confident covered language keeps the transcript. A clear other language, or an unclear one (top guess under 0.6, or mean confidence under 0.5), runs the other-languages model too, and its own spoken-language detection decides: the second transcript is kept unless it hears a language the first model covers. A model that doesn't cover a language still writes words in the scripts it knows, with low confidence (Parakeet on Japanese speech: top guess Indonesian at 0.26, mean confidence 0.36), so text alone can't be trusted to name the language; Whisper's audio-based detection settles it without editing `WhisperKitEngine`. If the other model isn't installed, the first transcript stays, with a notice when it's probably another language.
  - The transcript records the model that actually produced it (`modelID`, `ProcessingSettings.model`) and the decision in its parameters: `language`, `languageCheck` (`kept`, `switched`, `unavailable`), `detectedLanguage`, and `routedFrom`.
- **Speaker routing.** `ModelRouting.diarizer`: an expected speaker count above the selected model's `maxSpeakers` (Nemotron's 8) runs an installed speaker model without that limit, preferring one that takes a count (Community-1); with none installed the selected model runs and says so. The person's choice is unchanged.
- **Voice profiles.** `ModelRouting.voiceEmbedder` picks the `speakerEmbedding` model when the speaker model has no `voiceEmbeddings` (Nemotron). Selections saved before the role had a built-in model take the catalog's initial choice (`ModelRouting.withDefaultVoiceEmbedder`), Community-1. As `EmbeddingVoices`, Community-1 takes each speaker's stretches of solo speech (at least 1 s, at most twelve 10-second pieces, longest first; the longest turn of at least 0.5 s when a speaker never talks alone) through its own FBank and WeSpeaker ResNet34 models, repeating each span to fill the 10-second window as FluidAudio's `embedSpan` does, and averages the raw embeddings by duration, as its own speaker centroids are. The vectors keep the embedding space `fluid-community1-embedding-df2625ac79a7ac6b`, so profiles from Community-1 runs and Nemotron runs compare. **Deviation:** FluidAudio's public `embedSpans` isn't in 0.17.7, and its `embedSpan` is internal, so `WeSpeakerSpanEmbedder` reproduces it (including the silence-aware FBank re-centering) over the public Core ML models; switch to `embedSpans` when FluidAudio releases it. The embedder is required like the speaker model: a Nemotron job waits for Community-1 if it isn't installed. Settings' Match Voices Across Recordings and Voice Matching are available when the speaker model or its voice-profile model makes voice profiles (`ModelRouting.makesVoiceProfiles`); they used to read only the speaker model, so Nemotron greyed them out though its speakers had profiles. Speaker profiles across conversations use the same space ([architecture](architecture.md#speakers-and-profiles)).

## Storage

```text
Models/
  <engine>/<family>/<variant>/<revision>/   an installed revision
    model/…  tokenizer/…                    one folder per artifact, files at their repository paths
    receipt.json                            the verified file list, capabilities, and engine options
  .partial/<engine>/<family>/<variant>/<revision>/   downloads in progress; they resume
  .staging/                                 installs and migrations being assembled
  .store.json                               pinned revisions
  UserModels.json                           the person's manifest
```

- **Installs:** the existing mechanism (swift-transformers' `HubApi.snapshot`, pinned to each artifact's commit, now limited to exactly the manifest's files) downloads into `.partial`, where an interrupted download resumes with the files it hasn't finished (since swift-transformers 1.3.5, one cut off partway starts again). Every file is checked by size and digest; a mismatched file is deleted so the next attempt fetches it again. The engine checks the assembled install, a receipt is written, and the folder is renamed into place. Before every load, the receipt and file sizes are checked again. **Deviation:** Community-1 used FluidAudio's own downloader for the same repository and pinned commit; it now goes through the same fetcher as the other models and fetches only the 21 files the loader reads.
- **Disk use:** `ModelStore.diskUsage()` reports each revision, unfinished downloads, and leftover pre-model-system folders.
- **Garbage collection** (`collectGarbage(protecting:)`) removes revisions a newer ready revision of the same variant replaced. It never removes a selected revision, one a queued or running job froze or a loaded model holds (leases), a pinned one, or a variant's newest ready revision.
- **Migration of existing installs:** at launch, `LocalIntelligenceRuntime.prepare()` moves each `Models/<legacy ID>/` whose marker matches the migration table into the new layout without downloading: every file is verified in place first, the folder is renamed into `.staging` in one step, its files are moved into the installed layout, and the result is renamed into place. Migration is idempotent and resumes after an interruption. A folder whose files don't match stays where it is, the person is told which models need downloading again, and the model manager can remove it.

## Small tasks

`ModelRole.smallTasks` is for short, fixed-shape jobs: a title, the meeting kind, and vocabulary suggestions. When `ModelSelections[.smallTasks]` names a model this device can run, the job carries it (`ProcessingJob.smallTasksModelID`, `InferenceProcessingEngine.Configuration.smallTasksModel`) and `InferenceProcessingEngine.summarize` runs it first:

1. `MeetingInference.performSmallTasks` gets the transcript, notes, the chosen kind, and the approved vocabulary. The engine reads a bounded excerpt (`SmallTasks.excerpt`: whole lines from the start, three middle passages, and the end, with "[…]" for gaps) sized to its context; AFM uses (context − 1,600) × 3 characters and retries once with half on a context overflow.
2. With an automatic kind, the small-tasks kind becomes the summary's kind, so its sections fit; a chosen template's kind is never replaced.
3. Its title replaces the summarizer's; its terms (only ones present in the source and not yet approved) come first among the suggestions, at most 12.
4. The summary records `smallTasksModel` and `smallTasksEngine` in `ProcessingSettings.parameters`; its `model` provenance stays the summarizer's.

Nothing selected, Apple Intelligence off, a guardrail refusal, or any other failure leaves the summarizer's title, kind, and terms exactly as before, without a notice. Selections saved before small tasks existed gain the initial choice once (the `modelSelections.smallTasksAdded` default); clearing it afterwards sticks. Legacy migrations fill it from `initialSelection` like any role with nothing stored.

## Platforms

- **Shared code:** the manifest, catalog, selection, and provenance types are in DaybookKit and DaybookCore, so the iPhone shows what produced a result; the store is in DaybookModelStore and the live engines in DaybookLive, which the iPhone links to run live captions' models.
- **Engines** for processing are in DaybookIntelligence, which both apps link; the iPhone registers the same engines less WhisperKit (built for the Mac only), and its MLX engine serves summaries only (MLXVLM is the Mac's). Each declares its platforms; availability is `unsupportedPlatform` ("Not available on iPhone") where an engine doesn't run. The iPhone reads its models' availability from the registry's descriptors plus `LiveEngines.descriptors`.
- **System models:** a variant with `systemProvided: true` has no revisions; nothing is downloaded or removed, and its engine decides whether this device has it: its descriptor's `unavailableReason` becomes `ModelAvailability.unavailableOnDevice` ("Turn on Apple Intelligence", "Needs macOS 26 or later", "Not available on this Mac", "Apple Intelligence isn’t ready yet"), and `validate` refuses it. `installedModels()` includes a system model only while it's available.

## The model manager

Settings › Models is built from the catalog and the engines this build registers. It has no list of models, engines, or roles of its own, so a new family, variant, engine, or role appears without interface code. `ModelManagerSnapshot` (`Sources/Daybook/App/ModelManager.swift`) turns plain inputs into everything the pane shows: the catalog, the engine descriptors, what's installed, the selections, the download queue, and update results. Tests build it from a synthetic catalog. `ModelManager` keeps what's on disk (inventory, disk use, protected revisions, results per model) and carries out actions through `LocalIntelligenceRuntime` and the app's download queue, so a download from the manager waits for processing and cancels like any other.

The pane, top to bottom:

- **Quality:**
  - Quick, Balanced, and Detailed from `ModelRecommendations`, each with its models, total download, and suggested memory. The one the catalog recommends for this Mac's tier is marked "Recommended".
  - A preset sets every role it names, and its speaker effort. Any other combination reads "Custom".
  - A row under them speaks only while the chosen models aren't all on this Mac: Download with the size, or progress and Cancel.
- **Role choices:**
  - One pop-up per role. Transcription carries the language rows from `TranscriptionLanguageSettings`. Speakers has the speaker model and, when a model serves it, voice profiles, then the speaker settings, enabled by capabilities, and Speaker profiles (Edit… opens the Speaker Profiles window). Summaries has summaries, plus titles and tags.
  - The roles offered are the `ModelRole.known` roles with a model that can run here, then any other role a registered engine serves. Any further role gets its own section.
  - Each menu item is the model, with its state underneath ("Downloaded", its download size, "Needs a newer Daybook") and "Non-commercial" where it applies.
  - Models that can't run here are listed last, disabled, with the reason. Hiding them would make an entry vanish without explanation, and the library lists them anyway.
  - Choosing a model that isn't downloaded chooses it, and the row shows "Not downloaded · 1.6 GB" with Download. Processing waits for it ("Waiting for models") and never runs another model instead.
- **Model Library:**
  - Disk use (`diskUsage`) with Show in Finder.
  - "Old revisions" with Remove, only when there are some: `ModelInventory.replacedRevisions`, less pinned, leased, and queued revisions, removed with `collectGarbage`.
  - "Old downloads" (`removeLegacyLeftovers`), only when there are some.
  - Updates, with Check for Updates.
- **Every model, by family:** families follow the pipeline (the first role they serve), then their names, and variants keep manifest order. A new quantization appears as a row in its family; a new model, as a new family.
  - Each row has the name, "Non-commercial" and "Added by you" labels, the maker, the size, and a status: Not downloaded, Waiting to download, Downloading · NN% (with Cancel), Downloaded, In use, Update available, Needs downloading again, Needs a newer Daybook, Not available on this Mac, or Included with macOS (system models, which have no size or download).
  - The likely action is a button (Download, Use, Update). The More menu has Details, Use for a role, Remove, and, for added models, Remove from Daybook.
  - Under the last family: Acknowledgements and Add Model.

**Removing** is confirmed with what it frees and what happens to each role that chose the model, from `ModelSelections.removing`: "Frees 489 MB. Transcription will use Whisper Base." or "Transcription will wait until you download it again." Removing a model the person added from Daybook (`removeAddedModel`) can't be undone by a download, so its roles move to the preset's model, and the confirmation says so.

**Details** (a sheet) show:

- the family, variant, release date, roles, size, and suggested memory;
- the status, and the roles that chose it;
- how many conversations have results from it (`ModelCatalog.resultCounts(in:)`, from each result's provenance, legacy IDs included);
- its capabilities in words ("Word timings", "Up to 4 speakers", "25 languages", "Voice profiles");
- the license with its link and required attribution, and the source;
- the revisions on this Mac with publication and download dates, and an update to install.

**Updates are opt-in and manual.** Check for Updates calls `checkForUpdates`. It first confirms Hugging Face can be reached, so being offline reads as a problem rather than "Up to date". Each update shows its size, publication date, and changed files, with Install. `recordUpdate` records the revision in the person's manifest, as `installUpdate` does, and the download (`key@revision`) joins the app's queue. Nothing is checked or installed automatically.

**Add Model** takes a repository or a Hugging Face link (a link to a branch or folder fills those in), an optional revision, and an optional folder.

- `previewAddition` lists the repository once and asks every registered engine, for each role it serves, whether it can run it. Nothing is written.
- The sheet shows the proposal: name, role, the family to join, engine, commit, license, memory, capabilities, and the files with their size. When no engine accepts it, each engine's reasons are shown.
- Add and Download calls `addModel`, pinned to the commit that was shown, and queues the download.
- A new engine's models can be added with no change here.

**Acknowledgements** come from `ModelAcknowledgements`. On the Mac they're in the About Daybook panel's credits, the standard place for credits, reachable from the app menu at any time, and in a sheet from Settings › Models next to the models themselves. On iPhone, Settings › About › Acknowledgements lists the models behind the library's results.

The additive APIs the manager needed are in their own files:

- `LocalIntelligenceRuntime.previewAddition`, `recordUpdate`, and `ModelInventory.replacedRevisions` (`DaybookIntelligence/LocalIntelligenceRuntime+Manager.swift`);
- `ModelCatalog.resultModelKeys(in:)` and `resultCounts(in:)` (`DaybookKit/Models/ModelCatalog+Manager.swift`).

Debug builds take `--model-demo <step,…>` (`ModelDemo`) to show any state against synthetic installs, with a download that stalls and a scripted Hugging Face, never the network: `preset:`, `use:<role>=<key>`, `downloading:<key>`, `updates:<key>`, `add` (or `add:<owner/name>`, a repository the scripted hub doesn't have), `details:<key>`, `remove:<key>`, `acknowledgements`, `voice-matching`, `about`, `scroll:library|updates|family:<id>`.

**Limits:**

- Add Model offers no engine option beyond a folder. A WhisperKit model whose tokenizer lives in another repository is added through a manifest instead.
- Presets cover only `ModelRole.known` roles (`ModelRecommendations`).

**Verified on October 24, 2026:**

- `ModelManagerTests` (15 tests) cover status derivation, presets and Custom, a synthetic catalog with a made-up engine, family, and role, removal confirmations, and fallback through the real runtime on synthetic installs. They also cover old-revision cleanup, and the update and add flows against a scripted Hugging Face, offline included.
- The pane, its sheets, and the About panel's credits were rendered in light and dark against synthetic installs.

**Not yet verified:**

- Real Hugging Face responses through the manager; the scripted hub follows the client's API shapes.
- A real download or update started from the pane.
- The pop-up menus' item subtitles, which the in-app snapshot doesn't capture (open menus aren't windows it renders).

## How to add a model

Generate revision entries from Hugging Face metadata with `scripts/model-revision.py`; it never downloads weights. Then run `swift test --filter ModelManifestTests` to check the manifest reads cleanly.

### A new quantization or revision of Gemma 4

The `gemma-4` family (`Families/gemma-4.json`) has E2B, E4B, 12B, 26B A4B (QAT 4-bit), and 31B 8-bit variants, each with `minimumEngineVersion: 2`.

1. **A new revision** (the same build re-uploaded or fixed): run `python3 -I scripts/model-revision.py --artifact model mlx-community/gemma-4-12B-it-4bit main '*.safetensors' '*.json' '*.jinja'` and append the output to the `12b-4bit` variant's `revisions` in `Families/gemma-4.json`. Macs that have the variant download it beside the old one when they update; selections switch once it verifies, queued jobs keep the old one until garbage collection. Between releases, the same revision reaches people through "Check for model updates" without an app release.
2. **A new quantization people choose between** (an 8-bit or QAT build): add a variant to the `gemma-4` family with its own `id` (`12b-8bit`), `name` ("Gemma 4 · 12B · 8-bit"), one-line `detail`, `recommendedMemoryGB`, capabilities (`contextLength`, `structuredOutput`), `engineOptions.architecture`, `minimumEngineVersion: 2`, and a revision from the script. If it replaces the old build, set `supersedes`/`supersededBy`. To make it a preset's choice, put its key first in that preset's `summarization` list; the old key stays next as the fallback.

No code changes.

### A new MLX language model family

1. Check that the pinned mlx-swift-lm registers its `config.json` `model_type` (`LLMTypeRegistry`). Adding it from Settings with `LocalIntelligenceRuntime.addModel` performs exactly this check.
2. Add a family as a new file, as `Families/qwen3.5.json` does: `id` (`qwen3.5`), `name`, `maker`, `engine: "mlxLanguage"`, `roles: ["summarization"]`, `license` (from the upstream card, with attribution and `allowsCommercialUse`), and its variants as above. Set `minimumEngineVersion` to the `MLXLanguageEngine.version` that added the architecture, so older builds show "Needs a newer Daybook" instead of failing.
3. Prompt settings are `engineOptions`: `"thinking": "off"` sets the chat template's `enable_thinking` to false (Qwen 3.x reasons by default; Gemma 4 only when asked), any `<think>…</think>` or `<|channel>…<channel|>` block that still appears is removed from replies, and a free-form reply can't open one. `"commitments": "brief"` asks the commitments pass in fewer words, for a model too small to follow the full prompt (Gemma 4 E2B; [validation](validation.md), 2026-10-31). `"noteCheck": "on"` checks each note against what was said around it before the summary is written, and passes on one that only repeats it without its words ([templates](templates.md#notes-and-bookmarks)); it's on only where the model tells a note that repeats from one that adds (Gemma 4 26B A4B and 31B, Qwen 3.6 35B A3B), because elsewhere notes that add something would lose their words. `"outputTokens"` sets the most a summary pass may write below its default, 16,384 for a variant whose `contextLength` is declared (no built-in variant needs one: at 40,000 tokens Gemma 4's KV cache is under 1 GB, Qwen 2.5 7B's under 2 GB). Declare `contextLength`: it sets how much a summary pass reads and writes ([model runtime](model-runtime.md), "Summarization"). Declare `structuredOutput: true` to have summaries constrained to their JSON schema. A new setting is an engine change, not a pipeline change. Engine options describe how the files run, not the files, so an install runs with the catalog's current ones; its receipt keeps those it was installed with.
4. Add it to the presets in `Catalog.json` if it should be a default.

### A new speech engine: Parakeet through FluidAudio (as built)

FluidAudio 0.17.7 already contained Parakeet Ultra (`AsrModelVersion.ultra`), so this took one type, one registration, and data:

1. **One type:** `Sources/DaybookIntelligence/Engines/ParakeetEngine.swift`, `struct ParakeetEngine: ModelEngine` (`.parakeet`, transcription, `FluidAudio 0.17.7`, macOS and iOS, shared). `validate` requires `Preprocessor`, `Encoder`, `Decoder`, and `JointDecisionv3` bundles and `parakeet_vocab.json`; a fresh install must also have every vocabulary token below the blank ID. `load` calls `AsrModels.loadLocal(from:version:)` on the install's folder. Each transcription gets a fresh `AsrManager`, which reads files longer than 30 s from disk in 15 s windows (FluidAudio's long-form path); recordings with several channels are mixed down first, since FluidAudio keeps only the first. `ParakeetWords` merges SentencePiece tokens into words with Whisper's leading-space convention, gives each word at least one 80 ms encoder frame (so it overlaps a speaker turn), and groups words into passages at sentence ends, pauses of 1 s, and 30 s. A word's confidence is the **minimum** of its sub-word tokens' confidences, punctuation excluded: a word is wrong when any piece is, the mean would hide one doubtful piece, and the product would mark long words down for their length, which would make ROVER prefer another recognizer's shorter split.
2. **One registration:** `ParakeetEngine()` in `ModelEngineRegistry.standard`.
3. **Manifest:** `Families/parakeet.json`, family `parakeet` (CC BY 4.0, with attribution naming Moondream, NVIDIA's v3, and the Core ML conversion as the change), variants `ultra` (`FluidInference/parakeet-ultra-coreml` at `95eaa59…`, 632 MB) and `redux` (`FluidInference/parakeet-redux-coreml` at `8c5ef97…`, 220 MB, the 2-bit build; not in a preset), each with the 25 `languages`, `wordTimestamps`, `wordConfidence`, `vocabularyPrompt: false`. **Deviation:** the variant is `ultra`, not `ultra-coreml`: every variant here is a Core ML build, so the suffix adds nothing.
4. **Tests:** `SpeechEngineTests` (token merging, passages, installs against synthetic files, additions against `FakeHubClient`), plus the registry and catalog tests.

**Nemotron 3 Diarization** is the same shape: `NemotronDiarizerEngine` (`.nemotronDiarizer`, `Diarizing`) and `Families/nemotron-3-diarization.json` with variants `offline` (the 30.4 s batch preset in `monolithic/v2/`, 199 MB) and `compact` (the split-graph W8A8 build `c128-split-w8a8`, 102 MB including the host-side projection, which FluidInference reports runs entirely on the Neural Engine; not in a preset), both `maxSpeakers: 8` without `voiceEmbeddings`, from `FluidInference/nemotron-3-diarization-coreml` at `25a90f9…` (the general-access weights). Each run reads the recording in 30 s blocks through one converter into FluidAudio's streaming path (`appendAudio` / `processBufferedAudio` / `finishStream`, frame-exact with `processComplete` but without holding the whole recording), and `SpeakerActivity` turns the 10 ms probabilities into turns as they arrive: active above 0.5, same-speaker gaps under 0.25 s bridged, turns under 0.2 s dropped. Voice profiles come from Community-1 (see "Routing").

## Live models

Live captions can run on local models on both devices (docs/model-runtime.md, "Live"). Three roles, read from `Catalog.json`'s `liveSelection` per platform and tier (`LiveModelChoices`), kept out of the processing presets so choosing Quick or Detailed never downloads them:

| Role | iPhone and Mac default | Download | License | Why |
| --- | --- | --- | --- | --- |
| `liveTranscription` | Nemotron 3.5 ASR Streaming · Latin (`nemotron-3.5-asr-streaming/latin-1120ms`), then the multilingual build | 588 MB (Latin, 1.12 s chunks) · 615 MB (multilingual, 2.24 s) | OpenMDW-1.1 | The only multilingual cache-aware streaming recognizer FluidAudio 0.17.7 runs with punctuation and capitals; words appear about 1.25 s behind and are never revised. FluidInference reports FLEURS WER 8.96% English, 4.80% Spanish, 9.52% French, 5.41% Italian, 6.14% Portuguese, 9.83% German at the 2.24 s tier (8.89–9.78% at 1.12 s), 3.67% on LibriSpeech test-clean, and 103–109× real time on an M5 Pro at 1.12 s. Encoder 6-bit palettized with 8-bit edge layers, iOS 17+, Neural Engine |
| `liveDiarization` | Nemotron 3 · Live (`nemotron-3-diarization/live`, preset `fast32-split-w8a8`) | 102 MB | OpenMDW-1.1 | Streaming with a speaker cache, so a voice keeps its slot; eight speakers; 2.88 s latency; the split W8A8 graph runs entirely on the Neural Engine (FluidInference), "matches the card-standard low profile's quality at a fraction of its per-call cost". NVIDIA's card reports AMI DER 9.75 for its streaming profile against Sortformer v2.1's 15.81 |
| `speakerEmbedding` | Community-1 (`community-1/offline`) | 22 MB | CC BY 4.0 (scoped) | The Mac's voice-profile model, so live embeddings land in `fluid-community1-embedding-df2625ac79a7ac6b` and profiles made on the Mac name speakers on the iPhone. Live captions load only its FBank and WeSpeaker bundles |

Everything an iPhone needs is about 712 MB (live transcription 588, speakers 102, voice profiles 22), downloaded over Wi‑Fi unless the person allows cellular. The recognizer suggests 6 GB of memory (`recommendedMemoryGB`; about 0.8 GB resident); an iPhone with less (a 4 GB iPhone 12 or 13) isn't offered it and keeps the system's captions, with live speakers still available. The speaker model suggests 4 GB.

**Considered and not chosen** (sizes from Hugging Face metadata; no weights downloaded):

- *Parakeet EOU 120M* (`FluidInference/parakeet-realtime-eou-120m-coreml`, 225 MB per chunk size, NVIDIA Open Model License): the smallest streaming recognizer, but English only, without punctuation or capitals (NVIDIA's card).
- *Nemotron Speech Streaming 0.6B, English* (626 MB, NVIDIA Open Model License): English only, at the size of the multilingual model.
- *Parakeet Unified 0.6B streaming* (590 MB int8, 1.18 GB fp16, CC BY 4.0): English only, and FluidAudio reports its int8 encoder fails to load on A16 iPhones, leaving the 1.18 GB fp16 build.
- *Parakeet TDT v3 (Ultra, Redux) through the sliding-window manager*: already on Macs, 25 languages, but an offline encoder re-run over 15 s windows: about 13 s behind the speech at FluidAudio's defaults, and several times the compute of a streaming model at a shorter window.
- *Sortformer v2.1 streaming* (242 MB FP16 or 92 MB palettized): four speakers, and Nemotron 3 supersedes it.
- *The system's SpeechTranscriber*: remains the fallback (no download, every language Apple supports), but it gives no speakers and Daybook can't choose or pin its model.

The live models are catalog entries like any other: `minimumEngineVersion`, revisions pinned to commits with a digest per file, `supersededBy`, Acknowledgements (the iPhone lists the live models it has downloaded beside the models behind its results). A better streaming model is a new variant and a `liveSelection` edit. On the Mac, Settings › Models shows Live transcription and Live speakers as roles of their own (the engines serve them), with the same Download and Remove; their defaults are filled in once (`modelSelections.liveAdded`).

## iPhone processing

The iPhone processes its own recordings with the same engines (docs/iphone.md, "Processing on this iPhone"). Its models are the catalog's `initialSelection` for iOS: `platforms.iOS` lists every role (an empty list means none), and `platformTiers.iOS` overrides it per memory tier (`PhoneTier`, from what the iPhone reports: under 4.5 GiB `small`, under 6.5 `medium`, under 9.5 `standard`, else `large`). `PhoneProcessingModels` reads them, keeps the person's choice when it can run there, and falls back to the first default that can. A Mac's tiers and presets ignore both tables.

| Tier | Transcription | Speakers | Voice profiles | Summaries |
| --- | --- | --- | --- | --- |
| small (4 GB) | Parakeet Redux, then Ultra | Nemotron 3 · Compact, then Community-1 | Community-1 | none |
| medium (6 GB) | Parakeet Ultra, then Redux | Nemotron 3 · Compact, then offline, then Community-1 | Community-1 | none |
| standard (8 GB) | Parakeet Ultra, then Redux | Nemotron 3 (offline), then Compact, then Community-1 | Community-1 | Gemma 4 E2B |
| large (12 GB and more) | Parakeet Ultra, then Redux | Nemotron 3 (offline), then Compact, then Community-1 | Community-1 | Gemma 4 E4B, then E2B |

**Summaries and memory.** iOS ends an app that goes past its memory limit, so a summary model is offered (`PhoneProcessingModels.fits`) only when its peak, `capabilities.memoryGB`, plus `headroomGB` (1 GB: the app, audio buffers, MLX's 256 MB buffer cache) fits in that limit. The peaks are measured with weights included: E4B 5.0 GB on the three-hour meeting, E2B 3.0 GB on the 22-minute weekly ([validation](validation.md), 2026-10-31), declared as 3.2 to allow for a three-hour meeting's KV cache (6 KB a token). The language model is exclusive, so the speech models aren't loaded beside it. The limit is read on the device as the app runs (`PhoneMemory`: `os_proc_available_memory` plus the app's footprint); where it can't be (the simulator, tests), `AppMemoryLimit.estimate` uses published figures: about 45% of the phone's memory, 70% with the Increased Memory Limit entitlement. So an 8 GB iPhone (about 3.6 GB, or 5.6 with the entitlement) summarizes with E2B only with the entitlement, and a 12 GB one (5.4, or 8.4) gets E2B without it and E4B with it. The app doesn't have the entitlement yet (it needs the account owner); the device's own reading decides either way.

The speech and speaker models fit every tier: Parakeet Ultra is a 632 MB download and Redux 220 MB, Nemotron 3 199 MB (Compact 102 MB), Community-1 22 MB. On the iPhone they run on the Neural Engine and CPU (`MLComputeUnits.processing`), as live captions' do, so they keep working in the background. Settings › Models lists, per role, the models any tier names (`PhoneProcessingModels.options`), and shows what can't run with the reason ("Needs an iPhone with more memory").

`ProcessingCapabilities.models` names the model the iPhone would use for each role it can run, and each result records its model, so an "Upgrade" offer compares an iPhone's transcript with a Mac's model ("Quality ranks", above; [multipoint](multipoint.md#upgrade)).

## Photos

The `imageDescription` role uses Apple Vision by default (`apple-vision/system`, engine `appleVision`): OCR, labels, sharpness, and near-duplicate detection, with no download. Gemma 4 E2B and E4B also serve this role through MLXVLM and the existing installation. Their optional captions retain exact provenance; Vision remains the fallback. See [Photos](photos.md#local-understanding).

## Cloud models

Summaries can also run on a cloud model ([cloud](cloud.md)); nothing else does. `CloudCatalog.json` (DaybookKit) is the cloud's counterpart to the manifest, slimmer: family rules that place a model ID in a tier (Best: Claude Opus, GPT Astra; Balanced: Claude Sonnet, GPT Sol; Economy: Claude Haiku, GPT Terra and Luna), and, for the models measured on our prompt, their rank within the tier, a `summaryQuality` (0–100, the scale the local summary models share for "Upgrade" offers: Gemma 4 26B A4B is 90 and E4B 53 on it; "Quality ranks", above), and how many tokens they write. Prices come from OpenRouter's model list, kept a day, over a bundled snapshot (`CloudPrices.json`). What's offered is what a person's key reaches: the measured models, newer versions of their families, and "-pro" variants a provider lists.

## What the next changes touch

| Change | What to do | Pipeline edits |
| --- | --- | --- |
| Parakeet Ultra, Nemotron 3 | **Done** (above). Language routing was the one pipeline addition: `TranscriptionRouter` inside `InferenceProcessingEngine.transcribe`, with its decisions in DaybookKit | Language routing |
| ~~Nemotron 3 for live speakers~~ | Done: `nemotron-3-diarization/live` (`fast32-split-w8a8`) for `liveDiarization` on the Mac and the iPhone ("Live models") | Live captions (DaybookLive) |
| ~~Glossary for live captions~~ | Done: the approved vocabulary biases the streaming decoder (`LiveVocabulary`, `setCustomVocabulary`), applied when a capture starts and whenever it changes (docs/model-runtime.md, "Live") | None |
| ~~Forcing Whisper's language~~ | Done: `WhisperKitTranscriber` takes the hint (`DecodingOptions.language`) and otherwise turns on `detectLanguage`. Before this, WhisperKit's defaults (prefill on, detection off) prefilled English, so Whisper never detected a language | None |
| ~~mlx-swift-lm 3.32.3, argmax-oss-swift 1.1.1~~ | Done: engines `mlxLanguage` 2 and `whisperKit` 2 (above) | None |
| ~~Gemma 4, Qwen 3.x~~ | Done: `gemma-4`, `qwen3.5`, `qwen3.6` families with `minimumEngineVersion: 2`; presets updated | None |
| ~~Constrained JSON output~~ | Done: `structuredOutput: true` variants are constrained to `MeetingSynthesis.summarySchema` and `actionSchema` through MLXGuidedGeneration (XGrammar); a failed or unparseable constrained reply falls back to the free-form prompt and parsing | None |
| ~~Apple Foundation Models~~ | Done: `AppleFoundationModelsEngine` serving `smallTasks` (above) | The small-tasks step |
| Prefill once, ask many | Fork the transcript's prompt cache for each extraction pass (mlx-swift-lm 3.x `ChatSession` cache reuse) | None |
| Qwen3-ASR through MLX audio | An `MLXAudioEngine` (`.mlxAudio`, `Transcribing`, exclusive residency) with the forced aligner as a second artifact; manifest entries with `minimumEngineVersion` | None |
| The model manager | Built (above). It reads `ModelCatalog` (origin, availability, revisions), `ModelStore` (inventory, `diskUsage`, pins, leases, `removeLegacyLeftovers`), and `LocalIntelligenceRuntime` (`remove`, `addModel` after `previewAddition`, `removeAddedModel`, `checkForUpdates` and `recordUpdate`, `collectGarbage`); downloads go through the app's queue. Results per model come from `ProcessingSettings.model` | None |
