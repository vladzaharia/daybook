# Validation record

## Security review fixes (2026-10-25)

Still requires real devices:

- **Link on a real network.** Pair and connect a phone and a Mac on ordinary Wi-Fi, over IPv4 and
  over IPv6 (including a network that hands out global IPv6 addresses), to confirm the listener's
  local-network check never drops a phone on the same network. A Mac with a public address should
  not be reachable from another network.
- **Floating Notes in screen shares.** On macOS 15 and macOS 26, share the entire screen and then
  just a window in Zoom, Google Meet (in Safari and in Chrome), and Microsoft Teams while Floating
  Notes shows notes and live captions over the call: the other side must not see the panel, and
  neither may a screenshot (⇧⌘3, ⇧⌘5) or a QuickTime screen recording. ScreenCaptureKit decides
  whether to honour `sharingType = .none`; if an app still captures the panel on a macOS version,
  record it here and hide the panel while that app shares.
- **Exported photos.** Export (Mac) and share as Markdown (iPhone) a conversation with a geotagged
  HEIC taken by an iPhone camera and a portrait JPEG: `exiftool` shows no GPS, MakerApple, Make,
  Model, or Software in the exported files, the portrait one still opens upright, the capture date
  is kept, and the library's originals are unchanged (same digest).
- **Mac keychain move.** With a signed build of the previous version paired to a phone, install the
  new build: the pairing keeps connecting with no keychain prompt, and Keychain Access no longer
  lists a "Daybook link" item in the login keychain. An ad hoc build keeps using the login keychain.

## Project review fixes (2026-10-25)

The review covered persistence and sync, local pairing, model downloads, recorder integration,
iPhone capture, and release checks. Regression tests now cover:

- Pairing cancelled, replaced, expired, or stopped during an exchange cannot save a peer key.
  Authenticated peers advertising invalid heartbeat intervals are disconnected without a timer overflow.
- Failed saves keep capture staging and recovery data. Filing waits for a successful persistence
  barrier, and the iPhone reports an unavailable durable library instead of switching to temporary storage.
- Deleted bookmarks stay deleted through unrelated concurrent edits; delete/edit conflicts retain
  deterministic history. Shared sync ancestors are visited once, including merge diamonds, and
  cancellation reaches an active engine pass. A cancelled pass can be retried without acknowledging it.
- Soundcore Stop works during setup and while queued behind another transfer. A Bluetooth reset
  invalidates the old session and reconnects. An iPhone media-services reset cannot restart input
  after Stop has begun.
- Folder exports use content digests, distinguishing equal names and sizes while offering identical
  copies once. Existing tracks provide digest aliases. Old completion records without digests adopt
  the first matching stable file once; their historical name/size ambiguity cannot be reconstructed.
- Photo deduplication verifies stored original bytes. Reimporting after corruption preserves the
  damaged original and saves a healthy copy. Model configuration reads enforce their byte limit while
  streaming, including responses without a declared length.

Release jobs now require the reusable CI workflow to succeed for the release commit. CI includes
the captions test bundle. No release was published during this review.

Final verification on Apple silicon with Xcode 27.1 / Swift 6.4:

- `swift test`: 699 XCTest cases passed across all seven test bundles.
- `scripts/build-ios.sh --test --test-arg -parallel-testing-enabled --test-arg NO`: 79 tests passed
  on the iPhone simulator.
- `scripts/ci/tests/run-tests.sh`: 70 offline release-helper checks passed.
- `actionlint`, `shellcheck scripts/build-ios.sh scripts/ci/*.sh scripts/ci/tests/*.sh`, and
  `git diff --check` passed. No model weights or personal recordings were used.

Hardware limitations remain: no physical Soundcore recorder, Bluetooth radio reset, microphone route
change, or signed CloudKit background delivery was exercised. Native-codec probes demonstrated that
trimming valid trailing zero bytes changes decoded audio; feeding the entire unframed padded slot also
changes it. Exact firmware packet boundaries are still needed. The reverse-engineered Soundcore
handshake exposes its audio encryption secret, and BLE link protection has not been verified. These
two protocol issues remain unresolved; the integration's technical notes and [protocol documentation](direct-soundcore.md)
now state them explicitly. Keep recorder originals and use file export for important recordings.

## iPhone camera and notes (2026-10-25)

- `scripts/build-ios.sh --test`: 86 tests passed. New coverage: a photo taken while recording keeps its shutter time (not the moment the review screen was accepted), lands in the journal, and survives a quit; a photo after Stop isn't kept with the recording; camera encoding keeps the EXIF shutter moment and orientation; filing anchors photos to the phone's track and never duplicates them on a retry; a photo taken as a Mac stops the recording joins the filed conversation; photos sit between notes and bookmarks in the recording's timeline; New Note makes a conversation without audio in the place being viewed.
- Duo simulator screenshots of the pocket recorder, table mode (book and flex, with and without Write Notes), and the library's New Note. The simulator has no camera, so the camera button is disabled there and Take Photo is hidden.

Still requires a real iPhone: taking photos with the system camera while recording (that the microphone keeps recording with no interruption, and the shutter time from real EXIF), the camera permission prompt, and Write Notes with the keyboard in flex mode on folding hardware.

## Photos (2026-10-25)

Recovered the unfinished Mac photo feature and completed iPhone import/viewing against the current CloudKit courier code.

- Full `swift test`: 684 tests passed before the final runtime, courier-photo, and queue-ordering regressions were added. All 50 focused photo, courier inbox, processing queue, and model-selection tests then passed on the final code.
- iPhone simulator build and `DaybookPhoneTests/ReadingTests`: 22 tests passed. Coverage includes image import, local/missing originals, thumbnail decoding, timed transcript entries, and a ZIP export containing Markdown and photos.
- Synthetic photo tests cover old-library decoding, byte-preserving imports, EXIF rotation/time zones, duplicate imports, restoration, concurrent edits, deterministic analysis ties, timeline/drift placement, summary evidence, OCR, image quality, and model provenance/fallback.
- The real `LocalIntelligenceRuntime` read a synthetic image through Apple Vision without installing models. Mac demo processing saved all four analyses, placed the three informative images under Budget, Hiring, and Packaging, and excluded the blurred image.
- Inspected Mac summary/viewer screenshots and the iPhone Duo cover-display importer, viewer, and transcript. Local screenshots are under ignored `build/photo-review/`. The inactive Duo display produces black screenshots; the cover uses `simctl io <device> screenshot --display=1`.

```sh
swift test
swift test --filter 'Photo|LibrarySyncInboxTests|ProcessingRequestQueueTests|ModelPreferenceMigrationTests'
scripts/build-ios.sh --test --test-arg -only-testing:DaybookPhoneTests/ReadingTests
```

Still requires real-device acceptance: choosing HEIC originals from an iCloud Photos library, Continuity Camera delivery, background/offline photo transfers through the signed CloudKit container, and richer captions from actual Gemma 4 VLM weights. No model weights were downloaded, no surroundings were recorded, and no personal photos were used for these checks.

## Earlier validation

Run on 2026-10-23 on Apple silicon, macOS 27.0, Xcode 27.1 / Swift 6.4, 64 GB memory. The deployment target is macOS 15; earlier supported OS releases have not been exercised on separate hardware.

