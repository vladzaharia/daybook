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
| Daybook on iPhone | Record control both ways over the local link, recording state and following the leader, the clock prior, and the phone's synced recordings joining conversations | [AppState+Phone.swift](../Sources/Daybook/App/AppState+Phone.swift), [PhoneLinkConnection.swift](../Sources/Daybook/App/PhoneLinkConnection.swift); on the phone, [PhoneAppModel.swift](../Apps/iOS/DaybookPhone/App/PhoneAppModel.swift) and [PhoneLibrary.swift](../Apps/iOS/DaybookPhone/Library/PhoneLibrary.swift) |
| Another device's work | A joining recording's notes and bookmarks, added once and held by its track (`Meeting.addRecordingWork`); recorders on the link and through their owner (`RecorderRemoteControl`) | [MultiSource.swift](../Sources/DaybookCore/MultiSource.swift), [LinkRecorders.swift](../Sources/DaybookKit/LinkRecorders.swift) |
| Starting anywhere | The recorders a device manages recording along with its shared recording, their live audio, and stopping them with it (`RecorderCascade`); the Mac's cascading start and stop (`CompanionRecorders`, `AppState.recorderButton`); the iPhone's (`PhoneAppModel+Cascade`) | [RecorderCascade.swift](../Sources/DaybookKit/RecorderCascade.swift), [MultiSourceCoordinator.swift](../Sources/Daybook/App/MultiSourceCoordinator.swift), [PhoneAppModel+Cascade.swift](../Apps/iOS/DaybookPhone/App/PhoneAppModel+Cascade.swift) |
| Notes and bookmarks shared live | Paragraphs and bookmarks by ID (`SharedNote`, `Meeting.applySharedNote`), what was shared so nothing echoes (`SharedNotesTracker`) | [SharedNotes.swift](../Sources/DaybookCore/SharedNotes.swift), [SharedNotesTracker.swift](../Sources/DaybookKit/SharedNotesTracker.swift), [AppState+SharedNotes.swift](../Sources/Daybook/App/AppState+SharedNotes.swift) |
| A recorder's live audio | A live portion replaced by the recorder's own file (`Meeting.supersededLivePortions`) | [LivePortions.swift](../Sources/DaybookCore/LivePortions.swift) |
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
control whose direct method is set up and on, and whose **Record along with this Mac** preference
is on (the default), starts too:

1. A `CompanionRecording` link is stored on the conversation right away (`starting`).
2. Daybook connects if needed (giving up when the connection does, or after 20 s): out of range →
   `unavailable`, "Soundcore Work isn't nearby. Recording on this Mac only." Having connected, it
   waits (up to 5 s) for the recorder's list read on this connection before deciding anything from
   it, since whether it's recording, and what, arrives after the connection does.
3. Already recording → `alreadyRecording`, with the recorder's start and recording ID. Daybook
   didn't start it, so it doesn't stop it.
4. Otherwise Start; the recorder must confirm within 15 s → `recording` with its recording ID and
   start, "Also recording on Soundcore Work." No confirmation → `failed`, "Soundcore Work didn't start
   recording. Recording on this Mac only."

A recorder another device manages (Settings › Devices, "One owner per recorder") is never reached
for. When that device is an iPhone connected over the link that says it controls its recorders,
this Mac asks it to start the recorder instead (`LinkRecordRequest.recorder`): the phone answers
from its own device session, as above, with the recording's ID and start, and the link is stored as
if this Mac had started it. Otherwise → `unavailable`, "Soundcore Work is managed by Alex's iPhone.
Recording on this Mac only."

When this Mac stops, recorders Daybook started get Pause (after their start finishes), must confirm
(`stopped` or `stopFailed`), and the finished recording is queued for import into this
conversation. Pause goes only to the recording Daybook started: the list is read again first, and
a recorder now recording something else (the person stopped Daybook's recording and started their
own) is left alone; Daybook's recording has ended, so it's imported. A recorder that reported
`failed` but turns out to be recording, live, since Daybook's command is stopped too. One that a
phone now manages (handed over mid-recording) is stopped through that phone, by the recording's ID;
when it can't be, the line names it: "Couldn't reach Soundcore Work to stop it. Stop it on Alex's
iPhone." That phone, which can't be told, stops it itself once it sees this Mac's recording end (its
presence, or the conversation arriving through sync; docs/devices.md, "Handing a recorder over").
Only links made by this recording are acted on; a link an interrupted session left behind never stops
a recorder.

Quitting waits up to 5 s for these stops to leave; going to sleep stops the recording (as before)
and holds sleep back, through the power notification, for up to 5 s while they do. After a crash,
once a recording is recovered at launch, its links are closed as its stop would have: recorders
Daybook started are stopped (only the recording it started), a recorder still `starting` is stopped
only if it is recording, live, since Daybook's command, and one that was already recording is left.

None of this can touch the Mac recording: it begins after capture started, runs in its own tasks,
never throws, and reports only through `CompanionRecorders.status` (one line) and the link's state.
The inspector's line for a link reads "Also recording on …" only while this Mac records the
conversation; after, "Waiting for the … recording." until it arrives, and not at all two days on.

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

## Mac first

A recording made alongside this Mac's (Daybook on iPhone, a recorder) reaches this Mac later than
this Mac's own: the phone's through iCloud, a recorder's when it's imported. This Mac never waits for
it. When its recording stops it's queued at once (`finishCapture` → `enqueue`), so this Mac's audio is
transcribed, its speakers found, and its summary written straight away; when the other recording
arrives, the enhancement above adds it and writes the summary again, keeping corrections, renamed
speakers, notes, and bookmarks, with the earlier summary in Version History.

Meanwhile the conversation says what it's waiting for, from data that syncs, so every place that
shows processing shows it, on the Mac and the iPhone:

