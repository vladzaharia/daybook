# Multipoint recording and post-hoc sources

One conversation often has several recordings: this Mac's microphone and computer audio, a
recorder worn in the room, a file added the next day. Daybook keeps each original, lines them up
on one timeline, fuses their transcripts, and summarizes from all of them. This document covers
the orchestration: starting recorders with this Mac, finding the conversation a later recording
belongs to, and enhancing a conversation when a source is added. The sound alignment itself
(`AudioAligner`) and fusion (`TranscriptFusion`) are described in [architecture.md](architecture.md).

## Code

| Piece | What it does | Where |
| --- | --- | --- |
| Records | `SourceAlignment` (a recording's place on the timeline and how it was found), `CompanionRecording` (a recorder asked to record alongside this Mac), `SourceSuggestion` (a recording that may belong elsewhere) | [MultiSource.swift](../Sources/DaybookCore/MultiSource.swift) |
| Matching | Multipoint links, overlap in time, the decision after comparing sound, the transcript check | [SourceMatcher.swift](../Sources/DaybookCore/SourceMatcher.swift) |
| Fusion with placements | Applies stored placements (with drift), settles waiting recordings by transcript then clock, keeps named speakers on merged passages | [SourceFusion.swift](../Sources/DaybookCore/SourceFusion.swift) |
| Record control | Starts and stops recorders with this Mac; one status line. Devices that answer each command (Daybook on iPhone, `AnsweringRecordControl`) report the answer directly | `CompanionRecorders` in [MultiSourceCoordinator.swift](../Sources/Daybook/App/MultiSourceCoordinator.swift) |
| Daybook on iPhone | Record control both ways over the local link, the clock prior, and the phone's synced recordings joining conversations | [AppState+Phone.swift](../Sources/Daybook/App/AppState+Phone.swift), [PhoneLinkConnection.swift](../Sources/Daybook/App/PhoneLinkConnection.swift) |
| Orchestration | Arrival planning, attach and enhancement, the processing steps, suggestions, interface words | [AppState+Sources.swift](../Sources/Daybook/App/AppState+Sources.swift) |
| Interface hooks | Inspector › Audio rows, suggestion buttons, status lines (unstyled) | [SourceHooks.swift](../Sources/Daybook/UI/SourceHooks.swift) |

Everything new on `Meeting` and `RecordingTrack` is optional, so libraries written earlier decode
unchanged and fuse exactly as before (`testLibrariesWithoutMultipointDecodeAndFuseAsBefore`).

## The timeline

A conversation's timeline never moves once anything is timed on it. Notes and bookmarks made while
this Mac records are timed by its capture clock, so a conversation recorded on this Mac keeps this
Mac's recording as its origin, even when a recorder's file arrives first. A conversation that began
as a recorder's recording keeps that recording as its origin when this Mac later records into it.

Each recording's place is `timeline = offset + rate × recordingTime`. This Mac's own recordings keep
their capture offset, as before. Every other source added to a conversation gets a
`SourceAlignment`:

| Method | Found by | Confidence |
| --- | --- | --- |
| `audio` | `AudioAligner` against the conversation's best placed recording (this Mac's original microphone, then computer audio, then recorders, longest first), composed onto that recording's own placement | the aligner's |
| `transcript` | phrases both transcripts share (`TranscriptFusion`'s anchors) | from the number of anchors and their residual |
| `clock` | the recorders' clocks only; used only when the start is trustworthy (a recorder's own clock, a multipoint link) | 0.2 |
| `manual` | Adjust Timing | — |
| `pending` | not placed yet | — |
| `unaligned` | nothing placed it; its transcript stays separate, as before | — |

