# Cloud summaries

A summary can be written by a cloud model, Anthropic's or OpenAI's, with the person's own key. Everything else stays on
the device: transcription, speaker detection, voice profiles, and audio. With no key nothing changes and nothing is
offered. With a key, Settings › Cloud chooses when summaries use the cloud (offered with a countdown first, always, or
never), for which conversations (a switch for each placement, Work and Personal, and one for Not Filed), and which model. Where a summary runs is decided by the placement planner (`SummaryPlacementPlanner`, the
placement stream); this page is the cloud side: the catalog, keys, discovery, the requests, and the summary itself.

## What is sent

A cloud summary sends the conversation's transcript text (with each note and bookmark in place, and the passages near
them marked), the notes (including words read from notebook pages) and bookmarks, the template (its kind and instructions), the vocabulary, and the conversation's
title and date. The title goes only when the person or the calendar gave it (never "Untitled Conversation", a recording's
placeholder, or a title a summary wrote earlier), cut to 120 characters; the date is when the conversation began as the
person's local day, time, and time zone, sent only when a recording's start is known, so the model can resolve "next
Tuesday" (`SummarySource.Context`). Nothing else: no audio, no photos or their captions, no notebook page pictures or sketches (nor a sketch's description or label), no voiceprints, no speaker
profiles, no calendar attendees or other calendar detail. Words from a page reading that isn't current, or of a passage kind this version doesn't know, are never sent. Photo captions and sketch descriptions stay on the device, so a cloud
summary places photos and sketches by time only (`PhotoPlacement.arrange`, `NotebookPlacement.arrange`). OpenAI's request sets `store: false`, so the response
isn't kept on OpenAI's side. The same is sent whatever brought the summary to the cloud ("When the cloud is chosen").