- `ProcessingStatus.awaitingRecordings([AwaitedRecording])` once this Mac's audio is done (in place of
  `.done`), and `ProcessingStatus.Progress.awaiting` while it's being processed. A recording is awaited
  when a multipoint link says the device recorded, or may have (`recording`, `alreadyRecording`,
  `stopping`, `stopped`, `stopFailed`), it isn't `attached`, the conversation holds no recording from
  that device (by the link's recording ID, a Listen Live portion included, or else one that started
  after this Mac did), and this Mac's recording ended less than two days ago (`AwaitedRecording.lifetime`,
  as the inspector's line). Untranscribed audio comes first (`.recorded`): it needs the queue or the person.
- The words come from DaybookKit, so both apps say the same: "Waiting for iPhone audio" (or the
  recorder's name; several are joined, "Waiting for iPhone and Soundcore Work audio") in the list row
  and Floating Notes; "Waiting for audio from Alex's iPhone" on the page; and while this Mac's audio is
  being processed, the page's line ends "· Waiting for iPhone audio". The iPhone's list row and page say
  the same for a recorder's audio. Its own recording is already in its copy of the conversation, so it
  never waits for itself; it shows "Waiting for your Mac" for its request until a Mac adds it.
- When the recording arrives the wait ends: the conversation reads "Not transcribed yet" or "Waiting"
  until it's queued, "Adding iPhone recording…" while it's added, then nothing.
- The wait and the arrival don't depend on **Transcribe synced recordings on this Mac**. A recording the
  conversation was waiting for (`Meeting.hasAwaitedRecordingToAdd`: its link recorded and isn't
  attached, the recording is here untranscribed, within `AwaitedRecording.lifetime`) is queued as soon
  as it arrives on a Mac with the models, with the request it came with, because it completes a
  recording made with that Mac. Other synced recordings still follow the setting. While another
  device's request waits and a recording is still awaited, the page keeps the waiting line.

This status isn't pending: Refresh Summary and the other actions stay available while it shows.

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
each one into its conversation with a `daybook.iphone` microphone track, and it arrives through sync.
Each recording has its own ID (the track's device recording ID and the one the link reports), so a
second recording into the same conversation is a track of its own.

**Recording state.** Each side tells the other what it's recording (`recording.state`): when that
changes, every 15 s while recording, and as the phone connects. With it go the recorders the side
manages, as its device sessions last knew them. The phone keeps a Mac's word for 45 s (on its own
clock); the recording screen shows a Mac it records with as stopped when it says so, and doesn't
offer to record on a Mac busy with another conversation. A recorder the other side manages shows as
"Soundcore Work · Recording since 10:02" (with "as of" once it isn't fresh) on the Mac's iPhone page
and the phone's status sheet, for up to 20 minutes past when it was known. A phone recording paused
by a call is still its recording on the Mac (Paused, and Stop on iPhone ends it).

**This Mac records, and asks the phone.** When this Mac starts recording (by hand or
automatically), each paired phone that is connected and whose **Record along with this Mac** is on
(the default) is asked to record the same conversation. The request carries the
conversation's title and date (so a phone it hasn't synced to makes the same record), this Mac's
start, where the conversation's timeline began (earlier than this Mac's start when it records into a
conversation that already had recordings) and how much of it has passed, and its estimate of the
phone's clock. The phone answers straight away, so there's no polling:

- yes → `recording`, with the phone's recording ID, its start on its own clock, and the link's
  clock estimate stored on the link (`CompanionRecording.clock`, measured again at Stop): "Also
  recording on Alex's iPhone."
- already recording this conversation → `alreadyRecording`; this Mac won't stop it.
- no → `failed`, with the phone's reason: "Alex's iPhone didn't record. Its microphone isn't
  available. Recording on this Mac only."
- not connected → `unavailable`, at once (the phone connects to this Mac, never the reverse).
- no answer yet (a microphone prompt, a reconnect) → asked again with the same request for up to
  45 s; the phone answers a repeat with its first answer, even on a new connection, so a start it
  made is never mistaken for one it didn't.

When this Mac stops, it asks to stop the phones it started, a phone that never answered, and one
that says it's recording this conversation after all (`stopped`). A stop the phone refuses is
`stopFailed`: "Alex's iPhone didn't stop. Stop it on the iPhone." One that doesn't reach it is owed
until it reconnects: "Couldn't reach Alex's iPhone to stop it. It stops when it reconnects." An owed
stop is kept in this Mac's preferences (`multipoint.owedStops`, never synced) for a day, so it still
goes if Daybook quits or restarts before the phone is back (`OwedStopsStore`). A stop of a recorder
the phone manages that doesn't name the recording (the phone's answer to the start didn't) is owed
only until Daybook quits, since it would pause whatever the recorder records by then.

The device page's **Start Recording on iPhone** asks for a conversation of the phone's own
(`standalone`), which that Mac may stop. The phone's recorders record along with it; no Mac is asked.

**The phone records, and asks this Mac.** This Mac records into the phone's conversation ID,
creating the conversation here if it hasn't synced yet, with the title and date the phone sent (and
keeping that date while it records), and links the phone as already recording, with the phone's
start and the clock estimate, rather than asking it back. It refuses with a reason when it's
recording another conversation (`recordingSomethingElse`, naming it), starting or stopping
(`busy`), or isn't allowed the microphone (`permissionDenied`; an undecided permission is refused
too, since nobody may be at the Mac to answer the prompt). A phone that asks on its own (a cascading
start, below) is declined when this Mac's **Record along with this Mac** for it is off: "Recording along
with Alex's iPhone is turned off on this Mac." The phone may stop a recording it asked for, or one it
records along with (below), not one started on the Mac without it (`declined`); it stops each Mac it started when it stops, including
one still being asked and one whose answer never came, and owes a stop that didn't arrive until that
Mac reconnects, kept for a day in `owed-stops.json` in its library's folder (never synced), so a
relaunch still sends it. A start that comes back after the phone stopped is stopped too.

**Who stops whom.** A device that records because the other asked follows it: when the one that
asked says it isn't recording that conversation any more (as it does on every reconnection), or
hasn't been reachable for 30 minutes, the follower stops too and says so ("Studio Mac stopped
recording, so this iPhone stopped too."). The phone accepts a stop only from the Mac its recording is
with: the one that started it, or one it asked to record along; the person can always stop it. This
Mac accepts a stop from the phone that asked it to record, and from a phone recording its
conversation along with it. Stopping anywhere stops the rest (below).

