# Models

Daybook's model system is modular. **Engines** are code that knows how to verify, load, and run one kind of model. **Models** are data, described in manifests and run by an engine. Updating a model never means editing the pipeline. A new quantization or revision of an existing model is a manifest change. A completely new model is a manifest entry, plus a new engine only when no existing engine can run it.

This page is the architecture as built. Where it differs from the plan agreed earlier, the difference and the reason are marked **Deviation**. [Embedded local models](model-runtime.md) covers what each engine does at run time, offline loading, and validation.

## Vocabulary

| Term | Meaning | Example |
| --- | --- | --- |
| **Role** | What the pipeline needs done | `transcription`, `diarization`, `speakerEmbedding`, `summarization`, `smallTasks` |
| **Engine** | Code that runs models for one or more roles | `whisperKit`, `parakeet`, `community1`, `nemotronDiarizer`, `sortformer`, `mlxLanguage`, `appleFoundationModels`; next: `mlxAudio` |
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
| `DaybookKit` (Mac and iPhone) | The manifest format (`ModelManifest`, `ModelManifestReader`), the built-in `Resources/ModelCatalog` folder, the merged `ModelCatalog` and `CatalogModel`, availability, `ModelSelections`, `ModelRecommendations` (presets, device tiers), `ModelRouting` (with speaker routing), `TranscriptionRouting` and `LanguageCheck` (language routing), `ModelAcknowledgements`, and the shared vocabulary (`ModelRole`, `ModelEngineID`, `ModelEngineDescriptor`, `ModelReference`, `ModelVersion`) |
| `DaybookIntelligence` (Mac today) | The `ModelEngine` protocol, role protocols, `ModelEngineRegistry`, the seven engines, `TranscriptionRouter`, `MeetingSynthesis` and `SmallTasks`, `ModelStore` and legacy migration, `ModelArtifactFetcher`, `ModelHubClient`, `ModelUpdateChecker`, model addition, and `LocalIntelligenceRuntime`, which coordinates them |

The iPhone links DaybookKit, so it names the model behind any result (Conversation Info) and can list acknowledgements. It registers no engines yet.

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
| `nemotronDiarizer` | 1 | diarization | FluidAudio 0.17.7 | shared | Nemotron 3 Diarization (`engineOptions.preset`: `offline`, or a split W8A8 build such as `c128-split-w8a8`); eight speakers, no embeddings |
| `sortformer` | 1 | diarization | FluidAudio 0.17.7 | shared | `engineOptions.precision` (`palettized` or `fp16`); four speakers, no embeddings |
| `mlxLanguage` | 2 | summarization | mlx-swift-lm 3.32.3 (mlx-swift 0.32.3) | exclusive | Any `model_type` the pinned mlx-swift-lm registers (`LLMTypeRegistry`); `engineOptions.thinking`; constrained JSON when the variant declares `structuredOutput` |
| `appleFoundationModels` | 1 | smallTasks | Foundation Models (the OS version) | system | `systemProvided` variants; available on macOS 26 / iOS 26 and later with Apple Intelligence on |

Version 1 of `whisperKit` was WhisperKit 0.18.0 and version 1 of `mlxLanguage` was mlx-swift-lm 2.29.3. Results keep the engine version they recorded (`"1 (WhisperKit 0.18.0)"`) and still resolve to their variant, which is matched by family and variant, never by engine version.

**Deviation:** `appleFoundationModels` serves `smallTasks` only, not `summarization` as the plan suggested: its context is 8,192 tokens on macOS 27 (4,096 on 26), and in the October research it invented and misattributed an action item on a 6K-token meeting. It runs before the summary, from a bounded excerpt (below). **Deviation:** because Apple Intelligence can be turned on or off while Daybook runs, the AFM engine's descriptor is computed each time it's read, and `LocalIntelligenceRuntime.engines` reads the registry afresh rather than once at launch.

