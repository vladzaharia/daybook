# Cloud summaries

A summary can be written by a cloud model, Anthropic's or OpenAI's, with the person's own key. Everything else stays on
the device: transcription, speaker detection, voice profiles, and audio. With no key nothing changes and nothing is
offered. With a key, Settings › Cloud chooses when summaries use the cloud (offered with a countdown first, always, or
never) and which model. Where a summary runs is decided by the placement planner (`SummaryPlacementPlanner`, the
placement stream); this page is the cloud side: the catalog, keys, discovery, the requests, and the summary itself.

## What is sent

A cloud summary sends the conversation's transcript text (with each note and bookmark in place, and the passages near
them marked), the notes and bookmarks, the template (its kind and instructions), and the vocabulary. Nothing else: no
audio, no photos or their captions, no voiceprints, no speaker profiles. Photo captions stay on the device, so a cloud
summary places photos by time only (`PhotoPlacement.arrange`). OpenAI's request sets `store: false`, so the response
isn't kept on OpenAI's side.

OpenRouter's model list (for prices) is fetched without a key and carries nothing about the person: no key, no cookies,
and a bare `User-Agent: Daybook`. It's fetched only once a key has been added.

## Where the code lives

| Target | Holds |
| --- | --- |
| `DaybookKit/Cloud` (Mac and iPhone) | `CloudInterfaces.swift` (shared with the placement and iPhone streams: `CloudProvider`, `CloudTier`, `CloudModel`, `CloudEffort`, `CloudSummaryPreferences`, `SummaryPlace`, `SummaryOptions`, `ProcessingCapabilities`, `CloudSummarizing`); `CloudCatalog` (family rules, measurements, estimates); `CloudPriceBook` and `CloudPrice` (OpenRouter's prices); `CloudOffer` and `CloudCatalog.offers` (what's offered, ranked, resolved); `CloudKeyStore` (`KeychainCloudKeyStore`, `MemoryCloudKeyStore`, `CloudAPIKey`); `CloudClient` (model lists, OpenRouter, streamed replies, retries) and `CloudError`; `CloudDirectory` (discovery and caches); `CloudSetup` (Settings › Cloud on both apps); `CloudProvenance` |
| `DaybookKit/Resources` | `CloudCatalog.json` (versioned) and `CloudPrices.json` (a snapshot of OpenRouter's list, Anthropic's and OpenAI's models only) |
| `DaybookIntelligence` | `CloudSummarizer` (the concrete `CloudSummarizing`) and `CloudSynthesis` (the prompt, schema, and checks, built on `MeetingSynthesis`) |
| `Daybook` (Mac) | Settings › Cloud (`CloudSettingsPane.swift`), the colophon's "Summarized with …", and the debug `--cloud-check` (`Diagnostics/CloudCheck.swift`) |
| `DaybookPhone` | Settings › Cloud (`Settings/CloudSettings.swift`) and the colophon |

## The catalog

`CloudCatalog.json` holds what Daybook knows before asking anyone:

- **Family rules** place a model ID in a tier: `claude-opus-*` and `gpt-*-astra` are Best; `claude-sonnet-*` and
  `gpt-*-sol` Balanced; `claude-haiku-*`, `gpt-*-terra`, and `gpt-*-luna` Economy. A rule is a prefix, a version
  ("5-5", "6.1"), and a suffix, optionally followed by "-pro" and a snapshot date ("-20251001", "-2026-09-29"). Anything
  else (Claude Fable, `gpt-5.5`, `o3`, embeddings, `:batch` listings) isn't offered.
- **Measured models**, each with its tier, its **rank** within the tier (lower is better: measured quality, then
  price), a **summary quality** (below), whether Anthropic's refusal fallback applies, and how many tokens it writes:
  output tokens (reasoning included) for 15, 30, 60, 120, and 186 minutes at medium effort, and low and high against
  medium on an hour (docs/validation.md, 2026-10-31).
- **Per provider**: transcript tokens per minute of conversation (Anthropic 311, OpenAI 214: Claude's tokenizer counts
  about 45% more), characters per token for estimating a prompt (2.8 and 4.0), characters of reply per output token
  (for progress), and a default output rate for a model with no measurements.
- **`promptCharacters`**: our own prompt's size without the conversation (instructions, rules, the notes check), for
  estimates. A test keeps it within 15% of the real prompt.

| Tier | Rank 1 | Rank 2 | Rank 3 |
| --- | --- | --- | --- |
| Best | Claude Opus 5.5 | GPT-6 Astra | |
| Balanced | Claude Sonnet 5.5 | GPT-6.1 Sol | |
| Economy | Claude Haiku 5.5 | GPT-6.1 Terra | GPT-6 Luna (unmeasured) |

### Summary quality

`summaryQuality` is 0–100, on the scale the local summary models will use for "Upgrade" offers. It comes from the
three-hour offsite fixture (22 topics, 66 commitments, 6 notes), the same fixture and scorer for every model:

    summaryQuality = 35 × topics kept / 22
                   + 45 × commitments with the right owner / 66
                   + 10 × notes handled right / 6
                   + 10 × commitments with the right owner / commitments listed   (capped at 1)

Topics and commitments are what a summary is for, so they weigh most; notes are six items, so they weigh little;
the last term charges for restated or invented next steps.

| Model | Topics | Right owner | Notes | Listed | Quality |
| --- | --- | --- | --- | --- | --- |
| Claude Opus 5.5 | 22 | 66 | 4 | 76 | 95 |
| Claude Sonnet 5.5 | 22 | 66 | 3 | 76 | 94 |
| Claude Haiku 5.5 | 22 | 64 | 3 | 75 | 92 |
| GPT-6 Astra | 22 | 62 | 5 | 89 | 93 |
| GPT-6.1 Sol | 22 | 61 | 6 | 88 | 94 |
| GPT-6.1 Terra | 22 | 62 | 6 | 82 | 95 |
| Gemma 4 26B A4B (local) | 22 | 66 | 3 | 129 | 90 |
| Gemma 4 E4B (local) | 14 | 29 | 2 | 36 | 53 |

The cloud rows are the lead's runs with the measuring prompt (one request, commitments with quotes), before this
change's notes fix; the local rows are docs/validation.md's three-hour meeting. Re-measure with `--cloud-check` and
the harness's scorer when the prompt or a model changes, and update the catalog.

## Prices

Prices come from OpenRouter's model list (`GET https://openrouter.ai/api/v1/models`), whose `pricing` is USD per token
as strings: `prompt`, `completion`, and `overrides` for long prompts (Claude Haiku 5.5's 0.50/2.50 over 100K input
tokens; OpenAI's 2× input and 1.5× output over 272K). Daybook keeps, per model, the prices per million tokens, the
long-prompt rates, `context_length`, `top_provider.max_completion_tokens`, `reasoning.supported_efforts`, and whether
`supported_parameters` includes `structured_outputs`. Only `anthropic/` and `openai/` models are kept, never `:batch`.

- **When:** once there's a key, then at most once a day (`CloudDirectory.priceLifetime`).
- **Offline:** the bundled snapshot, `CloudPrices.json`, which has every catalog model. A live list's entries win over
  the snapshot's.
- **IDs:** OpenRouter's `anthropic/claude-sonnet-5.5` is Anthropic's `claude-sonnet-5-5` (the version's dots become
  dashes; a snapshot date is dropped); `openai/gpt-6.1-sol` is `gpt-6.1-sol`.
- **Estimated:** a newer version OpenRouter doesn't list yet takes its family's newest price, marked "estimated price"
  in Settings. A model with no price at all isn't offered.
- **Refreshing the snapshot:** fetch the list and keep `anthropic/` and `openai/` entries without `:batch`, with the
  fields above (the script is in docs/validation.md, 2026-10-31).

## What's offered

`CloudCatalog.offers(listings:prices:)` takes what each provider's own model list says the key reaches and keeps:

- a measured model, with its catalog rank;
- a newer version of a known family (`claude-sonnet-6`, `gpt-7-astra`), ranked after the measured ones in its tier,
  newer first, then cheaper; its estimates use its family's newest measurements;
- a "-pro" variant, as its own model, only when the provider lists it and it's at least the family's measured version;
- a dated snapshot only when its alias isn't listed.

An older version of a family (`claude-sonnet-4-6`) isn't offered. Each offer's efforts are those the provider or
OpenRouter says the model takes, of Low, Medium, and High (all three when neither says); its output limit is the
provider's `max_tokens`, else OpenRouter's, else 32,000.

**Recommendation and resolution** (`[CloudOffer].resolve`): the chosen model while a key reaches it; else the tier's
best-ranked offer; else the nearest tier's (Balanced, then Economy, then Best). A chosen model that's gone isn't
cleared: it comes back when its key does. Choosing a tier goes back to its recommendation.

## Keys

One key per provider, in iCloud Keychain (`KeychainCloudKeyStore`): a generic-password item, service
`local.daybook.cloud-key`, account `anthropic` or `openai`, label "Daybook Anthropic API key", synchronizable,
readable after first unlock, in the keychain group both apps share (`<team>.local.daybook.shared`, where library keys
live; `KeychainLibraryKeyStore.sharedGroup()`). A key added on the Mac reaches the iPhone; removing one removes it
everywhere (Settings says so). A Mac build without the shared group (unsigned development builds) keeps keys in its
login keychain, unsynced.

A key is never logged, synced through the library, written to preferences, or shown in full: `CloudAPIKey`'s
description, debug description, and mirror are the masked form ("sk-ant-…gDAA"), and provider error messages are
masked too (`CloudError.scrubbed`). Adding a key checks it first with the provider's model list: it's kept only when
the provider accepts it ("This key works"), else the reason ("Anthropic didn’t accept this key.") with the provider's
words behind Details.

## Discovery

`CloudDirectory` asks each provider with a key for its list (Anthropic `GET /v1/models`, every page, with
`max_input_tokens`, `max_tokens`, and `capabilities.effort`; OpenAI `GET /v1/models`, filtered by the family rules),
and keeps it in preferences with the time it was fetched, until Settings opens or a refresh is asked for
(`availableModels(refresh: true)`). A list that can't be fetched keeps the last one. A provider's list goes when its
key does.

## Requests

| | Anthropic | OpenAI |
| --- | --- | --- |
| Endpoint | `POST /v1/messages`, `anthropic-version: 2023-06-01`, `x-api-key` | `POST /v1/responses`, `Authorization: Bearer` |
| Prompt | `system`: `MeetingSynthesis.instructions`; one user message | `instructions`; `input` |
| Reasoning | `thinking: {type: "adaptive"}`, `output_config.effort` | `reasoning.effort` |
| Structure | `output_config.format: {type: "json_schema", schema}` | `text.format: {type: "json_schema", name, schema, strict: true}` |
| Limit | `max_tokens` | `max_output_tokens` |
| Other | `stream: true`; `fallbacks: "default"` with `anthropic-beta: server-side-fallback-2026-07-01` for Opus 5.5 and Sonnet 5.5 | `stream: true`, `store: false` |

The schema is sent as written, so its properties keep their order (the order a reply is written in). Replies stream
as server-sent events: Anthropic's `message_start` (model, input tokens), `content_block_delta` text, `message_delta`
(stop reason, output tokens); OpenAI's `response.output_text.delta`, `response.refusal.delta`, and
`response.completed` or `response.incomplete` with usage. A stream that ends without a stop broke off.

**Failures**, each a plain sentence with the provider's words behind Details (`CloudError`):

| What happened | Message | Tried again |
| --- | --- | --- |
| 401, a refused key | "Anthropic didn’t accept this key." | No |
| 402, `billing_error`, `insufficient_quota` | "Your OpenAI account is out of credit." | No |
| 429 | "Anthropic is limiting requests from this key. Try again in a minute." | Yes, after `retry-after` (or `retry-after-ms`, or OpenAI's rate-limit resets) when it's a minute or less, else 2 s, 8 s |
| 5xx, 529, an `overloaded_error` in the stream | "Anthropic is busy. Try again in a few minutes." | Yes, 2 s then 8 s |
| No connection | "You’re offline." | No |
| A dropped or timed-out connection | "The connection to Anthropic was lost." | Yes |
| 403 or 404 for the model | "This key can’t use Claude Sonnet 5.5." | No |
| `stop_reason: "refusal"`, an OpenAI refusal | "Claude Sonnet 5.5 declined to summarize this conversation." (the category in Details) | No |
| The reply's limit, twice | "The summary was longer than Claude Sonnet 5.5 can write." | Once, with the model's whole limit |
| Another 400 | "Anthropic couldn’t take this request." | No |

Three tries in all. A 400 naming the fallback beta (an account it isn't open to) sends the request once more without
`fallbacks`. With a fallback, the declined model's partial text is discarded and the summary records the model that
wrote it.

## The summary

`CloudSummarizer.summary` (and `summarize`, the protocol's) builds the same source a local summary does
(`MeetingEvidence.summarySource`) and the local pipeline's final prompt and schema in one pass over the whole
conversation (every catalog model's window holds far more than a day of talk), through `CloudSynthesis`:

- **Prompt:** `MeetingSynthesis.finalPrompt` with the template's kind and instructions (bounded to about 700 tokens, as
  locally), the vocabulary, the transcript with notes and bookmarks in place, and two cloud additions:
  `quotesActions` (each action item with an exact quote from the transcript) and `findsWhatNotesAdd` (below). Local
  prompts are unchanged.
- **Schema:** `CloudSynthesis.schema`, the local `summarySchema`'s properties in the same order as structured outputs
  take them: plain strings (the providers' decoders escape quotes, which the local grammar's pattern works around), no
  `maxItems`, every object closed with all its properties required, action items with `evidence`, and, with notes, the
  notes' findings first. A test keeps it in step with the local schema.
- **Commitments:** the reply's action items go through `MeetingSynthesis.verifiedActions`, the commitments pass's check:
  only those whose quote is in the transcript, word for word, each with the owner the quote shows. A notes-only
  conversation has none.
- **Parsing:** `MeetingSynthesis.parse`, so a cloud summary has the same shape, terms check, and fallbacks as a local
  one.
- **Limit:** twice the expected output plus 8,000 tokens, at least 16,000, at most the model's; a reply cut off there
  is asked for once more with the model's whole limit.
- **Progress:** the reply's characters against what the model is expected to write.

**Notes (the fix for Claude).** Claude Sonnet 5.5 and Haiku 5.5 folded what only a note said into the summary as if it
had been said (3 of 6 notes handled right on the offsite). With notes, the cloud reply first fills `notes`: for each
note, what the conversation says about its subject, what the note adds that no speaker said, and any conflict; then
every fact in a note's "adds" is written in its section as the user's, in a sentence that starts "Your notes add".
Working it out in the reply, rather than only being told to, is the same idea as the local note check
(`MeetingSynthesis.notesRepeatingWhatWasSaid`) in one pass. It needs the owner's real run to confirm (docs/validation.md).

**Provenance** (`CloudProvenance`): the summary's `modelID` and `ProcessingSettings.modelID` are
"anthropic/claude-sonnet-5-5"; `ProcessingSettings.model` has family `anthropic`, variant `claude-sonnet-5-5`, engine
`cloud`, and the name "Claude Sonnet 5.5"; the parameters keep `cloudProvider`, `cloudModel` (the provider's model ID),
`effort`, `inputTokens`, `outputTokens`, `estimatedCostUSD` (from the price in force, long-prompt rates included),
`priceIsEstimated`, `sentBy` (the device that sent it: `CloudSummarizer(directory:deviceName:)`; the Mac gives
`ProcessingRequest.Device.currentName`, the iPhone its library name), `templateID`, and `templateInstructions`
(`CloudProvenance.Key`). The placement adds where it ran on the same summary (docs/multipoint.md, "Where summaries
run"): `summarizedBy`, `summarizedByName`, `place` (`cloud`), and `model.<role>`, with `model.summarization`
"anthropic/claude-sonnet-5-5". A summary placed in the cloud without the cloud's provenance (a test's or a demo's
stand-in) gets the model it was sent to, so every cloud summary has both. `MeetingSummary.origin.cloudModel` is the
model's name for any cloud summary, placed or not (`--cloud-check`'s, or one written before the placement). The
page's colophon reads "Summarized with Claude Sonnet 5.5", with the cloud glyph, on both apps; the Mac inspector's
Summary row names the model, with its tokens and cost under it ("12,700 tokens · $0.05", `CloudProvenance.usage`).

## Estimates

- **An hour** (Settings): `provider.inputTokensPerMinute × 60 + promptCharacters / charactersPerToken` tokens in, and the
  model's measured output for 60 minutes at the preferred effort, at its prices. Measured hours at medium: Sonnet $0.0885
  (estimate $0.091), Sol $0.0798 ($0.082), Haiku $0.0077 ($0.0078).
- **A conversation:** the same with its minutes (`CloudOffer.estimatedCost(minutes:effort:)`); output between measured
  lengths in proportion, longer at the longest run's rate. After the run, the provenance records the real tokens and
  their cost.

## Settings

Settings › Cloud (a pane of its own on the Mac, between Models and Devices; a screen on the iPhone, after Models):

- **Keys:** each provider's masked key with Replace… and Remove…, or Add Key…. Adding opens a sheet (Mac) or screen
  (iPhone) with a secure field; it checks the key before keeping it.
- **Summaries** (once a key is set): Use the cloud (Offer First, Always, Never), and Countdown (15 or 30 seconds) while
  it offers first.
- **Quality** (unless Never): Best, Balanced, and Economy, each with its recommended model and what an hour costs; Model,
  Recommended or a model of the tier (with its cost when one is chosen); Effort, the efforts the model takes.
- One footer line: "Sends the transcript and notes, never audio."

Preferences (`CloudSummaryPreferences`) are each device's own, in its UserDefaults (`cloudSummaryPreferences`), read and
written only through `CloudSetup.preferences`; the Mac's `--library` runs keep their own suite. The countdown's length
and the policy (Offer First, Always, Never) live here and nowhere else: the placement reads them from the same
`CloudSetup`. Debug builds open the pane with `--open-settings cloud` and fill it with
`--cloud-demo none|anthropic|both|never|failed` (in-memory keys, the catalog's models, no network); the iPhone also
takes `--open-settings cloud-key`.

## Checking a model

A debug build summarizes one fixture with a real key and prints the tokens and cost:

    ANTHROPIC_API_KEY=… .build/debug/Daybook --cloud-check anthropic claude-sonnet-5-5 offsite.json [--fixture <id>]
        [--effort low|medium|high] [--output run.json]

The key comes from `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or `DAYBOOK_CLOUD_KEY`) and is printed only masked. The
fixture is the summary harness's format (`[{id, title, kind, speakers, lines, notes, bookmarks}]`) or a conversation's
`meeting.json`. Nothing touches a library, the keychain, or the app's preferences. `--output` writes the run in the
harness's scoring format. `DAYBOOK_CLOUD_BASE_URL` sends every request to another server, such as a local fake one.

## For callers

Both apps' summary placement (docs/multipoint.md, "Where summaries run") reaches the cloud through one `CloudSetup`
each: `AppState.cloud` on the Mac (made when Settings › Cloud or a summary step first needs it) and
`PhoneAppModel.cloudSummaries` on the iPhone (handed to `PhoneSummaryPlacement.cloud` at launch).

- **What's on offer:** `resolved` (the `CloudOffer` the preferences choose, nil without a key) is the placement's
  `SummaryOptions.cloud`; the planner leaves it out with Never. `preferences` give the policy, the countdown, and the
  effort.
- **Changes:** `onChange` fires when a key, the models offered, or the preferences change, and the placement updates
  every countdown at once (a key removed or Never chosen mid-countdown starts its default now).
- **Before a summary is placed:** `reload()` reads the keys again and the models kept for them. No provider is asked,
  except once for a key this device never listed (one added on the other device, which iCloud Keychain brought). The
  iPhone also reloads at launch and when it comes back to the screen.
- **The summary:** `CloudSummarizer(directory: cloud.directory, deviceName:)`, the concrete `CloudSummarizing`; callers
  use `summaryOutput(…)`, which keeps the suggested vocabulary and warnings `CloudSummarizer.summary` returns (a
  `CloudSummarizing` fake gives the summary alone). The summary step applies it with `MeetingSummary.placed`, which
  keeps the cloud's provenance and adds where it ran. Tests and demos set a summarizer of their own
  (`AppState.cloudSummarizer`, `PhoneSummaryPlacement.cloudSummarizer`) and Settings with in-memory keys
  (`CloudSetup.demo`).
- `estimatedCost(_:template:vocabulary:model:effort:)` prices a conversation before anything is sent.

## Tests

`CloudCatalogTests`, `CloudKeyStoreTests`, `CloudClientTests`, and `CloudDirectoryTests` (DaybookKitTests) and
`CloudSummarizerTests` (DaybookIntelligenceTests) run against `FakeCloudServer` (DaybookTestSupport), a URLProtocol
that answers as Anthropic, OpenAI, and OpenRouter with a host per test: no test reaches the network or the keychain.