**The clock prior.** The link measures the phone's clock against this Mac's (NTP-style, good to a
few milliseconds on a quiet network); the phone also stores what it measured while recording on its
track (`capture.peerClocks`). The phone's first sample (the track's own start), on this Mac's clock by
the later of the two measurements, is the recording's `clockOffset`, which is `AudioAligner`'s
expected offset when the sound is compared. A phone track's start is converted this way wherever
starts are compared.

**Its recording arrives.** A recording made with a Mac (one that recorded, or may have: it never
answered) is filed into that conversation as a source to place: offset unknown, its bookmarks on its
track, and its notes, matched by ID so nothing doubles, timed by its own clock and held by its track
(`SourceAlignment.heldNoteIDs`, as for **Record on This Mac**) until it's placed, when they move with
it. A note taken before the recording that sets the timeline began keeps its place before zero (a
negative time). The phone never writes the conversation's title, date, status or message; one that
hasn't synced to it yet is made as its leader sent it. A recording made alone is a conversation of its own,
as before. A recording the phone was killed while making is recovered with the Macs it was made
with (its journal keeps them): it joins the same way, and the phone stops the Macs it started.

The phone's recording, and a recorder's recording another device imported (the phone, after taking
the recorder over), join the multipoint pipeline when first processed, as the first step of the job,
so only the Mac that carries out the request does this (any Mac, for a recording without one):

- **In a conversation of its own**, the phone's goes through `planArrival`: the link by recording
  ID, then overlap in time, then the sound; a recorder's, by its link only. A match moves it into
  that conversation like any recording that finds its conversation later (with its bookmarks, and the
  clock prior), and its own conversation goes to the Trash unless the person worked in it (notes
  taken on the phone, say), in which case it stays and is processed too. Anything less becomes a
  suggestion, settled by the transcript. A phone recording filed to be placed that turns out to be
  alone sets its conversation's timeline. One in a conversation a Mac recorded with this phone (its
  link is there) waits for that Mac's recording instead.
- **In a conversation that has this Mac's recordings**, it waits to be lined up, `pending` with the
  clock prior (keeping the notes it holds), and the link is marked `attached`.
- **Transcribed on the iPhone** (docs/iphone.md, "Processing on this iPhone"): a recording the phone made
  alone and transcribed itself arrives with its transcript, and with only a Summarize request or none. The
  first time a Mac sees one (`phoneTranscriptArrived`, before anything else in the job; after a sync pass,
  a job only for the check, which phones aren't told about), it finds its conversation the same way. A match
  moves it there with its transcript and speakers (`MultiSourceCoordinator.Carried`), so it isn't transcribed
  again, and that conversation fuses and summarizes through the placement; its own goes to the Trash as
  above, and the phone's countdown or summary for it stands down when the deletion arrives. Each is checked
  once per Mac (`multipoint.checkedPhoneRecordings` in its preferences, never synced). One that stays keeps
  the phone's summary; this Mac summarizes it only when the phone asked. One the phone holds a claim on (it's
  summarizing it) is checked when that's done. A recording the phone transcribed counts as the phone's when
  its Transcribe request was finished by the device that asked; one a Mac transcribed was checked before.

## Starting anywhere

Starting a recording on any device starts every device connected to it, and stopping on any device
stops the rest: a cascading start and stop. Each device records a conversation once, under the one
conversation ID, however many ways it's asked.

| Started on | What else starts |
| --- | --- |
| This Mac (by hand or a detected meeting) | Each connected iPhone (as above); the recorders this Mac manages; a recorder a phone manages, through that phone |
| An iPhone (by hand, a Shortcut, the control, the Action button) | Each connected Mac, on its own (`LinkRecordRequest.cascade`); the recorders the phone manages |
| An iPhone, because a Mac asked | Its recorders; no Mac is asked back |
| A recorder's own button | The device that manages it records (a new conversation), and so everything that device reaches |

