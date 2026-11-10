# Daybook for iPhone

A full Daybook app for iPhone. Recording, notes, bookmarks, the library, reading, playback, editing, organizing, devices, templates, vocabulary, sync, and settings all work on the phone. Once its processing models are downloaded, the phone transcribes its own recordings, tells their speakers apart, names them from the synced voice profiles, and summarizes them where it has the memory, with the Mac's engine ("Processing on this iPhone", below); otherwise, and for a Mac's recordings, a Mac does and the results sync back. It also runs models for live captions ("Live transcription").

**Recorded but not processed is a normal, complete state.** A conversation recorded on the phone is immediately useful: you can play it, take timed notes, bookmark it, title it, file it, and search its notes. It says where it stands ("Not transcribed yet"), never that something is broken. The architecture keeps on-device processing possible later without restructuring.

Designed first for **iPhone Duo** (book-style foldable, iOS 27.1+): closed it's a pocket recorder, open it's a two-page notebook. Every other iPhone gets the closed layout, or the open one at regular width or on its side.

## Scope

Everything below is in v1:

- **Record.**
  - Microphone recording, background-safe, interruption-safe, compressed (AAC).
  - **The input.** The recorder names it in its phase, "● RECORDING · iPhone Microphone ▾", and the name is a button for the system's input picker (`AVInputPickerInteraction`, AVKit). The choice follows the Mac's rule (`MicrophoneChoice`; docs/capture.md, "Choosing the microphone"), but the iPhone can't see other apps' audio, so Automatic records the built-in microphone with AirPods connected, which iOS would otherwise make the input: a phone on the table records the room, not the voice of whoever wears them. It's the session's preferred input, set before the session activates, so AirPods nobody picked never switch to their hands-free profile, and AirPods connecting mid-recording don't take over (`AudioInputPlan`, `LiveAudioSession`). A wired or USB microphone, which iOS records by default, is kept. What the person picks is recorded from at once and remembered by device and by kind (other AirPods stand in for chosen ones), so the next recording starts on it; opening the picker and leaving it as it was changes nothing. Picked AirPods that can capture the room (`bluetoothMicrophoneExtension?.farFieldCapture.isSupported`) record it with `.farFieldInput` (iOS 26.2; with `.allowBluetoothHFP`), and a route that won't take it records as before. The recording's notes say each input it used.
  - Notes with recording times and bookmarks, exactly as on the Mac (`TimedNotes`, highlights), in every posture.
  - Photos from the camera at their moment in the recording ([photos](photos.md)).
  - Start, stop, and bookmark from the Lock Screen, Dynamic Island / Live Activity, Control Center, the Action button, and Siri (App Intents).
  - **Live captions while recording.** Tentative, on-device captions, shown like closed captions: from the live models when they're downloaded (local transcription, speakers, and names; "Live transcription", below), else from the Speech framework's `SpeechTranscriber` (volatile results). They prove the audio pipeline is working and give something to read until the transcript arrives, and they are never the transcript: phone-local (`<library>/LiveCaptions/<id>.json`, never synced), never fused, summarized, or used as evidence, and replaced, as on the Mac, by a transcript made after they began (`SavedCaptions.shown`, the rule both apps read): until then they read on the transcript's page, in the transcript's place while there's none, else after an earlier recording's transcript (`SavedCaptionsView`, shared with the Mac), and search finds them; then they're deleted (`LiveCaptionStore`, DaybookCaptions). If the language isn't available, the app says so and recording is unaffected.
- **Calendar.** Settings › Recording › Use Calendar (off by default) reads this iPhone's calendars through EventKit (`PhoneCalendar.swift`, with the Mac's `CalendarMeetings`; docs/capture.md, "Calendar"). Turning it on asks for full access to events, then whether Daybook may post notifications. Refused, or taken away in Settings since, the page offers Allow Calendars in Settings. Events are read on this iPhone and never leave it; only a meeting's title is kept, as its conversation's title.
  - A recording started here (Record, the Lock Screen, Siri) is named after the meeting going on, or starting within 10 minutes, that the person hasn't declined and isn't all day. A Mac's request keeps the Mac's title.
  - A meeting with other people sends a notification as it starts: its title, "Starting now · 4 people. Tap to record." Tapping it, or its Record, opens Daybook, which starts recording once it's in front (iOS starts the microphone only there), named after the meeting. One arriving while Daybook already records isn't shown.
  - iOS doesn't let an app look at the calendar as each meeting starts, so the reminders are scheduled ahead (`remindMeetings`): the next 20 meetings within two days, in place of those scheduled before, whenever Daybook comes to the front or leaves it, the calendar changes while it runs, and on each background refresh. A meeting moved or added while Daybook hasn't run since is reminded of at its old time, or not at all, until then.
- **Library.** Places (All, Work, Personal), folders, tags, search (titles, notes, transcripts, summaries), Trash, and multi-select, drawn with the Mac's list rows, results, empty places, and Trash rows (DaybookUI's `Library/`; docs/interface.md, "Window structure"). Its chrome is the same on one page and two (`LibraryChrome`): the place's menu is the title, "All Conversations ⌄", leading in every place, the Trash too (the system's inline title moves between leading and centred with what the bar holds, and its large inline form shows no chevron and doesn't fit a long name beside More and Settings); More (⋯: Select Conversations, New Folder…, Devices) and Settings trail it, each its own glass; and the toolbar at the foot holds Record (a wide capsule with the red dot, in its own glass), the system's search, and New (+: New Note, Import Audio…). Search is the one entry the system gives (`DefaultToolbarItem(kind: .search)`, minimized): its button in the toolbar, and while it's used the field there, at the thumb above the keyboard; the results start with the scopes, as on the Mac. Above the toolbar, only while there's something to say, the status strip says it (Status sheet, below). The Trash has no toolbar: nothing records into it or searches it. A row's menu, its swipes, and the selection bar offer what `ConversationActions` lists for an iPhone (a selection: Summarize, Move, Tags, Work or Personal, Trash). An empty library that this install's first sync pass is still bringing in says "Getting your conversations…" with a spinner, then "No Conversations Yet" if it's still empty. Open on the Duo, a tap shows a conversation on the right page, and Open (with the open book, beside Info and More) or a second tap on the row opens it across both pages. Beside the Trash, the right page shows one of its conversations read only with Restore, the newest until another is tapped, as the Mac's page beside its Trash. The list's rows, search's results, the Trash's rows, the shown row's wash, and the strip above the toolbar keep clear of the crease. New Note starts a conversation that's only your notes (and any photos), titled "Note at 10:15 AM", as on the Mac. Its byline says "Notes only", as on the Mac, and the page offers Record, which records into it; the recording joins after the notes.
- **Reading.**
  - The summary page: lede, next steps, sections, your notes, bookmarks, colophon. Its blocks are the Mac's, from DaybookUI (`ConversationHeader`, `StatusBlock`, `SummaryBody`, `YourNotes`, `Colophon`): the same words, order, and behaviour, at the iPhone's size. A title or a bookmark label is saved once editing ends, and an emptied title puts the old one back; ticking a next step, editing a label, deleting a bookmark, and Don't Wait can be undone (shake, or three-finger swipe), each on its own item, as on the Mac.
  - The transcript: speakers, times, tap to play.
  - Audio playback that downloads on demand, in the player both apps draw (DaybookUI's `PlayerBar` over DaybookKit's `PlaybackEngine`): the buttons on a row and the scrubber under them, with the time played and the time left ("−12:03") at its ends and, of several recordings, which one plays; a safe-area bar, so the page fades hard under it. The recorder owns the audio session: once a recording starts, however it starts, the player pauses, takes its card off the Lock Screen and Control Center, and stops answering their buttons and headphones' (`PlaybackController.follow(recording:)`, `suspendForRecording`); nothing plays and the session's category isn't touched until the recording is filed. The Lock Screen shows the title and when it was, never who was there, and a Personal conversation as "Daybook conversation".
  - The More menu lists what DaybookKit's `ConversationActions` lists, in the Mac's order and words, leaving out what doesn't apply now: Copy Summary (it says "Copied" for a moment), Share ▸ Markdown, Full Data (JSON), Audio; Take Photo, Add Photos…, Add Recording… (from Files, into this conversation); Reprocess ▸; Version History…; Move to Folder…, Tags…, Move to Work or Personal; Move to Trash…. Info and More are glyphs in title ink, like the back chevron (the open Duo's spread draws its back button the same way).
  - A sheet that only shows (Info, Version History, Details, Settings) closes with the system's close button (×); one that edits keeps its words (Cancel, Save). On the open Duo a reading sheet goes on the right page and leaves the left page as it was ("iPhone Duo", below); it closes with its close button, a swipe down from its grabber, or VoiceOver's escape.
  - Version History, with restore.