**Deviation:** the plan named one `fluidDiarization` engine. Community-1, Sortformer, and Nemotron load different artifacts, take different options, and have different capabilities, so they are three engines. **Deviation:** Community-1's voice embeddings come out of diarization, so it declares the `diarization` role and the `voiceEmbeddings` capability; it also serves `speakerEmbedding` (`EmbeddingVoices`) for diarizers without embeddings (Nemotron), see "Routing".

## Manifests

- **Built-in catalog:** `Sources/DaybookKit/Resources/ModelCatalog/`, a package resource of DaybookKit, shipped with each release. `Catalog.json` holds the presets, the recommended preset per tier, and the initial selection. `Families/<family>.json` holds one family each, as a complete manifest. Adding a model family is adding a file. Each file declares its own `minimumReaderVersion`, so a family that needs a newer reader is skipped with a warning while the rest load. Families load in file-name order; the interface sorts as it needs (acknowledgements are alphabetical).
- **The person's manifest:** `Models/UserModels.json`, beside the store, in the same format. It holds models added from Hugging Face ("Added by you") and revisions installed through update checks. `ModelCatalog` merges it into the built-in catalog: a family or variant with a built-in ID only gains variants or revisions; built-in metadata is never overridden. Presets come from the built-in manifest only.
- **Revision checks (opt-in):** `LocalIntelligenceRuntime.checkForUpdates(client:)` asks Hugging Face, through an injectable `ModelHubClient`, whether each installed variant's tracked branch (`artifact.track`, default `main`) moved, and whether the files its `include` patterns select actually changed. It returns `ModelUpdate`s with the changed files, the size, and the publication date. Daybook never installs one by itself; `installUpdate(_:)` records the revision in the person's manifest and downloads it.

### Format (schema 1)