**Asked on its own.** The request a starting device sends carries `cascade` (what started it: the
person, a recorder's button, a detected meeting, or another device), so the receiver joins the same
conversation, says why, and never takes it for a conversation of its own. The Mac's **Record along
with this Mac** for the phone decides both ways (on by default): off, a phone's cascading start is
declined, while a start the person chose for that Mac still records. The phone asks every Mac
connected when it starts, and one that connects within the next minute (the link can take a moment
to come back as the app comes forward); "Record on Studio Mac too" still asks one that connects later.
A Mac that asked the phone isn't asked back, and the phone doesn't ask other Macs then.

**No loops, no echoes.** A device asked to record a conversation it records already answers "already
recording" (`wasAlreadyRecording`), and one asked again with the same request answers once, so a
start reaching a device two ways (the Mac asking for the phone's recorder while the phone starts it on
its own) is one start: the phone's `RecorderCascade` runs one start per recorder and gives every ask
its answer. A recorder's own start or pause isn't news: only a state it reports while no command of
Daybook's is waiting (`SoundcoreConnection.onButton`) counts as its button. A conversation that ended
on a device isn't begun there again by a late ask.

**Stopping.** A stop goes to every device the stopping device started or was started by, except the
one whose word the stop is: this Mac stops the phones it started (as before) and now the phone that
asked it to record (`CompanionRecorders.leads`), unless that phone's stop is what stopped it
(`stopCause`); a phone stops the Macs it started (as before) and now the Mac that asked it, unless
that Mac's stop is what stopped it, owed until it reconnects; a recorder stops with the recording it
was started for, the one whose button began it, and one whose button joined it (only that
recording, read from its list first); its button stopping it stops the recording it's part of
everywhere. A recorder that was already recording when the conversation began records along and is
left running, as before.

**Permission.** A Mac may start an iPhone's microphone from the moment it's paired: the per-Mac
choice from the security review (Settings › Macs › <Mac> › Can Start Recording) stays, visible and
switchable, but starts on, and the pairing sheet no longer asks. Turned off, a Mac's start is declined
with the reason as before. A choice belongs to one pairing; pairing again turns it on again.

**A recorder's button and the iPhone.** The recorder tells the device managing it when its button
starts or stops a recording (`18 82`, `SoundcoreSession.Push.recording`). To hear it, an iPhone holds
the link to a recorder it manages that records along with it, while the recorder is in range,
including with Daybook in the background (docs/devices.md, "Holding the recorder's link"). Pressed:

- Daybook is recording: the recorder joins that conversation (its audio saved into it as it records,
  below) and stops with it.
- Daybook is in front, or iOS lets it start the microphone: this iPhone records a new conversation
  with the recorder as its lead, and asks its Macs.
- In the background, iOS doesn't let an app start the microphone (since iOS 12.4,
  `AVAudioSession.ErrorCode.cannotStartRecording`; Apple's Developer Technical Support says only CallKit,
  LiveCommunicationKit, and PushToTalk may, and only for calls; `AudioRecordingIntent` runs only when
  the system performs it from the Action button, a control, Siri, or Shortcuts, never from an
  accessory's event; and a Live Activity can't be started from the background without a push server).
  So only the recorder records (`PhoneAppModel.recorderOnly`): its audio is saved into the new
  conversation as it records, a notification says "Soundcore Work is recording. Daybook is saving its
  audio. Open Daybook to record on this iPhone too.", the link is brought up (`backgroundRecording`)
  and each Mac that understands it is asked to record, told the phone itself doesn't
  (`LinkCascade.requesterRecords` false: the Mac expects no recording of the phone's own). The phone's
  `recording.state` names the conversation in `sharedConversationID`, so a Mac following it keeps
  recording. Opening Daybook (from the notification or otherwise) records on this iPhone too, into the
  same conversation; the recorder's button stopping it, or a Mac's stop, ends it and stops the rest.
  Never a microphone kept open, never a claim this iPhone records when it doesn't. If the microphone
  still can't start when Daybook comes forward (it's refused, or a call holds it), the library says so
  over Record, in the status sheet in the hand and at the foot of the notebook's left page: "Soundcore
  Work is recording. This iPhone isn't." Record then records on this iPhone too, into the same
  conversation.

On a Mac that manages the recorder, its button starts and stops this Mac the same way while the Mac
is connected to it (a Mac lets the recorder go when idle, so the iPhone is where this matters), and
never asks for the microphone for it.

## A recorder's audio while it records

The device that manages a recorder recording along with a shared recording saves the recorder's audio
into the conversation as it records, from the stream Listen Live uses (`DeviceSession.captureLive`),
and captions it, beside the device's own captions (docs/capture.md, "Every source"). When the recording stops, the
recorder's audio is already in the conversation (in the library within a fraction of a second of the
stop, against minutes to transfer the file afterwards), so multipoint processing has every source at
once. It's a live portion: its recording ID ends with `~live`, it joins the conversation as a source
to place like the recorder's file would (the link's clock prior, then sound), and it doesn't satisfy
the recorder's multipoint link.

The recorder's own file is imported into the conversation as before (when this Mac stops, the phone
when asked, or whenever the recorder is next in range: `DeviceSession.importWhenFinished`), and it's
authoritative:

- Byte for byte the live portion (the stream had every frame, as when the recorder's button ended it
  and the stream ran to its end), the import finds that track and names it for the whole recording
  (`MeetingStore.importAudio`): one track.
- Otherwise (the live audio was cut when a device stopped the recorder, the link dropped, or packets
  differ), both stay, and the live portion is replaced for transcription and fusion
  (`Meeting.supersededLivePortions`; `transcribableTracks` leaves it out, and fusion reports it as
  "Replaced by the recorder's own file"). Its original stays for provenance and playback.

The link dropping keeps what arrived (as Listen Live does), and the file is imported after the
recording; so does the stream going quiet (no longer discarded after the stall timeout), and the
recorder saying it stopped ends the stream after a moment (`SoundcoreTiming.liveTail`) if it doesn't
end on its own. While it streams, the recorder's list can't be read nor Pause sent, so a device
stopping it saves the live audio first. What it costs the link is in docs/direct-soundcore.md,
"Live audio for a shared recording".

## Notes and bookmarks during a shared recording

While a Mac and an iPhone record one conversation, a paragraph written in Floating Notes (or the
conversation page) on the Mac appears in the iPhone's Write Notes at once, and one written on the
iPhone appears on the Mac; so do bookmarks, a bookmark's label, and a deleted paragraph or bookmark.
Over the local link (`note`, `bookmark`, `bookmark.change`; docs/link.md), only between devices that
both record the conversation and list `sharedNotes`.

- **Identity.** A paragraph is its anchor ID (`TimedNote.id`), a bookmark its `Highlight.id`, minted
  on the device where it was written and kept on the other. The copy the link brings and the one sync
  brings later are therefore one item, and the library's merge keeps each once (by ID with no common
  ancestor; with one, two copies holding the same paragraphs in another order aren't a conflict for
  History, `MergedNotes.holdsSameParagraphs`).
- **Time.** Each paragraph travels with the time the device that wrote it files it at, and the other
  device keeps exactly that, so the copies agree: a Mac's note at its time on the timeline; an iPhone's
  at its recording's time plus where the link's clocks put its recording (the same shift its filing
  uses). The iPhone shows a Mac's paragraph at its moment in its own recording (from when it was
  written, on the Mac's clock moved onto the iPhone's), and files it as the Mac does: not held by its
  recording (`PhoneCaptureJournal.sharedNotes` and `sharedBookmarks`).
