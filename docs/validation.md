# Validation record

## Restated commitments, notes that repeat what was said, and the unchecked models (2026-10-31)

The section below left six things open: a three-hour meeting's summary listed 129 actions for its 66 commitments,
Gemma 4 E2B listed a customer's process and a question as commitments, a note that only repeats what was said still
got "Your notes add", splitting a long meeting left a last part of 828 tokens, four catalog models had never run the
new pipeline, and Qwen 2.5 1.5B stood in for summaries it couldn't write. All six are handled here
([model runtime](model-runtime.md), "Summarization"; [templates](templates.md#notes-and-bookmarks);
[models](models.md#selection-updates-and-provenance)).

**Setup.** The same harness, conversations, notes, bookmarks, and scoring as below, against main with #35 (39b89e3) as
"before". Gemma 4 E2B, E4B, 12B, and 31B 8-bit, Qwen 3.5 4B and 9B, and Qwen 3.6 35B A3B were downloaded through the
app's store (`LocalIntelligenceRuntime.download`) into a scratch models folder, every file's SHA-256 or git object ID
checked again afterwards (75 files), and deleted when done; Gemma 4 26B A4B and Qwen 2.5 7B are the installed copies,
used read-only through symlinks (the installed folder's listing unchanged afterwards). Decoding is greedy, so a pass
repeats exactly given the same prompt. Besides whole summaries, two scratch tests ran one kind of pass alone: the
commitments passes (to compare prompts and splits) and the note check (to compare models). The commitments passes
read only the transcript, so where only they changed after a whole run, they were run again alone and their actions
put with that run's summary; where only the reading of replies changed (quotes, restatements, markers), the saved
replies were read again by the final code. Loads are the load average when a run started; other agents' builds and
tests shared the Mac.

**Changes.**

- **Restated commitments** (`RestatedCommitments`). Commitments are listed in the order they were said, and a later
  one with the same owner whose task is mostly an earlier one's distinctive words (0.6 of the shorter task's weight)
  is the same commitment, kept once in its first wording; so is one that sums up several earlier ones (0.75 of its
  weight, each sharing two of its words: "Complete account deletion, refund status, and the kill switches"). A word
  weighs more the fewer of the meeting's commitments use it, so "fix" or "iOS" alone never make two tasks one;
  versions count alike in words and digits ("five point seven", "5.7"), plain numbers and dates don't count, and two
  commitments quoted from different words of one passage, listed side by side, are never one. On the 26B's
  three-hour meeting, the restatements merged scored 0.61 and more, and the closest two different tasks of one owner
  0.55 ("Build the Android flow in the same sprint", "Build the update screen on Android for version 6.1").
- **Quotes.** A quote shortened with an ellipsis ("[...]", "…"), or whose sentences skip what was said between them,
  counts when each piece is there word for word, in order, with at most 400 characters between them; a quote in its
  own quotation marks counts without them.
- **Even parts.** A long conversation is still read in as few parts as full ones would take, but each closes nearest
  an even share of what's left. The commitments passes keep #35's parts, evened out only where those leave a part
  under half the size of another.
- **Notes that repeat what was said** (`noteCheck: "on"`: Gemma 4 26B A4B and 31B 8-bit, Qwen 3.6 35B A3B). Before
  anything is written, one pass compares each note on the timeline with what was said from two minutes before it to
  30 seconds after (what the passages say about it, what the note adds, where it conflicts). A note that adds nothing
  and conflicts with nothing goes on to every pass without its words (`NOTE N1, written by the user, repeats what was
  said around it`), so none can give it "Your notes add"; its passages still carry more weight. The summary compares
  the rest as before. On the other models the check called notes that add something repeats, so they don't run it.
- **Markers in a summary.** The extraction's "NOTE N2 adds: …" reads "Your notes add: …", and "Note N2 suggests"
  reads "Your note suggests".
- **Gemma 4 E2B's brief commitments prompt** says the quote is the person taking the task on ("the person saying they
  will do it, or agreeing to it") and leaves out "how things are done today, or what someone needs or wants".
- **Qwen 2.5 1.5B serves no role** (`roles: []`, catalog 2026.10.31), below.

**Restated commitments, on the 26B.** The three-hour meeting's 66 commitments are 76 people's: ten were each taken
on by two people, one per platform ("Spike storage for iOS" for Lena, "Spike storage for Android" for Oskar), and
both stay. The recap at the end restates most of them ("Complete the storage spike", "Release Bugnet in five point
seven", "Complete account deletion, refund status, and the kill switches"), and the parts' overlap repeats a few.

| | Before | Now |
| --- | --- | --- |
| Three-hour meeting: actions listed | 129 | 90 |
| Three-hour meeting: commitments kept (owners right), of 66 | 66 (66) | 66 (66) |
| Weekly: actions listed, commitments kept (owners), of 38 | 43, 36 (36) | 43, 36 (36) |
| Short conversations: actions listed, commitments kept (owners), of 14 | 12, 12 (11) | 12, 12 (11) |

The commitments passes' prompts and parts are #35's, so these are #35's replies, read by today's code: nothing
distinct was merged anywhere, and the weekly and short conversations, with few restatements, list what they did. What's
left of the 90 is the 76 people's commitments, sub-tasks said on their own ("Include the consent question in the
email to legal", "Write automated tests for anonymization on the backend"), a few commitments the fixture doesn't
count ("Pair with Oskar one day a week on the iOS integration"), and restatements with no distinctive words in common
with the first time ("Start the Kotlin spike in February" for "Lead the four-week spike on the fare rules module",
"Complete the Lingo Bridge contract by the twentieth" for "Sign the translation contract by January 20th"). With even
parts (an intermediate version), the 26B quoted the tracking plan as Hana's sentence and Diego's next, leaving out his
"Yes, end of February." between them, so that commitment was rejected; quotes stitched from nearby sentences, or
shortened with an ellipsis ("I'll email legal about the attribution SDK's data sharing this week. [...] Yes, I'll put
both questions in the same email to legal."), now count.

**Parts.** The three-hour meeting is read in five parts of 10,215 to 10,254 tokens, where it was four of 12,000 and
one of 828. The commitments passes keep #35's split, only evened out where it leaves a part under half another's
(none of these conversations): split evenly, the weekly's two commitments parts moved by a passage, and the weekly
commitments each model kept moved too, by up to 13 and in both directions.

| Weekly commitments kept, of 38 | 26B | 31B 8-bit | Qwen 3.6 35B | Qwen 3.5 9B | Qwen 3.5 4B | E2B |
| --- | --- | --- | --- | --- | --- | --- |
| #35's split (now) | 36 | 36 | 34 | 29 | 25 | 18 |
| Even split | 35 | 36 | 33 | 35 | 38 | 13 |

Where the parts split matters more than which split it is; #35's is the one the 26B and E2B were tuned on, and it
gives the presets' models (E2B, 26B, 31B) 90 of their 114 against 84.

**Notes that repeat what was said.** The note check alone, on every model, over the 18 notes on a timeline in the
four conversations and the three-hour meeting: 7 repeat what was said and 11 add something or conflict. "Passed on"
are repeating notes the check found; "lost" are notes that add something it would have passed on without their words.

| Model | Repeats passed on, of 7 | Notes that add, lost, of 11 | Time (four conversations and the meeting) | `noteCheck` |
| --- | --- | --- | --- | --- |
| Gemma 4 31B 8-bit | 7 | 0 | 210 s | on |
| Gemma 4 26B A4B | 5 | 0 | 82 s | on |
| Qwen 3.6 35B A3B | 3 | 0 | 131 s | on |
| Gemma 4 12B | 5 | 2 | 87 s | off |
| Qwen 3.5 9B | 4 | 2 | 96 s | off |
| Gemma 4 E4B | 6 | 4 | 65 s | off |
| Qwen 3.5 4B | 6 | 6 | 77 s | off |
| Gemma 4 E2B | 6 | 8, and 4 notes not checked | 31 s | off |
| Qwen 2.5 7B | 7 | 11 | 38 s | off |

On the 26B the check adds 9 to 25 s to a conversation's summary. Its summaries, before and now: in the four
conversations, one note that repeats what was said is still given "Your notes add" (the weekly's "tell support": the
conversation says only who needs to know, and the check takes the to-do as the note's own), and all five notes that add
something are written as the person's, none as fact. In the three-hour meeting, "Rating drop = mostly the password
reset login loop" no longer gets "Your notes add that this drop is mostly due to the password reset login loop";
"Account deletion has to be in the app (Apple)" is still not attributed; N2 and N3 are added as the notes', N4
(marketing's March 3) stands beside the April 7 that was said, and N5 (Quinn sounds burned out) is still left out.
The 31B gives no repeating note "Your notes add" in any conversation. An intermediate version also gave the summary
the check's findings for the other notes ("adds", "conflicts", and "'Your notes add' is only for a note's adds"): the
26B then gave two repeating notes "Your notes add" ("Your notes add that these exports are run daily"), wrote Dana's
email as a fact, and attributed four of five adding notes, so the summary compares those notes itself, as before.
Other wordings of the check ("everything the passages say about what the note mentions", "what the note would tell
someone who had read the passages") found fewer repeats on the 26B, or lost three notes that add something.

**Gemma 4 E2B's commitments.** The commitments passes alone, on #35's split: listed, then kept (owners right).

| Prompt | Customer interview (1) | Launch (7) | 1:1 (6) | Weekly (38) |
| --- | --- | --- | --- | --- |
| #35's brief prompt | 8 listed, 1 (1) | 4, 3 (3) | 6, 5 (3) | 18, 17 (14) |
| Plus "a commitment is something a person agrees to do after this conversation" | 2, 1 (1) | 6, 4 (4) | 6, 5 (3) | 34, 19 (16) |
| Plus "how things are done today, or what someone needs or wants" | 1, 1 (1) | 5, 4 (4) | 6, 5 (3) | 22, 15 (14) |
| That and "the person saying they will do it, or agreeing to it" | 1, 1 (1) | 5, 4 (4) | 6, 5 (3) | 29, 19 (17) |
| The same, as committed (one line break moved) | 1, 1 (1) | 5, 3 (3) | 6, 5 (3) | 26, 18 (16) |

The customer interview's 8 were the process Elena described ("Paste the export into a Google Sheet that has all our
formulas", "Copy the summary into a Notion page"), a question ("Walk me through what a normal morning looks like"),
what security would want ("Review for security", "Ensure single sign-on with Okta"), and a wish ("Flag exceptions
automatically"); now only Jordan's "Put together a short proposal for a one-month pilot and send it by Friday".

**The models nobody had checked.** Weekly topics of 13 and commitments of 38 (owners right), the short conversations'
commitments of 14, notes that repeat given "Your notes add" (of 5), notes that add something attributed to the notes
(of 5; in parentheses, how many written as if said), conflicts mentioned (of 2), the weekly's time with the load when
it started, and peak MLX memory, weights included. The 26B and E2B rows are this change, for comparison.

| Model | Weekly topics | Weekly commitments | Short commitments | Repeats as "notes add" | Adding notes (as fact) | Conflicts | Weekly time (load) | Peak memory |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gemma 4 31B 8-bit | 13 | 36 (35) | 11 (10) | 0 | 5 (0) | 2 | 1,760 s (11, then 87) | 34.6 GB |
| Gemma 4 26B A4B | 13 | 36 (36) | 12 (11) | 1 | 5 (0) | 2 | 629 s (81) | 15.3 GB |
| Qwen 3.6 35B A3B | 13 | 34 (33) | 11 (10) | 0 | 3 (1) | 2 | 502 s (20) | 20.2 GB |
| Qwen 3.5 9B | 13 | 29 (29) | 10 (9) | 2 | 3 (4) | 2 | 449 s (8) | 6.0 GB |
| Qwen 3.5 4B | 9 | 25 (23) | 11 (9) | 0 | 0 (3) | 1 | 273 s (15) | 3.3 GB |
| Gemma 4 E2B | 13 | 18 (16) | 9 (7) | 0 | 0 (0) | 2 | 256 s (4) | 3.0 GB |

The short conversations took 171 to 194 s each on the 31B, 66 to 85 s on Qwen 3.6, 29 to 39 s on Qwen 3.5, and 23 to
24 s on E2B. What each model needed:

- **Gemma 4 31B 8-bit** (workstation Detailed) needed nothing: every topic, 36 of the weekly's commitments, and every
  note handled right. It's by far the slowest, 29 minutes for the weekly; its second commitments pass alone took 679 s
  while another agent's tests raised the load from 11 to 87.
- **Qwen 3.5 4B** put every quote in quotation marks of its own (`"\"I'll ask Ines about design time this week.\""`),
  so no quote was found: no actions for the 1:1 at all. Quotes are now read without their own quotation marks: 11 of
  the short conversations' 14. It keeps 9 of the weekly's 13 topics, and writes three of the notes' additions as said
  ("Dana confirmed the $40k limit via email this morning").
- **Qwen 3.6 35B A3B** carried the extraction's marking into the weekly's summary ("NOTE N2 adds: 'Ben can maybe swap
  Dec 3 - ask him after.'"), which now reads "Your notes add: …". It checks notes (`noteCheck: "on"`).
- **Qwen 3.5 9B** named a note by its label ("Note N2 suggests Ben might be able to swap"), which now reads "Your note
  suggests…". It still writes most of what only the notes say as said, once as a speaker's ("Sam observed that Alex
  seemed tired, noting this was the third late night"), and gives two repeating notes "Your notes add"; no catalog
  setting changes that, and no preset chooses it first.

**The three-hour meeting on the larger models.** Topics of 22, commitments of 66 (owners right), traps listed (of 25),
and the notes.

| | Gemma 4 26B A4B | Qwen 3.6 35B A3B | Gemma 4 31B 8-bit |
| --- | --- | --- | --- |
| Passes | 16: note check, 5 parts, final, 9 commitments | 15: note check, 4 parts, final, 9 commitments | 16: note check, 5 parts, final, 9 commitments |
| Time (load) | 1,751 s, 29 min (53, then 40) | 1,189 s, 20 min (11) | 6,391 s, 1 h 47 min (59; other agents' work took it as high as 286 on the way) |
| Topics | 22 | 22 | 22 |
| Commitments (owners), actions listed | 66 (66), 90 | 66 (66), 81 | 66 (66), 83 |
| Traps listed | 0 | 0 | 0 |
| Notes | N1, which repeats, no longer "Your notes add"; N2, N3 as the notes'; N4 beside the April 7 said; N5 left out | N3, N4, N5 written as fact ("The Flagpost quote is only valid until Jan 31."); N2 left out | Every note right: N1 and N6, which repeat, not attributed; N2, N3, N5 as the notes'; N4 beside the April 7 said ("though your notes add that marketing targets March 3") |
| Peak MLX memory | 15.5 GB | 20.6 GB | 35.7 GB |

The 31B, the workstation's Detailed preset, keeps everything in the three-hour meeting and handles every note right,
at a cost: its final pass alone took 761 s, and each part 477 to 811 s, on a Mac other agents kept busy. The 26B and
Qwen 3.6 keep every topic and commitment too, at a quarter and a fifth of the time. Qwen 3.6's three notes written as
fact come from its final pass (the parts' evidence has them as the notes': "NOTE N3 states the Flagpost quote is only
valid until Jan 31"), and no catalog setting changes that; it's an alternate on large and workstation Macs, after
every Gemma 4 model.

**Qwen 2.5 1.5B.** It serves no role now (`roles: []`, catalog 2026.10.31): with every prompt and budget tried in the
section below it missed most topics and commitments of the weekly and wrote the launch's question ("Launch May 12?")
as the date decided. It's out of every summarization list, so it never stands in when another model is removed, and
it serves no other role (it's text only; small tasks run on Apple Foundation Models or the summary model). Someone who
chose it, or whose choice from before the model system ("qwen-1.5b") maps to it, moves at launch to the preset's first
installed choice, or its first choice, with "Qwen 2.5 · 1.5B no longer works for summaries. Summaries now use Gemma 4
· 26B A4B: download it in Settings › Models." (on this Mac's tier); processing waits for the download rather than
running the old model, and a job queued with it fails with "can't be used for summaries". Settings › Models lists it
only while it's on the Mac, to be removed ("Used for: Nothing"); summaries made with it still name it.

**Automated.** `SummaryCompletenessTests`: restatements merged, one summing up three, the parts' overlap kept once in
the first wording, while the same task for two people, two tasks sharing "fix" and "iOS", and two listed side by side
stay; quotes shortened with an ellipsis or stitched from nearby sentences, and rejected out of order or far apart;
even parts with no scrap, and the commitments' tuned parts evened out only for a scrap. `SummaryNotesTests`: the
check's prompt and passages, a repeating note passed on without its words with its passages still marked, the others
and an unreadable check left as before, and no check without `noteCheck`. `SummaryRepairTests`: a leaked note marker
or label read as the notes', a quote in its own quotation marks found. `StructuredOutputTests`: the brief prompt's new
sentences, the models marked brief, and the models that check notes. `ModelSelectionTests`,
`ModelPreferenceMigrationTests`, `ModelManagerTests`: Qwen 2.5 1.5B in no list, a choice of it (installed alone,
beside Qwen 2.5 7B, or from "qwen-1.5b") moved with its notice, and the library hiding a model that serves nothing
unless it's on the Mac. `swift test` passed 1,352 XCTest cases across the eight bundles (one skipped, as before):
Captions 13, Core 424, Devices 119, Intelligence 175, Kit 202, Link 74, Live 39, Mac app 306.

**Still to check:** a release build's times on an unloaded Mac; real recordings of an hour or more; the 12B, E4B, and
E2B still give repeating notes "Your notes add" where they did, since their own check would lose notes that add
something; a check that takes "tell support" after "Who needs to know about that? Support, mainly" as said; Qwen 3.6's
notes in a long meeting, and Qwen 3.5's topics (4B) and notes (4B, 9B); how much each model's commitments move with
where the parts split.

## Cloud summaries (2026-10-31)

Summaries can run on Anthropic's or OpenAI's models with the person's own key ([cloud](cloud.md)): a catalog of family
rules and measured models, OpenRouter's prices over a bundled snapshot, keys in iCloud Keychain, discovery of the
models a key reaches, a summarizer that reuses the local pipeline's prompt, schema, and checks in one pass, and
Settings › Cloud on the Mac and the iPhone.

**Measurements the catalog is built on.** The lead's runs on 2026-10-31 (the synthetic offsite's first 15, 30, 60, 120,
and 186 minutes, one request each with a measuring prompt that asked for commitments with quotes; `max_tokens` 32,000,
64,000 for the 186-minute runs). Output tokens include reasoning.

| Model | Low, 60 min | Medium: 15 / 30 / 60 / 120 / 186 min | High, 60 min | Medium hour's cost |
| --- | --- | --- | --- | --- |
| Claude Opus 5.5 | 8,137 | 4,168 / 6,796 / 11,627 / 17,849 / 23,934 | 15,042 | $0.312 |
| Claude Sonnet 5.5 | 5,345 | 2,276 / 3,361 / 4,875 / 10,917 / 10,434 | 8,377 | $0.089 |
| Claude Haiku 5.5 | 10,100 | 3,538 / 6,220 / 11,336 / 18,822 / 28,402* | 20,795 | $0.008 |
| GPT-6 Astra | 5,219 | 1,886 / 3,462 / 5,501 / 8,734 / 12,297 | 11,105 | $0.413 |
| GPT-6.1 Sol | 4,591 | 2,049 / 2,997 / 5,228 / 8,132 / 11,838 | 8,317 | $0.080 |
| GPT-6.1 Terra | 3,235 | 1,941 / 2,656 / 3,648 / 5,710 / 7,970 | 5,027 | $0.032 |

\* Haiku's 186-minute run in the series stopped at its 32,000-token limit; this is the 64,000-token run's 28,402. That
cut-off is why the summarizer raises a reply's limit once when it's reached. Input: Claude counted 311 tokens a minute of
conversation, OpenAI 214 (2.8 and 4.1 characters a token). On the 186-minute offsite, scored with the summary harness's
scorer: topics 22 of 22 for all six; commitments with the right owner Opus 66, Sonnet 66, Haiku 64, Astra 62, Sol 61,
Terra 62 of 66, listing 76, 76, 75, 89, 88, and 82; notes handled right (by hand) Opus 4, Sonnet 3, Haiku 3, Astra 5,
Sol 6, Terra 6 of 6. `summaryQuality` (docs/cloud.md, "Summary quality") gives 95, 94, 92, 93, 94, 95, and Gemma 4 26B
A4B 90 and E4B 53 from the three-hour meeting above.

**Changes.**

- `CloudInterfaces.swift` as the plan has it (with `ProcessingCapabilities.models`), the same in all three branches.
- `CloudCatalog.json` (version 1) and `CloudPrices.json`, 73 Anthropic and OpenAI models from OpenRouter's list of
  2026-10-31, without `:batch`, with prices, long-prompt rates, limits, and efforts. Made with:

      python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); keep=[]
      for m in d["data"]:
          if not m["id"].startswith(("anthropic/","openai/")) or m["id"].endswith(":batch"): continue
          p=m.get("pricing") or {}; e={"id":m["id"],"name":m.get("name"),"context_length":m.get("context_length"),
            "pricing":{k:p[k] for k in ("prompt","completion","input_cache_read") if k in p},
            "top_provider":{"max_completion_tokens":(m.get("top_provider") or {}).get("max_completion_tokens")},
            "supported_parameters":[x for x in m.get("supported_parameters") or [] if x in ("structured_outputs","reasoning","response_format")]}
          if p.get("overrides"): e["pricing"]["overrides"]=[{k:o[k] for k in ("min_prompt_tokens","prompt","completion") if k in o} for o in p["overrides"]]
          if m.get("reasoning"): e["reasoning"]={k:m["reasoning"].get(k) for k in ("supported_efforts","default_effort")}
          keep.append(e)
      json.dump({"source":"https://openrouter.ai/api/v1/models","fetched":"<date>","data":keep},open(sys.argv[2],"w"),indent=1)' models.json CloudPrices.json

- Keys: `KeychainCloudKeyStore`, synchronizable, in `<team>.local.daybook.shared`; `CloudAPIKey` prints only its masked
  form. Discovery: `CloudDirectory`; OpenRouter is asked only once a key is set, then at most daily.
- `CloudSummarizer`: `MeetingSynthesis.finalPrompt` gains `quotesActions` and `findsWhatNotesAdd` (both off for local
  models, whose prompts are unchanged; the local summary tests pass as before), `CloudSynthesis.schema` mirrors
  `summarySchema` for structured outputs, and action items go through `verifiedActions`.
- Settings › Cloud on both apps; the colophon reads "Summarized with Claude Sonnet 5.5"; `--cloud-check` (debug).

**Verified here.**

- 57 new tests, against a URLProtocol server that answers as Anthropic, OpenAI, and OpenRouter (`FakeCloudServer`):
  `CloudCatalogTests` 12, `CloudKeyStoreTests` 7, `CloudClientTests` 18, `CloudDirectoryTests` 8, `CloudSummarizerTests`
  12; and one on the iPhone (`SettingsWordsTests`, the Settings row's words). They check each request as sent (headers, effort, adaptive thinking, the schema in its order, `store: false`,
  the fallback), both streams, refusals, the length cap raised once, 429 with `retry-after`, a limit longer than a
  minute not waited for, out of credit, overloaded streams and 529s tried twice more, offline at once, a dropped
  connection tried again, keys masked in Details, the keychain items' attributes (with a fake keychain), the offers
  and recommendations, estimates within 25% of the measured hours, provenance and cost, and that a commitment whose
  quote nobody said, or that quotes a note, is dropped.
- `--cloud-check` against a local fake server (`DAYBOOK_CLOUD_BASE_URL`) for both providers on the harness's `launch`
  fixture: the key check, the model list, OpenRouter, the streamed summary, the invented commitment dropped, tokens and
  cost printed, and the run written in the scorer's format.
- Settings › Cloud's states in light and dark on the Mac (`--cloud-demo`), the Add Key sheet with a refused key, and the
  colophon before and after; Settings › Cloud on an iPhone 17 Pro simulator clone.

**Real runs.** The lead ran `--cloud-check` on the 186-minute offsite at medium effort with the owner's test keys
(`--output`, scored with the summary harness's scorer). Both providers accepted the requests as sent: the schema under
Anthropic's `output_config.format` and OpenAI's strict `json_schema`, and `fallbacks: "default"` with its beta header.
No run warned.

| Model | Input / output tokens | Topics | Commitments, right owner | Listed | Notes handled | Cost | Time |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Sonnet 5.5 | 65,025 / 10,547 | 22 / 22 | 66 / 66 | 76 | 5 of 6 | $0.236 | 62 s |
| Claude Haiku 5.5 | 65,025 / 45,020 | 22 / 22 | 66 / 66 | 77 | 3 of 6 | $0.029 | 178 s |
| GPT-6.1 Terra | 45,404 / 7,133 | 22 / 22 | 64 / 66 | 80 | 4 of 6 | $0.081 | 81 s |

The notes findings lift Sonnet from 3 to 5 of 6. Every note missed is one that only repeats what was said, called an
addition. Terra's two commitments missed are worded past the scorer's patterns ("snapshot-testing proposal").

**Still needs the owner's devices.**

- A key added on a signed Mac reaching a signed iPhone through iCloud Keychain, and removed from both.

## Processing on the iPhone (2026-10-31)

The iPhone now processes its own recordings as the Mac does: transcription, speakers, voice profiles,
the background-audio check, fusion, speaker labels from the synced profiles, and a summary where it has
the memory ([iPhone](iphone.md#processing-on-this-iphone), [models](models.md#iphone-processing),
[model runtime](model-runtime.md#iphone)). DaybookIntelligence is linked on the iPhone without
WhisperKit and MLXVLM. The models come per memory tier from the catalog (`initialSelection`'s iOS
lists), with Settings › Models › Processing to download them. Work runs under the Mac's
`ProcessingRequest` claims (`OnDeviceProcessing`): claimed as a recording is filed, its own recordings
only, fused where the last recording arrives, handed back to a Mac for the summary when the iPhone
can't make one. It goes on in the background under iOS 26's continued-processing task where allowed,
and pauses for a recording, the screen, heat, Low Power Mode, and a low battery.

**Size** (unsigned Release archives, `scripts/build-ios.sh --archive --no-sign`): 23.1 MB before (binary
20.9 MB, 10.6 MB zipped); 46.0 MB with DaybookIntelligence as the Mac builds it (17.3 MB zipped); 43.1 MB
with WhisperKit and MLXVLM left out (binary 38.6 MB, 16.2 MB zipped). MLX's Metal library is 2.3 MB.

**Memory.** Summary peaks with weights included, from the long-summary runs above on a Mac: Gemma 4 E2B
2.9 to 3.0 GB on the four short-to-22-minute conversations (declared 3.2 GB in the catalog, for a
three-hour meeting's larger KV cache), E4B 5.0 GB on the three-hour meeting. With a gigabyte for the
app, E2B needs about 4.2 GB and E4B 6.0 GB of the per-app limit. Published figures put that limit at a
little under half the phone's memory, about seven tenths with the Increased Memory Limit entitlement,
which the app doesn't have: so 8 GB iPhones summarize with E2B only with the entitlement, 12 GB ones
get E2B without it and E4B with it. On a device the limit is read as the app runs
(`os_proc_available_memory`), so the estimate only decides what the simulator and tests show. The speech
models: the Mac smoke test with Parakeet Ultra, Nemotron 3 (offline), and Community-1 on a 10-second
`say` recording (debug build) peaked at 859 MB of process footprint; in the simulator the iPhone app
peaked at 106 MB on the same recording and 165 MB on a 3-minute one.

**A real transcription in the simulator.** Parakeet Ultra, Nemotron 3 (offline), and Community-1 were
downloaded through the store into scratch (`Daybook --smoke-test --download-models --models <scratch>`,
every file checked by size and digest), copied into the simulator app's container, and the app was
launched with a scratch library and `--import-file` of a 10-second `say` recording ("Thanks for joining.
The beta ships on Friday. Alex will send the release notes…"). The import was claimed as it was filed,
transcribed word for word (four passages, one speaker with a Community-1 voice profile, the
background-audio analysis on the track, the unified transcript fused), and, since the simulator can't
summarize, the request was given back, reading "Waiting for your Mac". A 3-minute recording took 60 s on
the simulator's CPU (72 passages), with "Transcribing on this iPhone · 77%" in the list meanwhile. The
transcript records `parakeet/ultra` at its pinned revision and FluidAudio 0.17.7. The Mac's own smoke test
of the same models on the 10-second recording passed (mean word confidence 0.99). The models were
deleted afterwards.

**Automated.** `OnDeviceProcessingTests` (9): its own recording is transcribed here; a Mac's recording,
or a request another device made, isn't; a claim another device holds is left alone; without the speaker
models a recording waits for a Mac; it summarizes here only when it can; a recording still to line up
leaves fusion to a Mac until it's placed; Transcribe Everything Again and Identify Speakers Again do
each recording once; a satisfied or finished request is nothing to do; this device's queue shows its
own work. `PhoneProcessingModelsTests` (8): tiers from memory, Ultra and Redux, Nemotron with
Community-1, summaries only where the measured peak fits (with and without the entitlement), a choice
that doesn't fit falls back, the Mac's choices unchanged, platform tiers round trip.
`InferenceProcessingEngineTests.testBehaviorTheLocalSummarizerIsTheEnginesSummaryStep`.
`ProcessingRequestQueueTests.testBehaviorAMacLeavesWhatAnIPhoneClaimedAndNeverTranscribesItAgain`: a Mac
leaves a recording the iPhone claimed as it filed it, then summarizes without transcribing when the
iPhone hands the request back. `PhoneProcessingTests` (13, on the simulator, with the engines' fakes):
claimed as filed, then transcribed, fused, and summarized here, with the model in each result; handed
back without a summary model; a Mac's recording left alone; Transcribe Everything Again done here leaves
the Mac only the summary; a recording pauses the work, which keeps its claim and resumes; heat, Low Power
Mode, and a low battery hold it; the continued-processing task gets the work's progress and stage,
carries it in the background, and pauses it when it expires; without the task leaving the screen pauses
it; the summary waits for the screen; another device taking the request stops the work; one conversation
at a time; the models per tier and what they let the iPhone do, with synthetic installs.
`swift test` passed 1,362 XCTest cases across the eight bundles (one skipped, as before): Captions 13, Core
424, Devices 119, Intelligence 170, Kit 218, Link 74, Live 39, Mac app 305. `scripts/build-ios.sh --test`
passed the iPhone's 201.

**Needs the account owner:** the Increased Memory Limit capability
(`com.apple.developer.kernel.increased-memory-limit`) and Background GPU Access
(`com.apple.developer.background-tasks.continued-processing.gpu`) on the iPhone's App ID and
entitlements. Without them, 8 GB iPhones don't summarize locally, 12 GB ones use E2B, and summaries run
only with Daybook on the screen.

**Still needs a real iPhone:** the Neural Engine's speed, heat, and battery on long recordings; whether
iOS grants the continued-processing task after Stop, how its Live Activity reads, and when it expires;
the `processing` background mode's need (added for the task); the memory limit `PhoneMemory` reads; a
Gemma summary's time and peak on a phone; Parakeet Redux and Nemotron Compact on a 4 GB iPhone.

## Where summaries run, and the countdown before them (2026-10-31)

A summary that's due now has a place: this device, a Mac another device sends it to, or the cloud with the
person's own key, decided by one planner both apps share, with a countdown (15 s, or 30) that lets the person
choose the cloud first (docs/multipoint.md, "Where summaries run"). Built against `CloudSummarizing` with a
fake: the concrete cloud, its keys, and Settings › Cloud are the cloud work's.

**What changed.**

- `SummaryPlacementPlanner` (DaybookKit, pure) and `SummaryPlacements` (a planner per conversation, one timer).
  Counting down to this device or a reachable Mac, waiting for a Mac with Use the Cloud, started, or waiting as
  before; Use the Cloud, Start Now, Wait for a Mac; Always and Never; asked-for summaries start at once; a
  change of what's on offer reaches every countdown.
- The Mac's summary step goes through it, on the page, the list row, the inspector, and Floating Notes, and
  connected iPhones see the countdown (`processing.progress`, `summaryCountdown`) and may choose
  (`processing.choice`). Without a key nothing changes.
- The iPhone sends a summary to a reachable Mac after a countdown (a Summarize request, nudged), waits for one
  with Use the Cloud, runs it in the cloud or on its own summarizer (the `LocalSummarizing` seam, nil until the
  iPhone's processing lands; `summaryIsDue` is the call it makes) with a claim, shows a Mac's countdown, and
  starts each countdown's default when it leaves the screen. The page, the list row, and the status sheet say it.
- One summary per conversation: claims through Summarize requests (with the summarizing stage), standing down
  for another device's claim, the merge's newest claim winning, and a summary another device wrote meanwhile kept.
- Macs advertise `ProcessingCapabilities` (with the model per role) over the link and in presence; earlier
  peers read as unknown. A summary records where it ran and the model behind each role; the colophon says it.

**Verified.**

- `swift test`: 1,406 tests, 0 failures (1 skipped, as before); `swift build --build-tests` clean. New: `SummaryPlacementTests` (35: every transition with a clock of the test's own,
  the words, preferences, the coordinator), `SummaryClaimTests` (8), `SummaryPlacementProcessingTests` (16:
  the Mac's countdown, Start Now, Use the Cloud, Always, Never, Summarize Again and another device's request
  starting at once, pausing during a countdown, standing down for a phone's claim, a phone's summary kept, a
  late Mac leaving a phone's cloud summary alone, a phone choosing the cloud over a loopback link,
  capabilities in presence and over the link), `LinkWireTests.testBehaviorSummaryPlacementIsAdditive`,
  `LibrarySyncReplicaTests.testBehaviorPresenceCarriesWhatAMacDoesForOthers`, and Floating Notes' chip and line.
- `scripts/build-ios.sh --test` on an iPhone 18 Pro simulator clone (iOS 27.1): 202 tests, 0 failures. New:
  `PhoneSummaryPlacementTests` (14: a countdown to a Mac then the request; without a key; waiting then a Mac
  arriving; a Mac's presence going stale; Use the Cloud with a claim and the provenance; Use the Cloud taking a
  waiting request; Always; its own summarizer and Wait for a Mac; a Mac already on it; a Mac claiming it during
  the countdown; losing the claim in a merge; leaving the screen; a loopback Mac's countdown shown and the
  choice reaching it; the status sheet).
- Window snapshots, before (5dac69e) and after, light and dark: the Mac's page, list row, and inspector
  counting down and in the cloud, Floating Notes' chip, and the colophon from the cloud and from another Mac
  (`--placement-demo`); the iPhone's page counting down to a Mac, waiting for one, in the cloud, and showing a
  Mac's countdown, the list row, the status sheet, and the colophon (`--placement-demo`).

**Needs hardware or the cloud work.** A real key and provider (the fake stands in); a Mac and an iPhone on a
real network choosing over the link while both count down; iCloud's latency between two devices that start
summarizing before either's claim arrives (the merge keeps one; Version History the other); the iPhone in the
background with a cloud summary under way (a suspended app's claim expires after 10 minutes and a Mac takes it).

## Long summaries on the other models, and a three-hour meeting (2026-10-31)

The long-summary fixes below (#34) were checked on Gemma 4 26B A4B only. The same check on the catalog's
other summary models, and on a meeting long enough to compress, found that #34 broke the 12B outright,
made E2B four times slower, and never finished a three-hour meeting on the 26B. All are fixed
([model runtime](model-runtime.md), "Summarization"; [models](models.md), "A new MLX language model family").

**Setup.** The same harness, the same four conversations, notes, and bookmarks, scored the same way.
Gemma 4 12B, E4B, and E2B were downloaded through the app's store (`LocalIntelligenceRuntime.download`)
into a scratch models folder, every file's SHA-256 or git object ID checked again afterwards, and deleted
when done; Gemma 4 26B A4B and Qwen 2.5 7B and 1.5B are the installed copies, used read-only through
symlinks from that folder (the installed folder's listing unchanged afterwards). "Before" is e781d1c,
"#34" is main with the fixes below (775edde), "now" is this change. Decoding is greedy, so a run repeats
exactly. The three-hour meeting is synthetic: a mobile team's Q1 planning offsite, 26,022 words in 1,229
passages (185.8 minutes at 2.5 words a second, 47,832 tokens), 22 topics, 66 commitments (24 in the last
hour), 25 traps (suggestions nobody took up, tasks put on hold, hypotheticals), 6 notes (2 that repeat
what was said, 3 that add something, 1 that conflicts), and 3 bookmarks. Its first hour (379 passages,
8 topics, 20 commitments, 2 notes) is the hour-long meeting.

**What broke with #34, and why.**

- **12B, no summary at all.** Its chat template ends the prompt with an empty thought block when thinking
  is off; on the weekly's second part it answered with nothing but more of them, `<|channel>thought
  <channel|>` for 1,800 tokens, which removing thoughts left empty, so the whole summary failed ("The
  local model returned no summary").
- **12B, six minutes on a three-minute meeting.** Constrained and greedy, with no repetition penalty, the
  launch's final pass wrote "Note: The group agreed on the pricing structure." until 2,954 of its 3,000
  tokens (357 s; before, its limit was 1,800). E2B looped the same way: the weekly's terms ("hit rate",
  "read load", …) and its commitments ("Fix the checkout test flakiness" thirty times), so the weekly took
  1,037 s against 263 s before.
- **E2B, fewer commitments.** The fuller commitments prompt found 1 of the 1:1's 6 (7 listed before) and
  10 of the weekly's 38; schema and prompt tried separately, the prompt alone made the difference.
- **E2B pasted notes with their markers** into the customer interview's sections ("(near N1) Exports ~20
  min each, run daily").
- **Qwen 2.5 1.5B copied the prompt's example** as a commitment: "Send the agenda tomorrow".
- **26B, a three-hour meeting never finished.** Eleven parts at "at most 400 words" (800 tokens) ran into
  their limit 7 times in 25 extraction passes and were read again in halves; compression was allowed to
  write as much as it read and read cut-off batches again in halves at the same limit, so the evidence
  grew: 16,500 tokens after extraction, 19,200 after the first round (13 passes, 5 at their limit), 21,100
  after the second (15 passes). Stopped after 2 h 10 min in the third round, never having reached the
  final pass (part of that time it shared the GPU with another of these runs, at loads of 25 to 76).
- **Already broken before, fixed too:** Qwen 2.5 7B wrote a section's bullets as a list of strings in 3 of
  its 6 short summaries, so the whole reply landed in the overview as raw JSON.

**Changes.**

- A pass whose reply ends in the same stretch of 12 to 2,000 characters four times in a row stops
  (`MeetingSynthesis.RepetitionGuard`). A constrained reply is cut back to its last complete section,
  commitment, or term and its JSON closed (`salvagedJSON`); with nothing complete before the loop the pass
  runs free-form, with its repetition penalty. A free-form reply is cut back to where it began repeating.
  A JSON reply broken off at its limit keeps its complete sections and commitments the same way.
- With thinking off, a free-form reply can't open a thought block: the token that would (`<|channel>`,
  `<think>`) is masked.
- `engineOptions.commitments: "brief"` (Gemma 4 E2B, Qwen 2.5 1.5B) asks for commitments in the earlier,
  shorter wording plus one sentence ("Write each task so it reads on its own, never "it" or "that", and
  leave out anything later dropped or put on hold"), with no example to copy. An install now runs with
  the catalog's current engine options; its receipt keeps those it was installed with.
- Budgets follow the context window (`MeetingSynthesis.Budget`): with a known window any pass may write
  up to 16,384 tokens (less if the prompt leaves less room; `engineOptions.outputTokens` can set less),
  the final pass reads up to 24,000 tokens of evidence (12,000 with Qwen 2.5's 32K), and a conversation
  longer than that is read in parts of 12,000 tokens (8,000). What the 26B was tuned on stays: a
  conversation up to 5,400 tokens is read whole, a longer one up to the evidence budget in parts of 4,800
  and 900 words, and commitments in parts of 5,400. Reading the weekly whole with commitments in one pass
  (an intermediate version) lost caching and kept 31 of the 38 commitments (36 in parts). Compression
  writes at most half of what each pass reads, halves included, so every round shrinks the evidence.
- Bullets written as a list of strings read as bullets; lines copied from the source with their markers
  ("(near N1) …", "NOTE N1, …") are left out of the sections.

**Four conversations, per model.** Weekly topics of 13 and commitments of 38 (right owner), the three short
conversations' commitments of 14 (right owner), notes that only repeat what was said given "Your notes
add" (of 5; fewer is better), notes that add something attributed to the notes (of 5; in parentheses, how
many stated as if said), conflicts mentioned (of 2), and the weekly's time with the load average when it
started. Loads ranged from 16 to 215 across these runs, from other agents' builds and tests and, before
the owner asked, from two of these runs sharing the GPU; times taken more than about 2× apart in load
aren't comparable.

| Model | Code | Weekly topics | Weekly commitments | Weekly time (load) | Short commitments | Repeats as "notes add" | Adding notes (as fact) | Conflicts |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 26B A4B | before | 8 | 0 | 206, 221 s (17–67) | 14 (1) | 3 | 5 of 6 | 1 |
| | #34 | 13 | 36 (36) | 368, 360 s (17–67) | 12 (11) | 1 | 5 (0) | 2 |
| | now | 13 | 36 (36) | 402 s (56) | 12 (11) | 1 | 5 (0) | 2 |
| 12B | before | 7 | 0 | 596 s (66) | 9 (0) | 3 | 4 (0) | 2 |
| | #34 | failed | failed | failed | 11 (9) | 4 | 4 (0) | 1 |
| | now | 13 | 28 (27) | 409 s (16) | 11 (9) | 3 | 5 (0) | 1 |
| E4B | before | 5 | 0 | 213 s (45) | 10 (1) | 0 | 0 (0) | 0 |
| | #34 | 12 | 26 (24) | 320 s (65) | 11 (9) | 0 | 1 (1) | 0 |
| | now | 12 | 26 (24) | 231 s (55) | 11 (9) | 0 | 1 (1) | 0 |
| E2B | before | 5 | 5 (4) | 263 s (198) | 10 (2) | 0 | 0 (0) | 2 |
| | #34 | 7 | 10 (10) | 1,037 s (83) | 6 (4) | 0 | 0 (0) | 1 |
| | now | 10 | 17 (14) | 318 s (43) | 9 (7) | 0 | 0 (0) | 1 |
| Qwen 2.5 7B | before | 3 | 0 | 149 s (215) | 9 (3) | 0 | 0 (1) | 0 |
| | #34 | 12 | 19 (17) | 240 s (111) | 7 (7) | 0 | 0 (2) | 0 |
| | now | 12 | 19 (17) | 197 s (62) | 7 (7) | 0 | 0 (2) | 0 |
| Qwen 2.5 1.5B | before | 2 | 0 | 73 s (25) | 2 (0) | 0 | 0 (2) | 0 |
| | #34 | 6 | 3 (0) | 62 s (31) | 2 (1) | 0 | 0 (2) | 0 |
| | now | 6 | 0 | 180 s (23) | 4 (2) | 0 | 0 (2) | 0 |

The 26B's before and #34 rows are the section below's runs (its short conversations scored there by hand).
The 26B, E4B, and Qwen 7B now run #34's passes word for word, only allowed to write more (the token counts
of every pass match), so their quality is #34's; their time differs only with load. Before these changes
the 12B and E2B rows were: 12B's weekly failed and its launch took 376 s, now 94 s (the constrained loop
is stopped at once and the pass runs free-form); E2B's weekly took 1,037 s, now 318 s. Qwen 2.5 1.5B's
weekly took 644 s with the loop guard looking back 400 characters (its commitments pass copied ten passages
over and over for 16,384 tokens), 180 s with 2,000.

Also broken, before or #34: Qwen 7B's raw-JSON summaries (3 of 6 short ones before, 1 with #34; none now),
E2B's pasted markers (1 with #34; none now). The brief commitments wording costs E2B noise in the customer
interview: 8 listed for its 1 commitment, the process Elena described ("Paste the export into a Google
Sheet…") and a question ("Walk me through…"), where the full wording listed 1. Qwen 2.5 1.5B is not
usable for summaries either way: before, #34, and now it misses most topics and commitments, and in the
launch it wrote that the launch is May 12 (the note's question, not the decision).

**Three-hour meeting.** The 26B, #34 against now, then E4B now. "Kept" commitments match a commitment's
task; owners in parentheses. Notes: N1 and N6 repeat what was said, N2, N3, N5 add something, N4
conflicts (marketing's March 3 against the April 7 that was said).

| | 26B, #34 | 26B, now | E4B, now |
| --- | --- | --- | --- |
| Passes | 56 before it was stopped, in compression's third round | 15: 5 extraction, final, 9 commitments | 15 |
| Time | over 2 h 10 min, unfinished | 1,305 s (21.8 min; load 19–50) | 759 s (12.6 min; load 47–58) |
| Passes at their limit | 20 of 56 | 0 | 0 |
| Topics, of 22 | – | 22 | 14 |
| Commitments, of 66 | – | 66 (66), 129 listed | 30 (29), 36 listed |
| Traps listed, of 25 | – | 0 | 0 |
| Notes | – | N2, N3 added as the notes'; N4 beside the April 7 that was said, not called a conflict; N1 (repeats) given "Your notes add"; N5 left out | none mentioned |
| Peak MLX memory (weights included) | – | 15.5 GB | 5.0 GB |

An intermediate version that read commitments in two parts of 24,000 tokens kept 60 of the 66 and listed
77; in parts of 5,400 it keeps all 66 but lists 129: the recap at the end of the meeting, and the parts'
overlap, restate most commitments in other words ("Complete the storage spike" after "Spike storage for
iOS and report back next Thursday"), and each restatement is kept as its own item. Excerpts, now: "Android
ANR rate is 0.9% of daily sessions (Google's threshold is 0.47%). Target is under 0.4% by March."; "Your
notes add that the Flagpost quote is only valid until Jan 31."; "Ask Wen on the data team to confirm the
list of unused events by Friday (Nadia)"; "Write the customer email about the update and send it two weeks
before March first (Hana)".

**An hour-long meeting** (the offsite's first hour, 26B). #34 and now run the same 8 passes: 4 extraction
parts of 4,800 tokens, the final pass, and 3 commitments passes. #34's parts, at 742 words and 1,484
tokens, stayed under their limit, so nothing was read again in halves or compressed. Both keep all 8
topics and all 20 commitments with their owners (22 listed); N2 is added as the notes' in both, and now
N1, which repeats what was said, is given "Your notes add" too. Now each part may write 900 words (its
share of the larger evidence budget, capped at a fifth of what it reads), so it writes 8,223 tokens against
7,825. Time: 626 s for #34 (load 22 to 40), 994 s now (load 36 to 24, peak MLX memory 15.3 GB); the
tokens differ by 5% and the rest is load: the same 3,277-token part took 68 s in one run and 281 s in the
other. An hour-long meeting costs about what it did with #34, 10 to 17 minutes on this loaded Mac; what
changed is a longer one, which #34 couldn't finish and now takes 22 minutes for three hours.

**Memory.** Gemma 4 keeps full attention in a few layers only (6 KB a token of KV cache for E2B, 16 KB for
E4B and 12B, 20 KB for 26B A4B, from their configs), so 40,000 tokens take under 1 GB beside the weights:
the 26B peaked at 15.5 GB of MLX memory and E4B at 5.0 GB on the three-hour meeting, weights included.
Qwen 2.5 7B takes 56 KB a token, under 2 GB at its whole 32K window. Each tier's models fit their tier
with 16,384-token passes, so no built-in variant sets `outputTokens`. The iPhone doesn't link
DaybookIntelligence and summarizes nothing.

**Automated.** `SummaryRepairTests` (16): a reply repeating a sentence, empty thought blocks, or a long
stretch is stopped and cut back to where it began; ordinary summaries and commitment lists aren't taken
for loops; a loop in the terms keeps every section; a summary broken off mid-section keeps its complete
sections; a commitments reply broken off keeps its complete commitments; nothing is salvaged without a
complete element; bullets as a list; pasted markers left out; the brief prompt for a model marked brief;
budgets from the context window and the catalog; a long conversation in parts of 12,000 tokens and
commitments in parts of 5,400; a meeting the evidence budget holds read in the same passes as before;
compression writing at most half what it reads even when the model writes all it may; a pass never asking
for more than the window holds. `RuntimeResidencyTests`: an install runs with the catalog's current engine
options. `StructuredOutputTests`: the models marked brief, and the two prompts. `swift test` passed 1,343 XCTest cases
across the eight bundles (one skipped, as before): Captions 13, Core 424, Devices 119, Intelligence 169, Kit
201, Link 74, Live 39, Mac app 304.

**Still to check:** a release build's times on an unloaded Mac (every time here is a debug build on a
shared, loaded one); real recordings of an hour or more; restatements of a commitment kept once; Qwen 3.5
4B and 9B, Qwen 3.6 35B A3B, and Gemma 4 31B 8-bit, which weren't run; E2B and E4B on a compact Mac's
memory and speed.

## Long summaries: every topic, commitment, owner, and sentence (2026-10-30)

The real-model check below found that a long conversation's summary lost topics, commitments, owners,
and once a sentence. Each had its own cause; all four are fixed in `MeetingSynthesis`
([model runtime](model-runtime.md), "Summarization"; [templates](templates.md#notes-and-bookmarks)).

**Causes.**

- **Topics.** The 22-minute weekly is read in two parts. The first part's extraction (5,190 tokens of
  transcript, 1,100-token limit, "at most 650 words") ran into its limit in every run: its reply stops
  at "### On-Call & Caching\n*", so on-call, caching, security, cloud costs, customer escalations, CI,
  and single sign-on never reached the final pass (on-call and caching came back only through the
  verbatim passages near a note and a bookmark). The final pass also kept a long conversation's summary
  "concise": with every topic in its evidence, it once grouped thirteen into seven sections and left two out.
- **Commitments.** With the transcript over 5,400 tokens, the action pass read the compressed evidence
  and quoted it ("Ben to investigate/fix the dashboard spinner…"); none of those paraphrases is in the
  transcript, so all 18 were rejected and the summary had no actions.
- **Owners.** An owner was kept only when the quote named them, so "Yes, I'll send the line items today"
  (Dana) had none: 1 owner across the three short conversations' 14 actions.
- **Truncation.** No per-section limit and no stop condition: under the grammar a `"` always ends a
  string, and the model opened a quotation unescaped (the evidence read `a "retry storm."`), so the body
  ended at "The root cause was a "; in one earlier run the model then wrote the section again in full.
  Separately, the final pass's 1,800-token limit would have cut a complete summary: the guided loop
  boosts closing tokens in its last 64, ending whatever string it's in.

**Changes.**

- Long transcripts are split into even parts between passages (the extraction's at most 4,800 tokens,
  the commitments' 5,400), each starting with the two passages before it. Each extraction is told to
  cover every topic in order, in terse bullets, and may write its share of the final pass's evidence
  (900 words each for two parts; 400 to 900); a reply that still runs into its limit is read again in
  halves (`readWhole`), and compression works the same way. The final pass is told to cover every topic.
- Commitments are extracted from the transcript itself, one pass per part, and verified against it
  (`SpokenPassages`): the quote must be there word for word (curly apostrophes, case, timestamps, and
  whitespace ignored), and a commitment found in two parts is kept once. The task text must stand on its
  own ("Send the agenda tomorrow", never "it"), and anything later dropped or put on hold is left out.
- An owner is kept when the quote names them or when they are the quoted passage's speaker (saying "I",
  or naming no one else); with no owner stated, a speaker saying "I" is the owner. A stated owner the
  quote doesn't show is dropped, never replaced by the speaker: in "send it to me two weeks before the
  deadline so I can give comments" Sam says "I", but the task is Alex's (an earlier variant got this
  wrong). "Unknown speaker" is never an owner.
- Prose strings in the schemas (title, overview, headings, bodies, action text) can't end in whitespace,
  so a quotation mark opening after a space can't end them and the escaped one is left. The final pass
  may write 3,000 tokens and each commitments pass 1,600; a section written again under the same heading
  is kept once. Since the commitments pass replaces them, the final pass of a model with structured output
  leaves its own actions empty (prompt and schema).
- Notes: "Your notes add" is only for what no speaker said ("most notes repeat what was said"); a
  bookmark's words only name a moment; extraction marks what a note adds as "N1 adds" and conflicts as
  "N1 conflicts".

**Real model.** The same check as below, the same four conversations, notes, and bookmarks: Gemma 4 26B
A4B QAT 4-bit from the installed copy, used read-only through a symlink from a scratch models folder with
its own receipt (the installed folder's listing unchanged afterwards), in a scratch, uncommitted XCTest
that calls `MeetingSynthesis.generate` with the loaded model and records every pass. Decoding is greedy:
the old code reproduced run 3 below exactly, and repeated runs of the new code matched each other, so
the counts below are not sampling noise. "Before" is the committed prompt (run 3 below); "after" is this
change. The weekly's commitments are scored against 38 in its transcript (someone says they will, or is
asked and agrees).

| | Before | After |
| --- | --- | --- |
| Weekly: topics kept, of 13 (11 when on-call with caching and hiring with documentation count as one) | 8 (6) | 13 (11) |
| Weekly: commitments kept, of 38 | 0 (18 extracted, every quote a paraphrase) | 36, every one with the right owner |
| Short conversations: commitments kept, of 14 | 14 | 12 |
| Short conversations: owners kept | 1 | 11 of 12 (the twelfth has none) |
| Truncated sections | 1 ("The root cause was a ") | 0 |
| Notes that only repeat what was said, given "Your notes add" | 3 (exports daily, stack, tell support) | 1 (tell support) |
| Notes that add something, attributed to the notes | 5 of 6 (Ben may swap: missing) | 5 of 6 ("Launch May 12?" now reads as a question raised) |
| "Only 2 reqs" against "three approved" | conflict mentioned | conflict mentioned |

Excerpts, after: "The root cause was a retry change deployed that morning; clients retried failed
requests immediately and without limits, exhausting the connection pool…"; "Aisha needs a swap for the
week of December 3rd due to an infrastructure conference; your notes suggest asking Ben about a potential
swap for that week"; sections for security, cloud costs, the three customer escalations, CI, and single
sign-on; "Send the numbers for the backfill to Tomas tonight (Ravi)" from "I'll send them tonight.";
"Ship the Safari login fix tomorrow (Ben)" from "Tomorrow, if the review is done today."; "Post in the
team channel regarding the on-call swap… (Aisha)" from "Aisha, can you post in the team channel? Aisha:
Sure, I'll post it today."; in the customer interview, neither note that repeats the call is mentioned.
"Start the design for the new admin pages", which Ben put on hold, is no longer listed.

Still wrong: "your notes add that support needs to be notified" (Tomas said so); the weekly misses Aisha
joining the cutover call and Mei emailing the offsite details; the launch's actions no longer list
"Marcus, you own the campaign" or Leo taking the signup page (its Ownership section still has both); the
1:1's "send it to me two weeks before the deadline" has no owner. A variant that called ownership a
commitment kept neither and lost the postmortem, so it wasn't kept. Prompt wording still moves single
notes: one variant ("a note that sums up or lists what someone said") wrote the launch's firm 40k cap as
fact again and was reverted.

**Time** (debug build, the weekly, interleaved runs at load averages of 17 to 67):

| Pass | Before | After |
| --- | --- | --- |
| Extraction, two parts | 79 and 93 s (1,777 tokens written, the first part cut off) | 130 and 136 s (2,721 tokens) |
| Final | 91 and 86 s (1,171 tokens, 14 actions included) | 115 and 114 s (1,707 tokens, every topic, no actions) |
| Commitments | 36 and 42 s (one pass, 1,999 tokens in, 607 written) | 123 and 109 s (two passes, 6,453 tokens in, 1,547 written) |
| Total | 206 and 221 s | 368 and 360 s |

About 150 s more, all of it more text read or written: the topics the first part used to drop (+47 s),
the final pass writing them (+26 s), and the commitments read from the transcript (+77 s). The prose
pattern costs nothing measurable: the final pass took 0.075 s per token written before and 0.067 s after,
prompt included. Leaving the actions to the commitments pass saves the final pass about 550 tokens,
roughly 35 s: an intermediate run that still wrote them took 132 s for its final pass. The short
conversations still run one final and one commitments pass; today they took 30 to 82 s each.

**Automated.** `SummaryCompletenessTests` (8; a deterministic model records each pass, XGrammar checks
the schemas without weights): a part whose reply runs into its limit is read again in halves and parts
start between passages; the extraction's share of words; a long conversation's commitments checked in
parts against the transcript, a paraphrase rejected, the final pass's unchecked action replaced, owners
from the quote and its speaker; parts repeat the two passages before them; owner rules (named, the
speaker saying "I", a stated owner who is only the speaker, a request, two speakers, a placeholder name,
"Unknown speaker", a curly apostrophe); a quotation mark after "was a" can't end the body under the new
schema but could under the old one, and the escaped one can; the final pass's empty actions; a section
broken off and written again is kept once; a model without structured output still lists actions in the
summary. `SummaryNotesTests` follow the new prompts; their long conversation now has 2,000 passages whose
parts write up to their limit, so its evidence is still compressed. `swift test` passed 1,316 XCTest cases
across the eight bundles (one skipped, as before): Captions 13, Core 422, Devices 119, Intelligence 151,
Kit 195, Link 74, Live 39, Mac app 303.

**Still to check:** a real meeting of an hour or more (four or more parts, compression), other summary
models (12B, E4B, Qwen) with the new prompts and schema, and a release build's times.

## Live captions from every source, and the live follow-ups (2026-10-30)

Live captions now cover every source a recording has, use the library's vocabulary, keep speakers in a
pocket, name people wherever captions show, offer the live recognizers' languages on macOS 15, and
download the iPhone's models in the background (docs/capture.md, "Every source"; docs/iphone.md, "Live
transcription"; docs/model-runtime.md, "Live").

**What changed.**

- **Every source.** A recorder recording along with a shared recording is captioned from the live audio
  it saves into the conversation (`DeviceSession.captureLive` now captions, `LiveCaptureCaptions`), on
  the Mac and the iPhone. A paired iPhone sends the Mac the captions it makes (its microphone's and its
  recorder's) over the local link (`LinkCaptions`, `liveCaptionsFeature`), only the lines that changed,
  once a second. Other devices' lines join by time on the recording's timeline (`LiveCaptionMix`):
  labelled with the person live speakers recognized, else the device; lines that repeat one already
  shown within 4 s (60% of the words in order) are left out; devices' names are saved with the
  captions (`LiveCaptions.sourceNames`).
- **The owner's call with only You captions.** The live-model path for Call works: with the real models,
  You and Call captioned two conversations at once over one loaded set of models (below), and the
  composition the Mac uses is covered by `LiveSourcesTests.testYouAndCallShareTheLoadedModelsAndEachCaptionsItsOwnAudio`.
  No defect was found in it. Two explanations remain and can't be told apart from here: computer audio
  off (Settings › General › Include computer audio; then there's no Call track to caption), or the
  Speech framework's captions rather than the live models'. This Mac's own library has no live
  transcription model installed (`Models/` holds Nemotron 3 Diarization's offline build, not Nemotron
  3.5 Streaming or the live speaker build), so a call recorded with it is captioned by two
  `SpeechAnalyzer`s at once, which still hasn't been checked in a real call (it wasn't run here, to
  avoid a speech-recognition permission prompt).
- **Vocabulary.** The approved terms bias the live recognizer (`LiveVocabulary`, FluidAudio's
  `setCustomVocabulary`), applied at the start of a capture and between batches when they change.
- **Speakers in a pocket.** The iPhone shed speakers whenever the app was out of sight; that was
  `LiveLoadPolicy.iPhone`'s choice, not an iOS limit. Out of sight they now go on at a lower cadence
  (`LiveWorkLevel.reduced`: four-second batches, no new embeddings for voices already named). Captions
  the speaker model didn't hear (shed for heat or battery, or a failure) are marked `needsSpeaker` and
  labelled from the filed recording when the app is next in front (`LiveSpeakerPass`).
- **Names** before the words on the Mac's Listen Live page, the iPhone's Live Captions page, and its
  status sheet's Listen Live, as Floating Notes and the recording screen show them. The Listening
  waveform is mint in Dark Mode and link ink in Light (`DaybookStyle.liveGlyph`), not neon cyan.
- **macOS 15:** the caption language lists the downloaded live recognizers' languages; a choice whose
  model was removed stays listed, and the footer says live transcription doesn't cover it.
- **iPhone downloads** run in background `URLSession`s (`BackgroundModelFetcher`): Wi‑Fi only unless
  cellular is allowed (two sessions), resumable from the system's resume data, reconnected after a
  relaunch (`phone.liveModels.downloading`, `inFlight`), with `PhoneAppDelegate` taking
  `handleEventsForBackgroundURLSession`.

**Real models, once, in scratch** (an M5 Pro, 64 GB, macOS 27.0). The three iPhone defaults were downloaded
through `ModelStore` with `HubSnapshotFetcher` into a scratch folder, every file checked against the
catalog's digests (Nemotron 3.5 Streaming Latin 14.0 s, Nemotron 3 Live 5.6 s, Community-1 11.1 s),
run by a scratch harness through `LiveCaptioners` as the apps compose them, and deleted afterwards.
Input: macOS voices, You a 20.7 s conversation (Samantha and Daniel, four turns, fed as a microphone:
44.1 kHz mono, 85 ms buffers) and Call a 21.7 s one (Karen and Fred, fed as a process tap: 48 kHz
stereo, 10 ms IO cycles), in real time. Voice profiles for Samantha and Karen were made from separate
utterances and read through `KnownVoices.fromProfiles`, as both apps read them.

- Names from profiles: Samantha's and Karen's voices named in every passage they spoke; Daniel and
  Fred, with no profile, unnamed. In both conversations the second speaker's last turn was labelled
  with the first speaker's slot (Daniel's "I'll post a status…" as S1 Samantha; most of Fred's
  closing line as S1 Karen), live and in the pass afterwards alike, so it's the speaker model's call
  on these voices, not the labelling. Worth watching with real voices.
- You and Call at once: both captioned their own audio throughout, sharing one loaded recognizer and
  speaker model (three models loaded for both captures); caption lag after a passage's last word,
  median 0.81 s (You) and 1.13 s (Call), at most 1.33 s.
- Words: You's four turns right but "sink fixes green" for "sync fix is green"; Call's "Nah yet" for
  "Not yet" and "the hell particles for the new X for feature" for "the help articles for the new
  export feature".
- Vocabulary: "Please ask Saharia whether Daybook…" became "Please ask Zaharia whether Daybook…" with
  Zaharia, Daybook, Nemotron, Kubernetes, and Neural Engine as the vocabulary; nothing else changed.
- Labelled afterwards: the You captions, marked as missed and labelled from an AAC copy of the
  recording, came back with the same speakers and names in 0.3 s (0.1 s of CPU).
- Cost: the first run loaded in 44.9 s (the Neural Engine compiling) and used 0.6 s of CPU for 20.8 s
  of audio, 91 MB footprint. Later runs coincided with the disk filling and load averages of 200 to
  670 from other work on this Mac: loads took 155 to 174 s, and CPU (5.8 s for one capture, 10.7 s for
  You and Call) and footprint (1.4 GB) show the models running off the Neural Engine then. Those
  numbers say nothing about the pipeline; the first run's do.

**Automated.** New and changed tests (synthetic data, no model runs): `LiveCaptionerTests` (vocabulary
given before audio and followed between batches, never given when empty, capped), `LiveSourcesTests`
(You and Call share one recognizer and speaker model, each captioning its own audio at its own
rate; speakers out of sight in four-second batches; shed speakers mark their captions; the pass labels
every caption from the whole recording; a recording file read back at 16 kHz), `LiveModelsTests`
(policy out of sight, languages of installed recognizers), `LiveCaptionMixTests`, `LinkWireTests`
(captions round trip, the feature), `SoundcoreSharedRecordingTests` (a recorder's live audio captioned
for the shared recording), `LiveCaptionsTests` on the Mac (other devices' lines joined, labelled, and
saved; a phone's captions placed on the Mac's recording; the macOS 15 languages), `LiveTranscriptionTests`
(approved terms only), `BackgroundModelFetcherTests` (against a local HTTP server: files at their
repository paths installed and verified by the store, a stopped download resumed with a byte range,
a server error failing cleanly, the sessions' network rules), and on the iPhone `LiveCaptionsTests`
(captions waiting for their recording, a recorder's lines joined and deduplicated, what goes to a
Mac) and `PhoneModelsTests` (downloads carried over a relaunch, other sessions' events).

On the rebased tree, `swift test` ran 1,242 XCTest cases across the eight bundles (one skipped, as
before): Captions 13, Core 389, Devices 102, Intelligence 137, Kit 190, Link 74, Live 39, Mac app 298.
One Live test (`testSpeakersAndNamesAreAddedToAnotherCaptionersWords`, from before this work) failed in
that run on a machine at load averages of several hundred: its 64-buffer backlog dropped the opening of
its eight seconds, moving every voice later. It now holds all of its audio, and the Live bundle passed
39 of 39 again. `scripts/build-ios.sh --test` on a dedicated iPhone 17 Pro simulator clone (deleted
afterwards) passed all 187.

Screenshots (before and after, in scratch): the Mac's Listen Live page with names and the new
waveform colour in light and dark, Settings › General › Live Captions acting as macOS 15
(`--captions-as-macos-15`) with German and with Japanese chosen, and the iPhone's Live Captions page.

**Still needs hardware.**

- A real call with live models on a Mac (both sources, an hour, no dropped buffers), and the same with
  the Speech framework (two `SpeechAnalyzer`s at once), which may be what the owner saw.
- An iPhone recording in a pocket: the Neural Engine's scheduling for a background app (Apple documents
  the GPU limit only), what four-second batches save in battery, and the pass's time on a long recording.
- Background downloads on a phone: suspended mid-download, ended by iOS, relaunched for the session's
  events, Wi‑Fi to cellular and back, Low Data Mode; whether Hugging Face's CDN resume data survives
  a long pause.
- A shared recording with an iPhone and a recorder in one room: how often the room is heard twice
  despite the 4 s window, and the link's clock estimate against real caption timing.

## Processing follow-ups: earlier recordings, notes in real summaries, rooms (2026-10-30)

Three follow-ups to the processing-quality work below: recordings transcribed before background
audio detection are listened to on the Mac ([architecture](architecture.md#background-audio), step 6),
the notes-in-summaries prompts on the real default model ([templates](templates.md#notes-and-bookmarks)),
and the sound classifier in rooms more like real ones. No recording of the room, no Bluetooth.

**Earlier recordings.** Tracks with a transcript run and no current analysis
(`Meeting.recordingsAwaitingBackgroundAudio`) are classified once each, newest conversation first, 20 s
after the last job, download, photo reading, voices given to speakers, sync, or recording, at utility
priority, stopping when other work starts. `LibraryController.addBackgroundAudio` keeps the analysis on
the track and fuses again only when that changes what's left out. Passages the person corrected are
never judged background, so a correction keeps its passage and its Version History entry; speaker
profiles reconcile when the passages left out change. Tests: `BackgroundListeningTests` (2, application: Apple's classifier on a
36 s recording of a `say` voice and then the synthetic band, transcribed without an analysis: the
words over the music left out, a corrected passage over the music kept with its correction, the
transcript runs, revisions, summary, and a renamed speaker unchanged, nothing transcribed or
summarized, the Inspector line, listened to once; nothing starts while a download runs, and a
recording the classifier can't hear is tried once), `BackgroundAudioTests` (2 more: a corrected
passage stays when background audio is left out again; which recordings await an analysis, with an
echo-cancelled copy's original and an untranscribed recording excluded and an older analysis measured
again), and `SpeakerProfileLibraryTests` (the coordinator takes a label off when the voice turns out to
be only in background audio).

**Notes in real summaries.** The default summary model for this Mac (M5 Pro, 64 GB: workstation tier,
first launch), Gemma 4 26B A4B QAT 4-bit, revision `0e3cbab38ce568cf6e23543010d08d03b731910c`. All ten
files matched the catalog (three safetensors and `tokenizer.json` by SHA-256, six small files by git
blob ID). The disk had under 10 GB free, so the installed copy was used read-only: a scratch models
folder with its own receipt and a symlink to the weights, the installed folder's listing unchanged
afterwards; nothing was downloaded. A scratch, uncommitted XCTest built each conversation as a
`Meeting` and ran `MeetingEvidence.summarySource` and `LocalIntelligenceRuntime.summarize` (debug build,
MLX's metallib from the same build). Decoding is greedy, so the prompt is the only difference between
runs. Four conversations written for this, with notes typed a few seconds after the passage they
follow and bookmarks during one:

- **Launch** (Priya, Marcus, Dana, Leo; 3 min, automatic template): an untimed prep note; "Budget
  cap is firm at 40k, Dana confirmed by email this morning" where Dana only said finance would like
  "around forty thousand"; "Launch May 12?" where the team chose the 19th because the 12th is too
  early; "Leo owns beta signup page", said; a "Pricing decision" bookmark and a bare one on a risk.
- **1:1** (Sam, Alex; 1:1 template): "Wants to lead onboarding redesign", said; "Seemed tired - third
  late night this sprint" where Alex said twice this week; "Promo packet due Nov 15" where Sam said
  mid-November; a "Feedback on demo" bookmark.
- **Customer discovery** (Jordan, Elena, Raj; Customer discovery template): "Exports ~20 min each, run
  daily" and "Stack: Notion + Google Sheets", both said; "Renewal is in March; procurement will need
  SOC 2", never said; a "Pricing objection" bookmark and a bare one on single sign-on.
- **Platform weekly** (five people; 22 min, 183 passages, read in two parts): "Postgres cutover moved
  to Sat 2am - tell support", said; "Ben can maybe swap Dec 3 - ask him after", never said; "Hiring:
  only 2 reqs approved per Mei's email" against "three backend reqs approved"; an "Incident root
  cause" bookmark and a bare one on a cache TTL.

Before the change, notes were never listed, given a heading, or quoted as a speaker, and every
bookmark's passage kept its detail ("$12 per seat… $10 per seat… free tier capped at three seats";
"Elena noted that $300 per month is higher than any other tool used by the team"; "lowered the cache
TTL to 90 seconds… hit rate from 94% to 81%"). But two notes that add something were written as fact:
"The budget cap is firm at $40,000, which includes the agency and paid social, as confirmed by Dana
via email this morning", and "There is a potential swap for Ben and Aisha on Dec 3". "Launch May 12?"
went unmentioned, and notes that only repeat what was said got a sentence of their own ("Your notes
identify this stack as Notion and Google Sheets").

The prompts changed in two places. The final pass compares each note with what was said around it:
what the conversation also says is written from the conversation without mentioning the note; what
only the note says is the person's ("Your notes add that…"), never something said, decided, or
confirmed; a conflict is mentioned. The system instructions say the same in a line. A long
conversation's extraction and compression keep what a note adds "marked as the note's". With both:

| Note | Before | After |
| --- | --- | --- |
| Launch: cap firm, Dana's email | written as fact | "Your notes add that the budget cap is firm at 40k, as confirmed by Dana via email this morning." |
| Launch: "Launch May 12?" | not mentioned | "Your notes suggest a potential launch of May 12th, but Leo noted that May 12th is too early due to the migration timeline." |
| 1:1: tired, third late night | attributed | "Your notes add that Alex seemed tired and has worked late three times this sprint." |
| 1:1: packet due Nov 15 | attributed | "Your notes add that the promo packet is due on November 15." |
| Customer: renewal, SOC 2 | attributed | attributed |
| Customer: two notes that repeat | own sentences | own sentences, now "Your notes add that these exports are run daily" |
| Weekly: 2 reqs against three | conflict mentioned | conflict mentioned |
| Weekly: tell support (said) | folded in | "Your notes add that support must be notified…" (it was said) |
| Weekly: Ben may swap | written as fact | not in the summary |

The extraction and compression change alone put the swap in as "Your notes suggest asking Ben about a
potential swap for Dec 3" but left the budget note as fact; a third variant ("every note's subject
belongs in the summary") wrote the budget note as fact again, so it wasn't kept. Four conversations
and one decoding each are a small sample, and a few words of prompt move the long conversation's
result; the change fixed the notes written as fact in the short conversations without adding one.
`SummaryNotesTests` pin the new wording in the final, extraction, and compression prompts and the
system instructions.

Seen and not changed here: in the long conversation five of its eleven topics (security, cloud costs,
customer escalations, CI times, single sign-on) were missing from every summary, and only one of about
twenty commitments survived the action check, which compares quotes with compressed evidence there; in
two of four runs a section's body stopped mid-sentence ("The root cause was a "), once followed by the
section again in full (constrained decoding). Owners are dropped when the quote doesn't name them
("Yes, I'll send the line items today"). Times in the debug build, with other work running: 49 to 147 s
a short conversation, 282 to 473 s the long one; loading took 6 to 8 s.

**Background audio in rooms.** `BackgroundRoomTests` (6) build rooms from `say` voices and the
synthetic band: a room's impulse response (direct sound, early reflections, a diffuse tail) close to
the microphone (RT60 0.45 s, direct sound 10 dB over the room) or across it (0.6 s, 4 dB under), a
TV's loudspeaker (150 Hz to 6 kHz) and a kitchen radio's (250 Hz to 4 kHz), and a song sung by the
"Good News" voice over the band. Levels are against the person at the table (about −22 dBFS). Scores
are means over each passage (speech; music or applause), the level its median, in dBFS:

| Scene | Passage | Speech | Music | Level | Result |
| --- | --- | --- | --- | --- | --- |
| TV across the room | the person at the table | 0.96 | 0.18 | −22 | kept |
| | presenter, bed 3 dB under, TV 10 dB down | 0.49 | 0.64 | −32 | broadcast |
| | the same, bed as loud as the voice | 0.53 | 0.66 | −32 | broadcast |
| | the TV's music alone | 0.00 | 0.92 | −34 | music |
| | a second person, 3 dB down | 0.94 | 0.28 | −25 | kept |
| TV on the whole time, 14 dB under | the person over it | 0.95 | 0.48 | −22 | kept |
| | the presenter between them | 0.44 | 0.63 | −36 | broadcast |
| | a second person over it | 0.92 | 0.52 | −25 | kept |
| Presenter, bed 3 dB under | 6 dB down | 0.49 | 0.64 | −28 | kept (missed) |
| | 8, 10, 12, 14 dB down | 0.49–0.51 | 0.64–0.65 | −30 to −36 | broadcast |
| | 10 dB down, bed 0 or 6 dB under | 0.37, 0.59 | 0.66, 0.62 | −32 | broadcast |
| Radio host, no music, 10 dB down | | 0.89 | 0.10 | −31 | kept (missed) |
| Song with vocals across the room, 8 dB down | | 0.06 | 0.88 | −30 | music |
| | the person over the song, 18 dB down | 0.94 | 0.53 | −22 | kept |
| Someone across the table, music in the room | 6 dB down, music 12 or 6 dB under them | 0.56, 0.43 | 0.74, 0.80 | −27 | kept |
| | 8, 10, or 12 dB down, music 6 to 9 dB under | 0.42–0.50 | 0.78–0.80 | −29 to −33 | **left out** |

What holds: a TV across the room is left out whether its bed is under or as loud as the presenter,
also when it runs under the whole conversation; its music alone and a song with vocals are music; the
people at the table stay, also over the TV or the song. What misses, as expected: a presenter only
6 dB down, and a radio host without music. What's wrong: someone sitting farther away than the others,
8 dB or more down, with music in the room within about 9 dB of their voice, is left out as a broadcast.
To the classifier and the level they are the presenter: speech 0.42 to 0.50 against 0.49, music 0.78 to
0.80 against 0.64 (higher only because the TV's loudspeaker takes the band's bass away), 7 to 11 dB
down against 8 to 14. The level is the one threshold between them, and moving it (`quieterBy` 10 dB)
would keep someone 8 dB down but still leave out someone 10 to 12 dB down and miss presenters 8 or
9 dB down: a trade, not a general improvement, so the thresholds are unchanged. The test pins that case
as an expected failure; Include brings such a passage back. `SyntheticAudio` (test support) now holds
the speech, music, room, and loudspeaker fixtures that `SoundClassifierTests`, `BackgroundRoomTests`,
and `BackgroundListeningTests` share.

**Still to check:** real rooms (a TV, a radio, music) at several distances, and someone far from the
microphone with music on; the listening pass over a real library of earlier recordings, including
recordings not yet downloaded from iCloud; Gemma 4 on real conversations with typed notes, and other
summary models (12B, E4B) with the new prompts.

## Second polish round: recordings, model names, Version History, chips, ticks, test hygiene (2026-10-30)

- **Recordings on the iPhone.** Info › Audio says what the Mac's inspector says, from DaybookKit's
  `RecordingWords`: the name says what the recording is, "Your Mac" only when the name doesn't say where
  it was made ("This Mac" on the Mac), and timing only when a conversation has several recordings (a
  later start, "The main recording", "Couldn't line up"); no 0:00 start, confidence, or drift. A
  recorder's live audio its full recording replaced says so, as on the Mac. `AppState.recordingName`,
  `sourceRole`, `sourceLine`, and `sourceTimingLine` are now the shared words with the Mac's place and
  pending wording. Tests: `RecordingWordsTests` (3); `MultiSourceProcessingTests` and `PhoneLinkTests`
  unchanged and passing.
- **Model names.** No ID a shipped Daybook stored shows raw: the first catalog's nine IDs (v0.1.0:
  `whisper-base`, `whisper-small`, `whisper-large-turbo`, `qwen-1.5b`, `qwen-3b`, `qwen-7b`,
  `speaker-community-1`, `speaker-sortformer-v2.1`, `speaker-sortformer-v2.1-compact`) name their models
  through the catalog's migration table, and no variant key has changed since v0.2.0 (the catalogs at
  v0.2.0, v0.3.0, and v0.4.2 hold the same keys). "parakeet-tdt-0.6b-v3" was never stored by Daybook: only
  the demos used it (`LibraryDemo`, `PhotoDemo`, `SpeakerProfileDemo`), and they name `parakeet/ultra`
  now. Test: `ModelSelectionTests.testEveryIDAShippedVersionStoredNamesItsModel`. The v0.1.0
  voice-embedding space (`fluid-community1-embedding-…`) is stored but never shown, so it isn't mapped.
- **Version History.** A summary's Markdown is drawn as the page draws it (bold, italics, "•" bullets,
  subheadings bold, links dropped) on both apps, with the changed words marked over that styling
  (`RevisionText.styled`, `WordChanges`, which both apps' `WordDiff` now use); the iPhone's list line has no
  marks either, and a summary two devices left in History ("sync:summary") reads as a summary. The iPhone's
  change page keeps its kind as the navigation title and shows the headline under it only when it says
  more. Tests: `VersionHistoryRestoreTests` (2 new). `--history-change "<title>"` opens a change on the
  iPhone for screenshots.
- **Floating Notes chips.** A chip whose short label says as much with its glyph (a paused iPhone's
  "Paused") shortens first (`ChipRow.Fit.shortFirst`), and a short recorder chip keeps its name
  ("Soundcore") instead of only its battery. At 360 pt, Call + Soundcore + a paused iPhone now reads
  "Call · ● Soundcore · 80% · Paused" (it was "● 80%"); at 280 pt, "Call · ● Soundcore · Paused". Every
  combination of Call, Soundcore, iPhone, and paused was captured at 360 and 280 pt wide, full (560 pt)
  and compact (212 pt), light and dark (48 window snapshots each, before and after). Compact panels
  still give way to glyphs first, as before, since the phase shares the band. Test:
  `FloatingNotesStatusTests.testChipsShortenThePausedIPhoneFirstAndKeepNames`.
- **Ticks through sync.** A summary's words now merge without its ticks, and each next step's tick merges
  on its own, found by its ID, else by its words and owner (a summary written again, or one written on
  each device). Before, a tick on one device and a speaker's name following into the summary on another
  conflicted over the whole summary, and either the tick or the new name was lost. Tests:
  `MeetingMergeTests.testATickSurvivesTheSummaryRenamingItsOwnerOnAnotherDevice` and
  `…testATickFindsAStepWrittenAgainByItsWordsAndOwner`, both failing on the merge before the change.
- **Test hygiene.** Tests that left folders in the temporary directory (`DaybookKit-…`,
  `DaybookPlaceTests-…`, `DaybookStatus-…`, `DaybookMultiSource-…`, `DaybookSaving-…`, `DaybookInspector-…`,
  `DaybookSealingTests-…`, and others) use `makeTemporaryFolder` (DaybookTestSupport): a folder per test
  in one folder per process, removed when the test ends (again if a queued save refilled it, which is how
  most leaked: a library's `local-work.json` landing while teardown emptied the folder) and with the
  bundle. `WindowInvalidationTests`, `DevicePageTests`, and a device link test named suites in
  ~/Library/Preferences; they use `makeTestDefaults`. The iPhone's tests name their suites by paths in the
  temporary directory (`makeTestSuite`, `makeTestDefaults` in its `TestSupport`), deleted per test. The
  library demo's recordings wait in one folder for the run, removed at exit, so a snapshot that exits
  mid-seed no longer leaves a `Daybook Library Demo <UUID>` folder.

How it was checked: `swift test` passed 1,226 XCTest cases (one skipped, as before): Captions 8, Core 391, Devices 101,
Intelligence 132, Kit 196, Link 73, Live 30, Mac app 295.
`scripts/build-ios.sh --test` on a clone of the iPhone 17 Pro simulator (iOS 27.0, deleted afterwards)
passed all 183. Window snapshots, before and after, light and dark: Floating Notes in every chip
combination (`--notes-demo multipoint|paused` with `--device-demo connected` and `--phone-demo
connected`, `--notes-size`), the Mac's Version History and inspector on `--library-demo`, and the
iPhone's Info › Audio and Processing, Version History's list, and a summary and a notes change
(`--demo-library`, which now has a Soundcore recording lined up by sound and the summary's "Summary
written" entry).

Still to check on hardware: the chips over a real call with a real Soundcore and iPhone (their names
and battery come from the device hub), and ticks made on two real devices at once.

## Words split off as "Unknown speaker" (2026-10-29)

From the owner (0.2.2, a microphone and call-audio conversation): the transcript read "Me: … / Unknown
speaker: I / Me: just came back …" again and again. Not the second recording: in that conversation the
iPhone never joined, and the call track held 13 passages. The microphone's own transcript had 124
passages of one or two words with no speaker, every one within 0.6 s of a labelled passage: words in
the gaps speaker analysis leaves between turns, which `TranscriptBuilder` gave no speaker.

Now a word in such a gap joins the nearest turn within a second, stored transcripts are fixed when fused
(`StrandedWords`), and the Mac fuses affected conversations again once at launch, keeping corrections.
Fused again with the fix, a copy of that conversation (read-only, in scratch) has 13 passages without
a speaker instead of 137: the call's, which had no speaker analysis. A relabelled word keeps its own
line within the speaker's passage until the recording is transcribed again.

Tests: `StrandedWordsTests` (5: between one person's passages, between two people and at the edges,
speech and far-off words left alone, other recordings ignored, fusion of stored transcripts) and
`TranscriptBuilderTests` (a word in a gap joins the nearest turn; one far from any stays unknown).

## iPhone follow-ups and processing-status gaps (2026-10-29)

What changed:

- **Not summarized yet.** `ProcessingStatus.transcribed`: a transcript with no summary and nothing asked
  for one. The iPhone's page says "Not summarized yet" with Summarize, a `summaryOnly` request a Mac
  carries out; its list row keeps the preview. The Mac's page is unchanged: Summarize and the template
  stay at its foot (`SummaryPage`'s colophon condition now reads `.transcribed`).
- **Mac first, whatever "Transcribe synced recordings on this Mac" says.** A recording a conversation was
  waiting for (`Meeting.hasAwaitedRecordingToAdd`) is queued as it arrives on a Mac with the models, with
  the request it brought, so it's added as with the setting on; other synced recordings still follow the
  setting. With another device's request open and a recording still awaited, the Mac's page keeps the
  waiting line.
- **The status sheet's queue** lists conversations waiting for a recording ("Waiting for Soundcore Work
  audio"), after the requests waiting, outside the Mac's "2 waiting".
- **The recorder page's toggles:** Import Automatically, Record Along, Hand Back to My Mac.
- **The notebook's status panel:** the preview keeps the panel's room (compact or medium) as a safe-area
  bar with the hard scroll edge effect, as the library's list does under Record. The effect runs only
  under something drawn, so the bar's room is drawn at 0.1% opacity; a clear bar gave no effect.
- **Live Activity caption:** the newest live caption, at most 80 characters ending with the newest words,
  while captions are on and showing; a new caption alone updates the activity at most every 5 s;
  `privacySensitive`, and hidden at Always-On brightness, paused, or stale.
- **Recorder only:** "Soundcore Work is recording. This iPhone isn't." over Record (the status sheet in
  the hand, the notebook's left page), and Record records along into the same conversation.
- **Open Duo crease:** Settings and its two-page sheets (Pair with Your Mac, Add Recorder) were already
  clear of the crease, open and opened while shown. The sheets Settings screens show over themselves
  (Add Term, a new template, the encryption sheets, Details) were cards across it; they're a card on the
  right page now (`pageSheet`), and still sheets in the hand.

How it was checked: `swift test` passed 1,188 XCTest cases (one skipped, as before): Captions 8, Core
373, Devices 101, Intelligence 131, Kit 186, Link 73, Live 30, Mac app 286. New:
`ProcessingStatusTests.testATranscriptWithoutASummaryIsTranscribed`,
`AwaitedRecordingTests.testAnArrivedRecordingItWaitedForIsToBeAdded`,
`MacFirstMultipointTests.testTheWaitAndTheArrivalDontDependOnTranscribingSyncedRecordings`, which fails
without the change: the phone's recording was never added. `scripts/build-ios.sh --test` on a clone of
the iPhone 17 Pro simulator (iOS 27.0): 183 passed, 177 before; new in `ReadingTests` (Summarize),
`StatusSheetModelTests` (the queue), `RecordingSurfacesTests` (the caption line, its pacing, who shows it,
and an earlier build's state decoding), and the recorder-only words in `CascadingRecordingTests`. Window
screenshots, before and after, on clones of the iPhone 17 Pro and the Daybook Shell Duo (open and
closed): the Dentist page, the recorder page's toggles, the queue at large, the panel at compact and
medium, recorder only (`--demo-recorder-only`), and Settings' screens and sheets (`--open-settings
add-term`); the Mac's transcript-only page through `--snapshot`. The clones answered the notification
prompt by a copied BulletinBoard entry, since simctl can't grant notifications.

Still needs hardware, or can't be captured: simctl can't show the Lock Screen or the Dynamic Island, so
the caption line was checked by its content state and pacing tests and a widget `#Preview`, not on
screen; the system's real update budget for local Live Activity updates needs a device. Recorder only
needs a real recorder's button with Daybook in the background. Two Macs with the setting off both queue
an awaited recording; the request's claim settles it within a sync round (docs/multipoint.md, "Limits").

## Speaker profiles: the iPhone, merging, summaries, voices, and a dry run (2026-10-29)

The open follow-ups for speaker profiles ([architecture](architecture.md#speakers-and-profiles),
[sync](icloud-sync.md#speaker-profiles)). Synthetic embeddings, temporary libraries and sync folders, a fake
inference engine; no models downloaded, no recording, no Bluetooth.

- **iPhone.** Info › People shows Recognized with Not <name> and Maybe <name> with Yes and No under a speaker,
  through the Mac's DaybookKit actions; Settings › Speaker Profiles lists, renames, merges, forgets learned
  voiceprints, removes one, and deletes. Captured on an iPhone 17 Pro simulator clone (iOS 27, deleted
  afterwards) with `--demo-library --speaker-demo`, before and after.
- **Merging** two profiles of one person (`SpeakerProfileMerges`, one record with `mergedInto`): Mac Speaker
  Profiles' Merge Into (confirmed), and a rename to another profile's name offering it. Tests:
  `SpeakerProfileTests` (merging moves voiceprints, identities, and labels and keeps the person's names; the
  merged name finds the kept profile; what another device taught the merged profile meanwhile follows it, in
  either order; two devices merging each into the other keep the later merge, deleting the kept profile takes
  both; the key round-trips and isn't written when unmerged) and `SpeakerProfileLibraryTests` (a merge on one
  Mac reaching another through a synced folder; renames refused with the merge target found).
- **Names in summaries.** Manual renames didn't touch summaries either, so the behaviour is new for both: a
  name Daybook gave (a placeholder, "Me", a label) follows into the summary, in place and in Version History.
  Tests: `SpeakerProfileTests.testANameDaybookGaveFollowsIntoTheSummary` (a label, a placeholder renamed, a name
  the person gave left alone, ticks kept, two Macs making one entry),
  `…testTheOwnersMeFollowsIntoTheSummaryOnlyWhileNoOneElseHasTheName`, `…testSummaryNamesReplaceWholeNamesOnly`,
  and `SpeakerProfileLibraryTests.testNotThemPutsTheEarlierNameBackInTheSummary`.
- **Speakers without voices** get them when the Mac is idle and the library has profiles, from the saved run
  (Identify Speakers Again's voice step), keeping names, transcript, and summary. Tests:
  `SpeakerProfileProcessingTests.testSpeakersWithoutVoicesGetThemWhenIdleAndKeepTheirNames` (an old Sortformer
  run recognized as Vlad, a voiceless speaker the person had named Dana starting its profile, nothing
  transcribed again, each run once) and `…testGivingVoicesGivesWayToQueuedWork` (a job queued meanwhile stops
  it, runs, and the voices are made afterwards); `SpeakerProfileTests.testSpeakersGivenVoicesLaterAreRecognizedAndTeachTheNamesTheyHad`.
- **One voice, two speakers.** Reproduced: with the microphone's owner and its own speaker both named Vlad,
  renaming one took the voiceprint from the other for good (two copies were taught, both retired, and the
  retirement blocked teaching it again). Now a voice another person-chosen speaker still stands for stays, and
  one sample is taught once (`SpeakerProfileTests.testRenamingOneOfTwoSpeakersWithOneVoiceKeepsTheOthersVoiceprint`,
  `SpeakerProfileLibraryTests.testNotThemKeepsAVoiceTheOwnerWasNamedWith`; both fail on the code before).

`swift test` passed 1,201 XCTest cases across the eight bundles (one skipped, as before): Captions 8, Core 383,
Devices 101, Intelligence 131, Kit 187, Link 73, Live 30, Mac app 288. `scripts/build-ios.sh --test` on an
iPhone 17 Pro simulator clone passed all 177. The Mac's Speaker Profiles window (`--library-demo --speaker-demo
--open-window speaker-profiles`, with `--speaker-profile`, `--profile-name`, `--merge-into`) was captured with
`--snapshot` before and after.

Still to do on real data and hardware: the thresholds on the owner's library (below); giving voices to old
Sortformer runs with Community-1 on a real library (time per conversation, and how many old speakers it then
recognizes); the iPhone screens on a device.

### Speaker profiles on real recordings

`Daybook --speaker-report <library> [--threshold 0.82] [--margin 0.06] [--recognition off]` (debug builds,
`.build/debug/Daybook`) runs the reconciler over a library as a dry run and prints aggregate numbers
(`SpeakerProfileReport`). Point it at a copy:

```sh
# Only the settings and conversations' metadata: no audio, no models. The library is
# ~/Library/Application Support/Daybook (a sandboxed build's is under ~/Library/Containers/local.daybook.app/Data),
# unless it was moved elsewhere.
rsync -a --include='*/' --include='library.json' --include='meeting.json' --exclude='*' \
    ~/Library/Application\ Support/Daybook/ /tmp/daybook-copy/
.build/debug/Daybook --speaker-report /tmp/daybook-copy
```

It reads `library.json` and each `Meetings/<id>/meeting.json` (a recovery copy when one doesn't decode)
directly: no store is opened, nothing syncs, no recovery copy is written, and nothing is written at all
(`SpeakerReportTests` compares every file's size and date before and after). The output has no names, titles,
or words:

- the library: conversations, profiles (and how many were merged), voiceprints by origin;
- the thresholds used, and what a reconciliation would change (speakers, conversations, voiceprints added and
  retired), after up to three rounds as the Mac runs them;
- speakers in the transcripts by kind of recording (microphone, systemAudio, soundcore.work, …) and outcome:
  no voice, named, confirmed, labelled, suggested, dismissed, unknown;
- the closest profile's similarity, binned by 0.05 with p10/p50/p90, for labelled, suggested, and unknown
  speakers; and for speakers the person named or confirmed, their own profile with that conversation's
  voiceprints left out (the same person) against the closest other profile (someone else), which is what the
  label threshold has to separate; then the same percentiles by kind of recording, with the label margin.

On the owner's library (2026-10-29, a JSON-only copy, deleted afterwards): 4 conversations, 1 profile (named on
the iPhone), 8 speakers. A reconciliation would label 1 microphone speaker (0.97 to the profile: the owner's
voice from the iPhone recognized through the MacBook microphone), suggest 1 (0.76), leave 2 iPhone speakers
unknown (0.01 and 0.63), and 2 microphone speakers from older runs have no voice yet (the Mac gives them one
when idle). Too few to tune the thresholds; the label and the suggestion both sit where expected.

## Mac UI follow-ups (2026-10-29)

**Inspector crash.** With the inspector open, opening Daybook on iPhone's page at launch threw
"Unable to activate constraint … NSHostingView<…InspectorStyleContext>.trailing and
_NSSplitViewItemViewWrapper.trailing because they have no common ancestor". Traced with lldb: the
inspector puts the page and itself in a split view of their own (`SystemSplitView`), and whenever the
page's view identity changed (the `detail` view's branches: an empty page, a conversation, a device
page), SwiftUI gave the page a new `NSSplitViewItem` (`setSplitViewItems:`), which took the
inspector's item out and put it back. The inspector's expand animation, deferred at launch until the
window's other animations finish (`Transaction.addAnimationListener`), then completed on the detached
wrapper. Both sides of that split are now one view (`ZStack`) whatever they show, so a page switch never
replaces its items. `LibraryInspectorTests` hosts `LibraryView` in a window and switches between a
conversation and a device page while the inspector collapses and expands: without the fix the page's
item changed on every switch and the inspector ended up out of the window; with it the items stay. The
repro (`--library-demo --inspector --select "Vendor walkthrough" --phone-demo connected --device-demo
none --window-size 1400x860`) crashed 3 of 5 runs before and 0 of 12 after (6 with the old `PhoneDemo`
timing, 6 with the new). `PhoneDemo` now waits for `LibraryDemo`'s seeding, so the selection lands
before the phone's page. Its conversations (audio still to arrive) also couldn't be saved in a library
named by a `/private` path: `LocalFiles.requireContained` resolved the file's existing ancestors but
not the conversation folder, which didn't exist yet, and Foundation drops `/private` only from paths
that exist (`MeetingStoreTests.testANewConversationWithRecordingsStillToArriveSavesInALibraryUnderPrivate`).

**Words and layout.** Floating Notes says what records along once, in its chips (the line under the
clock is gone; a paused iPhone's chip names it). The iPhone's recording screen has no chips and says it
once in `MultipointStatus`, so it has no duplication. A first summary reads "Summary written" with no
empty Before, on the Mac and the iPhone (`RevisionText.hasBefore`). The inspector names each recording
once and shows timing only for several recordings, without a 0:00 start, confidence, or drift. Device
pages: method rows leave out what the byline says, "Last import" is capitalized (the shared
`ImportFolderWatcher.summary`, which the iPhone's method rows show too), the iPhone's page has no
Import heading or method rows, Listen Live's captions label shares the Listening row's glyph column,
the More menu hides what doesn't apply (`DeviceMenuOffer`), and the sidebar's import ring is drawn by
Daybook. Controls says Play or Pause from `PlaybackActivity`, which publishes only whether playback is
playing (`AudioPlaybackTests`, a silent file played muted). Capture warnings: a device change and a
recovered track's missing timing file are one plain sentence, the detail in the track's capture notes.
The photo demo's recording has its own transcript. Floating Notes already carried the copy pass's words.

**The window's content under the toolbar** (the owner's report from 0.2.2). Not reproduced on this
branch. `--window-actions` drove the window through each suspected trigger before a snapshot, run as an
app (`open`) so it could take full screen: full screen in and out, the toolbar hidden and shown (also in
full screen), zoom and back, the sidebar collapsed and expanded, the window against the top of the
screen, and a recording with live captions on the page with the notes focused. Every column started
under the toolbar each time. On this Mac (a notched 1512 × 982 display) full screen puts the window
below the camera band (1512 × 949) with the toolbar in its own window; the report shows the window
reaching the top of the screen, which none of these produced. The window can't be made shorter than
its 532 pt minimum (`setFrame` is clamped), so content centred in a too-short window isn't it either.

Verified: `swift test` passed 1,192 XCTest cases across the eight bundles (one skipped, as before): Captions 8,
Core 374, Devices 101, Intelligence 131, Kit 185, Link 73, Live 30, Mac app 290. `scripts/build-ios.sh --test` on a
dedicated iPhone 18 Pro simulator clone (deleted afterwards) passed all 177; the iPhone's Version History was
captured there with a first summary, before and after, in light and dark. Window snapshots, before and after, light and dark where colour is involved, are
listed in the branch's report. Still to check on hardware: the owner's layout report on their own
setup (`--window-actions` is there for it), the sidebar ring in an active window on a real import, and
a real recorder's device change during a recording.

## Sync follow-ups: compaction, new containers, reinstalls, encryption leftovers, warnings (2026-10-29)

The open follow-ups in the sync engine and library encryption (docs/icloud-sync.md, "Compaction", "The iCloud
container", "Devices and presence", "Encryption"). Temporary libraries and sync folders, synthetic audio and settings;
no iCloud account, CloudKit, network, or model downloads.

- **Compaction.** One Mac prunes settings versions that aren't heads and deleted conversations' history at once, and a
  live conversation's history once every device seen in the last 30 days has acknowledged a proposal. The manifest
  becomes version 3 first. `LibrarySyncCompactionTests` (16): settings pruned while a lagging phone publishes against a
  version that's gone and waits for nothing; a conversation's history kept until the phone acknowledges, then pruned up to
  each proposal's root, with later edits merging cleanly; a phone's concurrent edit, slow to reach iCloud, keeping its
  merge base (the phone never acknowledges, nothing of that conversation goes, both changes kept with no conflict); a
  phone away a month merging its offline edit against its stored base and publishing it next pass, with a newer
  Daybook's unreadable entry elsewhere in the journal; deleted conversations keeping only their deletions once the phone
  has applied them, after it kept a paragraph it added meanwhile as a new conversation; an event that alone names a
  highlight sidecar staying, so a new Mac installs it; a recent device without `compact-1` holding compaction back until it's a month
  old; only the Mac with the smallest ID compacting; the standard policy waiting for enough to gain; the frozen version 1
  engine refusing version 3 and changing nothing; pruned files left out while their commit isn't uploaded, and a reader
  that finds a parent gone before its commit waiting for it; an encrypted library's records sealed (kind 5, no
  plaintext, no names), plaintext records from before encryption replaced, and records sealed again under a rotated key
  by the sealer, with no Mac compacting, before the old key retires;
  a newer Daybook's record a warning rather than a download, with no compacting over it; a Mac whose clock runs a month
  ahead pruning no conversation's history alone.
- **Measured** (`DAYBOOK_COMPACTION_MEASURE=1 swift test --filter LibrarySyncCompactionTests/testCompactionShrinks`, a
  debug build on this Mac, other builds running): 200 settings versions with 20 profiles of 24 voiceprints each (0.4 MB a
  version) and 100 conversations relabelled three times. Plaintext: 601 journal files and 109.2 MB before, 103 files and
  0.7 MB after; a new device's first pass 3.56 s before, 1.04 s after. Encrypted: 601 files and 109.3 MB before, 103 files
  and 0.7 MB after; first pass 6.46 s before, 2.09 s after. The ordinary test runs the same at 8 versions and 6
  conversations.
- **Two devices on a new container.** `LibrarySyncNewContainerTests` (5): a Mac and an iPhone each start an encrypted
  library, iCloud brings both markers together, and both settle on the first one started with one marker left, the loser's
  sealed files and key gone, both conversations on both, and nothing more published; the loser's files and key kept
  while a third device still on its key hasn't moved on, then its entries and its republished recording gone, and a stray
  object nothing republished kept with the key until it's gone; the same winner whichever marker
  is the copy (the first started, though its ID is the larger); libraries started a month apart still pausing. `LibrarySyncCompatibilityTests` and
  `LibrarySyncStartOverTests` now also check the copy is deleted.
- **One device, listed once.** The cause, reproduced on an iPhone 17 Pro simulator clone (iOS 27.1): every `simctl install`
  over the app moved its data container, and each launch took a new device ID (4, then 5, then 6 presence records in the
  sync folder). With the identity's keychain item named by the library's path within the container
  (`SyncDeviceIdentityTests.testTheIdentitysKeychainAccountSurvivesTheContainerMoving`), three more installs moved the
  container three times and the count stayed at 6. Settings › iCloud said "4 others" before the list was collapsed and
  "1 other" after (the Studio Mac), from a sync folder with two earlier installs of the same iPhone as well.
  `LibrarySyncReplicaTests.testAReinstalledDeviceIsListedOnceAndOldIdentitiesRetire`
  (`firstSeen` kept, an earlier ID superseded, two in use at once both listed, retirement after 180 days, every ID still
  known); `LibrarySyncEncryptionTests.testAnEarlierIdentityOfAReinstalledIPhoneIsListedOnce` (DaybookKit: not listed
  among the devices that would stop syncing, while automatic encryption still waits for it to be a month old).
- **Review.** An independent read of the change found that deleted conversations' history was pruned before every device
  had applied the deletion (a concurrent edit's additions could be lost), that an event alone naming a highlight sidecar
  could be pruned, that a key could retire while a compaction record was still sealed with it, that a newer-format entry
  anywhere kept a returning device from merging, and that the smallest ID let a library an offline device started later
  replace an established one. Each is fixed above, with a test.
- **Second review.** A second independent read (PR #30) found four more, each fixed with a test that fails without the
  fix: files sealed with a retired key were deleted once nobody held it, and their author then reverted its own edits
  (now never deleted, and the author publishes its copy again:
  `LibrarySyncSealingTests.testFilesSealedWithARemovedKeyAreKeptAndTheirAuthorPublishesItsCopyAgain`; the key stays while
  any device of any age or any object, by its header, still needs it: `testARetiredKeyStaysWhileAnyDeviceOrObjectStillNeedsIt`);
  the race's loser was deleted before every device had moved on (`testTheLosersFilesAndKeyStayUntilEveryDeviceHasMovedOn`);
  a Mac whose clock ran a month ahead compacted on its own acknowledgement
  (`LibrarySyncCompactionTests.testAMacWhoseClockRunsAMonthAheadDoesntPruneConversationsAlone`); and the iPhone's
  identity migration could take another library's identity
  (`SyncDeviceIdentityTests.testTheAppsLibraryNeverAdoptsAnotherLibrarysIdentity`, DaybookKit, which didn't compile against
  the earlier code: it took the latest identity item of any library).
- **Third review.** A third read confirmed those close their scenarios and found what could be kept forever. Each is fixed
  with a test: a lost device's presence held a retired key, and a losing library's files and key, back for good (presence
  older than six months no longer counts: `LibrarySyncSealingTests.testALostDeviceHoldsARetiredKeyBackForSixMonthsAtMost`,
  `LibrarySyncNewContainerTests.testALostDeviceHoldsTheLoserBackForSixMonthsAtMost`); an iPhone never removed a key while
  its recordings were only in iCloud (a recording's object is known by its name; only one nothing names is downloaded,
  on Wi-Fi, to read its header: `testAnIPhoneRemovesARetiredKeyWithoutDownloadingRecordings`); a file sealed with a
  removed key kept the republish armed for good, and one that was a compaction record didn't hold compaction back (both
  count for 30 days from when a device first finds them, remembered in its checkpoint:
  `testAFileSealedWithARemovedKeyCountsForAMonthOnly`); a Mac clock six months ahead compacted alone
  (`LibrarySyncCompactionTests.testAMacWhoseClockRunsSixMonthsAheadDoesntPruneConversations`: a phone it sees writing
  says the clock is ahead, while a device lost long ago holds nothing back; set right again, compaction resumes, where
  a run and a proposal dated in the future had held it back for as long). Forgetting a device by hand in Settings
  isn't built: presence older than six months no longer holds anything back.
- **On an iPhone simulator** (a clone of the iPhone 17 Pro, iOS 27.1, a sync folder in the app's container): a plaintext
  library whose Mac was last seen 40 days ago, with a recording only in iCloud (a placeholder). The iPhone encrypted it on
  its own and, as the migrator waiting for that recording, showed "Encrypting · 1 left" with Use Cellular Data below it
  (before this change, no switch).
- **Encryption leftovers.** Retired keys: `LibrarySyncSealingTests.testARetiredKeyLeavesTheKeychainOnceEveryDeviceHasMovedOn`
  (recorded in the manifest, kept 30 days, held back by a recent device still waiting for the current key, then removed;
  a file sealed with it afterwards kept, neither waited for nor a warning). Cellular: `testAPhoneAllowedCellularSealsHistoryOffWiFi`,
  `LibraryWordsTests`. Reset encryption: not built; Start Over is the disaster path, and a reset while a key may exist
  would delete what's only in iCloud (docs/icloud-sync.md, "No separate reset encryption"). iPhone backups: already
  automatic for an encrypted library (`BackupExclusion`, since the 0.3.0 review); kept as it is, with the reasons in
  docs/iphone.md, "Backups".
- **Warnings.** `SyncWarningWordsTests` (a pass with a damaged entry warns in plain sentences, its name behind Details;
  waiting for a download or the key is the whole warning), `LibrarySyncApplyTests.testADamagedEntrysNoticeIsAPlainSentence`,
  `LibrarySyncTests` (a recording kept beside its copy). Settings › Library captured before and after with
  `--sync-demo damaged` (a new demo state).

On this tree, `swift test` passed 1,220 XCTest cases across the eight bundles (one skipped, as before): Captions 8, Core
404, Devices 101, Intelligence 131, Kit 188, Link 73, Live 30, Mac app 285. `scripts/build-ios.sh --test` on a dedicated
iPhone 17 Pro simulator clone (iOS 27.1, deleted afterwards) passed all 177 before the third review's fixes, which change
no iPhone-only code. `swift build --build-tests` adds no warnings.

Still needs the owner's devices:

- Two devices launched at once on a new iCloud container (a new Apple Account, or the container's data deleted in
  Settings): whether iCloud keeps a conflict version or a renamed copy, and that both settle on one library.
- Compaction on real iCloud: commits uploading before the pruned files go, a phone that was offline for weeks coming back,
  and the sync folder's size before and after (Settings › Apple Account › iCloud › Manage Storage › Daybook).
- A rotated key leaving iCloud Keychain on every device 30 days on (Passwords app, or Keychain Access on the Mac:
  `local.daybook.library-key`).
- An iPhone reinstalled (delete the app, install again): "Devices in This Library" lists it once.
- An iPhone that turned encryption on sealing history on cellular with Use Cellular Data on.

## Soundcore: two apps on one link, and Wi‑Fi Fast Transfer (2026-10-29)

Two follow-ups for the Soundcore Work ([direct Soundcore](direct-soundcore.md)), built and tested
against `SimulatedSoundcore` only: no Bluetooth scanning, no Wi‑Fi, no recording, no downloads.

**Two apps on one link.** On iPhone the Soundcore app's transfer reaches Daybook as audio it didn't ask
for. While that's arriving, Daybook's transfers, Listen Live, and Start and Pause wait until it has been
quiet for three seconds, and the recorder's page (Mac byline, iPhone header and import row) and the
iPhone's status line say "Waiting for the Soundcore app to finish". Daybook never sends Stop Transport
over it, a transfer of Daybook's that the other app's request cuts off starts again afterwards (not a
failure), its own stragglers aren't taken for another app's, and another app's key exchange makes
Daybook exchange keys again. The simulator emulates the other app's paced transfer
(`beginAnotherAppsTransfer`) and records any command of Daybook's that would cut it off; four new
`SoundcoreSimulatorTests` cover the import, Start, a transfer under way, and the key exchange.

**Wi‑Fi Fast Transfer (iPhone).** Built from the community protocol notes and tested end to end on
loopback: `SoundcoreFastTransferTests` (10) run the real connection, session, and queue against the
simulated recorder's access point, a TLS WebSocket server whose self-signed identity is made in memory
(`SecPKCS12Import` with `kSecImportToMemoryOnly`; the login keychain was checked untouched) and whose
parser takes only the official client's header names, plus a UDP keep-alive listener. Three new
`SoundcoreProtocolTests` pin the byte formats and WebSocket framing. The read-only allow-list gained
only `1A 05` and `1A 02` (file requests over Wi‑Fi are `1A 07`). A race found while testing (a
recording queued just after the Wi‑Fi link ended tried to open it without Bluetooth, and paused Fast
Transfer) is fixed, and its test fails without the fix. The owner enabled the Hotspot Configuration
capability on `local.daybook.phone`; the entitlement is in the iPhone app (`Apps/iOS/project.yml` and
`DaybookPhone.entitlements`), not the widgets or the Mac app.

`swift test` passed 1,202 XCTest cases across the eight bundles (one skipped, as before): Captions 8,
Core 373, Devices 118, Intelligence 131, Kit 184, Link 73, Live 30, Mac app 285.
`scripts/build-ios.sh --test` on a dedicated iPhone 17 Pro simulator clone (iOS 27.0, deleted
afterwards) passed all 178, with the status line's new case. In the iOS Simulator, the iPhone app ran
Fast Transfer end to end against the simulated recorder's access point (`--device-simulator
--device-autopilot --demo-transfer wifi`), and waited for its emulated other app (`--demo-transfer
other-app`); screenshots of both, the new preference, and the Mac page (`--device-demo other-app`), each
before and after.

**Needs a recorder.** Whether the Soundcore app's transfer reaches Daybook on iOS, and whether three
quiet seconds is enough between its files. All of Fast Transfer: `1A 05` and its reply, the ten-second
start, joining (iOS's prompt, the address), TLS and the WebSocket handshake on the recorder's parser,
the file request's form and last byte, the keep-alive, the recorder accepting Bluetooth while its
access point is open, `1A 02`'s reply and whether `FINISH` closes the access point on its own, and the
throughput against Bluetooth ([verifying it](direct-soundcore.md#verifying-it-on-a-recorder)).

## The Mac while it transcribes and summarizes (2026-10-29)

The owner found the Mac's window very slow while it transcribes or summarizes, on 0.2.2. There, every
engine report set `AppState.processingProgress` from its own main-actor task, so each report redrew every
window; 0.4.0 throttled progress and gave it its own observed object. Measured again on main (3420e2f), in
a debug build, with a 15.4-minute dialogue of three `say` voices (Samantha, Daniel, Karen) imported into a
scratch library whose models were the owner's installed ones, mirrored read-only (Parakeet ultra,
Community-1, Gemma 4 26B-A4B for summaries).

**How.** `--perf-log` (debug, `PerfProbe`) writes a line a second: the main thread's CPU time
(`thread_info`), the longest a ping from another thread waited for it and every wait over 100 ms, the
stage, and frames a tiny Metal layer got on screen. Body counts came from temporary `PerfProbe.body`
calls in 18 views (the library window, list and rows, page parts, inspector, Floating Notes; not kept).
`sample` attributed the time. Two harnesses repeat one cause in isolation: `--perf-progress` reports
progress as an engine does for the demo library's transcribing conversation, and `--perf-touch` changes the
selected conversation every two seconds, as each step of a job does. Other agents shared the machine
(load averages of 100 to 1,000, swap nearly full), so before and after ran interleaved, and CPU time
counts for more than waits.

**What it found on main.**

- Summarizing: the main thread was idle (0.1% busy, no waits over 100 ms, no redraws). Frames reached the
  screen at 57.5 a second with the display awake, two gaps over 50 ms (at most 83 ms) in 220 s, so the
  model on the GPU didn't hold the window's frames back on this Mac (64 GB).
- Transcribing, while the percent moved (recognition, listening for music): the main thread was 31 to 35%
  busy. Each report (up to ten a second) started animations that overlapped for the whole job: the bar
  eased to its width under its glow, the page's percent rolled its digits, and the list row faded its line.
  Each frame laid the window out again from its root through every split-view column. Turning off the
  animations alone took the synthetic progress from 32% to 11%.
- Every change of the library (a step of the job finishing, a status, a typed note) drew the window twice:
  the app observed `AppState`, so each change also rebuilt every scene; that made SwiftUI write the menu bar
  item's visibility back to its setting, and the write redrew every view that keeps a setting, the library
  window again among them. `LibraryController.update` also announced each change twice, and once for an
  update that changed nothing. The page and the inspector were drawn again by the window after drawing
  themselves. With forty conversations, most of a change's main-thread time went to the list rows: each
  routed the models through the whole catalog again to ask whether this Mac can process.
- When the transcript arrived, the window stalled for 0.9 to 2.1 s in all.

**What changed.**

- Progress redraws its views only on a new percent or message (`ActivityProgress`); the bar and the percent
  step without animating; a row fades its line only when its words change (`RowStatus.phrase`).
- The app holds `AppState` without observing it (`AppStateHolder`), the menu bar item observes it in its own
  label, and an unchanged visibility isn't written back.
- The page and the inspector are `Equatable` by conversation, so the window doesn't draw them again.
- `LibraryController.update` announces a change once, and not at all when nothing changed.
- The routed models are worked out once per change of what routes them (`routedRequiredModelIDs`).

**Before and after.** Main-thread CPU, waits over 100 ms, and bodies of the 18 counted views:

| Run | Before | After |
| --- | --- | --- |
| Synthetic progress, recognition (2 rounds, 20 s each) | 49.2%, 16.7/min, 18.7/s | 10.4%, 2.9/min, 11.3/s |
| Synthetic progress, finding speakers | 25.1%, 0/min, 9.5/s | 2.4%, 0/min, 5.2/s |
| Synthetic progress, listening for music | 43.8%, 26.2/min, 8.9/s | 5.8%, 0/min, 5.0/s |
| A change every 2 s, transcript page (2 rounds) | 7.5%, 30/min, 62/s | 2.4%, 1.7/min, 17/s |
| A change every 2 s, summary page | 6.2%, 27/min, 20.5/s | 2.4%, 0.8/min, 7/s |
| A change every 2 s, 40 conversations | 8.5%, 30/min, 20/s | 3.1%, 1.7/min, 7/s |
| Real job, transcribing while the percent moves | 35.2%, 6.7/min, 5.7/s | 4.2%, 0/min, 4.2/s |
| Real job, finding speakers | 2.7%, 0/min, 0.9/s | 0.9%, 0/min, 1.5/s |
| Real job, all of transcription | 8.9%, 3.2/min, 2.9/s | 1.8%, see below, 3.2/s |
| Real job, summarizing | 0.1%, 0/min, 0/s | 0.0%, see below, 0/s |

On the transcript page a change now costs about 47 ms of main-thread time in the debug build, from 150 ms;
the longest wait in most seconds with a change went from 130 ms to 28 ms (median), 217 ms to 50 ms (90th
percentile). The real runs compare runs with the display asleep (the first before run, and the after run).
In the after run the transcript's arrival stalled the window once, 137 ms with the main thread busy;
before, 0.9 s. The after run's other waits over 100 ms (up to 0.94 s, while the summary model loaded) came
with the main thread idle, 0% CPU, while the machine paged with 29.5 of 30.7 GB of swap in use, and the
Mac slept twice during it.

Tests: `WindowInvalidationTests` (progress that changes neither percent nor message redraws nothing but
reaches the app; every delivery reaches `onChange`, only visible ones redraw; a row fades on its words,
not its percent), `LibrarySavingTests.testAnUpdateChangesTheLibraryOnceAndAnUpdateThatChangesNothingNotAtAll`,
`SpeechRoutingTests.testRoutedModelsAreWorkedOutOncePerChangeOfWhatRoutesThem`. `swift test` passed 1,189
XCTest cases across the eight bundles, one skipped: Captions 8, Core 373, Devices 101, Intelligence 131,
Kit 185, Link 73, Live 30, Mac app 288.

Not established here: a release build (the debug build's own code runs unoptimized; SwiftUI's and AppKit's
work, most of what was measured, doesn't change); frames with the display awake after the change (the
display slept for the after runs); a Mac where the summary model barely fits in memory, where paging can
stall the window whatever it draws; and the owner's 0.2.2 build itself. Still drawn per change: a
conversation's visible passages (they take the whole conversation), 18 on the transcript page. Floating
Notes' progress line (`WorkProgressLine`, shared with the iPhone) still eases each step, at most five
times a second and now only on a new percent.

## The four streams together (2026-10-29)

Processing quality, speaker profiles, live transcription, and recording across devices were built
apart and land together. Where they meet:

- A voice heard only in passages left out as background audio (`Meeting.backgroundOnlySpeakerIDs`) is
  never labelled or learned into a speaker profile; background audio included, labelled, and left out
  again takes the label and what it taught off (`SpeakerProfileTests.testAVoiceOnlyInBackgroundAudioIsNeverLabelledOrLearned`).
- Live captions on both devices name people from the synced speaker profiles
  (`KnownVoices.fromProfiles`: each profile's voiceprints in the live voice model's space, newest
  sixteen) instead of named speakers grouped by name (`LiveSpeakerTests.testTheLibrarysVoiceProfilesAreKnownVoices`).
- The iPhone's Settings › Models row sits in the redesigned Settings, after Storage.

On the combined tree (with the polish of #21 to #23), `swift test` passed 1,185 XCTest cases across
the eight bundles (one skipped, as before): Captions 8, Core 373, Devices 101, Intelligence 131, Kit
184, Link 73, Live 30, Mac app 285. `scripts/build-ios.sh --test` on a dedicated iPhone 17 Pro
simulator clone (iOS 27.0, deleted afterwards) passed all 177, the encoder timing tests included.

## Processing quality: background audio, notes in summaries, Mac-first multipoint (2026-10-29)

Three of the owner's requests: keep TV, radio, and music out ([architecture](architecture.md#background-audio)),
weight and fold notes and bookmarks into summaries ([templates](templates.md#notes-and-bookmarks)), and
process this Mac's audio while saying it's waiting for the iPhone's ([multipoint](multipoint.md#mac-first)).
Synthetic audio, temporary libraries and sync folders, loopback, deterministic models; no model
downloads, no recording, no Bluetooth.

**Background audio, measured.** Apple's built-in classifier (SoundAnalysis `.version1`, two-second
windows every second) on recordings made from `say` voices (Samantha, Daniel, Fred, Karen, Moira,
Rishi, Tessa) and a synthetic band (chord pad, plucked arpeggio, bass, kick, snare, and hi-hat at
120 bpm), mixed at known levels, in a debug build:

- Speech alone reads speech 0.94, music 0.09; the band alone, music 0.90, speech 0.00. 24 s classifies
  in 0.34 s.
- The classifier has no TV or radio label, and gives a person talking over music and a presenter over a
  music bed at the same relative level the same scores (speech about 0.8, music about 0.7). So a
  broadcast voice is judged only when it's also quieter than the conversation (rule 3).
- Sweep, a person alone and then a second voice over the band: a second person (5 voices; 0, −3, and
  −6 dB against the first; music 20, 15, 12, 9, and 6 dB under their voice) was kept in all 75 cases.
  A presenter (Daniel; −3, −6, −10, and −14 dB; music 10, 6, 3, and 0 dB under) was judged a broadcast
  in the 4 cases at least 10 dB quieter with music within 3 dB, and kept in the other 12 (missed, the
  conservative side). The first thresholds tried (3 dB quieter, margin 0.2) judged a person 6 dB
  quieter over music 12 to 15 dB down a broadcast (Fred, Tessa); the shipped ones (7 dB, 0.15) don't.
- The living-room fixture (64 s), as the recognizer and diarizer would report it:

  | Passage | Speech | Music | Result |
  | --- | --- | --- | --- |
  | The person alone, 0–6 s | 0.95 | 0.09 | kept |
  | A presenter 10 dB down over a bed 3 dB under it, 12–19 s | 0.77 | 0.72 | broadcast |
  | "Thank you for watching" over the TV's music alone, 24–32 s | 0.00 | 0.86 | music |
  | The person over music 20 dB down, 32–39 s | 0.94 | 0.49 | kept |
  | A second person over music 12 dB down, 44–50 s | 0.82 | 0.76 | kept |
  | The person alone again, 56–60 s | 0.95 | 0.13 | kept |

Tests: `BackgroundAudioTests` (8, core: sound tags, music without speech, a broadcast voice only beside
the conversation and only when quieter, named speakers never judged, compact frames, fusion leaving
passages out and Include bringing them back, a passage another recording heard as conversation kept,
bookmark context, merging the choice); `SoundClassifierTests` (4: the classifier on synthetic audio, the
living room, a broadcast voice's turns kept out of voice profiles and its speaker given no embedding,
a recording classified once and a classifier that can't run leaving everything in).

**Notes in summaries.** `SummaryNotesTests` (7) with a model that records every prompt: note windows
(a minute before, 15 s after) and bookmark windows (30 s before, a minute after), notes and bookmarks
placed in the transcript at their times, untimed notes listed, a bookmark on a recording that isn't
lined up carrying its own passages, trimming that gives every note its nearest passage first, the short
prompt (notes in place, folded in, never listed or copied), the long one (each part sees its notes and
every note, the marked passages reach the final pass word for word and unmarked filler only
compressed), templates with notes, a note's words never accepted as a commitment's quote, and inference
that only takes strings getting what it always did. Not measured: how well a real model (Gemma 4) folds
notes in, which needs real conversations and the models, not downloaded here.

**Mac first.** `AwaitedRecordingTests` (4, DaybookKit: which links are awaited, arrival by recording ID
and Listen Live portion, two days, several devices, untranscribed audio first), `MacFirstMultipointTests`
(1, application: this Mac records with a phone over loopback, summarizes its own audio while the
phone's is blocked from arriving, says "Waiting for iPhone audio" in the row and Floating Notes and
"Waiting for audio from …" on the page, keeps a correction, a renamed speaker, and notes when the
phone's recording arrives through sync and is added, with the first summary in Version History), and
`AwaitingRecordingStatusTests` (1, iPhone: its row and page). The list row, page line, and inspector
hooks were captured with `--library <scratch> --device-demo none --snapshot`.

`swift test` passed 1,078 XCTest cases across the seven bundles (one skipped, as before); `scripts/build-ios.sh --test` on a dedicated iPhone 17 Pro simulator
(iOS 27.0, deleted afterwards) passed 158.

**Still to check:** real rooms with a TV, a radio, and background music at several distances, real
voices, and a news anchor without music (expected to stay in); summaries from real models with notes
and bookmarks; the waiting line through real iCloud latency with a real iPhone.

## Speakers across conversations (2026-10-29)

From the owner (Balanced: Nemotron 3 for speakers, Community-1 for voice profiles): naming themselves in one
conversation labelled only that one, though they speak in others; Settings › Models showed "Match voices across
recordings" greyed out, "Not available with this model".

Why (lines as of 4abb4ba): no identity outlived a conversation. `SpeakerMatcher.match` compared a new recording's
speakers only with the same conversation's (`Sources/DaybookCore/SpeakerMatcher.swift:35-60`, "It does not maintain a
global voice identity store"), only while that recording was processed (`Meeting.apply`,
`Sources/DaybookKit/ProcessingEngine.swift:182`; `AppState.adopt`, `Sources/Daybook/App/AppState+Sources.swift:225`),
and a rename (`Meeting.renameSpeaker`, `Sources/DaybookCore/Models.swift:506`) changed one label in one conversation.
Also: the setting's availability read only the speaker model's capabilities (`ModelRouting.supportsVoiceMatching`,
`Sources/DaybookKit/Models/ModelSelections.swift:75`, used at `Sources/Daybook/UI/SettingsModelsPane.swift:151`), so
Nemotron greyed it out though its speakers get Community-1 voice profiles in the same space; and the fused microphone
owner ("Me") has no embedding of its own (`Sources/DaybookCore/MultiSourceFusion.swift:880`), so naming it taught
nothing and it was never compared.

Now speaker profiles (docs/architecture.md, "Speakers and profiles"; docs/icloud-sync.md, "Speaker profiles"):
names given on any device teach profiles, the Mac labels and suggests across the whole library (recordings
processed earlier included) whenever a name, conversation, or profile changes and before each summary, confident
labels teach profiles within bounds, and profiles and voiceprints sync as library settings.

Automated, with synthetic 64-dimension embeddings in temporary libraries (no models, recording, Bluetooth, or
network):

- `SpeakerProfileTests` (23): the reported case, retroactively (three conversations, one named); Nemotron and
  Community-1 runs matching each other and another space never; the fused owner through its microphone speaker;
  names the person gave (or Daybook didn't) never replaced; loose, short, and ambiguous matches only suggested; two
  voices of one recording; renaming a label (rejected, forgotten, never offered again) and a placeholder; deleted
  profiles; learning a new kind of recording; the quality gates (short, overlapped, background); an outlier name;
  drift (a voice close to learned voiceprints but not the person's stays below a label); bounded learning with
  retirements that never come back; no self-recognition; recognition off; a rename made meanwhile winning; live
  identification from synced settings; half-float storage; fields and encodings from a newer Daybook; an earlier
  Daybook's item-by-item merge; two devices teaching one profile in either order; identity merges.
- `SpeakerProfileLibraryTests` (6): two Macs syncing through a temporary folder, each teaching Vlad before they
  sync again (every voiceprint kept, settings identical); a name given on another device teaching the Mac and its
  labels reaching that device; Not, Yes, profile rename, Forget Learned Voiceprints, and delete; the coordinator
  following library changes.
- `SpeakerProfileProcessingTests` (1): a new recording of a known voice is labelled before its summary, which has
  the name.
- `ModelSelectionTests.testRoutingUsesCapabilitiesNotModelIDs`: the setting with Nemotron and a voice-profile model.

On Apple silicon with Xcode 27.1, the seven bundles passed 1,084 XCTest cases (one skipped, as before): Captions 8,
Core 357, Devices 93, Intelligence 120, Kit 174, Link 70, Mac app 262. `swift test` here ran another worktree's test
bundles (its `DaybookLiveTests`, Kit, and Intelligence) through the shared Swift Build service while both built, so
each of this worktree's bundles was run with `xcrun xctest` after `swift build --build-tests`. `scripts/build-ios.sh`
(the simulator build, no tests) succeeded; the iPhone app wasn't changed. Snapshots of a scratch library
(`.build/debug/Daybook --library … --snapshot`) showed the inspector's Recognized with Not Vlad and Maybe Priya with
Yes and No, the Speaker Profiles window, and Settings › Models on Balanced with Match Voices Across Recordings
available.

**Still to check with the owner's library and devices:** how often the owner's voice through the MacBook
microphone, call audio, a Soundcore Work, and the iPhone is labelled rather than suggested at the default 0.82 / 0.70,
and that no one else is labelled (the thresholds come from the in-conversation defaults, not real recordings);
Community-1 profiles of one person across sessions from Nemotron and Community-1 runs; the first reconciliation's
time on the owner's library, and its sync cost: one new event per relabelled conversation, and settings versions
about 1 KB larger per voiceprint.

## Recording across devices (2026-10-29)

The owner asked that starting a recording on any device start every device connected to it (a Mac its
iPhone, an iPhone its Mac and its recorder, a recorder's button its iPhone and so the Mac), that the
recorder's audio arrive while it records so multipoint processing can start at once, that notes and
bookmarks appear on the other device live, and that the iPhone keep its recorder's link in the
background so the button works there too. What was built is in docs/multipoint.md ("Starting
anywhere", "A recorder's audio while it records", "Notes and bookmarks during a shared recording"),
docs/link.md ("Shared recordings"), docs/devices.md ("Holding the recorder's link (iPhone)"), and
docs/direct-soundcore.md ("Live audio for a shared recording").

**What iOS allows, and how Daybook handles what it doesn't.**

- *Starting the microphone in the background*: not allowed. Since iOS 12.4 an app in the background
  can't activate a recording session (`AVAudioSession.ErrorCode.cannotStartRecording`, '!rec'); Apple's
  Developer Technical Support confirms only CallKit, LiveCommunicationKit, and PushToTalk are exempt,
  for calls only (Developer Forums thread 816408, answering this very case: a Bluetooth accessory's
  button). The `audio` background mode only keeps a recording going that started in front.
- *`AudioRecordingIntent`*: lets Daybook start recording without coming forward only when the system
  performs it (the Action button, a Control Center control, the Lock Screen, Siri, Shortcuts), and the
  intent must start a Live Activity. An app can't perform it in response to an accessory's event.
  Daybook's Start Recording intent already conforms; nothing more applies.
- *Live Activities*: can't be started from the background ("Target is not foreground") except by such
  an intent or a push-to-start push from a server, which a local-only app doesn't have.
- *An audio session already active*: recording that's running carries on in the background, so a
  recorder's button pressed while Daybook records (in front or not) joins that recording. Keeping a
  session active (silence) to start later is the silent-microphone trick App Review rejects and the
  owner ruled out.
- *Bluetooth in the background*: allowed with the `bluetooth-central` mode Daybook already has. iOS
  delivers the recorder's notifications to a backgrounded or suspended app, relaunches it after the
  system ended it (state restoration, `willRestoreState`), and keeps a pending connection with no
  deadline. Scanning in the background is restricted, so a held link never scans.

So a recorder's button pressed with Daybook in the background records the recorder only: its audio is
saved into a new conversation as it records, a notification says "Soundcore Work is recording. Daybook
is saving its audio. Open Daybook to record on this iPhone too.", the link comes up and the Macs that
understand it are asked to record (told the phone doesn't), and opening Daybook records on the phone too.
A Mac can't start an iPhone whose Daybook is in the background and not recording (its link is closed
then), and says the iPhone isn't connected. No entitlement or capability on the owner's account is
needed: `audio` and `bluetooth-central` are already in the iPhone's background modes, and the
notification is an ordinary local one (Time Sensitive delivery would need the Time Sensitive
Notifications capability, which wasn't added).

**Automated** (no Bluetooth, recording, or downloads; the link on loopback, `SimulatedSoundcore` for the
recorder, newly able to record in real time and stream as it records):

- `CascadingRecordingTests` (Mac, 8): the Mac's start asks the phone with its cascade; a phone's start
  joins the Mac, never comes back, answers once however it's asked, and is declined with "Record along"
  off while a start the person chose still records; stopping the Mac stops the phone that led but not
  the one whose stop it was; a phone recording along can stop the Mac and isn't asked back; a phone
  recording only through its recorder is followed (`sharedConversationID`), stopped, and owed the stop
  until it reconnects; notes and bookmarks both ways (edits, a deleted bookmark), never echoed, and once
  each after the libraries sync; a recorder this Mac starts saves its audio into the conversation and
  its file replaces it; the recorder's button starts and stops the Mac. `PhoneLinkTests` changed for the
  new stop authority (a phone recording along may stop the Mac).
- `SharedRecordingTests` (DaybookKit, 6): recorders start once with the shared recording however
  they're asked (the phone's own start and a Mac's request at the same moment send one Start), save
  their audio into it, stop with it, and their files follow; one already recording records along and is
  left running; the one whose button led stops with it, one with "Record along" off isn't started; the
  button stopping one keeps its audio and imports its file; a late ask never restarts an ended
  conversation, one shared recording runs at a time, and a stop for another ends nothing; the notes
  tracker shares each change once, never echoes, and keeps a paragraph that arrived a moment before an
  editor wrote its text back.
- `SoundcoreSharedRecordingTests` (8): the button heard, Daybook's own commands not, and a press missed
  while the held link came back still heard (one long running isn't); holding the link (no idle release,
  back without the cooldown, the person's Disconnect stands, never a scan, the system's record tried
  again); live audio saved into the shared recording with the recorder's file becoming the same track
  (identical bytes) or replacing it (different); live audio that goes quiet kept; and what live audio
  costs (docs/direct-soundcore.md: about 8,000 bytes a second on the link, the whole recording in the
  library about 80 ms after it stops).
- `SharedNotesTests` (DaybookCore, 7): paragraphs by ID (written at the end, edited in place, deleted,
  the rest of the text as it was); bookmarks once by ID; the link's copy and the synced copy one
  paragraph each with or without a common ancestor (and different paragraphs still a conflict for
  History); edits and deletes through sync; a recorder's file replacing its live audio for transcription
  and fusion; the same bytes becoming one track named for the whole recording.
- `LinkSharedRecordingTests` (3): the new messages and fields round trip; what an older build sends
  reads the same; the new types read as unknown by a build that doesn't know them, and travel a session
  both ways.
- iPhone, `CascadingRecordingTests` (6): starting asks the connected Mac on its own (and not twice) and
  stopping stops it; a Mac-led recording stopped here stops the Mac, not when the Mac stopped it; the
  recorder's button starts the iPhone and its Mac with the recorder leading and its audio saved, and its
  button's stop stops both; in the background (`cannotStartRecording`) only the recorder records, the
  person is told, the Mac is asked with `requesterRecords` false over a link brought back up, the
  state says so, and coming forward records here too; a recorder-only recording ending stops the Mac;
  a Mac's notes and bookmarks show at once, are filed as the Mac files them (not held), and this
  iPhone's go to the Mac with the time it files them. `LinkServicesTests` changed for the permission on
  by default (a paired Mac starts recording until turned off; a choice per pairing survives a relaunch).

On Apple silicon with Xcode 27.1, `swift test` passed 1,086 XCTest cases across the seven bundles (one
skipped, as before), and `scripts/build-ios.sh --test` on a dedicated clone of the Daybook Shell Duo
simulator passed 163.

**Still to check on real hardware** (an iPhone, a Mac, a Soundcore Work, one network):

- The recorder's button with Daybook in front, in the background, suspended, and ended by the system:
  that the `18 82` push reaches Daybook each time (and its relaunch), and how long iOS keeps it running
  for the recorder's stream; that the notification appears, and opening Daybook from it records into
  the same conversation.
- That the link comes back from the background (Bonjour lookup and TLS while woken for Bluetooth) fast
  enough to ask the Mac, and stays up while only the recorder records.
- Holding the recorder's link for days: the iPhone's and the recorder's battery, whether the recorder
  stays connectable (or sleeps and drops it), how quickly the pending connection completes when it's
  back, and that the Soundcore app on the same iPhone still works alongside.
- Live audio over a long recording: sustained throughput, the recorder's real live pacing and packet
  size, whether its stream ends when its button stops it (or only the 2 s tail ends it), how often the
  recorder's file and the live audio are byte for byte the same, and whether firmware accepts Pause
  during a live stream (Daybook ends the stream first).
- Notes typed on both devices at once in a long meeting: that nothing moves under the cursor in Write
  Notes and Floating Notes when a paragraph arrives (both editors take the new text from their model).

## Soundcore: a list that doesn't come, and Details (2026-10-28)

From the owner's iPhone (0.4.1): Soundcore Work "Connected · 100%" with "Nothing New to Import" while
the Soundcore app listed two recordings on it and was transferring them over Bluetooth. A list
request the recorder didn't answer (or refused) left the connection "connected" with the remembered
list, which read as current, nothing said so, and nothing tried again; automatic import and queued
imports waited silently. Now (docs/direct-soundcore.md, "A list that doesn't come"): the device says
"Soundcore didn't list its recordings" with Refresh Status, `DeviceSession.listingState` is
`.notListed`, it's tried again after 15 and 60 s, a refusal of both layouts keeps the 12-byte one,
and status and list are read separately. Device Details gains the last list (count, pages, when, or
why it failed), what the recorder names as in progress, and counts of audio and replies Daybook
didn't ask for (another app on the iPhone's shared link). The iPhone's device page gains Details:
every recording on the recorder with why it is or isn't new, and Copy (with the app's version).

Automated, against `SimulatedSoundcore` (new: unanswered and refused list requests, and another
app's list reply and transfer on the same link): `SoundcoreSimulatorTests` (48, six new) covers the
problem and `.notListed` state, the quiet try again and its limit, automatic import carrying on once
listed (it times out with no try again, as before), the 12-byte layout after a refusal, another
app's traffic counted and ignored, and each recording's standing matching what's offered.
On Apple silicon with Xcode 27.1, `swift test` passed 1,050 XCTest cases across the seven bundles (one
skipped, as before), and `scripts/build-ios.sh --test` on a dedicated clone of the iPhone 17 Pro
simulator passed 152, including Details' copied text. No Bluetooth, recording, or model downloads.

**Still to check with a physical Soundcore Work and the Soundcore app on the same iPhone:** whether
the recorder answers a list request while the Soundcore app is transferring (and whether its reply
can satisfy Daybook's request), and what the list's trailing field (`currTransportFileTimestamp` in
the protocol notes; Daybook's "named in progress") names while it transfers. If it names the file
being transferred, Daybook shows that recording as Recording now until it's named no longer.

## App Sandbox readiness and the switch (2026-10-26)

The Mac app's move to the App Sandbox (docs/sandbox.md): release N's changes, unsandboxed, and the switch, with signed
builds still unsandboxed unless built with `--sandbox`. Verified on Apple silicon with Xcode 27.1 and macOS 27, on the
owner's Mac without touching its library, models, or preferences.

Automated:

- `swift test`: 945 XCTest cases passed across the seven bundles. New coverage: the home folder from the user
  database and display paths with an injected home; an unreadable highlights sidecar (mode 000) importing without
  it, and a sidecar chosen with its recording pairing by name; exports into a folder never replacing an earlier one;
  CloudKit account status mapping, and no container without the entitlement; `Sync/replica.json` restoring the
  identity after a move with and without preferences, without a keychain, never on another Mac, and on the way back;
  an empty library under a known device ID publishing no deletions and a lost device ID republishing without
  deleting; the development library for unbundled runs; sandboxed path flags; the way back out of the container
  (classification, the move with preferences, setting an older library aside, a failed move undone, Not Now); the
  launch check's classification, the old keychain item's identity, the verified copy into the container, and the
  library held while a move is offered; the import folder and the previous sync folder asking to be chosen again;
  the probe's levels.
- `scripts/ci/tests/run-tests.sh --require-all`: 294 checks, including `check-mac-app.sh` on stand-in apps signed
  ad hoc with the repository's entitlements files (each kind, and each way one can be wrong), the sandboxed signed
  entitlements matching the signed ones plus the sandbox's keys, `build-app.sh --sandbox` and `--sandbox-rehearsal`
  (and what they refuse), and `package-mac.sh --notarize [--sandbox]` refusing an app of the wrong kind before
  anything goes to Apple. `actionlint` and `shellcheck` are clean.

The ad hoc build (`scripts/build-app.sh --ad-hoc --debug`): `codesign -d --entitlements -` shows `app-sandbox`,
audio input, microphone, Bluetooth, network client and server, user-selected files, app-scoped bookmarks, and the
read-write exception `/private/tmp/daybook/` (plus `get-task-allow`, a debug build's); the bundle ID is
`local.daybook.app.adhoc` and there's no `container-migration.plist`. Run sandboxed, with
`log stream --predicate 'sender == "Sandbox"'` open:

- `--library /tmp/daybook/ui --snapshot /tmp/daybook/shots`: the window renders; the app creates
  `/private/tmp/daybook/` itself when it's missing.
- `--photo-demo` into `/tmp/daybook/seed`: a conversation with a recording and four photos, read by Vision, written
  through the exception.
- `--device-demo none --phone-demo connected`: the link connects on loopback (the listener and the connection, which
  need `network.server` and `.client`).
- `--smoke-test --download-models` with Community-1 as the only model: the 21 MB download reached the container's
  `Models` over the network, the fixture came from `/usr/bin/say` inside the sandbox, and the run then stopped as
  expected ("can't be used for transcription").
- A path outside the container, `--library ~/Documents/…`: stops at launch with the message, exit status 2.
- The only denial for Daybook in every run: `system-info vfs.disk-space`, which macOS 27 also logs for `tccd`, `mds`,
  and WebKit at the same time; nothing in Daybook asks for disk space.

The migration rehearsal (`--sandbox-rehearsal --debug`), with a synthetic library: the sandboxed demo conversation
above plus APFS clones of the real `Models` (21 GB, 219 items, cloned in under a second at no cost):

- `local.daybook.app.rehearsal`: the library was in the container 1.2 s after launch (a rename), every item with the
  same size, `Daybook Rehearsal` gone. `sandboxMigration` recorded `moved`, and the identity came back from
  `replica.json` (sync device, installation, and link IDs). **The preferences didn't move**: they stayed in
  `~/Library/Preferences`, so the app showed Welcome. Both manifests now move `${Library}/Preferences/${BundleId}.plist`
  too.
- `local.daybook.app.rehearsal2`, with that: the library and the preferences (onboarding, reading scale, a marker)
  arrived in 1.2 s; the app opened the conversation directly, at the moved reading scale. The only changes in the
  library were the app's own (`replica.json` rewritten, an empty `Models/.staging` pruned by the model store).
- `local.daybook.app.rehearsal3`: launched first with nothing to move (`fresh`), then given a library at the old
  place: `stillAtOldLocation`, nothing created in the container, and the "Move your library" sheet. It was hidden
  behind Welcome; the library window now opens instead while a move is pending.

The real library: `stat` of `~/Library/Application Support/Daybook` and its first two levels before and after is the
same (inode, modification and change times, sizes), except one sync checkpoint the owner's running Daybook
(`/Applications/Daybook.app`) rewrote during the session. No `~/Library/Containers/local.daybook.app` exists. The
rehearsal and ad hoc containers were emptied afterwards; their protected metadata files can only be removed in Finder.

Not exercised (owner, on real hardware and a signed build):

- The process-tap probe, sandboxed (it needs System Audio Recording), with an app and a browser call.
- Bonjour while pairing is open (`dns-sd -B _daybook-link._tcp local.`), the local-network prompt, and pairing a real
  iPhone; Bluetooth (the Soundcore); the microphone and AirPods routes; real calls with the ScreenCaptureKit fallback
  and meeting detection; live captions and Foundation Models; Continuity Camera.
- Open and save panels, drops, and paste in the sandbox: Move Library… (the panel's grant, the verified copy, and
  Move to Trash on the old copy), Export Here, the import panel and drops with a sidecar, Add Photo, the import
  folder chosen again, the previous sync folder's Choose Folder Again….
- A signed sandboxed build: the first launch on the real library (prerelease only, after a backup), the sync
  identity's and the link keys' keychain items across the move, iCloud Drive, CloudKit and the courier, CloudKit's
  account status, notarization and `spctl`.
- Going back: an unsandboxed release finding the container's library and moving it back (and whether macOS asks
  about reading another app's data for a container of the same app and team).

## Cross-stream follow-ups (2026-10-26)

Regression tests now cover:

- **A recorder handed over mid-recording, its Mac out of reach** (`RecorderHandoffTests`, against
  `SimulatedSoundcore`): handed to the phone while the Mac's recording had it record too, it stops
  once the Mac's presence no longer names the conversation, with the link gone, and its recording is
  imported; or once the conversation arrives through sync with its link to the recorder ended. A
  recording the recorder was making already, and one the person started on it since, are left alone,
  and a Mac whose presence goes stale is given up on. The release and the synced record carry the new
  optional `stopsWithConversation`; older messages and records decode without it.
- **Owed stops across relaunches**: the Mac's stop owed to a phone that's away is sent when the phone
  reconnects to the relaunched Mac (`PhoneLinkTests`), the iPhone's to a Mac after the app relaunches
  (`LinkServicesTests`); each is kept a day (`OwedStopsTests`).
- **A phone's notes from before the Mac joined** keep their times in the phone's recording, before
  the timeline's zero, through placement, editing, and a merge (`MultiSourceTests`, `TimedNotesTests`,
  `PhoneLinkTests`).
- **iPhone filing**: filing and imports flush only their own conversation, so another that can't be
  saved doesn't stop them, and an import cancelled while it waits for the library stops waiting and
  imports nothing (`PhoneLibraryTests`).
- **Fields a newer Daybook adds**: kept through edits made here in conversations, their recordings,
  bookmarks, summary, sections, action items, and photos, and in each library setting, merged key by
  key (deterministic, commutative, idempotent) and through a sync pass (`UnknownFieldsTests`,
  `LibrarySyncCompatibilityTests`, `LibraryControllerTests`).
- **Shared capture code**: the level measure and the format converter both apps use
  (`AudioBuffersTests`, with the Mac's and iPhone's capture suites unchanged).
- **A stop by a stale list**: a recorder's owner stopping a named recording waits for its list read
  again, and never pauses the person's own recording on an older one (`MultipointRecordingTests`).
- The sync and multipoint tests wait and name their preferences through `DaybookTestSupport`.

Verification on Apple silicon with Xcode 27.1: `swift test` passed 917 XCTest cases across all seven
bundles; `scripts/build-ios.sh --test` on a dedicated iPhone Duo simulator (iOS 27.1, run serially)
passed 138 tests. No Bluetooth, recording, network beyond loopback, or model downloads.

Still requires real devices:

- **Stopping a handed-over recorder out of reach.** Record on the Mac with a Soundcore Work
  recording along, use it on the iPhone, take the iPhone off the Mac's Wi‑Fi, and stop the Mac: the
  iPhone pauses the recorder once iCloud Drive brings the Mac's presence (note how long, with the app
  in front and in the background), and the recording joins the Mac's conversation.
- **Owed stops after a real relaunch**: quit Daybook on the Mac while the phone is away, then bring
  the phone back; force-quit the iPhone app with a stop owed to a Mac, then reopen it near the Mac.
- **Notes before zero on screen**: a phone-led conversation the Mac joined late shows the phone's
  early notes with negative times (−0:42) on the Mac's Transcript page, in Floating Notes, on the
  iPhone, and in exports.

## Finishing the 0.3.0 review (2026-10-26)

Start Over for an encrypted library whose key is lost, an iPhone that seals history only on Wi‑Fi, iPhone backups of an
encrypted library, times before the start in VoiceOver, and a copy sweep of the code written after the copy pass
(docs/icloud-sync.md, "Starting over" and "The sealer"; docs/iphone.md, "Backups"; docs/copy-pass-2026-10.md).

- `swift build --build-tests`: no new warnings. `swift test`: 1035 tests, 0 failures, one skipped (the 1 GiB
  benchmark): DaybookCoreTests 330, DaybookTests 256, DaybookKitTests 164, DaybookDevicesTests 120,
  DaybookIntelligenceTests 87, DaybookLinkTests 70, DaybookCaptionsTests 8.
- `scripts/ci/tests/run-tests.sh --require-all`: 294 passed, 0 failed, 0 skipped.
- `scripts/build-ios.sh --test` on a new iPhone Duo simulator (iOS 27.1), serial: 151 tests passed. The simulator was
  deleted afterwards.
- Regression tests:
  - `LibrarySyncStartOverTests`: two replicas losing the key, then starting over and republishing; refusals while a
    key is available; two devices starting over at once; unrelated libraries still pausing.
  - `LibrarySyncEncryptionTests.testStartingOverWhenTheKeyIsLostOnEveryDevice`, through the controller.
  - `LibrarySyncSealingTests.testAPhoneSealingHistoryDownloadsRecordingsOnlyOnWiFiInBatches` and
    `testADeviceRemembersSyncingAnEncryptedLibraryBeforeAnyPass`.
  - `BackupExclusionTests.testAnEncryptedLibraryKeepsItsConversationsOutUnlessIncluded`.
  - `TimeWordsTests`, `LibraryWordsTests` (the encryption status and the network condition), `ProblemWordsTests`,
    `PlainWordsTests`, `FloatingNotesStatusTests`, and `ModelManagerTests`.

Still requires the owner's devices: Start Over (above, in "Library encryption"); an iPhone that turned encryption on
sealing its history on cellular, then on Wi‑Fi ("Waiting for Wi‑Fi", then a few recordings at a time); and an iPhone
backup of an encrypted library leaving out `Meetings/` (Settings › General › iPhone Storage › Daybook, or a Finder
backup's size).

## Library encryption (2026-10-26)

End-to-end encryption of the sync journal (docs/icloud-sync.md, "Encryption"). In 0.4.0 it was dark by default: Settings
offered Encrypt Library in iCloud. From 0.4.1 it turns on by itself (below, "Automatic encryption"), at the owner's
request, before the device checks below have run.

- The format is frozen by known-answer vectors computed by an independent implementation of the specification (pure
  Python AES-256, GCM, HMAC, and HKDF, itself checked against FIPS-197 and the GCM specification's test case), not by the
  Swift code (`SealedObjectTests.testKnownAnswerVectorsFreezeTheFormat`).
- Compatibility: the frozen version 1 engine (`LegacyLibrarySyncFixture`) refuses an encrypted library with
  `unsupportedVersion(2)` and leaves every byte of the sync folder as it was; a plaintext library's manifest, events,
  and objects are written as before (`LibrarySyncSealingTests`); every existing sync test passes unchanged.
- `swift test`: 944 tests passed across all seven bundles (`DaybookCoreTests` 309, one skipped: the 1 GiB benchmark;
  `DaybookKitTests` 143; `DaybookLinkTests` 69). `scripts/ci/tests/run-tests.sh`: 251 passed. An unsigned iPhone
  archive (`scripts/build-ios.sh --archive --no-sign`) passes `scripts/ci/check-ios-archive.sh`, which now also checks a
  signed archive's keychain groups. `scripts/build-ios.sh --test` on an iOS 27.1 simulator: 136 tests passed.
- An independent review of the engine found plaintext that could reach an encrypted container (a chosen folder moved
  before the container's manifest downloaded, presence written before the first pass, a courier delivery promoted after
  a day), a rotation that could leave late files unreadable, deletions and newer-format entries that could hold a
  conversation forever after retirement, and a crafted length that could crash; each is fixed with a regression test.
- Performance, `DAYBOOK_SEALED_PERFORMANCE=1 swift test --filter SealedObjectTests`, a 1 GiB original on this Mac
  (Apple silicon, debug build, quiet runs): copy and SHA-256 (today's upload, an APFS clone) 0.41 to 0.45 s; seal 0.39 to
  0.48 s (0.88 to 1.10 times); open 0.40 to 0.48 s (0.90 to 1.11 times); at most 6.8 MiB more memory sealing and 3.2 MiB
  opening. Budget: 1.5 times, 8 MiB. Hashing a file now drains each read, so a long recording's SHA-256 no longer holds the
  whole file in memory until the pass ends.

Still requires the owner's devices, before turning it on for anyone:

- **Shared keychain group.** `codesign -d --entitlements - --xml /Applications/Daybook.app | plutil -p -` lists
  `keychain-access-groups` = `48H7CLBV8Y.local.daybook.app`, `48H7CLBV8Y.local.daybook.shared` on the Developer ID build;
  `scripts/ci/check-ios-archive.sh` passes on a signed TestFlight archive (it checks the iPhone's groups and their order).
  Existing pairings and the sync device ID still work after updating (the default group didn't move).
- **The key through iCloud Keychain.** Turn encryption on on the Mac with a few conversations. How long until the iPhone
  (TestFlight) leaves "Waiting for this library’s key." without a recovery key or the link? Repeat with the iPhone
  turning it on.
- **iCloud Keychain off** on the iPhone: it waits; Get Key from <Mac> over the link opens the library and the Mac says it
  sent it; turning iCloud Keychain back on changes nothing.
- **No keychain prompts** on the Mac, at launch, on a pass, or when the key arrives.
- **Locked iPhone.** Lock it and let a background refresh run (or simulate the `local.daybook.phone.sync` task in the
  debugger): the pass reads the key (`kSecAttrAccessibleAfterFirstUnlock`) and syncs.
- **Recovery key.** Delete the key from one device's Passwords app (or reset iCloud Keychain on a test account): it waits;
  Enter Recovery Key opens the library. A wrong key says it doesn't match.
- **Start Over.** On a test account, turn encryption on without a recovery key, then delete the key from every device's
  Passwords app (or reset iCloud Keychain): once each device has synced, both show Start Over…, never while one still
  holds the key. Start Over on the Mac: the iPhone gets the new key from iCloud Keychain, both devices' conversations
  appear on both, and the container settles back to about the library's size (the old library's `Sealed/` files are
  deleted). Press it on both at once (airplane mode, then reconnect): both end in one library, nothing is listed twice.
- **Accounts.** Sign the iPhone out of iCloud and into another account with a plaintext library: after Sync with This
  Account it syncs that library, without "The library in iCloud is no longer encrypted."
- **Large recordings.** Seal (upload) and open (install on a second Mac, fetch on the iPhone) 2 to 4 GB recordings: time,
  memory, and the iPhone's thermals.
- **The courier in Production.** Record on the iPhone with the Mac open: CloudKit Console › Production › Private Database
  shows the `SealedCourier` zone with `CourierFile` records (no schema change: the same record type), gone once the Mac has
  stored them. Nothing new appears in the `Courier` zone.
- **Retirement.** A week after turning it on, with another device holding the key or a recovery key saved, the container's
  `Events/`, `Metadata/`, and `Blobs/` are empty on every Mac (`~/Library/Mobile Documents/iCloud~local~daybook/
  Documents/Daybook`), and the iPhone still plays everything. Restore a deleted plaintext file from iCloud.com › Data
  Recovery: the next pass on the migrator seals it if it's live and deletes it.
- **An earlier Daybook.** Daybook 0.3.0 on a second Mac says "This library was synced by a newer Daybook (version 2).
  Update Daybook to sync." and writes nothing but its presence record (whose plaintext name the migrator deletes and it
  writes again: a known limitation).
- **Erase Deleted Conversations from iCloud.** After every device has synced once, a week later the deleted conversation's
  audio is gone from the container and the live ones still play everywhere.
- **Backups.** Whether the synchronizable key appears in an iPhone backup and comes back on restore.
- **Export compliance.** The owner re-confirms the exempt answer (docs/release.md, "Export compliance").

## Security review fixes (2026-10-25)

Regression tests cover: a pairing refusal believed only before the first commitment, a Mac
impersonator that refuses after a reveal burning the code (across a relaunch, as salted digests that
expire), and an early `busy` leaving it usable; which addresses the link listener treats as local,
and that it drops others before pairing; moving Mac link keys into the data-protection keychain,
falling back, retrying an interrupted move, and keeping the newer pairing; model links dropped in
the app and Markdown escaped in exports and Copy Summary; Floating Notes kept out of screen capture;
model files without a checksum refused; copies kept off Universal Clipboard on both apps; exported
and shared photos without GPS, maker notes, camera details, or original names, originals untouched;
inbox copies removed after import and kept on failure, shared exports cleared; backup exclusion and
the library setting; and a newly paired Mac refused until allowed, with earlier pairings unaffected.

- `swift test`: 728 tests passed across all seven bundles (`DaybookLinkTests` 66).
- `scripts/build-ios.sh --test` on an iOS 27.1 simulator: 95 tests passed.

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
- **iPhone backups.** With a few recordings and some downloaded audio, Settings › [your name] ›
  iCloud › Manage Storage › Backups lists Daybook at the library's size without the downloaded
  audio; with Include in iPhone Backups off, near zero. Restoring a backup made with it on brings
  back the library, and played audio downloads again.
- **Mac permission to record on the iPhone.** Pair a new Mac: the iPhone asks "Let <Mac> start
  recording on this iPhone?". After Not Now, a recording the Mac starts with the phone shows the
  phone's refusal on the Mac; turning on Can Start Recording in that Mac's row lets the next one
  start. A Mac paired before the update keeps starting recordings without being asked.
- **Recording while locked.** Record, lock the phone, take a call (an interruption) and return
  to recording, then Stop from the Live Activity while still locked: the recording is filed with
  both segments joined and its captions kept, before unlocking. This is why staging stays at
  `completeUntilFirstUserAuthentication` (docs/iphone.md, "File protection"); repeat it before
  changing any recording file's protection class.
- **Mac keychain move.** With a signed build of the previous version paired to a phone, install the
  new build: the pairing keeps connecting with no keychain prompt, and Keychain Access no longer
  lists a "Daybook link" item in the login keychain. An ad hoc build keeps using the login keychain.

## Hardware review fixes: Soundcore, handoff, and the iPhone's Lock Screen (2026-10-25)

Fixes from the review of recorder sessions, the recorder handoff, and the iPhone's Live Activity,
widgets, and control, each with a regression test against `SimulatedSoundcore` (now with firmware
variants that list the active file and keep a paused recording open, a button press, and a skewed
clock) or the state and timeline logic:

- Automatic import waits for a listing made on this connection, and a recording the recorder names
  as active is in progress whether or not it says it's recording; the snapshot keeps it.
- A recording seen before the link went shows "Recording · as of 10:07 AM" for 20 minutes, then
  unknown. The button's stop lists the recorder again. Recordings are dated by the recorder's
  measured clock. Staged audio a killed import left is removed at launch.
- The recording's identity is checked again right before ingest (session, Mac, iPhone), so an import
  arriving through sync mid-transfer isn't duplicated. Library links are rebuilt only when a device's
  own tracks change. One start-date helper replaces three.
- A handoff mid-recording carries the recording and the conversation waiting for it.
- iPhone: background app refresh re-arms automatic import; the recording's Live Activity, widgets,
  and control turn "Not confirmed" when the app stops confirming, every launch path clears leftovers,
  paused clocks freeze, titles are private on the Lock Screen, the Live Activity's buttons keep
  4.5:1, "1 bookmark"; Soundcore recordings started on the iPhone and Listen Live get a Live Activity.

Verification on Apple silicon with Xcode 27.1: `swift test` passed 713 XCTest cases across all seven
bundles; `scripts/build-ios.sh --test --simulator <iPhone 17 Pro, iOS 27.0>` passed 97 tests. (iOS 27.1
offers only the iPhone Duo simulator, so a dedicated iPhone 17 Pro on iOS 27.0 was used.) No Bluetooth,
recording, network, or model downloads.

**Still to check with a physical Soundcore Work:** whether firmware lists the recording in progress
among the list's entries or only after them, and whether Pause keeps it open (both are handled;
which one is real decides when a paused recording imports); whether the button reports `18 82`
unasked on start and stop; how far real recorder clocks are off (and whether any firmware keeps
local time rather than UTC), and that the measured offset is within two seconds when in step; that
iOS background app refresh actually wakes the app often enough to reach the recorder after the
15-minute wait (it's only scheduled while sync is connected); and a handoff during a real
multipoint recording, ending with the recording in the Mac's conversation.

**Still to check on a real iPhone:** that `privacySensitive` titles are redacted on the locked Lock
Screen (widgets and both Live Activities) and shown once unlocked; that the Live Activity turns
"Not confirmed" about 90 seconds after the app is killed mid-recording, stays "Paused" through a
long call, and that the widget's second timeline entry fires; that the Control Center control turns
off after a crash; that the Live Activity buttons read well on the Lock Screen and in the Dynamic
Island in light and dark; and that a Soundcore Listen Live activity's Stop Listening runs with the
app in the background.

## Persistence, performance, and the model runtime (2026-10-26)

Regression tests now cover:

- Saving: a burst of note edits is one write and one published change per keystroke; saves happen
  without a flush shortly after an edit; a failed save is retried at the next flush, ends when its
  conversation goes to the Trash (or is trashed behind the library's back), and doesn't stop an
  import into another conversation; flush waits for saves queued while it waited.
- The store: unchanged files aren't read back to save; another writer's change is read once and its
  recordings kept; an unchanged snapshot writes nothing; the recovery copy is the previous snapshot;
  files are compact and earlier pretty-printed ones read; a sparse 2 GB import doesn't hold up other
  saves and stops when cancelled.
- Opening: damaged, newer-schema, unreadable (permissions), and partly undecodable `library.json`,
  and an interrupted conversation that can't be re-saved at launch.
- The barrier records every file and folder an import, a save, or a Trash move wrote; durable writes
  leave a complete user-only file.
- CryptoKit digests equal the earlier SHA-256 across block, padding, and chunk boundaries.
- Models: released after the idle delay, kept between back-to-back jobs, released on memory pressure
  (after a running job), system models kept; a revision being loaded isn't garbage-collected.
- Photos: one unreadable photo is a failure of its own (real Vision, garbage bytes), waits with
  backoff, isn't re-read by sync passes, and is retried alone; a failed caption model is recorded.
- Redraws: progress throttled to the interval with the latest value delivered, the window redrawn only
  on a new percent or message, search and the visible list worked out once per change.
- Reading: the playhead and bookmark lookups equal the scans they replaced on 200 random
  transcripts; the layout is built once per version; the Mac plays the transcribed copy.
- iPhone: an import whose file another coordinator holds keeps the main actor running; a journal that
  can't be written is reported once while recording continues.

Not established by these tests: that `F_FULLFSYNC` survives a real power loss (that needs pulling
power on a test Mac mid-import), how a real memory-pressure event (`sudo memory_pressure -l warn`)
interacts with an MLX model in use, frame times on a multi-hour transcript (profile with Instruments
while playing), and File Provider waits for an iCloud Drive file not yet downloaded on an iPhone.

## Test reliability (2026-10-26)

A testing review of 19803b4 ran the test bundles at background priority beside 24 background-priority
busy loops on an 18-core Mac and found timing assertions that fail on a starved machine, waits that
gave up silently, and checks that vanished on CI. Fixed:

- **One way to wait.** `Tests/DaybookTestSupport` (package) and `DaybookPhoneTests/TestSupport.swift`
  (iPhone): `waitUntil`/`waitFor` always fail on timeout by throwing, naming what they waited for,
  the call site, and the last state seen. Every timeout is multiplied by `DAYBOOK_TEST_TIMEOUT_SCALE`
  (default 1); `xcodebuild` passes it to the iPhone runner as `TEST_RUNNER_DAYBOOK_TEST_TIMEOUT_SCALE`.
  The link tests' loopback timeouts (heartbeat, handshake, request, pairing) stretch with it too.
- **Test preferences.** `makeTestDefaults()` names each suite by a path in a per-bundle temporary
  folder, removed when the bundle ends. Removing a named suite still left its emptied plist in
  ~/Library/Preferences (the preferences daemon writes it again seconds later); this Mac had about
  13,000 of them.
- **Bounds from what was measured.** Link clock estimates are checked against the NTP bound: off by
  (up − down) / 2, give or take half of the round trip beyond the relay's delays. The heartbeat
  timeout is measured from the relay's last delivery to each side, and the phone can't reconnect
  until both sides have timed out. Recorder handoff: only the first transfer is long and paced, no
  speed assertions, patience checked at a given moment, and every sync pass must be acknowledged.
  The simulated disconnect is disarmed once its transfer starts. Model removal and request queue
  tests wait for their own outcome instead of giving up silently or trusting an idle queue.
- **Nothing vanishes on CI.** Text recognition checks skip (reported as skipped) where Vision can't
  read text; what makes a photo informative is checked everywhere with readings that include text.
  Caption availability is read through question-only answers the test supplies (so it can't
  download), and this machine's real answer is skipped without a transcriber and bounded to 10 s.
- **New coverage.** Files written by v0.1.0-preview and v0.2.2 (`Tests/DaybookTests/Fixtures/Shipped`,
  `DaybookPhoneTests/Fixtures`, generated by each tag's own code; their READMEs say how) decode and
  round-trip with today's code. Mac recordings without capture-result.json: two tracks, a missing or
  damaged sidecar, a never-closed CAF, and opening the library again after a crash before cleanup or
  between tracks. iPhone recovery from an orphaned segment, a torn last fragment, and a crash after
  an interruption. EXIF times without an offset, in fixed time zones.

Verification:

- `swift test`: 714 XCTest cases passed across the seven bundles (699 before), none skipped on this Mac.
- `scripts/build-ios.sh --test --test-arg -parallel-testing-enabled --test-arg NO` on an iPhone 18 Pro
  simulator (iOS 27.0; the iOS 27.1 runtime only offers iPhone Duo): 92 passed (86 before). The changed
  iPhone classes then passed 5 iterations each.
- Starved runs, as the review ran them: each `.xctest` bundle copied aside and run with
  `taskpolicy -c background xcrun xctest -XCTest <tests>` beside 24 `taskpolicy -c background` busy
  loops, while other work kept the Mac busy. Recorder handoff and ownership suites: 10 of 10
  (the transfer test 16–25 s, against 31–33 s and a timeout before). The Soundcore disconnect test:
  20 of 20. The link clock and heartbeat tests, on the final code: 20 of 20 unscaled and 18 of 20 with
  `DAYBOOK_TEST_TIMEOUT_SCALE=3`. Across 140 starved runs of them while fixing, no clock bound failed
  (the review saw 2 of 4 fail); the heartbeat bound failed once, from bytes the relay delivered after
  the freeze, which it now drops. The other failures were connections that took longer than the
  unscaled 5 s to set up, and a healthy connection whose process went unserviced past its heartbeat
  timeout (1.2 s, or 3.6 s scaled), which is a real timeout on so starved a machine.

Still open, for the streams that own the code: the sync, multipoint, and courier suites keep their
own waits and leak preference suites (they can adopt the helpers); `MultiSourceRig.processed()` is
satisfied before queued work starts; the sync debounce is a fixed 2 s that `SyncReviewTests` sleeps
through.

## Sync engine review fixes (2026-10-26)

The sync stream fixed the review's sync findings (docs/icloud-sync.md describes the behaviour). Regression
tests, all on temporary libraries and folders with synthetic data, now cover: two creations of one
conversation keeping what either set; criss-cross histories (tag, bookmark, photo removal, a revert, three
devices); a held conversation publishing an edit once; a remote deletion while a device records into the
conversation, the automatic-trash race, and audio installed before a deletion; restoring a synced deletion
as a new conversation; unknown enum values, extra fields, newer-schema events and settings; upgrading in
place from the version 1 engine with an unacknowledged pass and a half-read journal; a crash between
writing an entry and saving the checkpoint; bounded memory and per-conversation base files; a fresh device
waiting for iCloud's listing and two manifests resolving to one library; a courier delivery whose
iCloud Drive copy never arrives; status kept as synced; edits during a pass on the Mac and the iPhone, and
pull to refresh joining a pass; an account change during a long pass; claims under clock skew and latency;
the device identity moving to the keychain, copied preferences, and two devices sharing an ID; recording
activity in presence and settings-only passes while recording; and random histories across an eager Mac,
an on-demand iPhone, and the version 1 engine from fixed seeds.

Verified on Apple silicon with Xcode 27.1:

- `swift test`: 747 XCTest cases passed across all seven test bundles.
- `scripts/build-ios.sh --test --simulator <a new iPhone 17 Pro, iOS 27.0>`: 87 tests passed. (The iOS 27.1
  runtime on this machine accepts only the iPhone Duo device type, so the new simulator used iOS 27.0.)

Not exercised, needing signed builds and real accounts:

- The data-protection keychain item for the device identity on signed Mac and iPhone builds (unsigned
  `swift test` has no such keychain, so preferences are used), and Migration Assistant or a backup restore
  producing a Mac that takes a new identity. Also the identity following the library into the App Sandbox's
  container and back (`Sync/replica.json`, docs/sandbox.md) with the real keychain.
- `NSMetadataQuery`'s first gather on a fresh device against a container that already holds a library,
  and `NSFileVersion` conflict versions of `daybook-sync.json` from two devices creating a library at once
  (renamed copies are tested; conflict versions can't be produced on a local volume).
- A courier delivery promoted into iCloud Drive after a day, observed from a second Mac or a new iPhone.
- Presence activity seen by the iPhone during a long Mac recording, and a handoff answered during one.

## Multipoint review fixes (2026-10-26)

Recording with an iPhone and with recorders, and the link's recording messages ([multipoint.md](multipoint.md),
[link.md](link.md)). Temporary libraries and sync folders, synthetic audio, fake recorders, and
DaybookLink over loopback with keys in memory; no Bluetooth, microphone, network beyond 127.0.0.1, or
model. The test doubles now behave like the apps: the Mac's test phone files into the shared
conversation as the phone does, and the phone's test Mac records the conversation it's asked to and
makes it on the phone as sync would.

- `swift test`: 729 XCTest cases passed across all seven bundles, 30 of them new: `PhoneLinkTests`
  (27: phone-led and Mac-led filing with notes held until placed and no placeholder fields, one
  bookmark after sync, the device page's start, the timeline's zero for a conversation recorded into
  again, the Mac's state and recorders reaching the phone, a slow or missing start answer, stopping
  before the phone answers, a refused, dropped, or undelivered stop sent again on reconnecting, a
  Mac following the phone that led, sleep holding briefly for the stop, a recovered recording closing
  its links, the clock prior from the phone's own start and stored clock, a linked phone recording
  staying put, a lone one setting its timeline, a paused phone recording, and a Soundcore recording
  the phone imported joining by its link), `MultipointRecordingTests` and `RecorderOwnerTests` (16:
  an already-recording recorder found only once its list arrives, a recording the person started
  since left alone at Stop, the late start, an unreachable or unconfirming recorder reported quietly
  with its recording still joining, and recorders driven through the phone that manages them),
  `MultiSourceTests` (another device's notes added once, held, and moved), and `LinkSessionTests` (a
  request repeated on a new connection while still being answered reaches the app once).
- `scripts/build-ios.sh --test` on an iPhone 17 Pro simulator (iOS 27.0; no device type pairs with
  the 27.1 runtime here): 106 tests passed, 20 of them new: `LinkServicesTests` (16), `PhoneLibraryTests`
  (15), `PhoneRecorderTests` (a recovered recording ends where its audio does), and
  `StatusSheetModelTests` (a recorder another device manages, with its age).

**Still to check with real devices:** that a stop sent while the power notification holds sleep
back (up to 5 s) reaches the phone before the Wi‑Fi goes; the phone's 15 s state over a Lock Screen
recording's slow heartbeats; a real microphone prompt on the Mac or phone outlasting the request,
answered once; the phone starting and stopping a Soundcore Work it manages for a Mac (start
confirmation and Pause timing over Bluetooth, and the finished recording importing into the Mac's
conversation); a recorder handed over mid-recording and stopped through its new owner; a recorder's
list arriving after connecting on real hardware (within the 5 s waited for); the clock stored on the
phone's track against the link's on real Wi‑Fi; and quitting with a phone out of reach (its stop is
dropped, and it follows the Mac's idle state on reconnecting).

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

`Daybook --evaluate <folder>` runs the speech pipeline as processing does (language routing, transcription, speaker detection, voice profiles, and fusion) over recordings that have references, and scores them. It never records, never touches a library, and downloads only with `--download-models`. Models come from the running build's library unless `--models` names a folder: for `swift run`, that's `~/Library/Application Support/Daybook Development/Models`, never the app's.

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

### Live transcription from local models

Run on 2026-10-29 on an M5 Pro with 64 GB, macOS 27.0 (docs/model-runtime.md, "Live"; docs/models.md, "Live models").

**Automated, no model running.** `DaybookLiveTests` (30): passages from streaming pieces (sentence ends, pauses judged up to what was decoded, the length limit, control tokens, stable IDs); speaker runs, solo stretches, the dominant voice, and runs that never stretch across a gap in the audio; naming (thresholds, margin, one person per voice, spaces that never mix); the library's voice profiles as known voices (deleted profiles, other spaces, and unusable voiceprints left out); the audio ring; the local captioner on the capture's timeline across a 10 s gap, a recognizer that can't load (only the captions end), and Critical heat (audio let go); speakers and names added to another captioner's words, words going on unlabelled without a speaker model, and speakers shed in Low Power Mode; the iPhone's and the Mac's load policies and the backlog's hysteresis; the catalog's iPhone defaults (streaming, phone-sized, commercial-use licenses with attribution, the Mac's embedding space), live models kept out of presets and processing, stored choices and defaults, per-platform choices and their round trip, the memory guard, install checks per role, and the language choosing between installed recognizers. `LiveTranscriptionTests` (4, Mac): a new Mac's live choices, an existing Mac gaining them once, the Settings roles, and caption turns by voice with names. `PhoneModelsTests` (4, iPhone simulator): the iPhone's defaults (711.9 MB for all three), a 4 GB phone not offered the recognizer, downloads waiting for Wi‑Fi and starting on cellular only when allowed, and captions staying the system's without downloads. Updated: the catalog and registry inventories, and acknowledgements.

**Real models, once, in scratch.** The three iPhone defaults were downloaded through `ModelStore` with `HubSnapshotFetcher` into a scratch folder, every file checked against the catalog's digests (Nemotron 3.5 Streaming Latin 19.4 s, Nemotron 3 Live 6.6 s, Community-1 13.6 s), run by a scratch command-line harness through `LiveCaptioners` exactly as the apps compose them, and deleted afterwards. The input was a 25-second two-voice conversation from macOS voices (Samantha and Daniel, four turns), fed in 100 ms buffers at real time, and a separate 12-second Samantha utterance embedded as her known voice.

- Words: all four turns transcribed, punctuated and capitalized; one error ("after launch" for "after lunch").
- Speakers: every passage labelled with the right voice (S1 Samantha, S2 Daniel), and Samantha named from her separate utterance; Daniel, with no profile, stayed unnamed.
- Latency: a passage's last words appeared a median 0.19 s (at most 0.99 s) after they were spoken, measured against the audio clock; speaker labels follow the model's 2.88 s latency by design.
- Load: 43.9 s the first time (the Neural Engine compiling the models for this Mac), 0.1–0.2 s afterwards.
- Cost: 0.4–0.5 s of CPU for 25 s of audio (2% of one core; the Neural Engine does the work); peak process footprint 63–72 MB over two runs. The weights are memory-mapped from their files and the Neural Engine's own memory isn't counted in the footprint.
- A second real-time run on the final code gave the same words, speakers, and name.
- Fed all at once instead (a 25 s burst into a 256-buffer queue), the backlog governor shed speakers until it drained, as designed: the words were the same and early passages went unlabelled.

These are synthetic voices on a fast Mac: they show the pipeline works with the real models and what it costs here, not accuracy on meetings or an iPhone's speed. Floating Notes and the conversation page were snapshotted with `--simulate-recording … --demo-captions`, whose Call lines now carry a named and an unnamed voice; the iPhone's Settings › Models was screenshotted on a simulator. The iPhone app built for a device (unsigned Release): 44.8 MB against main's 27.1 MB, most of it FluidAudio.

Still to check on hardware:

- An iPhone (A17 Pro or later, and an 8 GB phone without Pro): first and later load times, real-time factor, battery drain over an hour's recording with the screen on and in a pocket, heat, and memory headroom (jetsam) with the camera and Live Activity running. The Neural Engine compile on first load may take minutes on a phone; captions show "Getting captions ready…" meanwhile.
- A 6 GB iPhone (the recognizer's suggested minimum) and a 4 GB one (offered speakers only).
- Downloads on a phone: Wi‑Fi to cellular mid-download (it stops and waits), the app sent to the background mid-download, and Low Data Mode. (Since 2026-10-30 the downloads run in background sessions and resume partway; see the top of this record.)
- A Mac recording a real call with live models: You and Call each captioned, the shared models loaded once, echo removal with live models' timing, and an hour without the recording dropping buffers. macOS 15 with live models (no Speech framework): captions, and Settings › General › Live Captions enabled.
- Real voices: whether live names match the Mac's profiles at the 0.82 threshold across microphones (a laptop's microphone against a phone's or a recorder's), how often two people's voices share a slot or one voice splits, and the multilingual model on Japanese and German.
- Soundcore Listen Live through live models on both devices.

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

## Design, copy, and accessibility sweep (2026-10-26)

Run on Apple silicon with Xcode 27.1, against fakes and synthetic audio only: no microphone, network, Bluetooth, or real library.

- `swift test`: 902 XCTest cases passed, none failed. New: `ProblemWordsTests` (the Mac's alert titles, plain sentences, and Details), `LibraryWordsTests` (the folder sentence and the photo VoiceOver label both apps share), `LibraryPlaceTests.testNewNoteIsTitledAsOnTheIPhoneAndSelected`, and `WindowInvalidationTests` rewritten for progress that redraws only what follows it and an AppState that forwards only the library and the device list.
- `scripts/build-ios.sh --test --test-arg -parallel-testing-enabled --test-arg NO` on a new iPhone Duo simulator (iOS 27.1): 145 passed. New: `PlainWordsTests` (notices with Details and fixes, the recorder's journal warning while recording), recording into a New Note (`PhoneLibraryTests`), the status sheet's plain Mac failures and its Recording line (`StatusSheetModelTests`), `MacPresence.recording` (`SyncServicesTests`), and Open Settings for iCloud (`ShellTests`).
- Mac `--snapshot` captures: the processing demo (list row, page status line, and Floating Notes chip all at 40 % through `ActivityReader`), Settings › General ("Record calls automatically"), and Settings › Models with a download at 40 %.
- iPhone simulator captures: table mode writing in flex mode (`--write-notes`: Bookmark and Done beside the clock), the notebook while recording, Settings and Pair with Your Mac on the cover display, the empty notebook library (the right page shows only the mark), and a New Note's "No recording yet" with Record on both the spread and one column.

Not verified here:

- The table-mode keyboard itself: the capture shows the writing state before the notes field takes focus (the simulator can't tap), so that the keyboard leaves the header's Bookmark and Done uncovered follows from the layout (they're on the standing half, the keyboard covers the flat one) rather than a capture.
- VoiceOver on a device: the pairing code field, the notes lane's "Note at …" labels, and the Mac transcript note's Show on Summary action were checked in code and by their accessibility modifiers, not with VoiceOver running.
- Open Settings lands on Daybook's page in Settings; iOS has no public link to iCloud's own settings, so signing in or turning on iCloud Drive is a step from there.

## Flow screenshot fixes (2026-10-27)

Six problems found while capturing the primary flows on Mac and iPhone. Run on Apple silicon with Xcode 27.1, against fakes and synthetic audio only.

- `swift test`: 1,039 passed, 1 skipped (the 1 GiB benchmark), none failed. New: `ModelManagerTests.testAModelWithTwoRolesIsListedOnceInItsPreset` (Quick listed Community-1 twice) and `LibrarySyncContainerTests.testTheAccountNotificationWithTheSameAccountLeavesSyncAsItWas`. Changed: the long-pass account test now turns iCloud off and on rather than posting the notification with nothing changed, `SyncReviewTests` checks a chosen folder stays through an unchanged account before it disconnects for a new one, and a cancelled pass keeps the status it had ("Connected · preparing sync"), not "Sync paused".
- `scripts/build-ios.sh --test` on a new iPhone Duo simulator (iOS 27.1): 151 passed. New: the status sheet's narrow recorder line ("80% · 2 new"; "Recording · 80%" while recording) in `StatusSheetModelTests`.
- iPhone 17 Pro simulator, `--library` and `--sync-folder` in fresh folders: the simulator posts `NSUbiquityIdentityDidChange` at launch. Before, the chosen folder disconnected ("Apple Account changed"), the iCloud row stayed at "Waiting to sync", and the Mac row at "Looking for it…"; with the fix, the first pass wrote the journal and the status sheet read "iCloud Up to date". The container path needs a signed build and wasn't run here; the same check covers it in `LibrarySyncContainerTests`.
- Mac `--snapshot` with `--phone-demo pairing --device-name "Studio Mac"`: Add iPhone names "Studio Mac", not the computer's name.
- iPhone Duo captures, open and closed: Pair with Your Mac as two pages when open (Macs on the left, the code above the number pad on the right, nothing across the crease; Pair stays in the bar as the code scrolls up), and one column closed with the code scrolled above the keyboard; flex-mode Write Notes with "RECORDING" on one line, the Mac as its glyph and red dot, and the clock, Bookmark, and Done whole (book, flex, and pocket unchanged); the library's rows no longer legible under Record and the status sheet; and the notebook panel's recorder line whole.

Not verified here:

- The iCloud container on a signed build and a real device: whether iOS posts the account notification at launch there too. Either way the account is compared before sync reacts.
- Typing the pairing code on the open Duo: the simulator can't tap, so the capture shows the code entry with the number pad up through a launch option.

## Automatic encryption (2026-10-28)

Library encryption turns on by itself (docs/icloud-sync.md, "Encryption"): a new library starts encrypted wherever the
device can keep a key, and an existing plaintext library encrypts itself after an acknowledged pass once every other
device that synced in the last 30 days reads encrypted libraries, with an iPhone leaving it to a Mac that's around. The
owner asked for it on before the device checks in "Library encryption" ran. Run on Apple silicon with Xcode 27.1, against
in-memory keychains and couriers and temporary folders standing in for iCloud.

- New: `LibrarySyncSealingTests.testANewLibraryStartsEncryptedWhenItsDeviceCanKeepTheKey` (key stored first, version 2
  manifest, nothing ever written in plaintext); `LibrarySyncEncryptionTests.testANewLibraryStartsEncrypted` (an iPhone
  sharing the keychain reads it), `testAPlaintextLibraryEncryptsItselfOnceEveryDeviceInUseCanReadIt` (an iPhone on
  0.3.0 seen yesterday holds it back; seen 31 days ago, it doesn't), and
  `testAnIPhoneLeavesAutomaticEncryptionToAMacThatsAround`.
- The engine and controller rigs that turn encryption on by hand start plaintext libraries
  (`SyncReplicaConfiguration.sealsNewLibrary`, `LibrarySyncController.encryptsAutomatically`).

Still requires the owner's devices, in addition to the "Library encryption" checks: the owner's existing library
encrypting itself once both the Mac and the iPhone run 0.4.1, the iPhone getting the key through iCloud Keychain, and
a device left on 0.3.0 or earlier, if any, saying to update (0.4.0 reads encrypted libraries).

## swift-transformers 1.3.5 (2026-10-28)

Dependabot's bump from 1.1.6 (#12). It moves `HubApi`'s downloads onto swift-huggingface's `HubClient` and brings
swift-huggingface 1.0.0, swift-crypto, swift-asn1, EventSource, and yyjson. Checked on Apple silicon against the
tokenizers installed on the owner's Mac (copies of their tokenizer and config files only) and one real download.

- **Tokenizers.** A 21 KB transcript in many scripts (curly quotes, accents, combining marks, Japanese voiced kana,
  CJK, Arabic, emoji with skin tones and ZWJ sequences) through both versions, offline as Daybook loads them:
  - Gemma 4 26B (`GemmaTokenizer`): 1.1.6 made 8,798 tokens and didn't round-trip the text; its chat template output
    had 16 literal `▁` where spaces belonged (`combining▁é`). 1.3.5 made 7,557 tokens, round-tripped exactly, and
    rendered the template with plain spaces. Encoding took 0.62 s on 1.1.6 and 0.02 s on 1.3.5.
  - Qwen 2.5 1.5B and 7B: identical token IDs and round trips. The chat template differs only after the generation
    prompt: 1.1.6 added a second newline after `<|im_start|>assistant`; 1.3.5 renders `trim_blocks` as Hugging Face
    does. Encoding is 2.3 times faster.
  - Whisper base: identical token IDs (WhisperKit reads its tokenizer through argmax's vendored code either way).
- **Downloads.** `HubSnapshotFetcher`'s exact call (empty token, `cache: nil`, literal globs) fetched
  `openai_whisper-base/config.json` and the 104 MB `TextDecoder.mlmodelc/weights/weight.bin` from
  `argmaxinc/whisperkit-coreml` at Daybook's pinned commit: only those two files arrived, the weights' SHA-256
  matched the catalog's, both matched the installed copies byte for byte, and nothing was written to
  `~/.cache/huggingface`. With the default cache, every file would also be kept there.
- **Resuming.** `HubClient` downloads each file with a URLSession download task, so a file cut off partway (the app
  quit mid-shard) starts again; files that finished are kept, as before. 1.1.6 resumed the file itself.
- The app links the new packages' licenses and NOTICE files (swift-crypto and swift-asn1 carry NOTICE.txt) in
  `Contents/Resources/Licenses`, and `THIRD_PARTY_NOTICES.md` lists them.

## One copy at a time on the Mac (2026-10-28)

Two copies of Daybook could run at once: the owner had 0.4.1 open from `/Applications` and from the mounted disk
image (`/Volumes/Daybook 0.4.1/Daybook.app`), and an ad hoc build (`local.daybook.app.adhoc`) or `swift run` could
join them. Each opened the library, synced, listened for the iPhone, held the recorder, and could record calls.

Now a copy that finds an earlier one (`local.daybook.app`, `local.daybook.app.…`, or the unbundled `Daybook`
binary), before it starts anything, brings that one forward and quits, with no alert. The earlier copy is the one
whose process started first by the kernel's clock (`SingleInstance.startTime`), then the lower process ID, so copies
started together agree. Debug builds launched with `--library` (screenshots, demos) are exempt unless they pass
`--single-instance`.

- `SingleInstanceTests`: which processes count (every Daybook build, not the iPhone app, the sandbox probe, or
  others), the earliest wins, simultaneous starts, and the kernel's start time.
- With the debug binary and `--single-instance`: three launches beside a running copy each showed the check at once
  (when it asked, before it switched silently), and a launch beside a running copy then exited within a second
  without creating its library, leaving the first copy running.
- AppKit lists other apps, and the current one, only after `NSApplication.shared` exists: the check creates it first.
  Without that it saw none of the running copies.

Not verified here: that the earlier copy comes to the front (a system dialog held the screen during the check).