```text
ModelManifest       schemaVersion, minimumReaderVersion, catalogVersion,
                    families[], presets[], recommendedPreset, initialSelection
ModelFamilyEntry    id, name, maker, engine, roles[], summary, homepage, license, variants[]
ModelVariantEntry   id, name, detail, engine?, roles?, license?, homepage, releaseDate,
                    recommendedMemoryGB, capabilities, engineOptions{},
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

**Licenses.** Daybook's code is MIT. Each model keeps its own license and declares it in its manifest entry; `allowsCommercialUse: false` is labelled "Non-commercial" wherever a model is chosen. The built-in entries: Whisper, MIT (OpenAI's release; Argmax's Core ML conversion is MIT too; the Hugging Face cards for base and small say Apache-2.0, for the Transformers port); Gemma 4, Apache-2.0 (Google's card links https://ai.google.dev/gemma/docs/gemma_4_license; mlx-community's E2B/E4B cards still carry stale "gemma" metadata, so the entry cites the upstream card); Qwen 3.5 and 3.6, Apache-2.0; Qwen 2.5 1.5B and 7B, Apache-2.0; Qwen 2.5 3B, the Qwen Research License (non-commercial); Apple Foundation Models, Apple's acceptable use requirements (a system model, nothing redistributed); Community-1, CC BY 4.0 as scoped by FluidInference's NOTICE.md; Sortformer 2.1, the NVIDIA Open Model License with NVIDIA's required notice, and CC BY 4.0 for the conversion; Parakeet Ultra and Redux, CC BY 4.0 (Moondream's post-trains of NVIDIA's parakeet-tdt-0.6b-v3), with the Core ML conversion named as the change; Nemotron 3 Diarization, the OpenMDW License 1.1, whose full text ships in `THIRD_PARTY_NOTICES.md` because the Hugging Face repository has no LICENSE file. `ModelAcknowledgements.list(from:only:)` builds the acknowledgements from the manifests (the Mac's About Daybook panel and Settings › Models › Acknowledgements; the iPhone's Settings › About › Acknowledgements): one entry per family and license, with the license name, link, required attribution, and the non-commercial label.

## Selection, updates, and provenance

- **What a selection names:** per role, a variant key, never a raw revision (`ModelSelections`). It resolves to the newest verified installed revision (`ModelInventory.resolve`).
- **Presets:** Quick, Balanced, and Detailed per device tier, read from the manifest's `presets` through `ModelRecommendations`. Each role lists choices best first, with optional per-tier overrides; the first choice this build can run is the preset's model. `recommendedPreset` and `initialSelection` say what a tier starts with. **Deviation:** presets are manifest data rather than Swift, so a new default model is a manifest edit. Parakeet Ultra is every preset's first transcription choice (Whisper follows as the fallback). Balanced and Detailed tell speakers apart with Nemotron 3, Community-1 next, and every preset names Community-1 for `speakerEmbedding`. Quick keeps Community-1 first: it makes turns and voice profiles in one pass and one 22 MB download, and no real-recording evaluation yet shows Nemotron better for it. `initialSelection` starts with Parakeet Ultra and keeps Community-1 for speakers, so a first launch needs no second speaker model.
- **Summaries by tier** (catalog 2026.10.24, after the MLX 3 upgrade): Gemma 4 is every list's first choice, the Qwen 3.5/3.6 alternates follow, and the superseded Qwen 2.5 variants come last, so an installed one still stands in when another model is removed and nothing installed stops working.

  | Tier | Quick | Balanced | Detailed | First launch |
  | --- | --- | --- | --- | --- |
  | compact (< 16 GB) | Gemma 4 E2B | Gemma 4 E4B | Gemma 4 E4B | E2B |
  | standard (16–31 GB) | Gemma 4 E4B | Gemma 4 12B | Gemma 4 12B | 12B |
  | large (32–63 GB) | Gemma 4 E4B | Gemma 4 26B A4B | Gemma 4 26B A4B | 26B A4B |
  | workstation (64 GB+) | Gemma 4 12B | Gemma 4 26B A4B | Gemma 4 31B 8-bit | 26B A4B |

  Small tasks start with Apple Foundation Models in every preset and in `initialSelection`. Where it isn't available, `ModelRecommendations` passes over it given the engines, and AppState only hands it to a job while it's usable (`installedModels`), so the summarizer keeps naming conversations as before.
- **Queued jobs freeze exact revisions** (`ProcessingJob.revisions`), so an update installed while they wait never changes what they run.
- **Updating a variant:** a new revision downloads beside the old one, is verified, and appears with one atomic rename; from then on selections resolve to it. The old revision stays until nothing selects, runs, queues, or pins it, then garbage collection removes it.
- **Removing a selected model** falls back to the preset's next installed choice, with a notice saying so, or keeps the choice and shows "Download" (`ModelSelections.removing`). Processing never silently switches models: a job whose frozen revision is gone fails with "Download … in Models" rather than running another one.
- **Provenance:** every transcript, speaker run, and summary records the exact family, variant, revision, engine, and engine version in `ProcessingSettings.model`, and the variant key in `modelID`. A model the catalog no longer lists, or one only another device had, is still named from the recorded provenance.
- **Migration:** before the model system, Daybook stored catalog IDs (`whisper-base`, `qwen-7b`, `speaker-community-1`, …). Each built-in revision's `legacy.ids` is the migration table: stored preferences map through it once at launch (`ModelSelections.migrating`; the old keys are left for an older build), and old results still resolve to their variant and exact revision (`ModelCatalog.provenance(of:modelID:)`, engine version "legacy").

## Routing

Jobs are routed when they're queued (`AppState.speechRoute`), and the result is frozen into the job like its models.

- **Language routing.** `ProcessingPreferences.transcriptionLanguage` is a BCP-47 code or nil for Automatic; `otherLanguagesModelID` is the model for languages the transcription model doesn't cover (nil picks one: the person's choice if it covers more, else the best model covering every language, installed first, in Detailed's order; today Whisper Large v3 Turbo). `TranscriptionRouting.route` reads the `languages` capability (nil or `["*"]` covers every language):
  - A chosen language the selected model covers runs that model with the language as a hint. One it doesn't cover runs the other-languages model instead (the job's `transcriptionModelID`), which then has to be installed.
  - Automatic with a model that covers some languages adds a language check (`ProcessingJob.languageFallbackModelID`, optional: it never blocks a job). `TranscriptionRouter` transcribes with the selected model, then reads the transcript's language with `NLLanguageRecognizer` (`TranscriptLanguageDetector`) and the mean word confidence (`LanguageCheck.verdict`). A confident covered language keeps the transcript. A clear other language, or an unclear one (top guess under 0.6, or mean confidence under 0.5), runs the other-languages model too, and its own spoken-language detection decides: the second transcript is kept unless it hears a language the first model covers. A model that doesn't cover a language still writes words in the scripts it knows, with low confidence (Parakeet on Japanese speech: top guess Indonesian at 0.26, mean confidence 0.36), so text alone can't be trusted to name the language; Whisper's audio-based detection settles it without editing `WhisperKitEngine`. If the other model isn't installed, the first transcript stays, with a notice when it's probably another language.
  - The transcript records the model that actually produced it (`modelID`, `ProcessingSettings.model`) and the decision in its parameters: `language`, `languageCheck` (`kept`, `switched`, `unavailable`), `detectedLanguage`, and `routedFrom`.
- **Speaker routing.** `ModelRouting.diarizer`: an expected speaker count above the selected model's `maxSpeakers` (Nemotron's 8) runs an installed speaker model without that limit, preferring one that takes a count (Community-1); with none installed the selected model runs and says so. The person's choice is unchanged.
- **Voice profiles.** `ModelRouting.voiceEmbedder` picks the `speakerEmbedding` model when the speaker model has no `voiceEmbeddings` (Nemotron). Selections saved before the role had a built-in model take the catalog's initial choice (`ModelRouting.withDefaultVoiceEmbedder`), Community-1. As `EmbeddingVoices`, Community-1 takes each speaker's stretches of solo speech (at least 1 s, at most twelve 10-second pieces, longest first; the longest turn of at least 0.5 s when a speaker never talks alone) through its own FBank and WeSpeaker ResNet34 models, repeating each span to fill the 10-second window as FluidAudio's `embedSpan` does, and averages the raw embeddings by duration, as its own speaker centroids are. The vectors keep the embedding space `fluid-community1-embedding-df2625ac79a7ac6b`, so profiles from Community-1 runs and Nemotron runs compare. **Deviation:** FluidAudio's public `embedSpans` isn't in 0.17.7, and its `embedSpan` is internal, so `WeSpeakerSpanEmbedder` reproduces it (including the silence-aware FBank re-centering) over the public Core ML models; switch to `embedSpans` when FluidAudio releases it. The embedder is required like the speaker model: a Nemotron job waits for Community-1 if it isn't installed.

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

- **Shared code:** the manifest, catalog, selection, and provenance types are in DaybookKit and DaybookCore, so the iPhone shows what produced a result and can later run engines itself.
- **Engines** are in DaybookIntelligence: the Mac today, iOS-capable later. Each declares its platforms; availability is `unsupportedPlatform` ("Not available on iPhone") where an engine doesn't run.
- **System models:** a variant with `systemProvided: true` has no revisions; nothing is downloaded or removed, and its engine decides whether this device has it: its descriptor's `unavailableReason` becomes `ModelAvailability.unavailableOnDevice` ("Turn on Apple Intelligence", "Needs macOS 26 or later", "Not available on this Mac", "Apple Intelligence isn’t ready yet"), and `validate` refuses it. `installedModels()` includes a system model only while it's available.

## The model manager

Settings › Models is built from the catalog and the engines this build registers. It has no list of models, engines, or roles of its own, so a new family, variant, engine, or role appears without interface code. `ModelManagerSnapshot` (`Sources/Daybook/App/ModelManager.swift`) turns plain inputs into everything the pane shows: the catalog, the engine descriptors, what's installed, the selections, the download queue, and update results. Tests build it from a synthetic catalog. `ModelManager` keeps what's on disk (inventory, disk use, protected revisions, results per model) and carries out actions through `LocalIntelligenceRuntime` and the app's download queue, so a download from the manager waits for processing and cancels like any other.

The pane, top to bottom:

- **Quality:**
  - Quick, Balanced, and Detailed from `ModelRecommendations`, each with its models, total download, and suggested memory. The one the catalog recommends for this Mac's tier is marked "Recommended".
  - A preset sets every role it names, and its speaker effort. Any other combination reads "Custom".
  - A row under them speaks only while the chosen models aren't all on this Mac: Download with the size, or progress and Cancel.
- **Role choices:**
  - One pop-up per role. Transcription carries the language rows from `TranscriptionLanguageSettings`. Speakers has the speaker model and, when a model serves it, voice profiles, then the speaker settings, enabled by capabilities. Summaries has summaries, plus titles and tags.
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

Debug builds take `--model-demo <step,…>` (`ModelDemo`) to show any state against synthetic installs, with a download that stalls and a scripted Hugging Face, never the network: `preset:`, `use:<role>=<key>`, `downloading:<key>`, `updates:<key>`, `add`, `details:<key>`, `remove:<key>`, `acknowledgements`, `about`, `scroll:library|updates|family:<id>`.

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
3. Prompt settings are `engineOptions`: `"thinking": "off"` sets the chat template's `enable_thinking` to false (Qwen 3.x reasons by default; Gemma 4 only when asked), and any `<think>…</think>` or `<|channel>…<channel|>` block that still appears is removed from replies. Declare `structuredOutput: true` to have summaries constrained to their JSON schema. A new setting is an engine change, not a pipeline change.
4. Add it to the presets in `Catalog.json` if it should be a default.

### A new speech engine: Parakeet through FluidAudio (as built)

FluidAudio 0.17.7 already contained Parakeet Ultra (`AsrModelVersion.ultra`), so this took one type, one registration, and data:

1. **One type:** `Sources/DaybookIntelligence/Engines/ParakeetEngine.swift`, `struct ParakeetEngine: ModelEngine` (`.parakeet`, transcription, `FluidAudio 0.17.7`, macOS and iOS, shared). `validate` requires `Preprocessor`, `Encoder`, `Decoder`, and `JointDecisionv3` bundles and `parakeet_vocab.json`; a fresh install must also have every vocabulary token below the blank ID. `load` calls `AsrModels.loadLocal(from:version:)` on the install's folder. Each transcription gets a fresh `AsrManager`, which reads files longer than 30 s from disk in 15 s windows (FluidAudio's long-form path); recordings with several channels are mixed down first, since FluidAudio keeps only the first. `ParakeetWords` merges SentencePiece tokens into words with Whisper's leading-space convention, gives each word at least one 80 ms encoder frame (so it overlaps a speaker turn), and groups words into passages at sentence ends, pauses of 1 s, and 30 s. A word's confidence is the **minimum** of its sub-word tokens' confidences, punctuation excluded: a word is wrong when any piece is, the mean would hide one doubtful piece, and the product would mark long words down for their length, which would make ROVER prefer another recognizer's shorter split.
2. **One registration:** `ParakeetEngine()` in `ModelEngineRegistry.standard`.
3. **Manifest:** `Families/parakeet.json`, family `parakeet` (CC BY 4.0, with attribution naming Moondream, NVIDIA's v3, and the Core ML conversion as the change), variants `ultra` (`FluidInference/parakeet-ultra-coreml` at `95eaa59…`, 632 MB) and `redux` (`FluidInference/parakeet-redux-coreml` at `8c5ef97…`, 220 MB, the 2-bit build; not in a preset), each with the 25 `languages`, `wordTimestamps`, `wordConfidence`, `vocabularyPrompt: false`. **Deviation:** the variant is `ultra`, not `ultra-coreml`: every variant here is a Core ML build, so the suffix adds nothing.
4. **Tests:** `SpeechEngineTests` (token merging, passages, installs against synthetic files, additions against `FakeHubClient`), plus the registry and catalog tests.

**Nemotron 3 Diarization** is the same shape: `NemotronDiarizerEngine` (`.nemotronDiarizer`, `Diarizing`) and `Families/nemotron-3-diarization.json` with variants `offline` (the 30.4 s batch preset in `monolithic/v2/`, 199 MB) and `compact` (the split-graph W8A8 build `c128-split-w8a8`, 102 MB including the host-side projection, which FluidInference reports runs entirely on the Neural Engine; not in a preset), both `maxSpeakers: 8` without `voiceEmbeddings`, from `FluidInference/nemotron-3-diarization-coreml` at `25a90f9…` (the general-access weights). Each run reads the recording in 30 s blocks through one converter into FluidAudio's streaming path (`appendAudio` / `processBufferedAudio` / `finishStream`, frame-exact with `processComplete` but without holding the whole recording), and `SpeakerActivity` turns the 10 ms probabilities into turns as they arrive: active above 0.5, same-speaker gaps under 0.25 s bridged, turns under 0.2 s dropped. Voice profiles come from Community-1 (see "Routing").

## Photos

The `imageDescription` role uses Apple Vision by default (`apple-vision/system`, engine `appleVision`): OCR, labels, sharpness, and near-duplicate detection, with no download. Gemma 4 E2B and E4B also serve this role through MLXVLM and the existing installation. Their optional captions retain exact provenance; Vision remains the fallback. See [Photos](photos.md#local-understanding).

## What the next changes touch

| Change | What to do | Pipeline edits |
| --- | --- | --- |
| Parakeet Ultra, Nemotron 3 | **Done** (above). Language routing was the one pipeline addition: `TranscriptionRouter` inside `InferenceProcessingEngine.transcribe`, with its decisions in DaybookKit | Language routing |
| Nemotron 3 for live speakers | Use Nemotron's streaming presets (`low`, 1.04 s; `fast32`, 2.88 s, the card's recommended default) in place of Sortformer v2.1 when live diarization is wired: eight speakers instead of four, AMI DER 9.75 vs Sortformer's 15.81 (NVIDIA card), and the same streaming API this engine already drives. Sortformer stays in the catalog until that ships | Live diarization |
| ~~Forcing Whisper's language~~ | Done: `WhisperKitTranscriber` takes the hint (`DecodingOptions.language`) and otherwise turns on `detectLanguage`. Before this, WhisperKit's defaults (prefill on, detection off) prefilled English, so Whisper never detected a language | None |
| ~~mlx-swift-lm 3.32.3, argmax-oss-swift 1.1.1~~ | Done: engines `mlxLanguage` 2 and `whisperKit` 2 (above) | None |
| ~~Gemma 4, Qwen 3.x~~ | Done: `gemma-4`, `qwen3.5`, `qwen3.6` families with `minimumEngineVersion: 2`; presets updated | None |
| ~~Constrained JSON output~~ | Done: `structuredOutput: true` variants are constrained to `MeetingSynthesis.summarySchema` and `actionSchema` through MLXGuidedGeneration (XGrammar); a failed or unparseable constrained reply falls back to the free-form prompt and parsing | None |
| ~~Apple Foundation Models~~ | Done: `AppleFoundationModelsEngine` serving `smallTasks` (above) | The small-tasks step |
| Prefill once, ask many | Fork the transcript's prompt cache for each extraction pass (mlx-swift-lm 3.x `ChatSession` cache reuse) | None |
| Qwen3-ASR through MLX audio | An `MLXAudioEngine` (`.mlxAudio`, `Transcribing`, exclusive residency) with the forced aligner as a second artifact; manifest entries with `minimumEngineVersion` | None |
| The model manager | Built (above). It reads `ModelCatalog` (origin, availability, revisions), `ModelStore` (inventory, `diskUsage`, pins, leases, `removeLegacyLeftovers`), and `LocalIntelligenceRuntime` (`remove`, `addModel` after `previewAddition`, `removeAddedModel`, `checkForUpdates` and `recordUpdate`, `collectGarbage`); downloads go through the app's queue. Results per model come from `ProcessingSettings.model` | None |