- **Edits and deletes** go by ID: an edited paragraph keeps its place, a new one from the other device
  goes at the end (so nothing moves under a cursor), a deleted one goes. The latest change of each
  item wins (`changedAt`, moved onto the receiver's clock); an older one arriving late is dropped.
- **Never echoed.** Each device keeps what it last shared or was sent (`SharedNotesTracker`) and sends
  only what changed against it; what arrived is recorded before it's applied. The Mac diffs its notes
  and bookmarks after each change to the conversation (every editing surface: Floating Notes, the page,
  the menus), a quarter-second after typing pauses; the iPhone after each change to its notes.
- **While typing.** Floating Notes and Write Notes take a paragraph from the other device while the
  person types (it goes at the end, so the cursor stays put), and one that arrived a moment before an
  editor wrote its text back is kept rather than taken as deleted (`SharedNotesTracker.keepingArrivals`).
- What was there before the shared recording began, and work after it, travel through sync as before.

## Where summaries run

A conversation's summary can run on the device that has its transcript, on a Mac another device sends it to,
or in the cloud with the person's own key (docs/cloud.md). Transcription, speakers, voice profiles, and audio
never leave the device. Where each summary runs is decided by one planner both apps share
(`SummaryPlacementPlanner` in DaybookKit), from what the device can offer when the summary is due
(`SummaryOptions`) and the person's preferences (`CloudSummaryPreferences`, Settings › Cloud):

| Code | What it does | Where |
| --- | --- | --- |
| Planner | One conversation's placement: its phase, the person's choices, and how it reacts when what's on offer changes. Pure; every change takes the time | [SummaryPlacementPlanner.swift](../Sources/DaybookKit/SummaryPlacementPlanner.swift) |
| Placements | A planner per conversation, the countdowns' timer, and the options and preferences every countdown follows | [SummaryPlacements.swift](../Sources/DaybookKit/SummaryPlacements.swift) |
| Claims and provenance | `claimSummary`, `summaryHolder`, `applyPlacedSummary`, and where a summary ran (`MeetingSummary.origin`, `modelsByRole`) | [LibraryController+SummaryPlacement.swift](../Sources/DaybookKit/LibraryController+SummaryPlacement.swift) |
| Reachable Macs, capabilities | `SummarizingMac.reachable`, and `ProcessingCapabilities` as the link and presence carry them | [ProcessingCapabilities+Devices.swift](../Sources/DaybookKit/ProcessingCapabilities+Devices.swift) |
| The Mac | The summary step of every job, its capabilities, phones' choices | [AppState+SummaryPlacement.swift](../Sources/Daybook/App/AppState+SummaryPlacement.swift) |
| The iPhone | Its options, sending to a Mac, running here or in the cloud, the background | [PhoneSummaryPlacement.swift](../Apps/iOS/DaybookPhone/App/PhoneSummaryPlacement.swift) |

**What a device offers.** Whether it can summarize itself (a Mac with its summary model; an iPhone whose
processing models have a summary model that fits, its `LocalSummarizing`), the Macs that summarize and are
reachable now (connected over the link, or seen through sync in the last 15 minutes, by their capabilities;
an earlier Daybook's Mac counts when it says it processes), and the cloud model Settings › Cloud resolves to
among those the person's keys reach (none without a key, or with Never). The keys, the models, and the
preferences (the policy, the countdown's length, the effort) are read from each app's one `CloudSetup`
(docs/cloud.md, "For callers"), whose changes reach every countdown at once.

**The phases.**

- **Counting down** to this device or a Mac: 15 s by default, or the setting (30 s). When it runs out, the
  default starts: this device when it can summarize, else the first reachable Mac. The person can choose
  **Use the Cloud** and **Start Now**, and, on a device that isn't a Mac and counts down to itself, **Wait
  for a Mac** (a reachable Mac gets it at once; otherwise it waits for one, passing over this device from
  then on).
- **Waiting for a Mac**: nothing here can summarize it and no Mac is reachable, with the cloud on offer.
  No countdown; Use the Cloud. When a Mac becomes reachable, a fresh countdown starts before it's sent.
- **Started**: here, sent to a Mac, or in the cloud. Nothing changes it after this.
- **Waiting, as before**: nowhere to run it, not even the cloud. It goes to the Macs as a request, as it
  always has.

**When it counts down.** Only when there's something to choose. Without a cloud model on offer (no key, or
Never) a summary starts at once where it can, as before there was a cloud. **Always** sends it to the cloud
with no countdown. A summary someone asked for starts at once wherever it can: Summarize Again, a template,
Identify Speakers Again, Transcribe Everything Again, here or as another device's request. Only the summary
that new audio makes due counts down.

**When what's on offer changes mid-countdown**, every countdown follows (`SummaryPlacements.update`): a
countdown keeps its deadline when where it ends up changes (the Mac it counted down to went away and another
is reachable; this device became able to summarize, or stopped); one with nowhere left to go waits for a Mac;
one whose cloud went away (the key removed, Never chosen) starts its default now, since the countdown was
there to offer the cloud; Always chosen sends it to the cloud. Waiting turns into a fresh countdown when
somewhere to run it appears.

**On the Mac.** The summary step of every job goes through the planner (`placedSummary`): when the
transcript is ready and the summary is due, the job reads Settings › Cloud again (`AppState.cloud.reload`),
counts down, then summarizes here, or in the cloud (`CloudSummarizer`, with the preferred effort) if the person
chose it. The queue waits for the countdown, so a batch of imports counts down one at a time (Limits, below).
Pause and Cancel during the countdown pause the job. It shows where processing status shows: the page's
line ("Summarizing on this Mac in 12 s · Use the Cloud · Start Now", then "Summarizing with Claude Sonnet
5.5" with Stop), the list row ("Summarizing in 12 s") and the list's subtitle, the inspector's Processing, and
Floating Notes (the chip, whose menu has the choices, and the home's line for this Mac). Connected phones see the countdown too
(`processing.progress`, phase `summaryCountdown`) and may choose; their choice arrives as
`processing.choice` and acts as if it had been made here. A Mac's own summarizer is always available to a
job (a job reaches the summary step only with the summary model), so a Mac never waits for another Mac. A
request another device makes that joins a job counting down (its own countdown for that conversation ran
out) starts it at once.

**On the iPhone.** The same planner, with "this iPhone":

- One summary path. Once `PhoneProcessor` has transcribed and fused a conversation of its own, its
  Transcribe request is done and the summary is the placement's (`PhoneSummaryPlacement.summaryIsDue`;
  Transcribe Everything Again and Identify Speakers Again done here hand it over as asked for, so it starts at
  once). It counts down to this iPhone when it has a summarizer, else to a reachable Mac ("Summarizing on
  Vlad's MacBook Pro in 12 s"), then runs it here or **sends** it: a Summarize request (`ProcessingRequest`
  `.summaryOnly`, the existing path), with a nudge to connected Macs. With no Mac reachable: "Waiting for a
  Mac to summarize · Use the Cloud", and a countdown when one arrives.
- Here, it runs as the processor's own work (`PhoneProcessor.summarizeHere`, on the Summarize request the
  placement claimed; `OnDeviceProcessing.Device.summariesHere`), under the processor's rules: only while
  Daybook is on the screen, stopped when it leaves; paused for Serious heat, Low Power Mode, or a battery under
  20% unplugged, and while recording; after the transcription models are let go; one conversation at a time.
  Its status is the processor's ("Summarizing on this iPhone · 40%"). A Summarize request this iPhone made
  that waits for a Mac is never run here.
- Summarize, Summarize Again, and a template the person asks for start at once where they can. With no
  Mac reachable the request waits for one in the library, as before, and while it waits the page offers
  Use the Cloud, which takes that request.
- A Mac counting down to a conversation shows the Mac's countdown here, with its choices sent to it, and
  this iPhone stops its own countdown for that conversation.
- In the background a countdown can't run, so each one's default happens as the app leaves the screen, and
  a summary waiting for a Mac is left to one through the library.
- Never stranded. A summary that's due is written down before it counts down: a Summarize request the
  iPhone claims (`claimSummary`, the summarizing stage) and holds through the countdown or the wait for a Mac,
  renewing it while it waits. Sending it to a Mac gives that request back; running it here or in the cloud
  carries it out. If Daybook is killed meanwhile, the next launch places it again
  (`PhoneSummaryPlacement.resumeHeldSummaries`: a request it claimed and never gave back, unless another
  device took it). If the iPhone never comes back, the claim's lease (10 minutes) runs out and a Mac takes the
  request like any other. A Mac checking where an iPhone-transcribed recording belongs doesn't wait for the
  hold to end.
- The conversation page, the list row, and the status sheet's Macs card say it, with the same choices.

**One summary per conversation.** Through the request and claim mechanism every Mac already respects:

- A device that summarizes a conversation here or in the cloud first claims it (`claimSummary`): a
  Summarize request waiting for a Mac that it may take, or one it makes for the purpose, claimed with the
  summarizing stage, so other devices read "Summarizing on Pocket iPhone" and no Mac takes it. A device
  that finds another holding a live claim on any of the conversation's open requests stands down: every
  request ends with a summary.
- The Mac stands down at the summary step, before and after its countdown, when another device holds the
  conversation (an iPhone chose the cloud and its claim arrived through sync), and its job finishes
  without a summary; that device's arrives.
- Two devices claiming at once: the merge keeps the newest claim, and the one that lost stops (the Mac's
  `reconcileClaims` as before; the iPhone's cloud or local run when a pass shows the claim held elsewhere).
- A summary another device wrote after this device began summarizing is kept rather than replaced
  (`summaryWrittenElsewhere`), on both apps.
- A Mac that arrives late finds the request claimed, or finished, and leaves it.

**Provenance.** A summary records where it ran in its processing settings (`MeetingSummary.origin`): the
device that ran it or sent it to the cloud (`summarizedBy`, `summarizedByName`) and `place` (`local` or
`cloud`). A cloud summary also keeps the cloud's own provenance (`CloudProvenance`: the provider and model ID as
`cloudProvider` and `cloudModel`, the effort, tokens, estimated cost, and `sentBy`; docs/cloud.md), and
`origin.cloudModel` is that model's name for every cloud summary, including one made without the placement. It
also records the model behind each role (`model.transcription`, `model.diarization`, `model.summarization`
("anthropic/claude-sonnet-5-5" for a cloud one), read with `modelsByRole`), for comparing later with what a device
could do better. The colophon says it: "Summarized on this Mac", "Summarized on
Studio Mac", "Summarized on this iPhone", "Summarized with Claude Sonnet 5.5"; a summary made before this
reads as before ("on this Mac" on a Mac, "on your Mac" on the iPhone).

**Capabilities.** A Mac advertises `ProcessingCapabilities` (transcribes, finds speakers, summarizes, and
the model it would use for each role it runs) over the link (`LinkCapabilities.processing`) and in its
presence record (`SyncDeviceIdentity.capabilities`): worked out from its routed models and, for summaries,
the memory the summary model suggests, and only while it transcribes synced recordings (otherwise it takes
no work from others, and says none). Earlier peers send none, which reads as unknown, not as "can't".

**Limits.** A countdown inside a job holds the Mac's queue for its length: the queue runs one job at a time,
and the job's claim, heartbeat, pause, progress for phones, and protection from sync all belong to the running
job, so the next conversation's transcription can't go ahead during it without either running a local summary
beside a transcription (two models in memory) or stopping the next job when the countdown ends. The iPhone's choice for a Mac's
countdown travels only over the link; without it, the iPhone sees the Mac at work through sync and can't
choose. Two devices that both start summarizing before either's claim reaches the other (no link, iCloud
slow) can both finish; the later one keeps the earlier summary if it arrived first, and otherwise the
merge keeps one and Version History the other. A Mac's presence counts as reachable for 15 minutes after
it was seen, so a Mac that went to sleep a few minutes ago can be counted on until then; the request waits
in the library for it. The iPhone summarizes itself only where a summary model fits its memory (docs/iphone.md),
and only on the screen.

## Upgrade

When a clearly better model than the one that made a conversation's transcript, speakers, or summary is within reach,
the conversation page offers to redo that step there, and every step after it: a better transcript means the speakers
found again, voice profiles, fusion, and a new summary. The person can dismiss it. Each device works the offer out for
itself from the conversation's synced provenance and what it can reach, so it shows on every device that sees a better
option, and goes everywhere once the work is done or the offer dismissed.

| Code | What it does | Where |
| --- | --- | --- |
| Ranks | Each local model's rank for each step it serves, and the cloud's `summaryQuality`, on one scale for summaries (docs/models.md, "Quality ranks"); `UpgradeRanks` reads them | [Families](../Sources/DaybookKit/Resources/ModelCatalog/Families), [CloudCatalog.json](../Sources/DaybookKit/Resources/CloudCatalog.json), [Upgrades.swift](../Sources/DaybookKit/Upgrades.swift) |
| The comparison | `Upgrades.offer`: the steps (`UpgradeRole`: margins, modes, words), what a device reaches (`UpgradeCandidates`), the offer (`UpgradeOffer`), the model behind each step now (`Meeting.upgradeCurrent`). Pure | [Upgrades.swift](../Sources/DaybookKit/Upgrades.swift) |
| Reachable Macs | `ProcessingMac.reachable`: connected, or seen through sync in the last 15 minutes, with the models they run | [ProcessingCapabilities+Devices.swift](../Sources/DaybookKit/ProcessingCapabilities+Devices.swift) |
| Requests and dismissals | `ProcessingRequest.Upgrade` (the step, the model, its rank, the device), `requestUpgrade`, `UpgradeDismissal` and `dismissUpgrade`, merged with the conversation | [ProcessingRequest.swift](../Sources/DaybookCore/ProcessingRequest.swift), [UpgradeDismissal.swift](../Sources/DaybookCore/UpgradeDismissal.swift) |
| The Mac | The page's line, accepting, which requests it takes, an upgrade's summary step | [AppState+Upgrade.swift](../Sources/Daybook/App/AppState+Upgrade.swift), [AppState+Requests.swift](../Sources/Daybook/App/AppState+Requests.swift), [AppState+SummaryPlacement.swift](../Sources/Daybook/App/AppState+SummaryPlacement.swift) |
| The iPhone | The page's line, accepting, what its processor runs | [PhoneUpgrades.swift](../Apps/iOS/DaybookPhone/App/PhoneUpgrades.swift), [OnDeviceProcessing.swift](../Sources/DaybookKit/OnDeviceProcessing.swift) |

**The comparison**, step by step (transcript, speakers, summary):

- **Now:** the transcript's and the speakers' models are each recording's latest run (as `modelsBehindTranscript` reads
  them), and with several recordings the weakest counts: a Mac's microphone with Parakeet Ultra and an iPhone's
  recording with Parakeet Redux make a Redux transcript. The summary's is its provenance (`modelsByRole`, else its
  `ProcessingSettings.model`, which for a cloud summary is "anthropic/claude-sonnet-5-5"). A step whose provenance is
  missing or unranked (a run with no recorded model, a model the person added) offers nothing.