## Automated tests

`swift test` passed 157 XCTest cases: 86 core and 71 application tests. Swift Testing reports zero tests separately because these suites use XCTest; that does not replace the XCTest results.

Coverage includes:

- Durable metadata round trips, atomic recovery copies, corrupt and newer-schema handling, digest deduplication, altered/missing original recovery, path and symlink rejection, highlight schema, trash and stale-save rejection.
- Offset and clock-drift estimation, stable timeline origin, explicit/negative offsets, insufficient/repeated anchors, short replies, contradictory variants, retained provenance, and user corrections after source preference changes.
- Two independent app libraries exchanging byte-identical recordings, folder/tag/template/vocabulary data, concurrent offline edits, paired transcript/alignment and note/timestamp conflicts, deletion tombstones, interrupted apply/acknowledgment, account-change invalidation, idle-loop prevention, and damaged sync objects.
- Note paragraph anchors, exact timeline-to-source seeking, model/configuration snapshots, speaker embedding compatibility, and conservative correction transfer.
- Devices (see below): Soundcore packet/checksum fixtures and parser fuzzing, P-256/HKDF/AES-CTR vectors, native Opus encode/decode with generated audio, the full Soundcore connection against a simulated recorder, the import queue, library identity, migration, and the files method.
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

## Model system

Run on 2026-10-24 (docs/models.md). The full `swift test` suite passed 512 XCTest cases: the 463 that passed before, and 49 model-system cases using synthetic files with real digests, a fake fetcher, and a scripted Hugging Face client. They cover manifest reading (round trip, unknown fields, a newer schema, unsafe entries), availability ("Needs a newer Daybook"), selections and their migration from stored catalog IDs, presets, removal fallbacks, capability routing, legacy provenance, acknowledgements, verified and atomic installs, resumed downloads, side-by-side revisions and garbage collection, legacy-layout migration (no download, idempotent, resumable, mismatches left in place), engine residency, models added for each engine kind (the MLX check instantiates a real Qwen2 architecture), and the update flow. `scripts/build-ios.sh` built the iPhone app, and a debug ad hoc Mac build packaged `Daybook_DaybookKit.bundle` with ModelCatalog.json; its `--smoke-test` against an empty models folder read the built-in catalog and reported the missing models without writing anything.

Still requiring a real run, because no model weights were downloaded:

- Migration of an existing pre-model-system `Models/` folder on a Mac that already has models: every file must match the catalog's digests, so a launch should report nothing to download again and leave no `Models/<catalog ID>/` folders.
- The smoke test with `--download-models`, then again with networking denied, on the new store layout.
- An update check against Hugging Face with a real repository that has moved.

## Speech models: Parakeet Ultra, Nemotron 3, and language routing

Run on 2026-10-24 on an M5 Pro with 64 GB, macOS 27.0, Swift 6.4 (docs/models.md, "Routing").

**Automated.** `swift test` passed 578 XCTest cases: the 528 that passed before (twelve of them updated for the new presets, the catalog's new keys, and the registry) and 50 new ones. They cover the scoring math on synthetic references (WER, CER, alignment, cpWER with extra and missing speakers, DER with misses, false alarms, confusion, overlapping speech, collars, and empty references, JER, word-timing error, Hungarian assignment, STM/RTTM/CTM parsing); language routing (code normalization, coverage, a chosen language routed to a covering model, the Automatic check, the other-languages default, the check's verdicts, the fallback decision, `NLLanguageRecognizer` on English, German, and Japanese); speaker routing (more than eight expected speakers, the default voice-profile model); Parakeet token merging, minimum confidences, minimum word length, and passages; Parakeet and Nemotron installs and additions against synthetic files and a scripted Hugging Face; Nemotron's streaming turn builder (gap bridging, short-turn removal, identical results from uneven chunks); voice-profile span selection, duration-weighted averaging, and the silence-aware FBank re-centering; the router over a scripted runtime (kept, switched, kept after the other model heard a covered language, the other model missing, the notice); the processing engine recording the model that actually transcribed; and the Mac's jobs (routed models frozen, the language check optional, Japanese needing Whisper, Nemotron needing Community-1 for profiles, large groups going to Community-1, fingerprints of earlier jobs unchanged). `scripts/build-ios.sh --test` built the iPhone app and passed its 71 tests on a new iPhone Duo simulator (iOS 27.1).

**Real models, once.** Parakeet Ultra (632 MB) and Nemotron 3 offline (199 MB) were downloaded through the store into a scratch folder, every file checked against the catalog's digests, and deleted afterwards. Nothing else was downloaded; Community-1, Whisper, Parakeet Redux, and Nemotron Compact were not run.