- **Editing that syncs.**
  - Notes, title, next steps, speaker names, and transcript passage corrections. A speaker named here teaches its speaker profile on the Mac, which labels the same voice in other conversations; profiles and their voiceprints sync as library settings ([sync](icloud-sync.md#speaker-profiles)). In Info › People, a speaker the Mac labelled reads Recognized with Not <name>, and one it's unsure of Maybe <name> with Yes and No, as in the Mac's inspector; the Mac acts on the answer when it arrives. Info is the Mac's inspector (DaybookUI's `ConversationInfoForm`), with each row's symbol, where each recording's audio is ("On this iPhone", "In iCloud · 12 MB"), and a recording's Move to New Conversation and Remove Recording…; a tag shows its conversations, and Version History replaces Info.
  - Folders, tags, Work/Personal placement, the template choice, and bookmarks during playback.
  - Typing and handwriting in the same notes, in a conversation, while recording, and after Stop ([Handwriting](#handwriting)).
- **Processing requests.** Transcribe, Summarize Again, a template change, Identify Speakers Again, and Transcribe Everything Again are all available. On the phone they become requests: this iPhone carries out those for its own recordings when it has the models ("Processing on this iPhone"), and a Mac the rest (see below).
- **Templates and vocabulary.** Browse and edit them; they sync as library metadata. Summary Templates and Vocabulary are the Mac's screens (DaybookUI's `TemplatesScreen` and `VocabularyScreen`; [templates](templates.md), [interface](interface.md)): a template's editor saves as you type, and Delete Template… (also the row's swipe) is confirmed; a term from a conversation is used only there until Used In says All conversations, and deleting one is Delete Term…, confirmed. Every vocabulary change undoes with a shake. Settings › About is the version, the privacy statement the Mac shows, and Acknowledgements: the models this iPhone can use (live captions' and its own processing's) and those behind the library's results, then the software it ships with each license and notice (`AcknowledgementsScreen`, the Mac's too).
- **Devices.**
  - Soundcore Work over Bluetooth from the phone, which is usually the device in your pocket.
  - Other recorders through Files.
  - A recorder's page, its recordings, Listen Live, its handoff, and adding one are the Mac's screens, in the same order and words (docs/devices.md, "Interface"): on paper with 20 pt gutters, the page's actions as tiles straight on it, its menu as the bar's ellipsis. The page pushes Details, Listen Live (from its Listen Live tile and Recording now), and All Recordings, where a recording swipes to Import or Add to “…”.
- **Multipoint.** When the Mac records, the phone can record too, and the reverse. Recordings join one conversation through the existing multipoint pipeline.
- **Settings.** iCloud (sync, the library's devices, encryption), Macs and pairing, recorders, recording, storage, templates, vocabulary, speaker profiles, and About. Speaker Profiles is the Mac's window as screens (DaybookUI's `SpeakerProfileList` and `SpeakerProfileDetail`): the profiles, and for each its name (another profile's name offers Merge Into <name>), its voiceprints (swipe to remove), Forget Learned Voiceprints…, its conversations (one closes Settings and opens on the page), Merge Into, and Delete Profile…. Deleting a profile (also its row's swipe, never a full swipe), removing a voiceprint, and forgetting what a profile learned ask first with what they cost, and can be undone. Every row has its symbol on a neutral tile in one column (teal while a Mac or recorder is connected), and each device page opens with the same header: tile, name, status. In the hand it's a sheet. Open on the iPhone Duo, where a sheet would be a card centred across the crease, it takes the display as two pages, as pairing does (`settingsSheet`): the list on the left, the chosen screen (iCloud at first, Add Recorder too) on the right. Folded shut while shown it's one column; shown in the hand and then opened, the sheet splits into the same two pages at the crease (`SheetCreaseSplit`). What a Settings screen shows over itself (Add Term and Edit Term, the encryption sheets, Details) is a sheet in the hand and, open, a sheet on the right page clear of the crease (`pageSheet`), as the reading sheets are; it closes with a drag down on its grabber and with VoiceOver's escape. A form with changes to lose (`guardingDismissal`) can't be swiped or dragged away, and its Cancel asks first (Discard Changes, Keep Editing).
- **File protection.** Recording segments, the capture journal, photos taken while recording, and live captions are `completeUntilFirstUserAuthentication`, like the library. `completeUnlessOpen` was weighed and kept out: it lets a locked phone create files and keep writing ones already open, but not reopen a closed one, and Daybook reopens its own closed files while locked in everyday use. Stop from the Lock Screen, Siri, or a Mac reads every segment back to assemble the recording (`RecordingAssembler` opens even a single clean segment to check it) and copies the result into the library; an interruption closes one segment and opens another, so both are read at Stop; filing reads the photos taken while recording, and recovering after a quit reads the journal; and live captions reread their file to keep its track. Under `completeUnlessOpen` each of those fails until the phone is unlocked. Finished library items stay at the same class because background sync reads them while locked.
- **Backups.** iPhone backups (iCloud and computer) never hold copies Daybook can rebuild: the courier's inbox and outbox (`Sync/Inbox`, `Sync/Courier`; iCloud Drive carries the same files), audio downloaded for playback, imports being copied in, and `Documents/Inbox` (`BackupExclusion`, applied at launch and after each download). The library itself goes in unless Settings › Storage › Include in iPhone Backups is off (default on), which keeps the whole library folder out, for someone who doesn't want recordings in a backup, with or without sync.
  - The Recent Conversations and Next Steps widgets' rebuildable app-group snapshot cache is excluded regardless of the library backup setting.
  - **An encrypted library** (this iPhone syncs it encrypted, waits for its key, or synced it so before; docs/icloud-sync.md, "Encryption") keeps its conversations, Trash, sync state, and saved captions (`Meetings/`, `Trash/`, `Sync/`, `LiveCaptions/`) out of backups by itself, and its settings with them: folders, templates, vocabulary, and the speakers' names and voiceprints (`library.json`, `glossary.json`, their recovery copies, and any damaged copy kept aside). The sealed journal in iCloud is their backup (settings as settings versions), and an iPhone backup isn't encrypted end to end unless Advanced Data Protection is on. Every save replaces a settings file, and the mark belongs to the file, so each save marks its new file before renaming it into place (`LibraryController.excludesSettingsFromBackup`); applying the rules marks what's there again. Recordings in progress (`Staging/`) and recorder state stay in. The same toggle, Include in iPhone Backups, then shows a choice of its own, off by default (`includesEncryptedLibraryInBackups`); turning it on includes the library again. How the two combine: a plaintext library follows the first choice as before; an encrypted one is included only when its own choice is on; otherwise, if the first choice is off, the whole library folder stays out as before, and if it's on, only those four folders and the settings do. A choice made for the plaintext library never carries over as on, so turning encryption on doesn't leave plaintext in backups because of an old setting; someone who wants an encrypted library in their backups turns it on again. Applied at launch, when either choice or the library's encryption changes, and after each sync pass.
  - *Why out by default.* Without Advanced Data Protection, Apple holds the keys to an iCloud Backup, so a backup with these folders and settings in it would hand Apple, in plaintext, exactly what the library's encryption keeps from it; the sealed journal already restores them to a new or erased iPhone. Recordings still being made (`Staging/`) stay in, since they aren't in iCloud yet. What remains is a narrow window: a conversation recorded or edited on this iPhone that hasn't reached iCloud (iCloud Drive off on cellular, or offline) when the iPhone is lost. The courier usually has a recording on the Mac within seconds, and iCloud Backup runs on Wi‑Fi, when iCloud Drive uploads too. Keeping such conversations in backups until they're uploaded was weighed and left out: it would put plaintext into the backup during exactly that window, which is the choice Include in iPhone Backups already offers.
- **Export.** Markdown, the full data (JSON), and audio through the share sheet, named after the conversation by DaybookKit's `ExportFiles`, which the Mac's Share menu uses too. Copy (a passage, a summary line, Copy Summary) stays on the device that copied it, on the Mac too: never Universal Clipboard (`LocalPasteboard`). Exports wait in `tmp/Daybook Export/` only until the share sheet is done with them, and anything left there is cleared at launch. A file another app opens in Daybook (iOS copies it to `Documents/Inbox/`) is removed once it's imported; a failed import keeps it.

**Not possible on iOS, by design**
- Recording another app's call audio. iOS has no per-app or system audio capture, so on a call the phone records its own microphone only. The Mac records the call.
- Noticing a call in another app. CallKit's `CXCallObserver` says only that a phone or VoIP call is under way, not in which app or for which meeting, and only to an app that's running; its audio couldn't be recorded anyway. So the iPhone asks by the calendar (Calendar, above), and the Mac asks when a call starts (docs/capture.md, "Calls").
- Recording cellular calls. Third-party apps can't. Importing iOS call recordings (saved to Notes) through the share sheet is a later addition.

## Processing on the Mac

A conversation's processing state comes from its data and is shown the same way on both platforms (`ProcessingStatus` in DaybookKit), in the words and boxes the Mac's page uses (DaybookKit's `ConversationStatusPresentation`, drawn by DaybookUI's `StatusBlock` on both apps):

| State | Meaning | Phone shows |
|---|---|---|
| **Recorded** | Audio with no transcript yet; no request yet | "Not transcribed yet" with Transcribe, in a box. Everything except transcript and summary works |
| **Requested** | A `ProcessingRequest` is in the library, waiting | "Waiting for your Mac", or "Waiting for Studio Mac" when one is around; under it "Last seen 2 h ago", "Studio Mac is recording", "Studio Mac is working on another conversation", "Needs iCloud", or "No Mac has synced this library yet. Open Daybook on your Mac." Cancel takes back a request this iPhone made that no device has started (nothing goes to Version History) |
| **Requested, this iPhone could do it** | Its own recording, Transcribe on This iPhone on, its models not downloaded, and no Mac around | "Download models to transcribe this conversation" with the size and Download; then "Downloading Parakeet · 40%" with Cancel. The processor takes the request once they're in |
| **Requested, nothing can summarize** | A summary with no Mac ever seen, no summarizer here, and no cloud key | "Needs your Mac to summarize" (no clock: nothing is coming until a Mac turns up) |
| **Processing** | A Mac claimed it | "Transcribing on <Mac name> · 40%" (live over the local link the moment the Mac starts, before sync brings its claim; coarse over sync), whole percents rounded down |
| **Transcribed** | A transcript with no summary, and nothing asked for one (a summary stopped partway, say) | "Not summarized yet" with Summarize, on both apps. The list row shows its preview |
| **Waiting for a recording** | A Mac's audio is transcribed and summarized; a recorder that recorded along hasn't been added yet ([multipoint](multipoint.md#mac-first)) | "Waiting for audio from Soundcore Work" on the page, with Don't Wait (it stops waiting on every device; the recording is still added if it arrives); "Waiting for Soundcore Work audio" in the list |
| **Done** | Transcript and summary present | Normal page |
| **Couldn't finish** | The Mac reported a failure | What it means in plain words, naming the device ("…on Studio Mac", "…on this iPhone"), ending "The recording is saved."; the fix (Try Again, which writes a new request), and the device's own reason behind Details. A cloud summary that couldn't run is titled "Couldn't summarize with Claude Sonnet 5.5", with the cloud's own sentence; Cloud Settings… for a key, credit, or model, Try Again only when it was offline or busy, and Summarize on This iPhone (with its own summarizer) or Use Your Mac |

- **Requests travel in the library.** A `ProcessingRequest` (meeting, mode, template, requested by, when) is synced metadata, like an edit. Recording on the phone requests **Transcribe** automatically.
- **Requests run on a Mac.**
  - A Mac with models claims a request, records the claim (so two Macs don't both run it), runs it through its normal queue (pause, cancel, missing models), and writes the result and its status back.
  - Stale claims expire, and the claim survives the Mac going to sleep.
- **On a Mac nothing changes.** New audio that arrives through sync is processed as it is today; requests only make the phone's intent explicit and visible.
- **The phone never fakes progress.** If no Mac is paired or has been seen, the state says so plainly.

### Where summaries run

The iPhone places its summaries with the Mac's planner (docs/multipoint.md, "Where summaries run";
`PhoneSummaryPlacement`, `model.placement`), from what it can offer: its own summarizer (`localSummarizer`, a
`LocalSummarizing` from its processing models, while Transcribe on This iPhone is on), the Macs that summarize and
are reachable now (connected over the link, or seen through sync in the last 15 minutes, by their
`ProcessingCapabilities`), and the cloud model Settings › Cloud resolves to (`cloud`, the app's `CloudSetup`, whose
preferences give the policy and the countdown; docs/cloud.md, "For callers").

| Moment | The page says | Then |
|---|---|---|
| Its own transcript is ready (`summaryIsDue`), a Mac is reachable, a key is set | "Summarizing on Vlad's MacBook Pro in 12 s" · Use the Cloud · Start Now | A Summarize request, nudged to the Mac |
| The same, with its own summarizer | "Summarizing on this iPhone in 12 s" · Use the Cloud · Start Now · Wait for a Mac | Summarized here by the processor, with a claim |
| No Mac reachable, a key is set | "Waiting for a Mac to summarize" · Use the Cloud | A countdown when a Mac arrives |
| Use the Cloud | "Summarizing with Claude Sonnet 5.5" · Stop | Summarized in the cloud, with a claim |
| A Mac counts down to it (over the link) | "Summarizing on Studio Mac in 12 s" · Use the Cloud · Start Now | The choice goes to the Mac |
| Summarize, Summarize Again, a template, with no Mac reachable and a key | "Waiting for a Mac to summarize" · Use the Cloud | The request waits for a Mac; Use the Cloud takes it |
| No key | As before | A request for a Mac, at once |

The list row says "Summarizing in 12 s" or "Waiting for a Mac to summarize", the Mac's status line, in the library's
strip, counts down too ("Studio Mac · Summarizing in 12 s"), and the status sheet's Macs card lists it under the Mac it counts down to (or
on its own while it waits), with the same choices. A first summary waiting for a Mac says "Waiting for your Mac to
summarize"; Summarize Again's, "… to summarize again". In the
background, where a countdown can't run, each countdown's default happens as the app leaves the screen, and a
summary waiting for a Mac is left to one through the library. The colophon says where a summary ran, with the
model and the date, as the Mac's does (DaybookKit's `SummaryColophon`): "Summarized on your Mac" (a summary that
doesn't say), "on Studio Mac", "on this iPhone", or "with Claude Sonnet 5.5"; its glyph is the device's kind (an
iPhone, a MacBook, another Mac, the cloud).

How it's wired (`PhoneAppModel.wireProcessing`): the processor hands each conversation it fused to the placement
(`Services.summaryDue` → `summaryIsDue`, or `summarize` for work the person asked for); the placement hands a summary
placed here back to the processor (`runHere` → `PhoneProcessor.summarizeHere`); `localSummarizer` is
`PhoneModels.summarizer()` while Transcribe on This iPhone is on, set again when a processing model is downloaded or
removed or that setting changes (`processingChanged`); `cloud` is set at launch and read again when Daybook comes
back. A summary that's due is held in the library from the start (a Summarize request this iPhone claims and keeps
through the countdown or the wait for a Mac), so killing Daybook never strands it: the next launch places it again
(`resumeHeldSummaries`), and if this iPhone never comes back, a Mac takes the request once its lease runs out. A
conversation that goes away (a Mac moved its recording into its own conversation of the meeting, and this one went
to the Trash) ends its countdown, its cloud run, or its summary here.

### On the Mac

The queue is `AppState`'s (`AppState+Requests.swift`); each change to a request is one of `ProcessingRequest`'s pure functions, saved like an edit.

- **Pick up.** After every sync pass, every finished job, a model download, a phone's nudge, and at launch, the Mac queues each open request it may take (unclaimed, its own, or with an expired claim), when **Transcribe synced recordings on this Mac** is on and it has the models that request needs. Otherwise the request stays unclaimed, except one that brings a recording the conversation was waiting for, which is taken whatever that setting says ([multipoint](multipoint.md#mac-first)). One job per conversation: a job already queued or running for it (new audio that arrived with it, say) carries the request, and finishes it.
- **Claim when it starts.** The claim (10-minute lease) is taken when the job starts, not while it waits, so the phone reads "Waiting for your Mac" until work begins and a Mac busy with a long job leaves the request to another. A request another device holds is never run; its job is dropped.
- **Heartbeat.** While the job runs, the claim is renewed with its stage and fraction at every change of stage and every minute. Sync passes keep running while a request runs (they wait for local work, as before), so the heartbeat and coarse progress reach the phone; the conversation being processed is protected from a remote deletion or status, as a recording is.
- **Finish.** The request is completed, or failed with the Mac's reason, which `ProcessingStatus` shows on both devices. Any other open request the work satisfied is completed too, so statuses agree everywhere.
- **Pause, Cancel, models.** Pause and Cancel give the claim back (the lease ends now) and keep the conversation paused on this Mac, so it isn't claimed again at the next pass; Resume claims it again. Missing models leave it unclaimed.
- **Two Macs.** If both claim before either has synced, the merge keeps the newest claim on both. The Mac that sees it lost stops its job at that pass, without pausing it or touching the request, and the other finishes it. Until then both work, for at most one sync round.
- **Stale claims.** A claim whose lease ran out (a Mac that vanished) is claimable, and claiming it starts a strictly newer claim that wins every merge. Claims are never cleared outright: the merge keeps the newest claim, so a cleared one would come back from the other copies at every pass.
- **Sleep and quitting.** A Mac that sleeps keeps its claim and renews it on waking, unless another Mac took it over meanwhile (then it stops). Quitting cancels processing, which gives claims back; they're published at the next launch's first pass, or simply expire if the Mac never returns. A Mac that crashes mid-claim runs its own claims again at launch.
- **No requests for its own work.** The Mac's own captures, imports, and menu commands write no requests: its queue is live on the Mac, phones see it over the link, and a request per job would double every job's sync traffic. It only completes requests its work satisfied.
- **Presence.** The sync controller publishes `SyncReplicaConfiguration.mac(displayName:canProcess:)`. `canProcess` is true when the models automatic processing needs are installed and the Mac transcribes synced recordings; it's updated whenever models are installed or removed, or those choices change, and the link's capabilities follow.
- **Status lines.** The list and conversation page read `ProcessingStatus`; while the Mac carries out another device's request they add "Requested from Alex's iPhone".
- **Live progress.** While any conversation is processed, connected phones get `processing.progress` at every change of phase (queued, aligning, transcribing, identifying speakers, summarizing, then finished, paused, failed, or waiting for models) and as the fraction moves. A `processing.nudge` makes the Mac sync at once.

## Processing on this iPhone

Once its processing models are downloaded, the iPhone processes its own recordings with the Mac's engine (`InferenceProcessingEngine` through the `ProcessingEngine` seam, DaybookIntelligence): transcription, speakers, voice profiles, the background-audio check, fusion, speaker labels from the synced profiles, and a summary where it has the memory for one. Every transcript, speaker run, and summary records the exact model that made it, as a Mac's do.

- **Models** (docs/models.md, "iPhone processing"), by the iPhone's memory:

  | iPhone | Transcription | Speakers | Voice profiles | Summaries |
  |---|---|---|---|---|
  | 4 GB (iPhone 11 to 13) | Parakeet Redux, 220 MB | Nemotron 3 · Compact, 102 MB | Community-1, 22 MB | none |
  | 6 GB (iPhone 12 Pro to 15) | Parakeet Ultra, 632 MB | Nemotron 3 · Compact | Community-1 | none |
  | 8 GB (15 Pro, 16, 17) | Parakeet Ultra | Nemotron 3, 199 MB | Community-1 | Gemma 4 E2B, 3.58 GB, where it fits |
  | 12 GB and more (17 Pro, Air, 18 Pro, Duo) | Parakeet Ultra | Nemotron 3 | Community-1 | Gemma 4 E4B, 5.18 GB, else E2B |

  A summary model is offered only where its measured peak (E2B 3.2 GB, E4B 5.0 GB, weights included) and a gigabyte for the app fit in what iOS lets Daybook use, read as the app runs (`PhoneMemory`: `os_proc_available_memory` plus what it uses already). By published figures that's a little under half the phone's memory, about seven tenths with the Increased Memory Limit entitlement, which the app doesn't have yet: without it an 8 GB iPhone summarizes nothing and a 12 GB one gets E2B; with it, E2B and E4B. The simulator never summarizes (MLX can't use its graphics).
- **Settings › Models** opens with Processing: Transcribe on This iPhone (on by default; off, recordings wait for a Mac as before) and Download with the size of what transcribing needs, then per role (Transcription, Speakers, Summaries) the model (a menu where there's a choice), its size and state, and Download, Cancel, or Remove, through the live models' background downloads, Wi‑Fi rule, and checks (each processing model is checked by its own engine). The summary model downloads on its own, being gigabytes. Where none fits, Summaries says "Needs an iPhone with more memory". The voice-profile model comes with the speaker model rather than as a choice of its own; it's the one model live captions and processing share. The Settings row counts what transcribing still needs, the figure Welcome offered ("852 MB to download"; live captions' models keep their sizes inside Models), and reads "Transcribes on this iPhone" once that's here. Welcome's Ready line says "It’s transcribed once the models download on Wi‑Fi." while the download waits for Wi‑Fi.
- **Who does what** (`OnDeviceProcessing`, under the `ProcessingRequest` claims a Mac uses):
  - Recording on the phone still writes Transcribe. When this iPhone can carry it out, the request is claimed in the same save that files the recording, so a Mac that receives the recording sees the claim and leaves it (`isHeldElsewhere`, `pickUpRequests`).
  - It runs only requests it made, and transcribes only recordings made or brought in on it: its microphone's (by device identity) and its imports and recorder transfers (listed beside the library in `brought-in-recordings.json`). A Mac's recording is the Mac's. It transcribes with speakers and voice profiles, as the Mac does, or not at all.
  - A Mac never transcribes again what the iPhone transcribed: its jobs only transcribe recordings without a transcript. A better model elsewhere redoes one only when the person accepts an "Upgrade" offer (docs/multipoint.md, "Upgrade"), which `ProcessingCapabilities.models` makes possible.
  - Fusion runs where the last recording arrives. The iPhone fuses when every recording of the conversation is transcribed and on the timeline (its own recording, alone). A recording made with a Mac waits to be lined up by its sound, which the Mac does: the iPhone transcribes its own and gives the request back, and the Mac places, fuses, and summarizes.
  - Before summarizing, the iPhone labels the conversation's speakers from the synced profiles (that conversation only; the Mac reconciles the rest), so the summary has their names.
  - Once fused, its Transcribe request is done here and the summary goes to the placement ("Where summaries run", above): a countdown when the cloud is on offer, then this iPhone, a Mac (a Summarize request, "Waiting for your Mac to summarize"), or the cloud. One placed here runs as the processor's own work on the Summarize request the placement claimed (`summarizeHere`; `LocalSummarizing`, filled by `LocalSummarizer`: the Mac's summary pipeline on MLX), under the same rules as the rest: on the screen, one at a time, backing off, never beside a recording, after the transcription models are let go. It records where it ran ("Summarized on this iPhone") and proposes its terms for the vocabulary.
  - The claim is renewed with the stage and fraction at each stage and every minute, and kept through a pause. One that lapses (the iPhone away longer than the 10-minute lease) is a Mac's to take, and the iPhone stops as soon as a sync pass shows one has (`reconcileClaims`).
- **When it runs** (`PhoneProcessor`): one conversation at a time, after a recording or import is filed, after sync passes and model downloads, and when Daybook comes back. Never beside a recording: starting one pauses the work and releases its models, and nothing starts until it's filed. The live speaker pass gives way to it. It backs off as live captions do: Serious heat, Low Power Mode, or a battery under 20% unplugged pause it until they pass.
- **In the background:** work started on the screen asks for iOS 26's continued-processing task (`BGContinuedProcessingTask`, `ContinuedProcessing`: one request per job, `local.daybook.phone.processing.<UUID>`, failing at once rather than queueing; on iOS 27 sent with `submitTaskRequest`, whose answer comes a moment later), whose Live Activity shows the stage and the work's own progress; transcription goes on under it with Daybook out of sight. The speech and speaker models run on the Neural Engine and CPU (`MLComputeUnits.processing`), which iOS allows in the background. Where the system declines the task, or ends it, the work pauses, keeps its claim, and resumes when Daybook is back. A summary runs on the GPU (MLX), which iOS doesn't give a background app without the Background GPU Access entitlement, so it waits for the screen, and stops the moment Daybook leaves it, before iOS would refuse its GPU work.
- **Status:** "Transcribing on this iPhone · 40%", "Waiting on this iPhone" (claimed, its turn next), and "Paused" with when it goes on ("Continues when Daybook is open", "… when iPhone cools down", "… when Low Power Mode is off", "… when iPhone is charging", "… after the recording"), from this iPhone's queue (`ProcessingStatus.phone`). A Mac reads the claim: "Transcribing on Alex's iPhone". The status sheet says it in a line of its own while there's work ("This iPhone  Transcribing · 40% · 1 waiting", "This iPhone  Paused · Continues when iPhone is charging", in the words a Mac's Floating Notes home uses for its own queue, `QueueStatusWords`) and lists it in the This iPhone card; the Macs card leaves it out.
- **Upgrade:** a conversation whose transcript, speakers, or summary a clearly better model within reach could redo says so on its page ("Upgrade transcript on Vlad's MacBook Pro", "Upgrade summary with Claude Sonnet 5.5", or "Upgrade transcript" when this iPhone's own models are the better ones and the recordings are its own), with Upgrade and Dismiss (`PhoneUpgrades`; docs/multipoint.md, "Upgrade"). Debug builds show it with `--library-demo --upgrade-demo mac|here|cloud|waiting --select "Weekly product sync"`.
- **Capabilities:** `PhoneAppModel.processingCapabilities` says what this iPhone can do now (`ProcessingCapabilities`: transcribes and finds speakers once the transcription, speaker, and voice-profile models are downloaded; summarizes once a fitting summary model is; `models` names each), for the summary step and other devices.
- **Size and memory** (October 31, 2026; unsigned Release archive): the app grew from 23.1 MB (10.6 MB zipped) to 43.1 MB (16.2 MB zipped), the binary from 20.9 to 38.6 MB, mostly MLX and mlx-swift-lm; MLX's Metal library is 2.3 MB. Linking DaybookIntelligence as the Mac builds it would have made 46.0 MB: leaving WhisperKit and MLXVLM out saves 2.9 MB. In the simulator, transcribing a 3-minute recording with Parakeet Ultra, Nemotron 3, and Community-1 peaked at 165 MB of physical footprint (Core ML maps the weights from their files) and took 60 s on the CPU; the summary models peak at about 3 GB (E2B) and 5.0 GB (E4B) on a Mac, which is why they need the memory checks above.
- **Needs the account owner:** the Increased Memory Limit capability (`com.apple.developer.kernel.increased-memory-limit`) for local summaries on 8 GB iPhones and E4B on 12 GB ones, and Background GPU Access (`com.apple.developer.background-tasks.continued-processing.gpu`) for summaries that go on in the background. Neither is in the entitlements yet.
- **Limits:** recordings made with a Mac are lined up, fused, and summarized there; a phone recording made alone and transcribed here still finds a Mac conversation of the same meeting when a Mac first sees it, and moves there with its transcript (docs/multipoint.md, "With Daybook on iPhone"), after this iPhone may already have summarized it; before a local summary, photos are read with Apple Vision alone (text, what they show, near copies), since a vision model's captions are the Mac's. Still to check on a real iPhone: the Neural Engine's speed and battery for a long recording, the continued-processing task (whether iOS grants it after Stop, how it shows, when it expires), the memory limit `PhoneMemory` reads with and without the entitlement, and a Gemma summary's time and peak on a phone.

## Architecture

```text
DaybookCore         (macOS + iOS)  models, storage, sync journal, fusion, alignment, echo DSP
DaybookKit          (macOS + iOS)  LibraryController: library state, edits + revisions, search,
                                   sync controller, recording ingest, ProcessingStatus,
                                   ProcessingRequest queue, ProcessingEngine seam
DaybookDevices      (macOS + iOS)  device framework, Soundcore (BLE, protocol, crypto, Opus)
DaybookLink         (macOS + iOS)  Mac <-> iPhone local-network channel: pairing, control, status
DaybookCaptions     (macOS + iOS)  the one live-caption protocol and the Speech framework's captioner:
                                   iPhone recordings, the Mac's You/Call capture, and hardware live
                                   audio (Soundcore live listening). Depends on Apple frameworks only.
DaybookModelStore   (macOS + iOS)  the model store: verified downloads and installs
DaybookLive         (macOS + iOS)  live captions from local models (FluidAudio): streaming
                                   transcription, speakers, and names, behind DaybookCaptions' protocol
DaybookIntelligence (macOS + iOS)  FluidAudio, MLX, and (Mac only) WhisperKit: the processing
                                   engines and ProcessingEngine, for the Mac's queue and the
                                   iPhone's own recordings (without Whisper and photo captions)
Daybook             (macOS app)    AppKit/SwiftUI app, capture, Mac UI
Apps/iOS            (Xcode, via XcodeGen)
  DaybookPhone          iPhone app (SwiftUI)
  DaybookPhoneWidgets   Live Activity, Control Center controls, widgets
```

- **One kind of model.** The shared controllers (DaybookKit's library, sync, handoff, and placements; DaybookDevices' hub, sessions, and connections) are `@Observable`, as the phone's own models and the player are. A view reads them directly, through the app model or not, and redraws for what it reads: a Listen Live caption redraws the caption strip, never the device list. Nothing mirrors them or counts their changes; what isn't a view follows them with `ObservationWatch`.
- **After Stop.** `PhoneAppModel.lastFiling` says where the recording went once Stop (or a recording that stopped on its own) has filed it: `.saved(conversation, when)`, or `.failed(sentence)` when it couldn't be added yet (it's kept and added the next time Daybook opens).
- **Processing seam.**
  - `ProcessingEngine` (in DaybookKit) takes a meeting and its transcribable tracks and returns transcripts, speakers, and a summary. Both apps implement it with DaybookIntelligence's `InferenceProcessingEngine`: the Mac's queue, and on the phone `PhoneProcessor` for its own recordings ("Processing on this iPhone").
  - Without the processing models, the phone's requests wait for a Mac as they always did.
- **Sync through Daybook's iCloud container.**
  - Both apps use one ubiquity container, `iCloud.local.daybook` (configurable through `DAYBOOK_ICLOUD_CONTAINER`). The journal lives at `<container>/Documents/Daybook`, read through `DaybookICloudContainerIdentifier`. There's no folder to pick: signing into iCloud is all it takes.
  - The container is hidden from the Files app.
  - The journal format is unchanged (`docs/icloud-sync.md`).
  - Macs that synced through a chosen folder move to the container once. The journal is content-addressed, so the copy is safe and idempotent. The old folder is left untouched.
  - The phone uses an **on-demand audio** policy: meetings, transcripts, and summaries apply immediately; audio blobs download only for playback, and can be evicted.
  - Phone recordings upload as blobs like any other source.
  - Requires signed builds with the iCloud capability on both apps (same team, same container). Unsigned development builds and tests keep the folder transport, which is never offered as the product setup.
- **Courier (CloudKit).**
  - The iPhone also sends every file a pass writes (the recording, its events, library metadata) through CloudKit, in the same container's private database. It does so right after a recording is filed, under the same background-task assertion as that pass.
  - The Mac stores them in its courier inbox, applies them in a pass, and deletes them from CloudKit, usually seconds after the recording is filed, on any network.
  - iCloud Drive still carries everything, and the courier never writes into the container. The courier is off in builds without CloudKit, without an account, or when CloudKit refuses; sync then works as before.
  - A send that's stuck for 15 minutes shows in the sync line ("Waiting to send 2 items to your Mac"). iCloud refusing what this iPhone sends for lack of storage, by iCloud Drive or the courier, shows at once ("iCloud storage is full"), ahead of what waits to upload, as on the Mac. See `docs/icloud-sync.md`, "Courier (CloudKit)".
- **Local link.**
  - When both are on the same network, DaybookLink (Network.framework, Bonjour, TLS with a pre-shared key from pairing) carries what iCloud is too slow for: start and stop for multipoint, live recording state, bookmarks, and live processing progress.
  - Without it, everything still works through sync, just later.
  - A paired Mac may start this iPhone's microphone from the moment it's paired: recording on one device starts every device connected to it (docs/multipoint.md, "Starting anywhere"). The choice stays per Mac, visible and switchable on that Mac's page in Settings › Macs (Can Start Recording); it belongs to that pairing (pairing again turns it on again), and the pairing sheet no longer asks. Turned off for a Mac, every start that Mac asks for is refused as `declined`, as the Mac's Can start recording does for this iPhone's starts; the Mac shows the sentence only for a start the person chose there, and doesn't ask on its own once this iPhone has told it (`record.permission`). A Mac whose Record along with this Mac was off for this iPhone in an earlier build asks it once to keep that off, and Can Start Recording for that Mac turns off. A stop from that Mac's page (Stop on iPhone) is taken while it's on; a Mac's stop of a recording it shares with this iPhone always is.
  - A Mac's page (Settings › Macs, and inside the status sheet) is the page the Mac shows for this iPhone (`PeerDevicePage`, docs/link.md, "A paired device's page"): its status, Pair Again… when it no longer recognizes this iPhone, which side to update when their versions don't meet, Open Settings when Local Network is off for Daybook and it isn't connected (its row then says "Local Network is off"), what it's recording with Stop on it when it would take it, the recorders it manages, Can Start Recording, its facts, and Unpair…. Pairing is the shared screen too ("What both devices show"): a Mac with another library open is listed dimmed, and a refused Local Network permission says so with Open Settings.
  - Starting here asks every connected Mac to record too, and starts the recorder this iPhone manages; a recorder's own button starts this iPhone (or, in the background, where iOS won't start the microphone, saves the recorder's audio and says so). Notes and bookmarks made on either device during a shared recording appear on the other at once.
- **What goes where.**

  | What | iCloud Drive (`<container>/Documents/Daybook`) | CloudKit courier (private database, zone `Courier`) | Local link |
  |---|---|---|---|
  | A phone recording (its audio object) | Always | From the iPhone, up to 50 MB, until a Mac stores it (at most 7 days) | No |
  | Conversations, edits, requests, library settings (events and metadata) | Always | From the iPhone | No |
  | Transcripts, speakers, summaries from the Mac | Always | No | Live progress only |
  | The manifest and presence (`daybook-sync.json`, `Devices/`) | Always | Never | Capabilities |
  | Recording control, live state, bookmarks during multipoint | No | No | Yes |
  | Courier bookkeeping (`Sync/Courier/`, `Sync/Inbox/`) | Never (local only) | No | No |

- **One live-caption engine.** Every live caption, whatever the source, goes through `DaybookCaptions`' captioner protocol, from the live models (DaybookLive) when they're downloaded and the Speech framework otherwise:
  - the phone's microphone;
  - the Mac's microphone and call audio, captioned separately as You and Call, with lines the microphone only heard from the speakers suppressed;
  - any recorder that streams live audio: Soundcore live listening, which replaced chunked WhisperKit previews (docs/devices.md, "Listen Live captions"), and a recorder recording along with a shared recording;
  - during a shared recording, the phone's captions on the Mac, sent over the local link.
  Captions are always tentative feedback, never the transcript, which the processing models make (this iPhone's or a Mac's).
- **The phone is a device to the Mac.** "Daybook on iPhone" is a `DeviceKind` with two methods: *direct* (DaybookLink, with record control) and *files* (sync). The existing multipoint coordinator, matcher, aligner, and fusion treat its recordings like any other source.
- **One Bluetooth owner per recorder.** A Soundcore is managed by the phone or by a Mac, never both at once. Ownership is a synced device setting; the other side shows "Managed by iPhone" and gets the recordings through sync. **Use on This iPhone** / **Use on This Mac** move it in one tap, in seconds over the local link and through sync otherwise ([devices.md](devices.md), "Handing a recorder over").

## Live transcription

When the live models are downloaded, the iPhone captions recordings, and a recorder's Listen Live, with them instead of the Speech framework: local streaming transcription, speakers told apart as they talk, and names for voices that match someone's voice profile (docs/model-runtime.md, "Live"). They're still live captions: tentative, phone-local, never synced or used for anything else. The transcript, its speakers, and the summary come from the processing models ("Processing on this iPhone", or a Mac's).