- **Within reach:** this device's own models (`ProcessingCapabilities.models`; a Mac's whether or not it takes other
  devices' work; the iPhone redoes only a conversation whose every recording is its own, as it transcribes only those),
  the Macs reachable now that name their models (the placement's reachability; an earlier Daybook names none, so offers
  nothing), and for the summary the cloud model Settings › Cloud resolves to, with a key and unless Never. The best rank
  wins; on a tie this device, then the Macs in order, then the cloud, so the work stays nearest. A transcription model
  must cover each recording's language as it was transcribed.
- **Clearly better:** the best must rank at least the step's margin above what's there now. Without one, every Gemma 4
  26B A4B summary (90) would nag toward the cloud's best (94–95).

  | Step | Margin | Offered | Not offered |
  | --- | --- | --- | --- |
  | Transcript | 10 | Parakeet Redux (80) to Ultra (90); Whisper Small (70) to Ultra | Whisper Large v3 Turbo (85) to Ultra |
  | Speakers | 10 | Sortformer 2.1 (79) to Nemotron 3 (89) | Community-1 (85) to Nemotron 3; Sortformer to Community-1 |
  | Summary | 10 | Gemma 4 E2B (25), E4B (53), or 12B (60) to the 26B A4B (90) or the cloud | The 26B A4B to the cloud (95); Qwen 3.6 35B A3B (87) to the cloud |