**Which conversations.** Settings › Cloud has a switch for each placement this version knows (`LibraryPlacement.allCases`:
Work, Personal) and one for Not Filed, kept in this device's preferences (`CloudSummaryPreferences.placements`,
`CloudPlacements`). A conversation's placement is the person's filing, else what its template or summary says
(`Meeting.effectivePlacement`: the Therapy and Personal templates and kinds are Personal, the rest Work). A conversation
not filed yet (neither the person nor its kind has placed it: every new recording's first summary) follows Not Filed's
switch, never Work's. Personal is off, and Work and Not Filed on, until the person changes them, which is what Daybook did
before there were switches (Always sent a conversation not filed yet); preferences saved before them read as those
defaults. A conversation whose placement or kind (or, while its kind is Automatic, its summary's kind) was written by a
newer Daybook, which this version can't read, is never sent: what the person chose for it is unknown here. Switches stored
in a shape this version can't read (malformed, or a newer version's) let nothing go, and Settings shows them all off; they're
written back as they were, so the version that wrote them reads them again, until the person sets a switch here, which
replaces them (that switch as set, the rest off). Switches in this version's shape keep any key it doesn't know. An older
Daybook that predates the switches drops them when it saves its preferences, so after going back to it and forward again
they're the defaults. A conversation whose switch is off is never sent to the cloud, whatever asks: Use the Cloud isn't offered
for it (the countdown, the wait for a Mac, the wait for this Mac's summary model, the status sheet and Floating Notes),
the cloud's Upgrade isn't offered, Always doesn't send it, and a countdown has nothing to offer, so it starts where it
can at once. Below the interface, the code that sends a summary checks again with the conversation as it is then
(`AppState.placedSummary` on the Mac, `PhoneSummaryPlacement.run` on the iPhone): a queued Use the Cloud, a cloud
upgrade accepted earlier, or a conversation moved to Personal (or a switch turned off) while it counts down is
summarized on the device instead, or sent to a Mac. Preferences are each device's own, so the device that sends a
summary applies its own switches; a Mac's countdown seen on an iPhone offers what the Mac's switches allow.

OpenRouter's model list (for prices) is fetched without a key and carries nothing about the person: no key, no cookies,
and a bare `User-Agent: Daybook`. It's fetched only once a key has been added.

## When the cloud is chosen

Always inside the privacy rule: the person's own key, a policy that isn't Never, and a conversation whose placement's
switch is on (above). Within it:

- **Use the Cloud**, an Upgrade to the cloud's model, and **Always**, as before.
- **Summarize Again with the cloud's model.** Summarize Again on the page's foot is a menu when there is more than one way
  to redo the summary (`SummarizeAgainChoices`): this device's installed summary models that fit (the chosen one first),
  then the cloud's model, "With Claude Sonnet 5.5". Rows that don't hold are absent. The same menu is Reprocess ▸ Summarize Again
  in More, a row's menu, Conversation ›, and Info (`ConversationActions`; a selection's stays plain); the cloud's row carries the
  cloud glyph, and the row of the model that wrote the current summary is checked.
  - **A model of this device's runs on this device, always.** Not under Always, and not after a failure: the Mac queues it
    as Summarize on This Mac is (`summarizesHere`), the iPhone keeps it here (`keptHere`, `beginHere`). On the Mac, another
    model than Settings' is for that job only; Settings keeps its choice. If that model goes while the job waits in the
    queue (uninstalled, or no longer fits), the job runs Settings' model on the Mac (`jobWithUsableSummaryModel`); if
    that isn't installed either, the summary waits for the summary model as any does. Never a download, never the cloud.
    A Mac that quits meanwhile asks for a plain Summarize Again when it starts again.
  - **The cloud row** is there only inside the privacy rule (a key, a policy that isn't Never, this device's switch for the
    conversation's placement, a placement or kind this version reads). Choosing it is the person's choice, sent as Use the
    Cloud is (`AppState.summarizeInCloud`; on the iPhone the summary is due, then Use the Cloud), which checks the
    conversation as it is at the click and again as it sends. It sends only if the cloud model resolved now is the one the
    row named; otherwise nothing is queued or sent and the menu, drawn from what's true now, drops the row. The iPhone acts
    only on the placement that call made and only on the screen, so a Mac's countdown is never handed it. Settings › Cloud
    holds one chosen model, so there is one cloud row, not one per provider. Naming a Mac is a follow-up: it needs a
    target on the request.
- **Only while the countdown is seen.** A countdown that ends in the cloud, whatever brought it there, runs only while the
  person can see it (`SummaryPlacements.countdownsAreSeen`). On the Mac (`CountdownVisibility`): its login session is the
  active one (`NSWorkspace` session notifications), the screen is unlocked (`com.apple.screenIsLocked`/`Unlocked`) and
  awake (`screensDidSleep`/`Wake`), the Mac isn't going to sleep (`willSleep`/`didWake`), Daybook isn't hidden, and the
  library window (whose list and page show a running summary's countdown) or Floating Notes is on the screen, not
  minimized and not covered (`NSWindow.occlusionState`); the menu bar item isn't counted. On the iPhone
  (`PhoneSummaryPlacement.isOnScreen`): the scene is active and iOS says the app is (`UIApplication.applicationState`, read
  each time, so a background launch starts unseen). When that stops being true, the countdown doesn't end in the cloud:
  the summary runs where it would have without the cloud (this device, or a Mac; after a failure here, the job fails), and
  it never goes back to the cloud on its own. A countdown that would begin, or come to end in the cloud, while unseen does
  the same. Always is unchanged: the person chose to send without asking.
- **A conversation the local model reads in more than one pass** (`LongConversations.cloudDoesBetter`): one longer than
  the model it would run on (this device's, or on an iPhone the Mac it would go to) reads whole, by the catalog's
  whole-read limit or its window (docs/model-runtime.md, "Usable window"; 5,400 tokens for every built-in model, about 17
  minutes of talk), when the cloud's model ranks above that model by the summary Upgrade margin (10 on the shared
  quality scale, `UpgradeRole.margin`: Claude Sonnet 5.5's 94 against Gemma 4 E4B's 53 is, against Gemma 4 26B A4B's 90
  isn't). The length is estimated before anything runs, at 3.5 characters a token (the local tokenizers read about 3.6
  on the three-hour fixture). Under Offer First its countdown ends in the cloud, "Summarizing with Claude Sonnet 5.5 in
  12 s", with Start Now and Don't Use the Cloud, which runs it where it would have run (this device, or the Mac); it's
  never sent without a whole countdown: one that comes to end in the cloud partway (a Mac's model changed) starts its
  time again, and an iPhone that leaves the screen mid-countdown, or whose summary falls due out of sight (where a
  countdown can't run), runs it where it would have run instead. Use the Cloud or an Upgrade to the cloud's model
  during it sends it at once, as the person's choice. Under Always it goes at once, as anything does. A summary someone
  asked for (Summarize Again, a template, Try Again, or another device's request syncing in) starts at once where it can,
  so never in the cloud on its own; asked for during a countdown that ends in the cloud, it leaves that countdown as it
  is, and only Start Now on it, where it's shown as it is, starts it early. A Mac's countdown seen on an iPhone names
  the model (`LinkProcessingProgress.cloudModel` during `summaryCountdown`) and sends Don't Use the Cloud back as
  `processing.choice` `useLocal`; a Mac before this one ignores it. An iPhone lists `cloudCountdown` when it shows such a
  countdown as one (`LinkCapabilities.cloudCountdownFeature`); one before this version, which would show it as the
  Mac's own, gets it with no countdown and no model ("Summarizing", nothing to choose), and the Mac ignores its Start Now
  and Use the Cloud for it, so the Mac's own countdown, while seen, is where it's chosen.
- **A summary that failed on the device** tries the cloud before the job fails, under the same rules: at once under
  Always, after a countdown to the cloud under Offer First (declined, the job fails with what went wrong on the
  device), never for a conversation kept off the cloud, one the person asked to summarize on this Mac, one whose cloud
  countdown they declined (Don't Use the Cloud) or that ran here because nobody could see it, or one the cloud already
  couldn't read. On the Mac, as it's sent, another device holding the summary or one it wrote since the summary step
  began stands this Mac down (the step's first start is kept, so a summary written meanwhile is never replaced). On the
  iPhone the processor asks the placement first (`PhoneProcessor.Services.summaryFailed`), and the request stays the
  iPhone's while the cloud is tried.
- **A conversation longer than the cloud model can read** (`CloudError.inputTooLong`, checked before sending) is
  summarized on the device instead (or, from an iPhone without a summarizer, by a Mac), with the cloud's sentence among
  the summary's warnings.

The summary records why it went (`cloudReason` in its parameters, `MeetingSummary.cloudReason`): `chosen`, `always`,
`longConversation`, or `localFailed`.

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
  price), a **summary quality** (below), whether Anthropic's refusal fallback applies, the efforts it takes (from the
  provider's model page), and how many tokens it writes: output tokens (reasoning included) for 15, 30, 60, 120, and
  186 minutes at medium effort, and low and high against medium on an hour (docs/validation.md, 2026-10-31). Extra
  High and Max aren't measured: each is a further step of high's ratio (Claude Sonnet 5.5's high is 1.72× medium, so
  Extra High is estimated at 2.96× and Max at 5.09×) until `--cloud-check` measures them.
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

`summaryQuality` is 0–100, on the scale the local summary models use for "Upgrade" offers (their `quality` in the model
catalog, docs/models.md, "Quality ranks"; docs/multipoint.md, "Upgrade"). It comes from the
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

An older version of a family (`claude-sonnet-4-6`) isn't offered. Each offer's efforts are those the provider says the
model takes (Anthropic's `capabilities.effort`: `low`, `medium`, `high`, `xhigh`, `max`, each `supported` or not), else
OpenRouter's `reasoning.supported_efforts`, else the catalog's (the model's or its family's newest), else Low, Medium, and
High; its output limit is the provider's `max_tokens`, else OpenRouter's, else 32,000.

**Effort.** Five levels, lowest first: Low, Medium, High, Extra High (`xhigh`), and Max. Every catalog model takes all
five: Anthropic's effort page lists `xhigh` and `max` for Claude Opus 5.5, Sonnet 5.5, and Haiku 5.5, and OpenAI's model
pages list `low` through `max` for GPT-6 Astra, GPT-6.1 Sol, GPT-6.1 Terra, and GPT-6 Luna (Terra and Luna also take
`none`, which Daybook doesn't use; checked 2026-11-16: platform.claude.com/docs/en/build-with-claude/effort,
platform.claude.com/docs/en/api/models/list, developers.openai.com/api/docs/guides/reasoning and its model pages).
Summaries ask for Extra High unless the person chooses another level in Settings (`CloudSummaryPreferences.effort`,
`effortIsChosen`); a model that doesn't take the level asked for gets the highest it takes below it, else the lowest
above (`CloudOffer.effort`), so the default is Extra High where offered and the highest level below it elsewhere.
Preferences an earlier version saved have no `effortIsChosen`: their Medium, the old default, can't be told from a
Medium the person chose, so it moves to Extra High, and a Low or High they chose stays.

**Recommendation and resolution** (`[CloudOffer].resolve`): the chosen model while a key reaches it; else the tier's
best-ranked offer; else the nearest tier's (Balanced, then Economy, then Best). A chosen model that's gone isn't
cleared: it comes back when its key does. Choosing a tier goes back to its recommendation.

## Keys

One key per provider, in iCloud Keychain (`KeychainCloudKeyStore`): a generic-password item, service
`local.daybook.cloud-key`, account `anthropic` or `openai`, label "Daybook Anthropic API key", synchronizable,
readable after first unlock, in the keychain group both apps share (`<team>.local.daybook.shared`, where library keys
live; `KeychainLibraryKeyStore.sharedGroup()`). A key added on the Mac reaches the iPhone; removing one removes it
everywhere (Settings says so). Replacing a key changes its item in place (`SecItemUpdate`, an add only when there's
none), never a removal first: a removal reaches every device, so a write that failed would leave no key anywhere. A
Mac build without the shared group (unsigned development builds) keeps keys in its login keychain, unsynced.

A key is never logged, synced through the library, written to preferences, or shown in full: `CloudAPIKey`'s
description, debug description, and mirror are the masked form ("sk-ant-…gDAA"), and provider error messages are
masked too (`CloudError.scrubbed`). Adding a key checks it first with the provider's model list: it's kept only when
the provider accepts it ("This key works"), else the reason ("Anthropic didn’t accept this key.") with the provider's
words behind Details. A key goes only to its own provider: one whose prefix names the other (`sk-ant-` in OpenAI's
field; `sk-proj-`, `sk-svcacct-`, or `sk-admin-` in Anthropic's; `CloudAPIKey.issuer`) is refused before anything is
sent, with "This is an Anthropic key." or "This is an OpenAI key." So is an OpenRouter key (`sk-or-`) in either field
("This is an OpenRouter key."), and any key without `sk-ant-` in Anthropic's, since every Anthropic key has it ("This
isn’t an Anthropic key."; `CloudAPIKey.refusal`). In OpenAI's field, a key with no recognizable prefix (an older OpenAI
key) is OpenAI's to judge.

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
| Reasoning | `thinking: {type: "adaptive"}`, `output_config.effort` (`low` … `max`) | `reasoning.effort` (`low` … `max`) |
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
| The prompt is longer than the model's window (checked before sending) | "This conversation is longer than Claude Sonnet 5.5 can read." | No; nothing is sent |
| Another 400 | "Anthropic couldn’t take this request." | No |

Three tries in all. A 400 naming the fallback beta (an account it isn't open to) sends the request once more without
`fallbacks`. With a fallback, the declined model's partial text is discarded and the summary records the model that
wrote it.

## The summary

`CloudSummarizer.summary` (and `summarize`, the protocol's) builds the same source a local summary does
(`MeetingEvidence.summarySource`) and the local pipeline's final prompt and schema in one pass over the whole
conversation, checked against the model's window first (a prompt longer than it is never sent; every catalog model's
1M-token window holds far more than a day of talk), through `CloudSynthesis`:

- **Prompt:** `MeetingSynthesis.finalPrompt` with the template's kind and instructions (bounded to about 700 tokens, as
  locally), the vocabulary, the conversation's title and date, the transcript with notes and bookmarks in place, and two cloud additions:
  `quotesActions` (each action item with an exact quote from the transcript) and `findsWhatNotesAdd` (below). Local
  prompts are unchanged.
- **Schema:** `CloudSynthesis.schema`, the local `summarySchema`'s properties in the same order as structured outputs
  take them: plain strings (the providers' decoders escape quotes, which the local grammar's pattern works around), no
  `maxItems`, every object closed with all its properties required, action items with `evidence`, and, with notes, the
  notes' findings first. A test keeps it in step with the local schema.
- **Commitments:** the reply's action items go through `MeetingSynthesis.verifiedActions`, the commitments pass's check:
  only those whose quote is in the transcript, word for word, each with the owner the quote shows, and a commitment
  restated later in other words kept once (`RestatedCommitments`). A notes-only conversation has none.
- **Parsing:** `MeetingSynthesis.parse`, so a cloud summary has the same shape, terms check, and fallbacks as a local
  one.
- **Limit:** twice the expected output (at the effort sent) plus 8,000 tokens, at least 16,000, at most the model's; a
  reply cut off there is asked for once more with the model's whole limit.
- **Window:** before anything is sent, the prompt's tokens, estimated from its characters (2.8 a token for Claude,
  4.0 for OpenAI's models), with room for the smallest reply limit (16,000 tokens, which providers count against the
  window), are checked against the model's window (`max_input_tokens`, else OpenRouter's `context_length`); a longer one
  fails with `CloudError.inputTooLong` and isn't sent.
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
run"): `summarizedBy`, `summarizedByName`, `place` (`cloud`), `cloudReason` (why it went, "When the cloud is chosen"),
and `model.<role>`, with `model.summarization` "anthropic/claude-sonnet-5-5". A summary placed in the cloud without the cloud's provenance (a test's or a demo's
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
- **Use the cloud for** (unless Never): a switch for each placement, Work and Personal, then Not Filed; labels only.
- **Quality** (unless Never): Best, Balanced, and Economy, each with its recommended model and what an hour costs; Model,
  Recommended or a model of the tier (with its cost when one is chosen); Effort, the efforts the model takes (a segmented
  control on the Mac, a menu on the iPhone), showing the level a summary would ask for: Extra High until one is chosen.
- One footer line: "Sends the transcript, notes, vocabulary, and the title and date, never audio."

Preferences (`CloudSummaryPreferences`) are each device's own, in its UserDefaults (`cloudSummaryPreferences`), read and
written only through `CloudSetup.preferences`; the Mac's `--library` runs keep their own suite. The countdown's length
and the policy (Offer First, Always, Never) live here and nowhere else: the placement reads them from the same
`CloudSetup`. Debug builds open the pane with `--open-settings cloud` and fill it with
`--cloud-demo none|anthropic|both|never|failed` (in-memory keys, the catalog's models, no network); the iPhone also
takes `--open-settings cloud-key`.

## Checking a model

A debug build summarizes one fixture with a real key and prints the tokens and cost:

    ANTHROPIC_API_KEY=… .build/debug/Daybook --cloud-check anthropic claude-sonnet-5-5 offsite.json [--fixture <id>]
        [--effort low|medium|high|xhigh|max] [--output run.json]

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