- **The models** (docs/models.md, "Live models"): Nemotron 3.5 ASR Streaming · Latin (588 MB; English, Spanish, French, Italian, Portuguese, German, about 1.25 s behind) or the multilingual build (615 MB, 35 languages, about 2.5 s); Nemotron 3 · Live for speakers (102 MB, up to eight, about 3 s behind); Community-1 for voice profiles (22 MB, the Mac's model, so its profiles name speakers here). About 712 MB in all.
- **Settings › Models** (`ModelsSettingsScreen`, from `PhoneModels`): per role, the model (a menu where there's a choice), its size and state ("Not downloaded · 588 MB", "Waiting for Wi‑Fi", "Downloading · 40%", "Downloaded"), and Download, Cancel, or Remove (confirmed with what it frees); Download All with the total while anything chosen is missing; and Download over Cellular, off by default. The Settings row reads "Live transcription on this iPhone" or the size left to download.
- **Downloads** go through the Mac's store and checks (`ModelStore`): pinned commits, every file's size and digest, an atomic install. They transfer in background `URLSession`s (`BackgroundModelFetcher`, one download task per file from Hugging Face at the pinned commit), so they go on while the app is suspended, or after iOS ends it, in the system's own process. Each download holds a background-task assertion (`BackgroundAssertion`), so files that finish just as the app leaves the screen are checked and installed; it ends when the install does or when iOS's time runs out, whichever comes first, and never twice, and an install the time cut short carries on when the app comes back. They start on Wi‑Fi (`NetworkConditionMonitor`: not expensive, not Low Data Mode), wait for it otherwise, and stop when the phone leaves it; a task on the Wi‑Fi session itself never uses cellular, a hotspot, or Low Data Mode (`allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` off), and Download over Cellular uses a second session that may. A download stopped partway (cancelled, Wi‑Fi gone, an error) keeps what it fetched as the system's resume data beside the file and continues from there, so the 566 MB encoder no longer starts again. After a relaunch the sessions are made again, which reconnects their tasks: the models that were downloading (`phone.liveModels.downloading`, and any file a session still has in flight) carry on and show as downloading, and files that finished while the app was away are checked and installed. When iOS relaunches the app for a session's events, `PhoneAppDelegate` hands them to the downloads (`handleEventsForBackgroundURLSession`).
- **Settings › Cloud** (`CloudSettingsScreen`, from DaybookKit's `CloudSetup`, the Mac pane's model): each provider's key (masked, or Add Key, a screen that checks a key before keeping it, with Replace Key and Remove Key), when summaries use the cloud and the countdown, the quality tier with its recommended model and what an hour costs, Model, and Effort ([cloud](cloud.md#settings)). Keys are in iCloud Keychain, shared with the Mac; the preferences are this iPhone's own. The Settings row reads the resolved model, "Never", or "Off" with no key.
- **Storage:** `Application Support/Models`, the Mac's layout, excluded from iPhone backups (it can be downloaded again). Settings › About › Acknowledgements lists the models this iPhone can use beside the models behind the library's results (`ModelAcknowledgements.entries`, the Mac's rule too).
- **What runs:** `PhoneModels.captioner` asks `LiveCaptioners` for each recording and Listen Live: the local recognizer when it's downloaded and covers the captions' language (Settings › Recording › Live Captions), another downloaded recognizer that covers it, else the Speech framework; speakers on top when the speaker model is downloaded; names when the voice-profile model is too and the library has named speakers with voice profiles. The local recognizer is biased toward the library's approved vocabulary, which syncs from the Mac (docs/model-runtime.md, "Live"). Simulator demos (`--synthetic-audio`, `--device-simulator`, `--demo-captions`) never load models.
- **Memory:** the models load when a recording starts, on the Neural Engine and CPU (never the GPU, which a locked phone can't use), and go when it ends. A phone with less memory than the recognizer suggests (6 GB; a 4 GB iPhone 12 or 13) isn't offered it and keeps the system's captions; speakers and names still work there.
- **Battery and heat** (`PhoneLiveConditions`, `LiveLoadPolicy.iPhone`): speakers stop in Low Power Mode, at Serious heat, or under 20% unplugged; captions stop altogether at Critical heat or under 10% unplugged, and resume, with a gap, when that passes. A recognizer that falls behind sheds speakers first, then drops the oldest audio; the recording never waits.
- **In the background** (a pocket recording, the screen locked): words and speakers both go on, the speakers at a lower cadence (the speaker model hears four seconds at a time, and voices already named aren't embedded again), so captions saved from a pocket have speakers. Before this the iPhone policy shed speakers whenever the app was out of sight; that was Daybook's choice, not a limit of iOS.
- **Every source.** A recorder this iPhone manages recording along is captioned from its live audio (`LiveCaptureCaptions`), its lines joining the phone's by time and labelled with the recorder, without the ones that repeat what the phone heard (`LiveCaptionMix`). During a shared recording with a Mac that shows them, the phone sends its captions (its own and its recorder's) to that Mac over the local link, a second at a time and only what changed (`CaptionShare`, `LinkCaptions`), where they join the Mac's (docs/capture.md, "Every source"). They're still live captions: never synced. Its input level goes to a Mac that draws it (`liveLevels`) the same way: its meter's readings, a few at a time about five times a second, never queued behind other messages (`LevelShare`, `LinkLevels`), so the Mac's Floating Notes meters this iPhone beside its own microphone.
- **Names.** Wherever captions show (the recording screen, the status sheet's Listen Live, and the Live Captions page that stands in for the transcript), the person live speakers recognized is named before their words, as on the Mac; a voice nobody's profile matched isn't labelled.
- **Labelled afterwards.** Captions the speaker model didn't hear (shed for battery or heat, or the model failed) are saved marked, and labelled from the filed recording when the app is next in front and not recording (`LiveSpeakerPass`; docs/model-runtime.md, "Live"). The open Live Captions page reads them again when that finishes.
- **What iOS allows.** An app recording audio in the background (`UIBackgroundModes` audio, an active recording session) keeps running with the screen locked. Apple documents that background apps can't use the GPU (Metal work submitted from the background fails); the live models load on the Neural Engine and CPU only (`.cpuAndNeuralEngine`), which have no documented background limit, and the words recognizer already ran there in the background. Once a recording ends the app has no audio session and is suspended within seconds, so the pass afterwards waits for the foreground rather than asking for background time (a `BGProcessingTask` runs at the system's discretion, usually on power, and isn't used). How the Neural Engine is scheduled for a background app, and what the lower cadence saves in battery, still need a phone (docs/validation.md).
- **App size:** the iPhone links DaybookLive and DaybookModelStore (FluidAudio and swift-transformers' Hub). An unsigned Release build for a device grew from 27.1 MB to 44.8 MB (October 29, 2026), most of it FluidAudio. Linking DaybookIntelligence for processing added 20 MB more ("Processing on this iPhone").

## Handwriting

Typing and handwriting go in the same notes, and either can follow the other at any moment. The editor is DaybookUI's `MarginNotesEditor`; the ink is in `Notes/NotesInk+UIKit.swift` and `NotesInk+TextView.swift`.

- **Writing.** Apple Pencil writes on the page past the last paragraph with nothing to switch on, and the tools come up once it has. Write by Hand lets a finger write too, puts the keyboard away, and takes two fingers to scroll. Keyboard, or tapping into the words, goes back to typing. Over typed words, Scribble (where the device has it) writes into them as usual.
- **In the column.** A block of ink is one paragraph, between typed paragraphs, with its recording time in the lane. It moves with the text, and a narrower column (the Duo folding) draws it scaled to fit, never enlarged. Ink doesn't float over the words, which is what keeps it whole across the Duo's two widths and Dynamic Type.
- **Words.** PencilKit's `PKStrokeRecognizer` (iOS 27) reads the strokes a moment after the writing pauses, on this device. It works from the strokes, so the appearance doesn't matter. Where it can't read them (iOS 26, a language it doesn't take), Vision reads a picture of the ink, always drawn dark on white: `PKDrawing.image` draws for the current appearance, so in Dark Mode it would be white on white. A block's menu has Convert to Text, Copy Text, and Delete, each undoable.
- **In the notes.** `NoteInk` (DaybookCore) is the strokes. Its paragraph in `Meeting.notes` holds the words read from it, or "Handwriting" until there are any, and its ID is that paragraph's `TimedNote.id`. So search, summaries, exports, and the Mac read ordinary words and needed no changes; on the Mac handwriting appears as those words, not as ink. A correction typed there is kept unless later strokes read differently.
- **Storage.** The strokes travel inside the conversation, like the notes (`Meeting.ink`): no separate file to download, and no state where text has arrived and its ink hasn't. While recording they're in the capture journal, so a recovered recording keeps them. Merging keeps every copy's blocks and the newer strokes of a block both changed. Merging picks one copy's notes whole, so a block whose paragraph lost that choice goes back at the end of the notes rather than being stranded. A deleted block keeps only a marker, so an older copy can't bring it back.

## iPhone Duo

Confirmed in the iOS 27.1 SDK: SwiftUI `onHingeChange { old, new in }` gives `DeviceHinge` (status `.closed`, `.partiallyOpen`, `.fullyOpen`, and `angle`). UIKit has `UIHingeInteraction`. Measure both displays in the iPhone Duo simulator before fixing layout constants.

| Posture | What the app becomes |
|---|---|
| **Closed** (outer 5.4") | *Pocket recorder.* One-handed. A large Record control at the thumb, the recorder's status, and recent conversations. Reading is one column, including when the cover is turned sideways; it never becomes the cramped two-page notebook. |
| **Open flat** (inner 7.6") | *Notebook.* Two pages split at the crease, never across it. Library, then conversation. In a conversation, the summary is on the left and the transcript on the right, linked: tapping a next step or bookmark scrolls the transcript to its evidence, and playback follows on the right. While recording: notes on the left; the recorder's sheet at the foot of the right page, with the captions or the bookmark log above it. |
| **Partly open on a table** while recording | *Table mode*, in landscape (flex mode): the phone is turned a quarter, hinge horizontal, the bottom half flat and the top half standing. The top half shows live captions in large type with the elapsed time and level, readable from across the table. The bottom half has large Bookmark and Stop targets, Write Notes, and the camera. Writing, the notes take the standing half and the keyboard the flat one; it doesn't dim until Done. Dimmed between interactions to save battery: a slow dim, a quick wake, a short fade under Reduce Motion. A touch anywhere wakes it; while it's dimmed that touch reaches Bookmark, never Stop or Write Notes. It keeps the screen on while Daybook is in front (Auto-Lock would otherwise lock a phone nobody touches), until ten minutes pass without a touch. |
| **Folding or unfolding** | Context carries over: unfold while reading a summary and the transcript opens beside it; fold mid-recording and the pocket recorder takes over without interrupting anything. |

The playback bar stays on the transcript page. On the unfolded Duo its glass card has a paper backdrop, so transcript text doesn't show through the controls; one-column playback keeps its existing glass treatment.

An open conversation's spine is a passive 24 pt context rail: a thin timeline with amber ticks for
bookmarks on the effective placed timeline and a mint playhead for the loaded player (including while
paused). Its extent is the furthest unified-transcript or placed-recording end; explicitly unaligned
source bookmarks are omitted, and unplaced sources have no invented bookmark or playhead position.
The rail appears only on the conversation spread, not its library preview or while a reading or share
sheet is open. It has no hit targets or separate
VoiceOver elements; the pages and their player remain the interactive controls. Only timeline numbers
are derived for the rail, with no content, audio, or transcript copied or persisted.

**The library across the spread.** The left page is the library as the 18 Pro draws it, in its own navigation
stack: the place's menu, More, and Settings at the top, and the same toolbar at its foot, Record, search, and New, the
list scrolling under it with a hard edge, and the status strip above it. Nothing on the page nests a stack of its own
(the status tray once did, and its stack hid the page's bar). Every sheet on two pages goes on the right page, clear
of the crease, and leaves the left page as it was: one card drawn on that page (`PageCard`: the panel radius,
`secondarySystemBackground`, a dim over its page only, a grabber to drag it away, VoiceOver's escape). The status
sheet, Info, Version History, Move, Tags, and what a Settings screen shows over itself all use it; Settings itself and
pairing take the display as two pages. iOS 27's `presentationPlacement(.trailing)` was tried for a system sheet there
(Duo, iOS 27.1): it aligns a form sheet about 650 pt wide to the display's trailing edge, across the crease, keeps its
detents, and dims both pages, so the card stays. The bars' items keep the system's margin, about 20 pt from the crease.

The reading column's crease-side inset is the full 16 pt clearance, not an addition to the normal
20 pt page gutter. Library row words and the selected-card wash use the same 16 pt clearance.
Controls, the player, recorder, and sheets keep their 24 pt clearance.
The left page ignores the display's far-right safe-area inset after splitting at the physical crease, so the status-bar reservation cannot create a second gutter inside that page.

**While recording**, every posture shows the recorder Floating Notes shows on the Mac (DaybookUI's `RecorderSurface`, in `Recording/UI/RecordingSurface.swift`'s `RecorderScreen`; docs/interface.md, "Floating Notes"): the phase, a chip for each recorder and Mac recording along ("Soundcore · 80%" and "Studio Mac" with the red dot, "Not recording" in warning ink when one asked to record along didn't start; a connected Mac's menu offers Record on Studio Mac Too), the clock, a meter for the microphone and for each recorder recording along, your notes in the editor the page uses (bookmarks and photos as ticks in its lane), live captions, and Bookmark and Stop. The camera, the live timeline, and the bookmark log are the iPhone's own. In the hand and on the open Duo the recorder is one sheet at the foot (`RecorderSheetSize`), with your notes above it in the hand and, on the open Duo's right page, the captions or the bookmark log above it; open it never crosses the crease and its largest size takes the page. Four sizes: mini (one row: the phase, the clock, a small meter, a glyph-sized Bookmark and Stop; Resume replaces Bookmark while paused), collapsed (the phase, the clock beside its meters, Bookmark and Stop; a pause's box in place of the meters), expanded (the whole recorder), and full (the whole recorder, the live timeline, and the bookmark log). It rests at the posture's size (mini open, on its side, and on the closed Duo's landscape cover; collapsed upright in the hand) and comes up one step at a tap on its grabber; a drag follows the finger and lands on the nearest size. A size the person chooses stays through folds and turns; dismissing it (the tap at full, a downward flick from any level, a drag that lands at or below rest, or VoiceOver's escape) returns it to rest, and rest is as small as it goes. The keyboard shows it as one row, above the keyboard, without changing that size; a notice keeps it at least collapsed. Debug launches can open at a level with `--recorder-sheet mini|collapsed|expanded|full`. After a Stop seen on it, the recorder stays about ten seconds (longer while you write): Saved with the conversation's length (the checkmark drawn on, and the hand feels whether it saved), what's becoming of it in a chip, in its library row's words ("Transcribing · 40%", "Waiting for your Mac"), as the Mac's panel says it, its title and notes, Open, and Keep Recording, which records into the same conversation after what was saved, so a Stop pressed by mistake doesn't split a meeting in two. It follows the Mac's rule (DaybookUI's `RecordMore`; docs/interface.md, "Floating Notes", After Stop): held past two minutes by writing, it reads Record, for a new conversation, and after a recording that stopped on its own it reads Record Again, into the same one. A recording that couldn't be added says so for the same ten seconds, with Record; its notice stays over Record in the library. Then the library comes back.

Accessibility: Dynamic Type, VoiceOver order across both pages, Reduce Motion for posture transitions, and everything reachable with one hand when closed. At the accessibility text sizes Bookmark and Stop keep their glyphs (and Bookmark its count) with their names in the large content viewer, the recorder's header holds its size and the captions keep only their newest line (none while paused) so the notes keep at least two lines, and each note's time sits on a line of its own above it rather than in a lane. As recording starts VoiceOver is told the screen changed and starts on the clock; a pause, a resume, a silent microphone, a notice, and Saved are announced.

### Measured

Measured in the iPhone Duo simulator (iOS 27.1, 24A94425; model iPhone19,4) with the phone app's `--log-geometry` probe, which records the window, safe area, screen, and hinge on every change. Both displays are @3x and 460 ppi.

| Posture | Display | Points (window) | Pixels | Safe area (top, left, bottom, right) | Size classes |
|---|---|---|---|---|---|
| **Closed** | Cover, 5.4" (screen ID 1) | 466 × 678, portrait | 1398 × 2034 | 0, 0, 34, 84 | compact width, regular height |
| **Partly open** (about 99°) | Inner, 7.6" (screen ID 3) | 951 × 669, landscape | 2853 × 2007 as shown (a 2007 × 2853 panel mounted at 270°) | 0, 0, 34, 84 | regular, regular |
| **Open flat** (180°) | Inner | 951 × 669, landscape | the same | 0, 0, 34, 84 | regular, regular |

- **The status bar is a column on the right edge** in both displays, beside the sensor bar. That's the 84 pt right inset; there is no top inset. The home indicator takes the bottom 34 pt.
- **The crease** runs down the inner display's middle, at x = 475.5 pt of the 951 pt window, *not* at the middle of the safe area (433.5 pt). Two pages split at the crease are 475.5 pt (left) and 475.5 − 84 = 391.5 pt of safe area (right). The system adds no inset for the fold, so the app has to keep content off it.
- **Corners:** the cover's spine side (left) is nearly square (8 pt radius) and its outer side round (59 pt); the inner display is 55 pt all round.
- **Partly open and open flat have identical geometry.** Only the hinge status and angle differ, so layouts key off the posture, not the window size.
- **The app moves between displays live**, without relaunching: the window becomes 951 × 669 or 466 × 678 and the scene's screen changes. For a moment during the move the safe area reads top 82, right 0 before it settles, and `UIHingeInteraction` reports no hinge (`hinge == nil`); `DevicePosture` keeps the last posture through that gap.
- **Hinge reports:** angle 0–180° (`UIHinge.angle` in radians, π when flat), about 20 reports per fold. `.fullyOpen` from about 175°. The switch between `closed` and `partiallyOpen` (and between displays) happens partway through a fold and isn't at a fixed angle: one sweep from closed went `partiallyOpen` at 23° and closed again at 49° on the way back; others held `closed` past 100° when opened in steps, or `partiallyOpen` down to about 70° when closed from flat. Key layouts off the status, not the angle. SwiftUI's `onHingeChange` reports every change but not the posture at launch; `UIHingeInteraction` reports both, so `HingeObserver` uses the two together.
- **The simulator boots closed:** the cover is lit and the inner display is black. With the device open, the cover is black.

**Folding the simulator.** This Xcode (27.1, 27A9275) has no Simulator.app and `simctl` has no hinge command. Xcode's DeviceHub app has a hinge slider for this device, unverified with CoreSimulator devices. What works from the command line is SpringBoard's private display tool service, through `Apps/iOS/Tools/duo-fold/duo-fold.sh <udid> closed|book|open|<0.0–1.0>`, which spawns a small entitled helper inside the simulator. It's private SPI, simulator-only, and may break with any runtime update. Screenshots: `xcrun simctl io <udid> screenshot --display=1` (cover) or `--display=3` (inner); the display not in use is black, and images follow the interface orientation.

## Status sheet

What the recorders, the Macs, this iPhone's own work, and iCloud are doing (`DaybookPhone/Status/`). It speaks only
of what exists and, at rest, only when there's something to say (docs/interface.md, principle 2). The words come from
`StatusSheetModel`, plain values from plain inputs, so tests read what each state says; a recorder's line is in the
words both apps give a recorder (`RecorderStatusWords`), this iPhone's in the words a Mac's home gives its own queue
(`QueueStatusWords`). The views are the status overview both apps share (DaybookUI's `StatusOverview`,
docs/interface.md).

**Which lines exist.** As on Floating Notes' home: a line for each recorder added ("Connected · 80% · 2 new",
"Recording · 80%", "Importing 1 of 3", "Managed by Studio Mac", a handoff under way); one for each Mac paired over the
link ("Connected", "Recording now", "Last seen today, 9:12 AM", "Not set up to transcribe"), whatever sync says, and for
the Mac the library synced with in the last 30 days or that's doing this iPhone's work ("Transcribing · 40%" with the
gradient line, "Connected · 2 waiting", "Summarizing in 12 s" counting down); this iPhone's while it has work of its own
("Transcribing · 40% · 1 waiting", "Paused · Continues when iPhone is charging"); and iCloud's only while it's a problem
("Signed out", "iCloud storage is full", "Sync paused"). With no recorder there's no recorder line, with no Mac no Mac
line, and up to date or syncing iCloud has none. The three lines the compact sheet once always showed, fine or not, so
Record wouldn't move under the thumb, are gone: Record is the toolbar's, and nothing here moves it.

**The strip.** One line above the library's toolbar, on one page and two, only when one of the lines has something to
say (`StatusSheetModel.strip`), in this order: what needs the person, in warning ink ("iCloud · Signed out"); what's
recording elsewhere, with the red dot ("Studio Mac · Recording"); what's working, with the gradient line ("Studio Mac ·
Transcribing · 55%"), or counting down. Otherwise there's no strip: a connected recorder, an idle Mac, and a queue
paused until it can continue say nothing at rest. It's the line's own words, ink, and progress line on glass, the
panel radius, with a chevron (at the accessibility sizes the words take the chevron's room). Tapping it goes where its fix is: iCloud's to Settings › iCloud, a recorder's problem to
its page, a paired Mac that can't connect to its page, a Mac not set up to transcribe (or one that couldn't finish) to
the sheet's Macs card; any other line shows the sheet. While everything is calm, More › Devices shows it.

**The sheet.** Titled Devices, with the system's close button. In the hand an ordinary sheet, at medium and then large,
dismissed as any sheet is; open on the Duo, a card on the right page ("iPhone Duo"), the left page in reach. It doesn't
repeat the strip's lines: each card's header says what they did. Top to bottom, only what exists:

| Group | What it shows |
|---|---|
| **iCloud** | Its line, while it's a problem (no card says it), opening Settings › iCloud |
| **Live captions** | While a recorder streams (`DeviceSession.liveCaptions`, tentative), first |
| **Recorders** | A card per recorder added: its tile, name, and status opening its page, then its handoff as a row (Use on This iPhone / Use on Studio Mac, progress, Take Over Anyway). At large it adds its storage to its status ("About 2,170 hours left"), its actions as one row of equal-width buttons (Connect, Record or Pause on Soundcore, Import N New, Listen Live or Stop Listening: only what can be done now, never a disabled button), and the recordings waiting on it with Import, then All Recordings. No card when there's no recorder: Add Recorder… is in Settings |
| **Macs** | While there's a Mac or work for one. Every paired Mac as a row opening its details, and one the library synced with lately ("Not set up to transcribe" in warning ink with "Finish in Daybook › Settings on Studio Mac." under it, when it isn't); the queue as rows under the Mac doing it (summaries counting down or waiting for a Mac first, with their choices: "Summarizing in 12 s" · Use the Cloud · Start Now; then running with progress, waiting oldest first with "Requested from this iPhone", then conversations waiting for a recording made alongside, "Waiting for Soundcore Work audio", oldest first and not counted in the Mac's "2 waiting", then what couldn't finish in the last seven days, with the page's plain sentence, Try Again, and the Mac's words behind Details; never "No speech in this recording", which its row and page say; the Mac isn't named again). Work no Mac has taken yet starts at the card's edge. Pair with Your Mac… last, while none is paired. A row opens its conversation, and the sheet goes |
| **This iPhone** | Its queue in the same rows while it has work (running, a summary counting down to it, waiting, paused and why, what couldn't finish here), and the audio kept on it ("1.2 GB of audio", as Settings says it), opening Storage |

Links open the full screens inside the sheet (the device page, a Mac, Settings › iCloud, Storage), in its own
navigation stack, never copies of them; a screen opens with the sheet at full height. A recorder's notification
(imported, almost full) opens the sheet at its page. Debug builds open the sheet with `--status-detent medium|large`,
at a screen with `--status-open device|mac|storage|icloud|add-recorder`, as a line's tap would with
`--status-choose mac|sync|recorder`, and show this iPhone's work without models with
`--status-demo phone-working|phone-paused`.

**While recording** there's no strip: `RecorderScreen` replaces the library and already shows the recorder's
essentials (clock, level, bookmarks, captions); during a call there's one thing on screen (docs/interface.md,
principle 1), and table mode needs the whole display.

Every status card has the same quiet fill, 16 pt radius, and 12 pt padding (DaybookDesign's `StatusCard` and
`StatusRow`); symbols sit in a column that grows with Dynamic Type so text in sibling rows lines up.

Accessibility: the strip is one element ("Studio Mac, Transcribing · 55%") with what tapping it does ("Shows more",
"Opens iCloud settings", "Shows how to fix it"); its glyph column grows with Dynamic Type up to 44 pt and its glyph up
to accessibility 2, and at the accessibility sizes its title takes up to two lines and its words the rest of four, the
strip growing to hold them, so nothing is drawn over or cut to a letter. Record stops growing at the toolbar's size,
and a long press shows its label in the large content viewer. The sheet's content scrolls at both sizes, and Reduce
Motion drops its animations; a countdown's digits fade rather than roll.

*Superseded (2026-11-10):* the standing sheet with a compact detent (Record, Import, and Search at the thumb above
three or four lines, its height measured from the fonts up to 55% of the screen) and the open Duo's combined tray on
the left page. They covered a quarter to a third of the list, said "None added" and "Hasn't synced this library yet"
of things that weren't there, and the tray's stack hid the left page's bar.

## Lock Screen, widgets, and the control

What they show comes from the app, which can stop at any moment (a crash, the system ending it, a
background relaunch that never reaches `launch`), so each says what it can still vouch for:

- **The recording's Live Activity** has a rolling stale date (90 s while recording, two hours while
  paused) that the app refreshes at least once a minute while it records. Stale, it says "Open
  Daybook to check", with no running clock and only Stop. On the Lock Screen it names the conversation
  under its state; a Personal one (Keep Recording into it) is never named: its activity's title is
  "Recording", and the line is left out (`RecordingActivityController.activityTitle`).
- **Recorder widget and the Control Center control** read `SharedRecordingState`, which carries `asOf`; the
  app writes it at least once a minute while recording (`SharedStatePublisher`). The timeline adds an
  entry where an unconfirmed recording turns into "Open Daybook to check", and the control is on only while
  it's confirmed. Paused, the clock is frozen ("Paused · 12:03"). The Recorder's Lock Screen sizes are unchanged.
  At rest it names the newest conversation Spotlight may list (`ConversationIndex.isShown`), never a Personal
  one, and follows the library: a conversation made Personal leaves it at once (`PhoneAppModel.lastRecording`).
- **Recent Conversations** is a Home Screen widget: small opens the latest conversation, medium lists three,
  and large lists six, each linked to its own page. An empty widget opens the library; a conversation
  deleted or not yet synced here also returns there. Like Spotlight, it excludes Trash and conversations
  whose placement or detected kind is Personal; an unclassified conversation can appear until classified.
  Once the library has loaded, the app publishes at most six IDs, titles, and dates to an app-group file
  and asks WidgetKit to reload when those rows change.
- **Next Steps** is also Home Screen only. Small opens the conversation of the first unfinished action;
  medium shows up to three and large up to six, grouped by conversation, with each row linked to that
  conversation. Actions come from summaries, newest conversation first and in summary order within each
  conversation. The same Personal and Trash exclusions apply. After the library loads, the app publishes
  at most six conversation IDs, titles, dates, and action texts, and reloads only when those rows change.
- **New Note** is a data-free shortcut in the small Home Screen, circular Lock Screen, and inline Lock
  Screen sizes. Its single tap opens `daybook://new-note`, routed to the existing New Note destination,
  which waits for the library and creates a fresh note without starting a recording.
- **Widget snapshots.** Recent Conversations and Next Steps share a file-backed app-group cache
  (`SharedWidgetCache`), not the library or EventKit. Each snapshot file and its directory are excluded
  from backups regardless of the library setting; an unexcluded or unreadable snapshot isn't used.
  The cache is separate from library encryption. No notes, transcript, audio, action owners, or other
  summary contents go to the widgets. The last good snapshot remains until the app loads or updates the
  library; WidgetKit controls when a reload appears. Before a snapshot is available, the widget asks
  the person to open Daybook.
- **Every launch** clears a recording state and activities an earlier run left (`App.init`).
- **Privacy.** Conversation titles and Next Steps action texts are `privacySensitive`: redacted when the
  system hides sensitive widget content. Recent Conversations and Next Steps have no Lock Screen sizes.
  New Note carries no library data. Spotlight lists every conversation but Personal ones by its title,
  with its date as the description (`ConversationEntity.attributeSet`), as the Mac does; never what was said.
- **On the Watch and in CarPlay** (the small family, `supplementalActivityFamilies([.small])`) the
  recording shows what it's doing, the clock, and Bookmark and Stop as glyphs; Soundcore Work's shows
  its state, the clock, and Stop Listening. Neither names the conversation. On iOS 27, when the Dynamic
  Island is narrower than usual (`isDynamicIslandLimitedInWidth`), the compact clock says whole
  minutes ("12m").
- **Live caption.** While live captions are on and showing for the recording, the activity adds a
  line with the newest caption (`ContentState.caption`): at most 80 characters, ending with the newest
  words, two lines on the Lock Screen and one in the expanded Dynamic Island. A new caption alone
  updates the activity at most every 5 seconds (`captionInterval`), within the system's update
  budget; one going away (captions off, paused) goes at once. What was said is `privacySensitive`,
  hidden while locked, and isn't shown at the dimmed Always-On brightness, paused, or once the
  activity is stale. Locked, the activity carries no caption at all: `activityCaption` gives one only
  while `isProtectedDataAvailable`, and the protected-data notifications update the activity, so once
  the iPhone's data is locked (seconds after the lock) what was said reaches neither the Lock Screen
  nor anywhere the system mirrors the activity (a Watch, CarPlay, a Mac's menu bar), whatever each
  does with redaction.
- **Soundcore Work** gets its own Live Activity (`RecorderLiveActivity`) for Listen Live (with Stop
  Listening) and for a recording this iPhone started on it: live while connected, "Recording · as
  of 10:07 AM" after it lets the recorder go, and "Open Daybook to check" once that's 20 minutes old. Its updates
  and its end reach ActivityKit in the order they were made (`RecorderActivityController`), so an older
  state never lands after a newer one, or after the end.
- Tests (`RecordingSurfacesTests`, `RecorderActivityTests`, `RecentConversationsWidgetTests`,
  `NextStepsWidgetTests`) cover the recording state and timelines, the Live Activity buttons' contrast
  (4.5:1 in light, dark, and Increase Contrast), the recorder activity against the simulated recorder,
  widget snapshot privacy, backup exclusions, publishing, and routing, not pixels.

## Design language

Same system as the Mac (`docs/interface.md`): paper, the Ink scale, Electric Teal, neon used sparingly (mint means playing, the gradient is brand and progress only, amber means bookmarks, red means recording). Use Liquid Glass for controls (iOS 26) and native navigation. Use New York for titles and SF for everything else.

## Phases and ownership

1. **Foundations, in parallel.**
   - *Kits*: DaybookKit (including `ProcessingStatus`, `ProcessingRequest`, and the engine seam), DaybookDevices, and the Mac adopting them.
   - *Sync*: the on-demand audio replica.
   - *Link*: DaybookLink.
   - *iOS shell*: the XcodeGen project, the recorder, Live Activity, controls, and App Intents.
2. **Features, in parallel.**
   - *iPhone library and reading*: the library, the page, the transcript, playback, editing, search, Version History, and Duo two-page layouts.
   - *iPhone recording, devices, and settings*: the recording screens (pocket, notebook, and table postures), Soundcore on iPhone (background BLE, state restoration), the sync folder, pairing, templates, and vocabulary.
   - *Mac integration*: the request queue and claims, iPhone as a device, pairing UI, multipoint with the phone, status to the phone, and Bluetooth ownership.
   - *Signing and iCloud container*: both apps get the iCloud capability. The Mac app moves to Xcode-managed signing (an XcodeGen project alongside the iPhone app, with a Developer ID provisioning profile), and Macs on folder sync migrate to the container once. Registering identifiers and the container on the Apple Developer account is done only with the owner's approval.
3. **Integration and design review** on iPhone Duo and iPhone 18 Pro simulators, plus the Mac.

## Moving to the new app

The iPhone app was `local.daybook.phone`; it's `local.daybook` now, with the Mac app, so one App Store Connect record ships both (docs/release.md, "One bundle ID"). To iOS that's a new app: its files are in a sandbox of its own, and it can't read the old app's.

- **What comes back:** the library, through iCloud (conversations, notes, transcripts, summaries, settings that sync; audio on demand); library and cloud keys, through the shared keychain group and iCloud Keychain; and this iPhone's identity and pairing keys, which the old app kept in `<team>.local.daybook.phone`, a group the new app lists too. So the Mac and the library's other devices see the same iPhone, with its recorders and claims, and pairing isn't needed again.
- **What doesn't:** recordings the old app hadn't synced yet; live captions (never synced); the list of recordings brought in on the old app (imports and recorder transfers), so the new app leaves their transcription to a Mac; this iPhone's own settings (recording, live captions, Transcribe on This iPhone, backups, the cloud's preferences; the keys stay); downloaded models, which download again on Wi‑Fi; and widgets and controls, which are added again.
- **Testers:** open the old app and wait until Settings says it's up to date, so every recording has reached iCloud; then delete it, and install the new one from TestFlight. Don't keep both: they would sync as the same iPhone, each with its own library. The new app notices the old one syncing as this iPhone and says so in Settings › iCloud ("Daybook is also installed as an older app on this iPhone. Delete the older app.") until a day after the old one last synced (docs/icloud-sync.md, "Devices and presence").

The old app could bridge the gap with one last release under `local.daybook.phone`: add the app group `group.local.daybook` to it, and have it write what doesn't sync (recordings not yet uploaded, the brought-in list, its settings) into the group's container, for the new app to read once at its first launch; its models could move there too, saving the download. That needs the group on the old App ID, a release of the old app, and an import in the new one, for a handful of testers. It isn't built: letting the old app finish syncing does the same for what matters.

## Verification

- `swift test` stays green for the Mac and core, with tests for the kits, the request queue and claims, the sync replica policy, and the link (loopback).
- iOS: `xcodebuild test` on the iPhone Duo simulator for kit and app logic, the iPhone's processing with the engines' fakes (`PhoneProcessingTests`). Screenshots with `xcrun simctl io <device> screenshot` in both postures and appearances.
- Still needs a real iPhone Duo and Mac: hinge transitions, background recording across calls and interruptions, Live Activity, Bluetooth with a real Soundcore in the background, local-network pairing, iCloud on-demand downloads, the CloudKit courier (pushes, background sends, cellular), battery and thermals.

Signing: set `DAYBOOK_TEAM_ID` for device builds. The app is `local.daybook`, the same bundle ID as the Mac app (one App Store Connect record ships both: docs/release.md, "One bundle ID"), its widgets `local.daybook.widgets`, with app group `group.local.daybook` and iCloud container `iCloud.local.daybook` (iCloud Documents and CloudKit). The App ID also needs Push Notifications, for the courier, and Hotspot.