- **At rest only:** nothing is offered while the conversation records, works, or waits (`ProcessingStatus` other than
  done: a request open, a job queued, a recording still to come) or while its summary is placed (counting down, in the
  cloud, or held by the iPhone, whose claimed Summarize request every device reads as work under way).
- **One line:** the most upstream step with an offer, since redoing it redoes the rest; when that one is dismissed, the
  next step's.

**The line.** One quiet line on the page, in the status line's idiom, on the Mac and the iPhone (never in list rows):
what improves and where, then Upgrade and Dismiss.

| The better model is | The page says |
| --- | --- |
| This device's | "Upgrade transcript", "Upgrade speakers", "Upgrade summary" |
| A reachable Mac's | "Upgrade transcript on Studio Mac" (on the iPhone: "… on Vlad's MacBook Pro"; on that Mac: "Upgrade transcript") |
| The cloud's | "Upgrade summary with Claude Sonnet 5.5" |

**Upgrade** goes through the existing request and claim path, to the device with the better model:

| Step | Better model | What happens |
| --- | --- | --- |
| Transcript | This Mac | Its queue runs Transcribe Everything Again, marked as an upgrade (`ProcessingJob.upgrade`) |
| Transcript | Another Mac | A Transcribe Everything Again request naming it (`ProcessingRequest.upgrade`), which it claims; the iPhone nudges it over the link |
| Transcript | This iPhone | A request naming itself, which its processor carries out |
| Speakers | Any | The same with Identify Speakers Again |
| Summary | This Mac | Summarize Again, marked as an upgrade: through the placement, with its countdown |
| Summary | This iPhone | The placement's `summaryIsDue`, as any due summary: held, and counting down while the cloud is on offer |
| Summary | Another Mac | A Summarize request naming it; that Mac's job counts down to it |
| Summary | The cloud | At once, since the person chose it: `SummaryPlacements.beginInCloud` on the Mac; `summaryIsDue`, then Use the Cloud, on the iPhone |