The order is always sound, then transcript, then clock. A recording placed only by the clocks (for
example a recorder file imported before this Mac's own recording was stored) is compared by sound
again once there is a placed recording to compare with. Recordings made on one clock (one Mac
recording's microphone and computer audio) share a `clockID` and move together when only one of
them can be lined up. A derived recording (the microphone with the call's echo removed) follows its
original's placement.

Drift: `TranscriptFusion` places a recording with a given offset at rate 1, so `SourceFusion`
scales a copy of that recording's segment times by the placement's rate first, leaving each
segment's provenance in the recording's own time. Corrections, which match by provenance, and
bookmarks on a recording (`alignedTime`) stay correct; the fused reports carry the rate.

## Multipoint recording

When this Mac starts recording (by hand or automatically), every configured recorder with record
control whose direct method is set up and on, and whose **Also record on <device> when this Mac
records** preference is on (the default), starts too:

1. A `CompanionRecording` link is stored on the conversation right away (`starting`).
2. Daybook connects if needed (giving up when the connection does, or after 20 s): out of range →
   `unavailable`, "Soundcore Work isn't nearby. Recording on this Mac only."
3. Already recording → `alreadyRecording`, with the recorder's start and recording ID. Daybook
   didn't start it, so it doesn't stop it.
4. Otherwise Start; the recorder must confirm within 15 s → `recording` with its recording ID and
   start, "Also recording on Soundcore Work." No confirmation → `failed`, "Soundcore Work didn't start
   recording. Recording on this Mac only."

When this Mac stops, recorders Daybook started get Pause (after their start finishes), must confirm
(`stopped` or `stopFailed`), and the finished recording is queued for import into this
conversation. A recorder that reported `failed` but turns out to be recording since Daybook's
command is stopped too. Only links made by this recording are acted on; a link an interrupted
session left behind never stops a recorder.

None of this can touch the Mac recording: it begins after capture started, runs in its own tasks,
never throws, and reports only through `CompanionRecorders.status` (one line) and the link's state.

The link makes the recorder's recording join this conversation however it arrives: the import
queued at stop, automatic import, an import the person starts later, or sync from another Mac
(links merge across Macs). The match is the recorder's recording ID; without one, its start within
5 s of the recorder's reported start; without that, a start within two minutes of this Mac's.

## Recordings that arrive later

A recorder recording imported without a chosen conversation, and a file imported by hand when
**Add imported files to conversations they overlap** is on (off by default), goes through
`planArrival`:

Matching, including the sound comparison, runs without holding the library's import lock, so a
long comparison never delays storing this Mac's own recording or another import.

1. **A multipoint link** claims it → it joins that conversation.
2. **Overlap in time** with conversations whose start is known (or the one being recorded now):
   at least 20 s and 30% of the shorter span.
   - none → its own conversation, as before;
   - two or more → its own conversation with a `severalConversations` suggestion;
   - one → compare the sound.
3. **The sound** against that conversation's best recording, with the clocks' offset as the prior
   (±120 s for a recorder's clock; ±15 min or the recording's length for a file's date):
   - confidence ≥ 0.6, agreeing with trustworthy clocks → it joins, already placed (`audio`);
   - ≥ 0.25 → its own conversation with a `lowConfidence` suggestion;
   - otherwise, or no verdict (today's `AudioAligner` stub) → its own conversation with a
     `checkingTranscript` suggestion.
4. **The transcript**, once both are transcribed: if the phrases line it up (`transcript`
   confidence ≥ 0.55), it moves into that conversation with its transcript and speakers, so nothing
   is transcribed twice, and its own conversation isn't summarized. Otherwise the suggestion stays
   for the person (`lowConfidence`).

A recording joins a conversation automatically only on a link, a confident sound match, or a
confirming transcript. Overlap in time alone is never proof (two meetings can happen at once).
Moving is a copy that brings the recording's transcript, speakers, and bookmarks. The recording's
own conversation then goes to the library's Trash, where it can be restored, unless the person has
worked in it (notes, corrections, renamed speakers, bookmarks with text, tags, a folder, a chosen
template or placement, completed next steps) or it holds other recordings, in which case it stays
and a notice says so.

Suggestions are state on the recording's own conversation (`Meeting.sourceSuggestions`); Inspector
› Audio offers **Add to "…"** for each candidate and **Keep Separate**
(`confirmSourceSuggestion`, `dismissSourceSuggestion`).

## Enhancement when a source is added

Whenever a recording joins a conversation that already has recordings (multipoint, a later match,
Add Recording › From a File…, a device page's Add to Conversation, a confirmed suggestion):

1. The track stores its wall-clock start (when trustworthy) and a `pending` placement with the
   clocks' estimate, or the placement the sound already found.
2. Version History gets "Added Soundcore Work recording" (`source:<track>`).
3. The conversation is queued. Processing, in order and cancellable at each step:
   `placePendingSources` (the sound) → transcribe only recordings without a transcript → fuse with
   placements, settling the rest by transcript, then clock → the transcript check for suggestions →
   summarize from the fused transcript of all sources. `setSummary` keeps the earlier summary in
   Version History.
4. Pause, Cancel, and missing models behave as for any processing: a paused enhancement keeps the
   new recording and its placement; with models missing it waits in `awaitingModels`.

The person's work survives fusion: corrections are carried by `CorrectionTransfer` (merged passages
keep the corrected wording under the passage's original ID), renamed speakers keep their names and
stay on passages that a new recording heard more clearly, note times don't change, and bookmarks
keep their times (a recorder's bookmarks follow its placement and drift).

While this happens, the conversation's status line reads "Adding Soundcore Work recording…"
(`sourceActivity`).

## The other direction

**Record on This Mac** (Inspector › Audio › Add Recording) records into an existing conversation,
for example one a recorder started. The conversation keeps its date and timeline; this Mac's
recordings join it as `pending` sources with the clocks' estimate (when the existing timeline's
start is known) and a shared `clockID`. Bookmarks made meanwhile move onto this Mac's microphone
recording, so they follow its placement exactly. Notes made meanwhile are held by the microphone
recording's placement and move onto the timeline once it's placed. A recorder file arriving before
this Mac's capture is stored (a race at the end of a multipoint recording) is placed relative to
this Mac's start, because the link records it.

## With Daybook on iPhone

A paired iPhone is a recorder with record control ([devices.md](devices.md)), reached over
Daybook's local link ([link.md](link.md)). Its recordings never travel over the link: the phone files
each one as a conversation with a `daybook.iphone` microphone track, and it arrives through sync.

**This Mac records, and asks the phone.** When this Mac starts recording (by hand or
automatically), each paired phone that is connected and whose **Also record on <iPhone> when this
Mac records** is on (the default) is asked to record the same conversation. The request carries this
Mac's start, the elapsed time, and its estimate of the phone's clock. The phone answers straight
away, so there's no polling:

- yes → `recording`, with the phone's recording ID, its start on its own clock, and the link's
  clock estimate stored on the link (`CompanionRecording.clock`): "Also recording on Alex's iPhone."
- already recording this conversation → `alreadyRecording`; this Mac won't stop it.
- no → `failed`, with the phone's reason: "Alex's iPhone didn't record. Its microphone isn't
  available. Recording on this Mac only."
- not connected → `unavailable`, at once (the phone connects to this Mac, never the reverse).

When this Mac stops, phones it started are asked to stop (`stopped`, or `stopFailed` when they
can't be reached: "Stop it on the iPhone; its recording will still be added here").

**The phone records, and asks this Mac.** This Mac records into the phone's conversation ID,
creating the conversation here if it hasn't synced yet, and links the phone as already recording,
with the phone's start and the clock estimate, rather than asking it back. It refuses with a reason
when it's recording another conversation (`recordingSomethingElse`, naming it), starting or stopping
(`busy`), or isn't allowed the microphone (`permissionDenied`; an undecided permission is refused
too, since nobody may be at the Mac to answer the prompt). The phone may stop a recording it asked
for, not one started on the Mac (`declined`).

**The clock prior.** The link measures the phone's clock against this Mac's (NTP-style, good to a
few milliseconds on a quiet network). The phone's start, corrected by that offset, is the
recording's `clockOffset`, which is `AudioAligner`'s expected offset when the sound is compared.

**Its recording arrives.** The phone's recording joins the multipoint pipeline when it is first
processed, as the first step of the job, so only the Mac that carries out the phone's request does
this (any Mac, for a recording without one):

- **In a conversation of its own**, it goes through `planArrival`: the link by recording ID, then
  overlap in time, then the sound. A match moves it into that conversation like any recording that
  finds its conversation later (with its bookmarks, and the clock prior), and its own conversation
  goes to the Trash unless the person worked in it (notes taken on the phone, say), in which case it
  stays and is processed too. Anything less becomes a suggestion, settled by the transcript.
- **In a conversation that has this Mac's recordings** (the phone recorded into it), it waits to be
  lined up, `pending` with the clock prior, and the link is marked `attached`.

## Preferences

| Preference | Default | Where |
| --- | --- | --- |
| Also record on <device> when this Mac records | On, for recorders with record control, Daybook on iPhone included | `ConfiguredDevice.alsoRecordsWithMac` (nil = on); Settings › Devices |
| Add imported files to conversations they overlap | Off | `matchesImportedFilesToConversations`; Settings › General |

## Limits and what needs a recorder

- `AudioAligner` returns nil until the alignment work lands, so today later arrivals settle by
  transcript and multipoint recordings by transcript, then clock.
- Whether Soundcore Work's Pause ends the file (the simulator assumes it does), how quickly a
  finished recording appears in its list, and how far its clock is from this Mac's need a real
  recorder.
- Files exported through the Soundcore app or another recorder's folder carry only a file date, which
  copying can change, so they are never placed by clock and need the sound or transcript to match.
- One status line is shared by all recorders; with two recorders the last message wins.
- Pause and Cancel take effect between steps: a sound comparison already running (synchronous in
  `AudioAligner`) finishes first.
- A renamed title isn't counted as the person's work when deciding whether a moved recording's own
  conversation goes to the Trash (it can be restored from there).
- A phone recording that moves into this Mac's conversation brings its bookmarks, not the notes
  typed on the phone; its own conversation keeps them and stays.
- When the phone asks this Mac to record a conversation that hasn't synced here yet, the two
  copies meet without a common ancestor, so differing titles or dates are kept in Version History.
- Record control with the phone, the clock prior on real Wi‑Fi, and a phone that loses the link
  mid-recording need a real iPhone on a real network; tests use loopback.