- The smoke test's 19.75-second synthetic meeting: Parakeet Ultra's transcript matched the script word for word (eight sentences, mean word confidence 0.995), and Nemotron found one speaker, 0.00–19.54 s. Rerun with networking denied by `sandbox-exec` (debug build): transcription 0.34 s and speaker detection 0.33 s, each including loading the compiled models; peak memory footprint 196 MB.
- A 568-second recording made by joining the synthetic meetings (release build, networking denied, second run): Parakeet Ultra 1.29 s (441× real time), Nemotron 0.64 s (884×); the whole evaluated pipeline, routing and fusion included, 3.4 s (168×). Peak memory footprint 223 MB, maximum resident size 530 MB. The first run of a newly built binary was 57×, the Neural Engine compiling for this Mac.
- `--evaluate` on four synthetic recordings (macOS voices; references from the script and each clip's own speech regions; collar 0.25 s):

| Recording | WER | CER | cpWER | DER | JER | Speakers (ref/found) | Language check |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Two speakers, 24.9 s (Daniel, Karen) | 0/59 | 0/293 | 0/59 | 0.0 % | 0.0 % | 2/2 | kept, en |
| Three speakers with 1.2 s overlap, 22.5 s (Daniel, Moira, Karen) | 4/56 | 15/278 | 36/56 | 31.3 % | 48.7 % | 3/2 | kept, en |
| German, 6.7 s (Anna) | 0/15 | 0/74 | 0/15 | 0.0 % | 0.0 % | 1/1 | kept, de |
| Japanese, 7.5 s (Kyoko) | – | 67/33 | – | 0.0 % | 0.0 % | 1/1 | unclear: notice |

  Nemotron merged the two female voices (Moira, Karen) into one speaker, on both the three-speaker recording and the 568-second one (DER 20.2 % there, collar 0). Of its four WER errors, one is "Right", lost in the overlap, and three are "handles twenty five" transcribed as "handles25": Parakeet writes numbers as digits (the scorer doesn't spell numbers out), and the run exposed a bug in Daybook's word merging. Parakeet writes a number as a bare "▁" token followed by digit pieces, and the merge dropped the bare boundary; it now starts a word there ("handles 25", unit-tested with those tokens), which would leave two errors for that phrase. The weights had been deleted by then, so the fix wasn't re-run with them. Without a collar the two-speaker DER is 2.6 %, almost all false alarm at turn edges (0.50 s, against 0.02 s missed). On the Japanese recording Parakeet wrote romanized guesses ("O hayogo zaimas, kinjobini…"): the language identifier's top guess was Indonesian at 0.26 and mean word confidence 0.36, so the check found it unclear, tried Whisper Large v3 Turbo (not installed in this run), kept the transcript, and said to download Whisper. With German chosen (`--language de`) the hint reached Parakeet, transcript unchanged, confidence 0.999. A stereo copy of the two-speaker recording with speech only in the right channel transcribed in full, showing the mix-down before FluidAudio (which reads the first channel).

These are synthetic voices: they show the pipeline works end to end and how the parts behave, not accuracy on meetings. macOS voices are cleaner and more alike than people, so DER here says little about Nemotron against Community-1.

Not verified with real weights, so still to run before release:

- Community-1 making voice profiles for Nemotron's turns (`WeSpeakerSpanEmbedder`, which reproduces FluidAudio's internal `embedSpan`): unit-tested only. Check that profiles from a Nemotron run and a Community-1 run of the same person match above the threshold, and that `--smoke-test --speaker-model nemotron-3-diarization/offline --voice-model community-1/offline` passes.
- The language check switching to Whisper on a real non-European recording (Whisper wasn't downloaded), and Whisper's `language` on Parakeet-covered speech keeping Parakeet's transcript. Found while merging: WhisperKit prefilled English whenever no language was given (its defaults turn detection off), so Whisper never detected a language; it now detects without a hint and takes a chosen language (`testWhisperDetectsTheLanguageUnlessOneIsChosen`), unverified with weights.
- Nemotron 3 Compact and Parakeet Redux (Redux's 2-bit encoder has no published macOS 27 measurement).
- Real recordings, in English and two or three other languages, with mic, call, and recorder tracks: the evaluation harness is ready for them (below); Quick should move to Nemotron only if they show it better than Community-1 there.
- The app itself (only the command-line paths ran), recordings over ten minutes, and iPhone.

## Evaluating speech models

`Daybook --evaluate <folder>` runs the speech pipeline as processing does (language routing, transcription, speaker detection, voice profiles, and fusion) over recordings that have references, and scores them. It never records, never touches a library, and downloads only with `--download-models`.

```sh
swift run -c release Daybook --evaluate ~/Recordings/eval --presets quick,balanced,detailed --output /tmp/eval.json
swift run Daybook --evaluate ~/Recordings/eval --transcription-model parakeet/ultra,whisper/large-v3-turbo \
    --speaker-model nemotron-3-diarization/offline,community-1/offline --collar 0.25
```

**Folder.** Each recording is an audio file (`wav`, `m4a`, `caf`, `aiff`, `mp3`, `flac`, `mp4`) with references beside it under the same name, or a folder of audio files recorded together (mic, call, recorder; same start) with references named `reference.*` or after the folder:

| File | Holds | Enables |
| --- | --- | --- |
| `name.txt` | The words spoken, plain text | WER and CER (one of `.txt`, `.stm`, `.ctm` is required) |
| `name.stm` | NIST STM: `file channel speaker start end [<label>] words` | cpWER; also the reference text |
| `name.rttm` | RTTM `SPEAKER file 1 start duration <NA> <NA> speaker <NA> <NA>` | DER and JER |
| `name.ctm` | CTM `file channel start duration word` | Word-timing error |

**Flags.** `--presets` runs each preset's models; `--transcription-model` and `--speaker-model` take comma lists and run every pair; with neither, the first-launch selection runs. `--language` chooses a transcription language (default Automatic), `--other-languages` the model for other languages, `--collar` the seconds not scored around reference boundaries (default 0, as NVIDIA's card scores), `--no-speakers` skips speaker detection, `--models` the models folder (default: the library's), `--output` the JSON report. Optional models (the language check's, the voice-profile model) run only when installed, as in the app.

**Scores**, pooled over recordings (errors and seconds add up before dividing):

- **WER** and **CER**: after lowercasing, straightening apostrophes, and dropping punctuation; numbers aren't spelled out, so write references the way the recognizer writes numbers. CER suits languages written without spaces.
- **cpWER**: each reference speaker's words against one transcript speaker's, under the mapping with the fewest errors, on the fused transcript, so right words under the wrong speaker count. For a folder of tracks, the same person on two tracks is two speakers (fusion doesn't match voices across tracks).
- **DER** and **JER**: on exact time spans, speakers mapped by the Hungarian algorithm, overlapping speech scored. One track: the speaker model's own turns; several: the fused transcript's speakers.
- **Word-timing error**: start and end differences of words the transcript and the CTM agree on (first track).

The report lists, per configuration and recording, the models that actually transcribed, the language and routing decision, notices, the hypothesis text and RTTM, and the processing time, with model loading counted in a configuration's first recording.

## Runtime upgrade: argmax-oss-swift, MLX 3, Gemma 4, Apple Foundation Models

Run on 2026-10-24 on an M5 Pro with 64 GB, macOS 27.0 (26A428), Xcode 27.1 / Swift 6.4 (docs/models.md, docs/model-runtime.md).

**Dependencies.** WhisperKit 0.18.0 → argmax-oss-swift 1.1.1 (the renamed repository; same `WhisperKit` product, vendored Hub and tokenizers). mlx-swift-lm 2.29.3 → 3.32.3, with mlx-swift 0.29.1 → 0.32.3 pinned directly. swift-transformers stays at 1.1.6, now for the model store's downloads and MLX's tokenizer only; swift-syntax 603.0.2 joins the resolved graph for mlx-swift-lm's macros, which Daybook doesn't build. What broke and how it was fixed:

- `OfflineWhisperKit` used swift-transformers' `AutoTokenizer` and `HubApi(useOfflineMode:)`, which WhisperKit no longer shares; it now reads the installed tokenizer through argmax's public `AutoTokenizerWrapper.from(modelFolder:)` with an empty token. The override of `loadTokenizerIfNeeded` is still needed: 1.1.1's `ModelUtilities.loadTokenizer` still falls back to a Hub download.
- mlx-swift-lm 3.x loads with `loadContainer(from: URL, using: TokenizerLoader)` and has no `HubApi`; `MLXLocalTokenizerLoader` adapts swift-transformers' tokenizer to its protocol (`decode(tokens:)` → `decode(tokenIds:)`). `GPU.set(cacheLimit:)`/`GPU.clearCache()` became `Memory.cacheLimit`/`Memory.clearCache()`, `prefillStepSize` became `prefill: .init(stepSize:)`, and `LLMTypeRegistry` is an actor (`contains(_:)`, `createModel(configuration: Data, modelType:)`).
- Turning mlx-swift-lm's default trait off (`traits: []`) made both `swift package resolve` and Xcode's resolver refuse to move an existing 2.29.3 checkout ("declares no traits"). The default trait stays on; it gates nothing Daybook links.

**Tests.** `swift test` passed 559 XCTest cases with 0 failures (528 before; 31 new, plus updated expectations in the catalog, preset, registry, addition, and migration tests). New: `StructuredOutputTests` (summary and action schemas, constrained replies used when declared, fallback to free-form parsing when constrained generation throws or returns something that isn't JSON, unchanged behaviour without `structuredOutput`, thought-block removal, the thinking flag, null owners, engine versions, every built-in MLX architecture registered in mlx-swift-lm 3.32.3), `SmallTasksTests` (excerpts within budget from start, middle, and end; prompt separation of source data; answer cleanup and term filtering; Apple Foundation Models availability labels and `validate`; the runtime serving a system model without downloading; Apple Intelligence off; the context-overflow retry; a language model staying loaded around the system model), the small-tasks step in `InferenceProcessingEngineTests` (title, kind, and terms applied before the summary; a chosen template keeps its kind; nothing selected or a failing model leaves the summarizer's answers and parameters unchanged), and AppState jobs carrying the small-tasks model only while it's usable. Tests that check `installedModels()` register the Apple engine with fake availability, so results don't depend on whether the test Mac has Apple Intelligence on. No test downloads a model or runs the system model.

**Tokenizers and chat templates without weights.** swift-transformers 1.1.6 with swift-jinja 2.5.2 loaded, offline, the tokenizers of `mlx-community/gemma-4-12B-it-4bit` (`GemmaTokenizer`) and `mlx-community/Qwen3.5-4B-MLX-4bit` (`TokenizersBackend`) and rendered both chat templates with `enable_thinking: false`: Gemma 4 12B's ends with an empty `<|channel>thought\n<channel|>`, Qwen 3.5's with `<think>\n\n</think>`. Encode/decode round-tripped mixed-script text. Only tokenizer and template files were fetched for this.

**Real models.** Whisper Base and Gemma 4 E2B · 4-bit (3.58 GB, `238767527555cb75a05732a84dff5d6ba0dd6809`) were downloaded once, through the smoke test's `--download-models` into a scratch `--models` folder (digests verified by the store), and deleted afterwards. All runs used the release build and the generated 19.75-second fixture, with `--speaker-model none` (speaker models are unchanged and weren't downloaded).

| Run | Result | Speech | Language model | Small tasks |
| --- | --- | --- | --- | --- |
| Download and first run (guided generation with fast-forward, since changed) | Passed every assertion; 391.6 s, nearly all download | Whisper Base through argmax-oss-swift: the fixture's words | Load 2.20 s; 2 constrained passes, 1,535 tokens in 6.70 s; one section body had junk JSON-like text inside its string | Apple Foundation Models, 1.76 s |
| Final code, all networking denied (`sandbox-exec`) | Failed the strict action check, below; 8.68 s in total | 2.58 s including loading; 50 timed words, mean confidence 0.896; "Daybook" from the vocabulary prompt | Load 2.10 s; 2 constrained passes, 1,335 tokens (prompt and output) in 1.22 s; clean JSON | 1.77 s: title "Project Planning Meeting", kind general, 4 terms |
| Diagnostic: constrained generation turned off | Same failure | 1.59 s | Prompt processing 1,215 tokens in 0.146 s (≈ 8,300 tokens/s); generation 153 tokens in 1.18 s (≈ 130 tokens/s) | — |

What these show: argmax-oss-swift loads and transcribes offline with word timestamps, confidences, and vocabulary prompting; mlx-swift-lm 3.32.3 loads Gemma 4 (`gemma4`) offline through the local tokenizer adapter with thinking off; guided generation produces schema-valid JSON at close to free-form speed in a release build; and Foundation Models' `@Generable` small tasks run on this Mac. The offline run reached the summary with the fixture's milestone, title, and Alex's checklist assignment in the summary's own action list, but the separate action-verification pass extracted only "ship the prototype on Friday", so the smoke test's strict check for Alex's assignment failed. With constrained generation off, Gemma 4 E2B returned the same single action, so this is the smallest model's recall on this prompt, not constrained decoding; it is recorded as a failure, as Qwen 1.5B's was. The first run passed only because fast-forward changed the model's formatting.

**Fast-forward is off.** XGrammar's fast-forward re-encodes the text the grammar forces (`{"kind":"`, `"},{"heading":"`) and feeds those tokens to the model. On Gemma 4 E2B that tokenization differs from what the model would have chosen and derailed it: in a debug-build comparison of the same final prompt, fast-forward with the default biases leaked text into a string and padded the JSON with whitespace, and fast-forward without them ran to the token limit (`incompleteOutput`). Masking only, with or without the closing and whitespace biases, produced clean JSON with the free-form reply's title and more sections. Constrained output can still spell a missing owner as the string "null"; parsing now reads "null", "none", "unassigned", and "n/a" as no owner.

**Apple Foundation Models.** The suggested terms from the system model on the fixture were phrases ("onboarding checklist", "audio capture") rather than distinctive names; they appear first among suggestions for the person to approve. Its availability label and fallback were exercised only with fakes, because this Mac has Apple Intelligence on.

**Xcode builds.** `scripts/build-ios.sh --test` on a new iPhone Duo simulator (iOS 27.1) resolved the new package graph, built the iPhone app, and passed its 71 tests. `./scripts/build-app.sh --debug --ad-hoc` generated the Mac project, built it with the new packages, and packaged and verified `dist/Daybook.app` (ad hoc signature).

Not verified:

- Gemma 4 E4B, 12B, 26B A4B, and 31B, and Qwen 3.5 and 3.6, weren't downloaded: their architectures are registered and the 12B and Qwen 3.5 tokenizers and templates load, but none has run here. The per-tier presets rest on the October research (docs/model-runtime.md), not on new measurements.
- Long conversations (the map-reduce passes with a constrained final pass), real multi-speaker meetings, and non-English input with the new models.
- macOS 15 and 26: the "Needs macOS 26 or later" path, mlx-swift 0.32.3's fix for the launch crash before 26.4, and Foundation Models' 4,096-token context on 26.
- Apple Intelligence turned off or still preparing on a real Mac; guardrail refusals.
- Existing Qwen 2.5 installs under the new runtime (they keep their receipts; the 2.29.3 → 3.32.3 change in `qwen2` loading wasn't exercised with weights).

## Release packaging

`scripts/build-app.sh` builds the Mac app with Xcode: XcodeGen generates `Apps/macOS/DaybookMac.xcodeproj` from `Apps/macOS/project.yml`, whose target compiles `Sources/Daybook` in place and links the package's libraries (DaybookCore, DaybookDevices, DaybookKit, DaybookIntelligence, DaybookLink) at the versions in `Package.resolved`. A release is `xcodebuild archive` followed by `-exportArchive` with the `developer-id` method, which re-signs with Developer ID Application and a Developer ID provisioning profile (the only way a Mac app gets the iCloud container), then a ZIP and, with `DAYBOOK_NOTARY_PROFILE`, notarization and stapling. The earlier SwiftPM-and-`codesign` packaging, which couldn't carry iCloud, is gone; `swift build`, `swift run Daybook`, and `swift test` are unchanged for development.

Checked on 2026-10-23 (Xcode 27.1, XcodeGen):

- **Ad hoc Debug** (`--debug --ad-hoc`, no team): builds; launches with `--snapshot` against a temporary library and renders the main window; Settings › Library reports "Not available in this build", and the folder transport appears only with `-DaybookDevelopmentFolderSync YES`. Entitlements: audio input only.
- **Ad hoc Release archive** (`--ad-hoc`): arm64 only; MLX `default.metallib` in `mlx-swift_Cmlx.bundle`, the FluidAudio and swift-transformers bundles, `Assets.car` (AccentColor), the generated `Daybook.icns`, `ThirdPartyNotices.md`, and package licenses are in Resources; Xcode embeds `libswiftCompatibilitySpan.dylib`; runtime search paths are `/usr/lib/swift` and `@executable_path/../Frameworks` only; hardened runtime on. Info.plist keeps every key, with `DaybookICloudContainerIdentifier = iCloud.local.daybook`.
- **Apple Development Debug with the team, before provisioning:** fails as expected. The only Mac profile on this machine is the wildcard team profile, and Xcode reports that it doesn't include the iCloud capability, the `iCloud.local.daybook` identifier, or the iCloud entitlements. The same build with the iCloud keys left out signs with the team's Apple Development identity, so the identity itself is fine; what's missing is the app ID and profiles, which `--allow-provisioning-updates` creates (README.md, "First-time provisioning"). Nothing was registered on the account and nothing was notarized for this record.

Notarization has not been performed: a configured `notarytool` credential profile was not supplied. The build script supports `DAYBOOK_NOTARY_PROFILE` and will submit, staple, and regenerate the archive for a Developer ID export.

Still needs a signed build and a real iCloud account (after first-time provisioning):

- `codesign -d --entitlements - dist/Daybook.app` on the export shows the iCloud keys with `iCloud.local.daybook`, plus `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profile; `spctl -a -vv` accepts the notarized app.
- Settings › Library reads "Syncing with iCloud", and `~/Library/Mobile Documents/iCloud~local~daybook/Documents/Daybook` holds the journal, hidden from iCloud Drive in Finder.
- A Mac that synced through a chosen folder shows "Migrating N of M files…", switches over, and leaves the folder unchanged; repeat on a second Mac after the first one moved, and after the iPhone started the container.
- With Optimize Mac Storage evicting the old folder: the move waits, downloads, and resumes.
- iCloud Drive off, signing out, and switching Apple Accounts pause sync with the right message; signing back in resumes.
- The Mac and iPhone exchange a recording through the container.

The standalone signed release passed the expanded notes/highlights diagnostic in 12.57 seconds with both networking and access to the repository's build products, Xcode, and developer toolchain directories denied. This checks that the packaged Metal resources and Swift compatibility library work without a developer installation. The [diagnostic report](validation/standalone-offline.json) contains only synthetic fixture data.

The installed app launched and remained running. Visual review covered the empty library, new-conversation detail, model selection, recording/import settings, sync settings, and the floating notes panel. The panel appeared at the right edge at 370 × 660 points. Review found and corrected an oversized processing-menu control. Bluetooth Scan reached “Waiting for Bluetooth”; a physical Soundcore connection was not established. Full-screen call behavior and actual note entry during capture remain live-use checks.

## Devices

Run on 2026-10-23. `swift test` includes 56 device tests in `Tests/DaybookTests/Devices/` plus the
device cases in `LibraryPlaceTests` and `LibraryPlacementTests`:

- `SoundcoreProtocolTests` (10): command bytes, fragmented and corrupted frame recovery, status and
  storage decoding, both list layouts, slice bounds, malformed lists, a seeded 2,000-round fuzz of
  every parser, the NIST AES-256-CTR vector, key agreement and file-key tampering, and simulator
  fixtures through the native Opus decoder.
- `SoundcoreSimulatorTests` (21): the real `SoundcoreConnection`, `SoundcoreSession`, and
  `DeviceSession` against `SimulatedSoundcore`: setup, listing (paged, 8-byte fallback), import with
  identity, one-at-a-time queues, integrity failures with one retry, stalls, Stop, disconnect
  mid-transfer with resume after reconnect, Bluetooth off mid-import and at setup, permission
  denied, remembered reconnect directly and after a scan, idle release, automatic import since setup, turning it off
  and release afterwards, no automatic import before the library loads, record control with and
  without confirmation, Listen Live portions, and the read-only command set.
- `DeviceFrameworkTests` (19) and `DeviceHubTests` (6): queue and retry policy, estimates and copy,
  library links, overlaps, setup and persistence, one Soundcore but many Other Recorders, migration
  from the single folder and recorder of earlier versions, and the files method end to end (stable
  files import once, failures get Try Again, originals untouched, a missing folder is reported).

Finding: macOS's Opus decoder conceals malformed packets instead of failing, so corrupted audio
inside an otherwise complete, in-order, correctly sized transfer isn't detected (the protocol has
no per-slice authentication). Loss, reordering, truncation, size mismatches, and key mismatches are.

Every device surface was captured in light and dark with `--device-demo` scenarios, which use an
inert transport and never touch Bluetooth.

**Physical-hardware validation is still pending.** No Soundcore Work was connected. Still to check
on a real recorder and current firmware: discovery and the permission prompt, status values (battery
buckets, case battery out of the case, storage), whether the recording in progress appears in the
list, transfer throughput and the time-left estimate, packet loss and the stall timeout, reconnect
and backoff timing, automatic import alongside the Soundcore phone app, Listen Live reception and
caption latency (real bursts: how much the recorder sends at once when listening begins, and whether
a minute of backlog keeps up), record control confirmation, and whether the phone app removes
recordings after it transfers them.

## Acceptance checks still requiring live use

- Grant microphone and Screen & System Audio Recording permissions, then verify both voices in a real Zoom/Meet/Teams call, including headphones and muted microphones.
- Check automatic starts/ends, browser tab ambiguity, localized window titles, unsupported applications, and manual-stop suppression.
- Exercise full-screen calls with the notes panel, multi-monitor arrangements, device switching, sleep/wake, permission revocation, and long sessions.
- Floating Notes (iPhone-style panel, `FloatingNotesStatusTests` plus `--notes-demo` snapshots with stand-in levels and scripted captions): over a full-screen call, check that its status chip menus, Bookmark, and Stop work without taking focus from the call; real You/Call meters and captions; Increase Contrast with the real system setting (only simulated so far, and the notes text keeps standard ink); and the hover-only Compact button snapping to 212 pt and back.
- Soundcore Work on a physical recorder (see Devices below). Export actual Soundcore MP3s and any available highlight metadata; verify import, playback, timing, and overlapping computer/wearable recordings. Double-tap marker extraction is not implemented.
- Evaluate recognition and speaker error rates on representative multi-speaker and multilingual recordings; review template choices and summaries for nuanced personal/therapy conversations.
- Sync two physical Macs (and an iPhone) through the iCloud container on signed builds, including the one-time move from a chosen folder (see Release packaging); exercise eviction, quota/full disk, offline edits, account changes, large audio, and simultaneous initial setup. Tests use shared local filesystem transport, not Apple’s remote service.
- Confirm Gatekeeper behavior after notarization on a separate Mac before broad distribution.

No real meetings, therapy sessions, or ambient microphone recordings were collected during automated testing. Diagnostic reports contain only generated fixture text. Normal tests use temporary libraries and do not install weights.

## Multipoint and post-hoc enhancement

Run on 2026-10-23 with `swift test` (see [multipoint.md](multipoint.md) for the behaviour). The whole
suite passed 244 XCTest cases (100 core, 144 application), including these 26:

- `MultiSourceTests` (10, core): a multipoint link claims its recorder recording by ID or start
  time, not another recorder's; overlap in time, then the sound decides (attach, low-confidence
  suggestion, transcript check, sound that contradicts trustworthy clocks); two overlaps become a
  suggestion; a conversation being recorded now is a candidate; a sound placement with drift drives
  fused times and the report while provenance keeps source times; a waiting source settles by
  transcript, then clock, else stays separate; adding a source keeps a correction (on the merged
  passage), a renamed speaker (still on that passage), note times, and bookmarks; this Mac's
  recording joins a recorder's timeline and its held note moves once; recordings on one clock move
  together; links merge across Macs; libraries without multipoint decode and fuse exactly as before.
- `MultipointRecordingTests` (7, application, fake recorder and simulator): the recorder starts and
  stops with the Mac recording and its recording joins the same conversation with its link,
  placement prior, and Version History entry; out of range, unconfirmed, and already-recording
  recorders leave the Mac recording untouched with one status line (and an already-recording one is
  not stopped); a link an interrupted session left behind never stops a recorder; the preference and
  a disabled direct method keep a recorder out; and the real
  `SoundcoreConnection` against `SimulatedSoundcore` records alongside, pauses, transfers, and
  attaches, sending only the read-only commands plus one Start and one Pause.
- `MultiSourceProcessingTests` (9, application, temporary libraries, synthetic audio, a fake
  inference engine, an injected `AudioAligner` result): a confident sound match joins with the
  aligner's offset and drift stored on the track and used by fusion; two overlaps become a
  suggestion, Confirm copies the recording in with its bookmarks and moves the separate conversation
  to the Trash; a recorder file stored before this Mac's recording is placed by the clocks, then by
  sound once this Mac's recording is in;
  a live conversation can be a candidate and Keep Separate keeps it; no overlap gives its own
  conversation; with no verdict from the sound, the transcript settles the match and the recording
  moves in with its transcript (each recording transcribed once, the separate conversation never
  summarized); enhancement transcribes only the new recording, writes "Added Soundcore Work
  recording", summarizes again from every source with the earlier summary in Version History, and
  keeps the correction, the speaker name, note times, and bookmarks; Pause and Cancel while adding a
  source keep the recording, its placement, and the earlier summary; this Mac recording into a
  recorder's conversation keeps its date and timeline, its bookmark follows the microphone recording,
  and its note moves onto the timeline once the sound places it.

These tests inject `AudioAligner` results; the aligner itself is covered under "Multi-source alignment" below. Not exercised: real Bluetooth,
a real Soundcore Work, and real speech. **Still to check with a physical recorder:** that Start and
Pause from Daybook are confirmed in time during a call, whether Pause ends the recording file (the
simulator assumes it does) and how soon the finished recording appears in the recorder's list, the
offset between the recorder's clock and this Mac's (the clock prior assumes seconds, not minutes),
connecting while the phone app holds the recorder, a recorder leaving range mid-recording, and the
sound and transcript alignment of a wearable against a Zoom call's microphone and computer audio.

## Mac integration with Daybook on iPhone

Run on 2026-10-23 with `swift test` (see [iphone.md](iphone.md), "Processing on the Mac",
[multipoint.md](multipoint.md), "With Daybook on iPhone", and [devices.md](devices.md)). Temporary
libraries and sync folders, a fake inference engine, a phone library on its own DaybookKit replica,
and DaybookLink over loopback with keys in memory; nothing advertised, no keychain, no microphone.

- `ProcessingRequestQueueTests` (10): a phone's request is claimed with the lease when its job
  starts, renewed with stage and fraction, and completed; a job queued for the same conversation
  carries the request and completes another it satisfied; a failure's reason reads the same in
  `ProcessingStatus` on the phone and the Mac; Pause and Cancel give the claim back and keep it from
  being claimed again until Resume; a stale claim is taken over and a live one left alone; missing
  models leave the request unclaimed with presence `canProcess` false, and installing them flips
  presence and runs it; two Macs that both claimed before syncing converge on one, the other stops
  without pausing and never finishes it; a Mac never runs a request another holds; a claim survives
  sleep and renews on waking unless another Mac took it over; claims left by a crash run again at
  launch, or go back without models.
- `PhoneLinkTests` (8): pairing shows a code, a new code with the reason after a wrong one, then the
  paired phone, which joins Devices, and unpairing removes it and stops the link; this Mac asks a
  connected phone to record and stop, storing its recording ID and clock estimate (a 2.5 s skew
  measured within 50 ms), and doesn't when "Also record on <iPhone>" is off; a phone's refusal is one
  quiet line; the phone asks this Mac to record into its conversation, which is refused while
  recording another, without the microphone, and for a stop of a recording started on the Mac;
  progress messages reach the phone through every phase; and the phone's synced recording joins this
  Mac's conversation by its link (moved from a conversation of its own, after a nudge), in place
  (recorded into it), and by time then sound (no link), with the clock prior as the track's
  `clockOffset` and as `AudioAligner`'s expected offset.
- `DaybookPhoneDeviceTests` (3, devices): the kind and its methods, a paired phone in the hub under
  its own ID listing only its recordings (and sync off reported), and the app's link as its direct method.

The device page, the pairing sheet, and Settings › Devices were captured with `--device-demo none
--phone-demo recording|pairing|connected --library <folder> --snapshot`, which runs the link on
loopback with keys in memory.

**Still to check with a real iPhone on a real network:** the local-network permission prompt on both
sides, Bonjour browsing and advertising (only while pairing is open or a phone is paired), pairing
by code, the phone reconnecting after the Mac sleeps or changes network, record control in both
directions during a real call, the clock estimate on real Wi‑Fi, the phone's recording arriving
through iCloud and joining the conversation, live progress on the phone, a nudge reaching a Mac, and
two Macs taking the same request through real iCloud latency. The phone's device ID on the link must
equal the installation ID its tracks carry for each phone to list only its own recordings.

## Recorder handoff and the iPhone status sheet

Run on 2026-10-24 (docs/devices.md, "Handing a recorder over"; docs/iphone.md, "Status sheet").
`swift test` passed 467 XCTest cases; `scripts/build-ios.sh --test` passed 71 on the iPhone Duo
simulator (iOS 27.1). No Bluetooth, no network beyond 127.0.0.1, no microphone.

- `RecorderHandoffTests` (8, DaybookKit): a Mac-side and a phone-side `RecorderHandoff`, each with
  its own library syncing through a temporary folder and its own `DeviceHub`, reaching for one
  `SimulatedSoundcore` that talks to one device at a time, over DaybookLink on loopback. Over the
  link the recorder moves in well under 5 s (the Mac, then the phone, in the recorder's connection
  log) and the synced record is cleared on both; a Mac that doesn't manage it refuses with who does,
  and an offer to a device without it set up is refused; with no link the phone waits through sync,
  says it's overdue after its patience, and Take Over Anyway connects only once the still-connected
  Mac hears and lets go; through sync alone the Mac lets go at its next pass and the phone takes
  over at its own; a transfer in progress finishes on the Mac, nothing else starts there, and the
  two waiting recordings import on the phone, each recording in exactly one conversation on both
  devices after sync; what the Mac imported isn't imported or offered again by a phone that imports
  everything automatically, until sync brings it; a recording keeps going and only the new owner can
  pause it; "Use on Studio Mac" and hand-back when the Mac comes back on the link.
- `LinkRecorderHandoffTests` (5, DaybookLink) and `RecorderHandoffRecordTests` (2, DaybookCore):
  the messages, compatibility both ways, and the synced record's merge and forward compatibility.
- iPhone: `StatusSheetModelTests` (8): every recorder, Mac, and sync line, the sections per detent,
  the queue's order with "Requested from this iPhone", and the compact detent with Dynamic Type;
  `DeviceOwnershipTests` adds Use on This iPhone through the app's own link and devices.

Screenshots: the sheet at each detent on the iPhone Duo closed and the iPhone 18 Pro, the panel
on the open Duo, light and dark, the handoff states on the iPhone's device page and in the sheet,
and the Mac's device page and Settings › Devices (`--handoff-demo`). The menu bar extra's line
isn't captured (`--snapshot` renders windows only).

**Still to check with a real Mac, iPhone, and Soundcore Work:** how long a real recorder takes to
advertise again after one device lets go, and whether it refuses a second central or simply isn't
found (the simulator models it as not found until free); CoreBluetooth's pending connection with no
deadline across the iPhone's background and state restoration; the handoff while the phone app is in
the background (the link closes then, so it goes through iCloud); hand-back when the Mac wakes on
the same Wi‑Fi; the time a real import takes to finish before letting go; Listen Live stopping and
saving on handoff; record control after a handoff mid-recording; the status sheet's feel and
VoiceOver order on device, its detent heights with real Dynamic Type sizes, and the panel with a
real hinge.

## Multi-source alignment

Run on 2026-10-23 in a debug build. See [alignment and fusion](alignment.md) for the method.

`AudioAlignerTests` (11) builds every recording in the test from synthetic speech: formant-shaped voiced syllables and consonant bursts from a remote and a local talker. A "call" capture is written as 16 kHz PCM with the remote talker only. A "room recorder" is written as 44.1 kHz AAC with both talkers, a decaying reverb impulse response, noise, gain swings between 0.35× and 1.6×, and its own clock. Nothing is recorded or downloaded.

| Case | Result |
|---|---|
| Recorder 197 s in, ±200 ppm | Offset error −8 and −10 ms, drift error −6 and +2 ppm (limits 20 ms and 20 ppm) |
| Recorder starts 90 s early and ends 80 s late | −9 ms, +1 ppm; reported overlap within 0.5 s |
| Confidence | Clean copy 0.999 > degraded recorder 0.997 > 40 s overlap 0.35 |
| Unrelated audio, or an adjacent non-overlapping stretch | nil |
| Prior that excludes the truth | nil |
| 30 + 30 minute pair | Offset −9.5 ms, drift −0.2 ppm; 2.5 s with decoding, at load average 50 (budget 15 s) |

The end-to-end test plans, measures, stores, and fuses a recorder whose transcript wording differs from the call's. That recorder is placed by sound. `MultiSourceFusionTests` (16) covers:

- audio, phrase, and start-time placement, and stale digests;
- caller placements and pre-rescaled segments giving the same transcript as a measured alignment;
- each utterance appearing once across call, echo-cancelled microphone, and recorder, with the raw microphone excluded;
- best-source wording, majority correction of a call misrecognition, and signal-to-noise choice;
- word-level provenance;
- crosstalk that shares common words staying separate;
- owner and remote attribution, and shared-speech speaker mapping;
- corrections and speaker names surviving the addition of a recorder, including a recorder segment that two passages cite;
- determinism and decoding of libraries without the new fields;
- sync merging that keeps the newest measurement and keeps the summary with its transcript.

Two `TranscriptFusionTests` now expect merged passages, where they previously expected separate ones, and still assert that the negation and the extra clause survive. A synthetic two-hour, three-source transcript (34,000 input words) fused in 2.4 s.

Still to validate with real recordings:

- A Soundcore Work (Opus/MP3) recorder next to a MacBook during real Zoom, Meet, and Teams calls, with laptop speakers and with headphones (no shared sound with computer audio). Measure offset against a clap or a click track, drift over two hours, and the confidence of each.
- Real rooms (small office, conference room, café), several distances, recorder in a pocket or bag, and with the recorder paused, restarted, or split into files mid-meeting.
- Bluetooth headset microphones and their codec delay, automatic gain control, noise suppression, and the echo-cancelled microphone track the capture layer produces.
- Recorder file dates as priors: how far real device clocks drift from the Mac's.
- Word error rate of the fused transcript against single sources on representative multi-speaker meetings, how often a vote removes a correct word, and duplicates that survive.
- Owner inference with several people at the Mac, in-person meetings, and diarization over-splitting. Check speaker mapping between recorder and microphone in real rooms.
- Correction and rename stability across real re-transcriptions with different models.

## Call capture and echo removal

**Verified automatically** (synthetic audio only, see `docs/capture.md` → Verification):

- **Echo removal.**
  - ERLE of at least 20 dB on call-only stretches, through a delayed, reverberant echo path with
    noise. Measured runs give 44–53 dB with the suppressor, and roughly 25–35 dB from the linear
    filter alone.
  - Near-end speech survives double talk, with correlation of at least 0.9 against the clean
    voice and level within 3 dB.
  - The GCC-PHAT delay is within 1 ms.
  - Echo is cleaned from the first seconds, thanks to the convergence pre-roll.
- **Formats and timing.**
  - A 44.1 kHz mono microphone works against a 48 kHz stereo call with different start times.
  - A call clock running 250 ppm fast is measured within 3 ppm (250.1) and corrected. After a
    minute, ERLE is about 51 dB with correction and 8 dB without.
  - A delay change mid-call is split into segments.
  - Drift of 900 ppm in either direction neither stops a recording nor inserts silence.
  - Device format changes are converted without losing frames.
- **Files and provenance.**
  - The original microphone and call files are byte-identical after processing, and in the
    library.
  - The derived track carries `derivedFrom` and `processing = "echo-cancelled"`, and is
    transcribed instead of the original.
  - Skip reasons are recorded for headphones, a silent call, no echo, and no call track.
- **Choosing the capture path.** Process tap versus ScreenCaptureKit selection, mid-call
  fallback, and route tracking are tested with injected fakes.

**Not verified: no real device, tap, aggregate device, or permission prompt was exercised.**

The following still need checking on real calls.

### Each app

Check each of these: Zoom (native), Google Meet in Chrome, Safari, and Arc, Microsoft Teams
(new client), and a Slack huddle.

- Confirm that `capture-result.json` → `systemAudio.method` is `process-tap`, and that
  `capturedApps` lists the audio helper. Chrome's helper is `com.google.Chrome.helper`; Safari
  uses `com.apple.WebKit.GPU`; Teams and Slack use helpers.
- Confirm the call track holds only the call, with no notifications, music, or other tabs'
  apps.
- Confirm the "System Audio Recording Only" prompt appears once on the first tapped recording,
  uses `NSAudioCaptureUsageDescription`, and isn't shown again.
- Deny that permission.
  - With Screen Recording already allowed: confirm the call falls back to ScreenCaptureKit after
    about 45 s (`switchedAt`, `fallbackReason`), and that no call audio is lost after the switch.
  - Without it: confirm the tap stays and the "stayed silent" warning appears.
- Sit alone in a Zoom meeting or a Meet waiting room for over a minute. Note whether the app
  outputs exact digital silence (the watchdog fires) or comfort noise (it doesn't).

### Speakers versus headphones

- **Built-in speakers at normal and loud volume, with both people talking over each other.**
  - Confirm `echoRemoval.outcome == applied` and a plausible delay, typically 20–120 ms on built-in
    speakers.
  - Confirm `echoReturnLossEnhancementDB` of at least 20.
  - Listen to `microphone.echo-cancelled.caf` for leftover echo and for clipped words of your own.
  - Confirm the transcript doesn't show the other side's words under "You".
- Wired headphones and AirPods: confirm `skipReason` `headphones` or `noEchoDetected`, and that the
  original microphone is transcribed.
- Open-back headphones at high volume: confirm leaked echo is still detected and removed.
- External USB or Bluetooth speakers and an HDMI display: confirm the delay found (Bluetooth
  speakers often add 150–300 ms) and the ERLE.
- Laptop moved or lid angle changed mid-call: confirm re-convergence without audible echo bursts.

### AirPods and device switching

- Connect AirPods mid-call, while recording on speakers.
  - Confirm route events show `speakers` then `headphones`.
  - Confirm the microphone continues (a note in `microphone.json`, a resync anchor) and that call
    capture follows the new output device. The tap rebuild note appears, or ScreenCaptureKit is
    unaffected.
  - Confirm echo is removed in the speaker part only.
- Start a call with AirPods as the microphone, so they switch to hands-free at 16 or 24 kHz.
  Confirm recording continues and that the converted microphone is clean.
- Switch input devices in System Settings during a call, and unplug a USB headset.
- Disconnect AirPods mid-call; output falls back to speakers.

### Long calls and timing

- 60–90 minute calls on built-in hardware, USB, and Bluetooth devices.
  - Confirm no "audio clock was interrupted" stop.
  - Note `microphoneDriftPPM` and `callDriftPPM` in the report.
  - Confirm transcript alignment between You and Them stays within about 100 ms at the end.
- Measure finalize time in a release build for a one-hour call. It should be well under the
  transcription time.
- Sleep during a recording, force-quit during a recording and during echo removal, then relaunch.
  Confirm recovery produces originals plus a derived track, or the original only when echo
  removal didn't finish.

### Automatic and manual starts

- Confirm that an automatic start targets the detected app.
- Confirm that a manual start during a Zoom call or a Meet call picks that app.
- Confirm that a manual start with only music playing falls back to ScreenCaptureKit with the
  "No call app" reason.

### Live captions

Verified with scripted captioners and fake sources only (`LiveCaptionsTests`,
`SoundcoreSimulatorTests`, `LiveCaptionEngineTests`); no speech recognition ran in tests or demos.
Still to check on a Mac running macOS 26 or later, in a real call:

- Two `SpeechAnalyzer`s at once (You and Call): both start, the second without a second download,
  and captions keep up for an hour without the recording dropping buffers or the disk backlog
  warning appearing.
- The first recording in a language: the speech assets download (`AssetInventory`), the strip says
  so, and whether the analyzer needs speech-recognition authorization (the one prompt it may ask).
- Speakers: the microphone's echo of the call is left out without hiding your own lines when you
  talk over the other side; tune `CaptionEcho.window` and `threshold` on real recognizer output.
  Headphones: both sources show in full.
- Floating Notes over a full-screen call: the strip stays fixed and readable, and the notes don't move
  as words arrive. The conversation page after Stop shows the saved captions until the transcript
  lands, then drops them, and `<library>/LiveCaptions/` empties.
- macOS 15: no captions, no Settings choices beyond the explanation, and no errors.
- Soundcore Listen Live on hardware: how large the opening burst is, that captions catch up to the
  present, and caption latency (see Devices above).

## CloudKit courier

Run on 2026-10-24 on Apple silicon, macOS 27.0, Xcode 27.1 (27A9275), with fakes only: no CloudKit, iCloud account, network, or real library was touched (`docs/icloud-sync.md`, "Courier (CloudKit)").

- `swift test`: 657 XCTest cases passed, up from 647. The ten new ones are `LibrarySyncInboxTests` (3, DaybookCore) and `LibrarySyncCourierTests` (7, DaybookKit); every existing sync test passed unchanged.
- `scripts/build-ios.sh --test` on an iPhone Duo simulator (iOS 27.1) made for the run: 73 passed, up from 72 (`SyncServicesTests.testAFiledRecordingGoesToTheCourierAndAStuckSendIsShown`). The iOS build compiles `CloudKitCourier` against the iOS 27.1 SDK.
- `scripts/build-app.sh --debug --ad-hoc`: the Mac Xcode project builds and packages; the ad hoc build carries no CloudKit or push entitlement and creates no courier.

What the tests cover, with `InMemoryCourier` and a temporary folder standing in for the container (files are held back from it to play iCloud Drive lagging):

- a pass reports the files it wrote, once; the iPhone's courier sends each once through network failures, retried passes, and a relaunch; files over 50 MB stay with iCloud Drive; storage-full refusals wait 1 minute, then longer;
- the Mac verifies deliveries into `Sync/Inbox`, applies them (audio included) before iCloud Drive brings them, deletes them from the courier, and never writes them into the container, not even when it publishes an edit to the same conversation;
- the same files arriving through iCloud Drive prune the inbox with nothing rolled back, and aren't a remote change;
- damaged, truncated, foreign-library, and non-journal deliveries are rejected; one damaged after it was stored is discarded when read, and iCloud Drive's copy is installed;
- `fetchAudio` installs from the inbox without waiting for iCloud;
- with the courier unavailable, sync runs as before and nothing is staged; `CloudKitCourier.ifEntitled` returns nil in an unsigned process;
- courier files expire after seven days, deleted by the sender and by a receiver that sees them;
- the iPhone's sync line shows a send stuck for 15 minutes, then "Up to date" once it goes.

Not verified (needs signed builds, the account steps in `docs/release.md` step 7, and real devices):

- `CKSyncEngine` against the real container, in Development and Production: zone creation, saves with assets, the "server record changed" answer to a resend, deletes, and the saved engine state across launches;
- pushes: delivery to the Mac with Daybook in front and behind, to the iPhone in the background, and whether the iPhone's engine, which leaves the `Courier` zone out of its fetches, settles rather than fetching again on each push;
- how long a filed recording takes to reach the Mac on Wi-Fi and cellular, against iCloud Drive; sends that finish after the background-task assertion ends;
- storage-full, offline, and Low Power Mode behaviour, and the real error codes CloudKit returns for a schema missing from Production;
- whether the 50 MB limit (Apple's documented asset-field maximum) is the right cut-off for the native API;
- the exported entitlements: `production` push and the `Production` container environment on the Developer ID and TestFlight builds;
- two Macs: the first to store a file deletes it, so the other gets it through iCloud Drive.