- **Every later step runs again.** Transcribe Everything Again transcribes every recording with that device's
  transcription model, finds the speakers with its speaker model, makes voice profiles, lines the recordings up, fuses,
  labels speakers from the profiles, and writes the summary; Identify Speakers Again starts at the speakers. Each later
  step uses the best the device has for it then, and the summary goes through the placement: an upgrade's summary isn't
  one the person asked for, so it's due as new audio's is, and counts down while the cloud is on offer (a better cloud
  summary may then be offered as its own upgrade).
- **Corrections are kept**, as the reprocess paths keep them: corrected passages carried by `CorrectionTransfer`,
  renamed speakers matched by voice and kept, notes, bookmarks, and ticked next steps; the earlier runs and summary stay
  in Version History.
- **Who carries out a request:** the device named, or any device whose own model for the step ranks at least as high
  (`ProcessingRequest.Upgrade.mayBeCarriedOut`). A Mac with a weaker model leaves it (`pickUpRequests`, and a job of its
  own doesn't take it on); the iPhone runs only upgrades naming itself (`OnDeviceProcessing`). Older Daybooks: below.
- **Waiting.** While the request waits, both apps' pages (and the iPhone's list row) say "Waiting for Studio Mac to
  upgrade the transcript", and nothing more is offered. If the named Mac is gone before it takes the request, the
  request stays and keeps saying so; a Mac with a model as good takes it instead when there is one.
- **Done.** The new results record the better model, so the comparison finds nothing more for that step, here or
  anywhere: a finished upgrade never offers itself again.

**Dismiss** is kept on the conversation (`Meeting.upgradeDismissals`: the step, the model, its rank, when) and syncs
with it. Dismissals merge as a union, once per step and model (the earlier), so two devices dismissing at once agree,
with nothing in Version History. An offer stays away while its model, or one ranked at least as high, was dismissed for
that step; a later, better model may offer again.

**Limits.**

- Older Daybooks don't know `ProcessingRequest.upgrade`: an earlier Mac may take an upgrade request and run it with its
  own models (the offer then shows again), and one that saves the conversation drops the field from its copy (the merge
  keeps one). They keep dismissals as they came (unknown fields).
- A Mac that doesn't take other devices' work (Transcribe synced recordings off) names no models, so other devices
  never offer it. Macs see each other only through presence, so one asleep for over 15 minutes isn't offered.
- Ranks that weren't measured are estimates (docs/models.md, "Quality ranks"); the margins keep them from offering
  what the evidence doesn't support.
- The iPhone redoes only its own recordings; a Mac's recording is offered to a Mac.

## Preferences

| Preference | Default | Where |
| --- | --- | --- |
| Record along with this Mac | On, for recorders with record control, Daybook on iPhone included. For an iPhone it decides both ways: off, the phone's cascading starts are declined too | `ConfiguredDevice.alsoRecordsWithMac` (nil = on); Settings › Devices |
| Record Along (per recorder, on the iPhone's recorder page) | On, for a recorder with record control the iPhone manages: whether it records along with the phone, its button starts the phone, and the phone holds its link for that | `ConfiguredDevice.alsoRecordsWithMac` (nil = on); the recorder's page |
| Can Start Recording (per Mac, on the iPhone) | On when the Mac is paired | `PhoneSettings.macMayStartRecording`; Settings › Macs › <Mac> |
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
- Links merge across Macs, so a second Mac with the models also queues an awaited recording that
  arrives, with **Transcribe synced recordings on this Mac** off too; the request's claim settles which
  one adds it, within a sync round, as for any request two Macs take at once.
- A recording that never arrives stops being awaited two days after this Mac's recording ended; the
  conversation then reads as done.
- Pause and Cancel take effect between steps: a sound comparison already running (synchronous in
  `AudioAligner`) finishes first.
- A renamed title isn't counted as the person's work when deciding whether a moved recording's own
  conversation goes to the Trash (it can be restored from there).
- A phone recording that moves into this Mac's conversation brings its bookmarks, not the notes
  typed on the phone; its own conversation keeps them and stays.
- When either device makes the other's conversation before it has synced, both copies carry the
  same title and date, but they meet without a common ancestor: until sync treats that case, a
  differing status is kept in Version History.
- When the phone led and this Mac joined later, this Mac's recording sets the timeline and the phone's
  is placed before its zero. Notes the phone took before this Mac started keep their time in the
  phone's recording, so they read before the timeline's zero (−0:42), as its passages do. Daybook
  0.3.0 and earlier reads note times from zero only, so editing those notes there drops their times
  (the notes stay).
- Starts still being asked are kept in memory: quitting drops them, and the device's own
  follow-the-leader check (or the next launch) stops it instead. Owed stops are kept for a day; one
  older than that is dropped, by when the other device has stopped by its own rule or the person
  has.
- A Mac reached through a phone's recorder can't measure the recorder's clock; its recording is
  placed by the recorder's own start, then sound and transcript.
- Record control with the phone, the clock prior on real Wi‑Fi, and a phone that loses the link
  mid-recording need a real iPhone on a real network; tests use loopback.
- A Mac can't start an iPhone whose Daybook is in the background and not recording: the link is
  closed then (docs/link.md, "Lifecycle"), and iOS wouldn't let the phone start its microphone anyway.
  The Mac says "Alex's iPhone isn't connected. Recording on this Mac only."
- Starting from a recorder's button in the background records only the recorder (above), and asking
  the Macs depends on the link coming back while iOS keeps Daybook running for the recorder's
  Bluetooth traffic; both need a real iPhone and recorder to confirm.
- A phone asked by one Mac doesn't ask its other Macs; a recorder only-recording phone asks Macs from
  this build on (those listing `cascade`).
- The phone keeps the recorders of its shared recording in memory: if Daybook is killed mid-recording,
  a recorder it started keeps recording until the person stops it, and its file imports as usual.
- A shared paragraph is one line: line breaks typed inside one paragraph arrive as spaces. A paragraph
  edited on both devices at once keeps the later edit.
- A Mac and an iPhone started by hand at the same moment (two cascades crossing) each refuse the
  other's start as recording something else, so they record two conversations; the later recording
  finds the other by time and sound as any recording that arrives later does.
