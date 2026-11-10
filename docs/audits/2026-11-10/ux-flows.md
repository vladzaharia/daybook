# UX: every flow on both apps, and the open product decisions

Reviewer lane: first run, recording, after Stop, reading, organizing, devices, sync and cloud, Settings, errors, on the Mac and the iPhone. Walked through the code at `design-pass-2026-11` and the captures in `scratchpad/shots/` (Mac complete; iPhone through `pro-welcome`, `pro-settings-*` at the time of writing). Nothing in the repository was changed.

## 1. Summary

The flows are in good shape after the 2026-11-01 audit: every status the page can be in has words and a way forward, Trash and Undo work on both apps, the iPhone has a real after-Stop moment, search opens at the passage, and errors name what failed and what to do. The large remaining problems are about the **first hour and the first week**, not about any one screen.

The biggest one is that a fresh Mac can't show a transcript until the summary model has downloaded: `ProcessingJob.requiredModelIDs` always includes the summarizer, so the first recording waits for 7.6 GB (16.5 GB on a 32 GB Mac) when the 0.85 GB that transcribes it arrived minutes earlier. A person who added a cloud key and chose "Always" still has to download the local summarizer before anything is transcribed. The iPhone already transcribes without a summarizer, so the two apps disagree about the most basic thing they do.

The second is that the same moment, "the recording ended, record more", has four behaviours. Floating Notes' Record after a normal Stop starts a new conversation. Its Record Again after an unexpected stop records into the same one. The "Recording stopped" notification's Record Again, which is what a person in a call actually sees, starts a new one. The iPhone's Keep Recording records into the same one for 10 s.

Third, recordings that start by themselves (a call, the prompt, a Mac's request, Floating Notes, the menu bar) are filed into whatever place the main window happens to show. They also jump the main window off the page the person was reading.

Fourth, the iPhone's status sheet reports devices the person doesn't have ("Recorder · None added", "Your Mac · Hasn't synced this library yet"), against principle 2. On an iPhone-only setup the summary path ends at "Needs your Mac to summarize", though Welcome promised "Read a short summary".

Of the delegated decisions, two are effectively settled already: the Mac's Settings is now a System Settings–style sidebar, and the pocket library has one search entry. I recommend closing them with small follow-ups. The other three are below with concrete rules.

## 2. Redesign proposals

### P1. Transcript first: a Mac transcribes as soon as it can, and summarizes when it can (L)

**What and why.** Today `ProcessingJob.requiredModelIDs` starts from `[summaryModelID]` and adds the transcription and speaker models (`Sources/Daybook/App/ProcessingPreferences.swift:166-175`). `enqueue` parks the job in `awaitModels` until every one of them is installed (`Sources/Daybook/App/ProcessingQueue.swift:245-254`), and `canProcess` (`AppState.swift:679`) is built the same way. Downloads already arrive in the right order: transcription, speakers, then the summarizer (`ModelRole.known`, `ModelIdentity.swift:37`; `ProcessingQueue.swift:469-483`). The first transcript still waits for the last byte of the largest model.

From the catalog:
- The transcribing set is Parakeet Ultra 0.63 GB, Nemotron 3 0.20 GB, and Community-1 0.02 GB: about 0.85 GB.
- Balanced adds Gemma 4 12B (6.77 GB) on a 16 GB Mac, or 26B A4B (15.64 GB) on a 32 GB one.
- On a 100 Mb/s line that's about 70 s to a transcript instead of 10–22 min. On 25 Mb/s it's 4.5 min instead of 40–90 min.

The first-run message "Start a conversation now. It's transcribed once the models download." (`WelcomeWords.readyMessage`) is honest, but the wait it describes is unnecessary.

It also breaks the cloud path. `summaryOptions` hard-codes `thisDeviceCanSummarize: true` with the comment "a job reaches the summary step only with the summary model here" (`AppState+SummaryPlacement.swift:26-31`). So "Use the cloud: Always" can't spare anyone the multi-GB download.

The iPhone already works the transcript-first way: it transcribes, then places the summary separately (docs/iphone.md, "Where summaries run"). Principle 1, "Afterwards: the gist and the next steps", is better served by a transcript and search in minutes than by nothing for an hour.

**Touches:**
- `ProcessingPreferences.swift:166`: split into `transcribingModelIDs` and the summarizer.
- `ProcessingQueue.swift:240-258`: gate a `.newAudio` job on the transcribing set only.
- `AppState.swift:999-1004`: before `placedSummary`, if there's no local summarizer and no cloud on offer, stop at `.transcribed` and owe a `.summaryOnly` job.
- `AppState+SummaryPlacement.swift:30`: `thisDeviceCanSummarize: processingCapabilities.summarizes`.
- `AppState.swift:679`: `canProcess` becomes "transcribes" for picking up synced audio and requests (`AppState+Requests.swift:58,154,270`).
- The `.transcribed` presentation on the Mac (`ConversationStatusPresentation.swift:450-456`) while the summarizer downloads.
- The download-wait chip in Floating Notes (see P6).

**Result.** After the first call on a fresh Mac, Floating Notes' chip reads "Transcribing · 40%", then "Transcript ready". The page opens on the transcript with search working. Where the summary goes, one bare line reads "Waiting to summarize after the download · 38%". That's `ProcessingWords.waitingHere(.summaryOnly, behind: .download)`, which exists, with the bar. With a cloud key, it adds Use the Cloud. When the summarizer lands, every conversation in that state is summarized in date order, and the line disappears.

Under "Always" with a key, no local summarizer is needed at all. Settings › Models › Summaries can then say "Not downloaded · 6.8 GB" without blocking anything.

**Risks:**
- Upgrade offers must not treat "no summary yet" as an upgrade.
- A phone's Transcribe request completed by a transcript-only Mac must leave a Summarize request open, so the iPhone shows "Waiting for your Mac to summarize" rather than nothing.
- Fusion and speaker labelling already run before the summary step, so nothing reorders.
- Tests: the queue, `ProcessingStatusTests`, placements with `thisDeviceCanSummarize: false` on a Mac.

### P2. One rule for "record more" after a recording ends, on both apps (M)

**What and why.** Four behaviours for one moment:

| Where | Label | Records into |
|---|---|---|
| Floating Notes after a normal Stop (`FloatingSurfaces.swift:123,134`) | "Record" | a **new** conversation |
| Floating Notes after an unexpected stop (`FloatingSurfaces.swift:123,156-170`) | "Record Again" | the **same** conversation (`AppState.recordAgain(into:)`) |
| Mac notification "Recording stopped" (`MacNotifications.swift:163-172`) | "Record Again" | a **new** conversation: `respond(.recordAgain)` calls `state.startRecording()`, and `RecordingNotificationResponse.recordAgain` doesn't even carry the conversation ID |
| iPhone after Stop (`Apps/iOS/DaybookPhone/Recording/UI/AfterStop.swift:39,158,177-181`) | "Keep Recording" | the **same** conversation, for 10 s |

The notification is the path a person in a call meets, because it posts only when Daybook isn't in front. Its "Record Again" splits the call in two, the exact thing the panel's Record Again exists to prevent. docs/interface.md says Record Again "records into the same conversation, after what was saved, so a call cut short isn't split in two."

**Touches:**
- `MacNotifications.swift`: `.recordAgain(UUID)`; respond with `state.recordAgain(into:)` once the library opens.
- `FloatingSurfaces.swift:113-136`.
- `AfterStop.swift`.
- `RecorderAfterStop`'s `recordTitle` docs.
- docs/interface.md, "After Stop".

**Result:**
- After any Stop, for 2 minutes (or until another recording starts), the control reads **Keep Recording** and records into the same conversation, on the Mac's panel and the iPhone alike. After that it reads **Record** and starts a new one, which is the panel's "for the next call" role.
- After an unexpected stop it reads **Record Again** into the same conversation everywhere, the notification included.
- The iPhone keeps its 10 s linger; on the Mac the panel stays, so its label changes when the window passes.

**Risks.**
- A person who stops one meeting and starts the next within 2 minutes gets one conversation. Mitigate by ending the window when the call app's meeting ends or a new calendar meeting starts, which `CallPromptWindow` and `AppState+Calendar` already know.
- `canRecordInto` refuses a conversation that's queued or processing, so Keep Recording must pause or cancel it first, as `recordAgain(into:)` already does.

### P3. Welcome sets up the first week, on both apps (M)

**What and why.** Two promises in Welcome aren't backed by what it sets up.

1. **Mac: calls are only caught while Daybook is open.** "When a call starts" defaults to Ask (`CallPolicy.stored`, `CallPolicy.swift:63-66`), but Open at login is "off until the person turns it on" (`SettingsView.swift:349`; `settings-general-light/General.png`), and Welcome never mentions it. After the first restart, the call prompt silently stops appearing.
2. **iPhone: "Read a short summary. Search every word."** (`WelcomeWords.swift:24`). The iPhone's models page downloads only "Transcription and speakers" (`PhoneModels.swift:213`, `processingMissing` is transcription, diarization, and embedding; `PhoneWelcome.swift:90-95`). An iPhone-only person's first recording then ends at "Needs your Mac to summarize", a line with no action (`ConversationStatusPresentation.swift:450-455`). That holds even on a 12 GB iPhone that can run Gemma 4 E2B (docs/iphone.md table: "12 GB and more … Gemma 4 E4B, 5.18 GB, else E2B").

**Touches:** `WelcomeWindow.swift` (WelcomeReady), `PhoneWelcome.swift` (PhoneWelcomeModels), `WelcomeWords.swift`, and `ConversationStatusPresentation.swift:450-455` with the iPhone's `LocalCapabilities` (it needs a "could summarize after download" fact, as `transcribesOwnAfterDownload` is for transcription).

**Result:**
- **Mac Ready page.** Under Record and Import, a single checkbox row: "Open Daybook at login", on by default only when When a call starts isn't Off. It's the one place an explanation is allowed: "So Daybook can notice calls."
- **iPhone Models page.** Two rows on the card where the phone can summarize: "Transcription and speakers · 850 MB" and "Summaries · 3.6 GB", both checked, the total on the button. Where it can't, only the first row, and the Ready message says what will summarize: "Your Mac summarizes it", or nothing when there's no Mac. Don't promise.
- **Page.** "Needs your Mac to summarize" gains "Download · 3.6 GB" where this iPhone could summarize. Otherwise it stays a bare fact.

**Risks.** A larger first download on the iPhone. It runs over Wi‑Fi by default and lands after the transcription models, so it never delays a transcript. Login items: ask, never add silently (HIG).

### P4. The iPhone's status sheet speaks only about what exists (S–M)

**What and why.** The compact sheet always shows the recorder, Mac, and iCloud lines, "fine or not" (`StatusSheetModel.swift:322-330`). For a person with no recorder it says "Recorder · None added" (`:385-389`; `pro-library-light.png`, `pro-status-large-light.png`). With no Mac it says "Your Mac · Hasn't synced this library yet" (`:441`). The large detent adds a "Recorders · Add Recorder…" card (`StatusSheet.swift:850-851`).

For an iPhone-only person, two of three lines describe things they don't own and read as something being wrong or missing. The Mac's equivalent, the Floating Notes home, shows a line per recorder and paired iPhone that exists, and iCloud only as a problem (docs/interface.md, "Home"). Principle 2: "When everything is fine, nothing reports status."

**Touches:** `StatusSheetModel.lines`, `mostPressing`, `StatusSheet.swift` (StatusRecorders), and the compact detent height in docs/iphone.md's table.

**Result:**
- Lines for each recorder added, each Mac paired or synced in the last 30 days, this iPhone while it has work, and iCloud.
- With no recorder there's no recorder line and no "Add Recorder…" card; Add Recorder… lives in Settings.
- With no Mac ever there's no Mac line. The iPhone's own line covers its work.

The doc's reason for always showing three lines is that Record mustn't move under the thumb. Keep that: compute the compact detent from the person's configuration (devices that exist), so the height changes only when they add or remove a device.

**Risks.** A Mac that exists but never synced (iCloud off on the Mac) loses its nudge. Keep the Mac line whenever a Mac is paired over the link, whatever sync says.

### P5. A recording that starts itself lands in All and leaves the window alone (S)

**What and why.** `startRecording` creates the conversation with `newMeeting(title:)`, whose default `selecting: true` files it into the place the main window shows: Work, Personal, or a folder (`AppState.swift:797-808`). It then sets `selectedID = id` (`AppState.swift:1419-1420`).

That's right for the window's own Record. But every other start goes through the same path:
- an automatic call recording (`AppState.swift:499`)
- the call prompt (`CallPrompt.swift:364,399`)
- the menu bar (`MenuBarView.swift:23`)
- Floating Notes' Record (`FloatingSurfaces.swift:134`)
- the notification (`MacNotifications.swift:171`)
- a recorder that starts (`AppState+Devices.swift:181`)

So a work Zoom call auto-recorded while Personal happened to be selected becomes a Personal conversation, with cloud and filing consequences (see ux-mac-10). And the page the person opened to prepare for the call is replaced by an empty recording page. The iPhone doesn't file by place at all, and one path on the Mac already does it right: `AppState+Devices.swift:179` uses `selecting: false`.

**Touches:** `AppState.startRecording` gets an `origin` (`.window` or `.elsewhere`), and its callers above.

**Result.** From the window, as today. From anywhere else, the conversation is unfiled (All), the selection stays put, and the new row with its red dot appears at the top of the list. Floating Notes is the recording's surface, and its Open brings the page.

**Risks.** Someone who records from the menu bar with a folder open loses the automatic filing. They can drag the row, and Undo-able filing exists.

### P6. Model downloads: one honest line everywhere, and they resume by themselves (M)

**What and why:**
- **Floating Notes shows a wait as a problem.** While the Welcome download runs, a conversation recorded on a fresh Mac is `.requested(.models)`. Floating Notes' chip says "Waiting for models" in attention (warning) tone (`FloatingStatus.swift:122`), and its menu offers only "Open Settings…" (`FloatingNotesView.swift:368-370, 381-383`). The page meanwhile says "Downloading Parakeet Ultra · 40%" with Cancel (`ConversationStatusPresentation.swift:533-537`).
- **A download failure is an alert for work that runs on its own.** It reads "Couldn't Download the Model" / "Check your internet connection and try again." (`ProcessingQueue.swift:452`). Docs/interface.md, "Errors": "Only what the person did raises an alert: work that runs on its own … writes its trouble to the log". The alert has no Try Again and doesn't name the model.
- **One failure cascades.** The next pending model starts at once (`:454-456`), so offline every model fails in turn.
- **Nothing resumes.** The pending list is in memory only (`ProcessingQueue.swift:65`). Quitting, a restart, or a lost connection mid-way leaves the person to find a Download button again.
- **The empty library's line counts per model.** "Downloading Parakeet Ultra · 100%" then "Downloading Gemma 4 · 3%" (`LibraryView.swift:592-599`), so the wait looks done and then starts over. Welcome's Ready page shows the total.

**Touches:** `FloatingStatus.workChip`, `FloatingNotesView` chip menu, `MenuBarStatus`, `ProcessingQueue.download`/`startPendingDownload` (persist `pendingDownloads` in preferences, resume at launch and on `NetworkConditionMonitor` becoming satisfied), `EmptyLibraryView`.

**Result:**
- One phrase everywhere: "Downloading models · 40%", calm, with a bar and the total.
- The chip's menu has Cancel. When nothing is downloading, the chip's menu has "Download · 0.9 GB" first.
- A failed download shows on the page and in Settings › Models as "Couldn't download Gemma 4 · Try Again", and retries by itself when the network returns. No alert unless the person pressed Download just now.

**Risks.** Auto-resume on a metered or hotspot connection. Respect `NetworkConditionMonitor`'s expensive and constrained flags and say "Waiting for Wi‑Fi", as the iPhone does.

### P7. Settings: "Library" means one thing, and everything can be found (S–M)

See the decision for xdev-settings-03 below. The concrete changes:

- The Mac's Library page gains a group with Summary Templates…, Vocabulary…, and Speaker Profiles…, opening their windows. On the Mac today these are reachable only through Settings › Models › Transcription / Speakers / Summaries › Edit… (`SettingsModelsPane.swift:216,330`; `SpeakerProfilesView.swift:28`). The iPhone lists them under a "Library" header (`SettingsScreen.swift:118-130`).
- The iPhone moves Storage into its Library section.
- Settings search keywords (`SettingsView.swift:55-64`) add "Profiles", "Voiceprint", "Glossary", "Recovery Key", "Notifications". Today "Speaker Profiles" or "recovery" find nothing.
- Remove the duplicate "Transcribe synced recordings on this Mac". It's on Models (`SettingsModelsPane.swift:128`) and in Library › iCloud Sync (`SyncSettingsView.swift:81`); keep it in Models.

### P8. Personal stays on this device unless the person says otherwise, per conversation (M)

See the decision for ux-mac-10 below. It touches the shared planner (`SummaryPlacementPlanner`, `SummaryPlacements.update`), `UpgradeOffer` (Upgrades.swift), and the iPhone's Live Activity title (`PhoneAppModel.swift:623,652`), which shows a calendar event's or a Personal conversation's title on the Lock Screen. The Mac's menu bar extra never names a Personal conversation (docs/interface.md, "Menu bar extra"); the Live Activity should say "Recording" for one.

## 3. Findings

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| uxf-01 | high | A fresh Mac shows no transcript until the summary model has downloaded: 7.6–16.5 GB instead of the 0.85 GB that transcribes. The iPhone transcribes without a summarizer; the Mac can't. | `ProcessingPreferences.swift:166-175` (`var models: Set<String> = [summaryModelID]`); `ProcessingQueue.swift:245-254`; `AppState.swift:679` | P1 | L |
| uxf-02 | high | The "Recording stopped" notification's Record Again starts a **new** conversation, splitting the call. The panel's Record Again, same words, records into the same one. | `MacNotifications.swift:163-172` (`await state.startRecording()`); `RecordingNotificationResponse.recordAgain` has no ID (`:29-33`); compare `FloatingSurfaces.swift:156-170` | Carry the conversation ID; call `recordAgain(into:)` (P2) | S |
| uxf-03 | medium | With a cloud key and "Use the cloud: Always", a Mac still has to download the local summarizer before it transcribes anything. | `AppState+SummaryPlacement.swift:26-31` (`thisDeviceCanSummarize: true`, "a job reaches the summary step only with the summary model"); uxf-01's gate | P1 | (in P1) |
| uxf-04 | medium | "Record more" after a normal Stop means a new conversation on the Mac ("Record") and the same one on the iPhone ("Keep Recording"), in the one shared view. | `FloatingSurfaces.swift:123,134`; `AfterStop.swift:39,158,177-181`; `pro-after-stop-light.png`; `notes-stopped-light/Floating Notes.png` | P2 | M |
| uxf-05 | medium | Automatic, prompted, menu-bar, Floating Notes, recorder, and notification starts are filed into whatever place the main window shows (a work call into Personal) and replace the page the person was reading. | `AppState.swift:797-808`, `:1419-1420`; callers at `AppState.swift:499`, `CallPrompt.swift:364,399`, `MenuBarView.swift:23`, `FloatingSurfaces.swift:134`; `AppState+Devices.swift:179` does it right with `selecting: false` | P5 | S |
| uxf-06 | medium | Floating Notes shows "Waiting for models" in warning tone while the download it waits for is running; its menu offers "Open Settings…" not Download. The page says "Downloading … · 40%". | `FloatingStatus.swift:122`; `FloatingNotesView.swift:368-370,381-383`; `ConversationStatusPresentation.swift:533-543` | P6 | S |
| uxf-07 | medium | Model download failures raise an alert for background work, don't name the model, offer no Try Again, cascade through the pending list, and never resume after quit or reconnect. | `ProcessingQueue.swift:446-462` ("Check your internet connection and try again."); `:65` (in-memory `pendingDownloads`); docs/interface.md "Errors" | P6 | M |
| uxf-08 | medium | Call detection silently stops after a restart: Open at login is off by default and Welcome never offers it, while When a call starts defaults to Ask. | `SettingsView.swift:171,349`; `CallPolicy.swift:63-66`; `settings-general-light/General.png`; `WelcomeWindow.swift:255-306` | P3 (Mac) | S |
| uxf-09 | medium | An iPhone-only person is promised summaries ("Read a short summary"); Welcome downloads only transcription and speakers, and the page ends at "Needs your Mac to summarize" with no action, even where the phone could summarize. | `WelcomeWords.swift:24`; `PhoneModels.swift:213`; `PhoneWelcome.swift:90-95`; `ConversationStatusPresentation.swift:450-455`; `ModelsSettings.swift:73-89` | P3 (iPhone) | M |
| uxf-10 | medium | The iPhone's status sheet always reports "Recorder · None added" and "Your Mac · Hasn't synced this library yet", and its large detent always shows "Recorders · Add Recorder…", unlike the Mac's home, which names only devices that exist. | `StatusSheetModel.swift:322-330,385-389,441`; `StatusSheet.swift:850-851`; `pro-library-light.png`, `pro-status-large-light.png` | P4 | S–M |
| uxf-11 | low | The iPhone's after-Stop moment says only "SAVED · 11 sec". It passes no chips, so it never says what becomes of the recording ("Transcribing on this iPhone", "Waiting for your Mac"); the Mac's panel does. | `AfterStop.swift:148-160` (no `chips:`); `pro-after-stop-light.png`; docs/interface.md "After Stop" | Pass the processing chip (`RecordingStatusWords`) as the Mac does | S |
| uxf-12 | low | The empty library's download line counts per model ("Downloading Parakeet Ultra · 100%", then the next at 3%), so the wait seems to restart; Welcome showed the total. | `LibraryView.swift:592-599` | "Downloading models · 40%" over the set (P6) | S |
| uxf-13 | low | Vocabulary and Speaker Profiles are reachable on the Mac only through Settings › Models › … › Edit…; the iPhone lists them under "Library". Settings search for "Speaker Profiles", "profiles", or "recovery" finds nothing. | `SettingsModelsPane.swift:216,330`; `SpeakerProfilesView.swift:28`; `SettingsView.swift:55-64`; `SettingsScreen.swift:118-130` | P7 | S |
| uxf-14 | low | "Transcribe synced recordings on this Mac" is two switches on two pages. | `SettingsModelsPane.swift:128`; `SyncSettingsView.swift:81` | Keep it on Models only | S |
| uxf-15 | low | The same permission is "Computer Audio" in Welcome and "Screen & System Audio Recording" in Settings › Recording › Permissions. | `WelcomeWords.swift:52`; `SettingsView.swift:264`; `settings-recording-light/Recording.png` | Label the Settings row "Computer Audio", with the system's name in its help or Details | S |
| uxf-16 | low | The iPhone's Live Activity shows the recording's title on the Lock Screen: a calendar event's title, or a Personal conversation's on Keep Recording. The Mac's menu bar never names a Personal conversation, and the iPhone's Recent widget hides them. | `PhoneAppModel.swift:623,652`; `RecordingActivityController.swift:25`; `RecentConversationsWidget.swift:63` | "Recording" for a Personal conversation (P8) | S |
| uxf-17 | low | The iPhone's Ready message says "It's transcribed once the models download." even when the download is waiting for Wi‑Fi (it counts `.waitingForWiFi` as downloading), so a person on cellular expects a transcript that won't come until they're home. | `PhoneWelcome.swift:58-68`; `WelcomeWords.readyMessage` | "…once the models download on Wi‑Fi" when waiting for Wi‑Fi | S |
| uxf-18 | low | iPhone and Mac count the models to download differently: Welcome offers "Transcription and speakers" (~850 MB), while Settings' Models row says "1.5 GB to download" because it adds the live-caption models. | `SettingsScreen.swift:151-162`; `pro-settings-root-light.png`; `PhoneWelcome.swift:302` | Say what the row's figure is for, or count only what transcribing needs and show live captions' size inside | S |

## 4. Decisions recommended

### ux-mac-10: Personal conversations and the cloud

**Recommendation: Personal is never sent to the cloud on its own.** "Always" means always for everything except Personal; there it behaves as Offer First, and there are no cloud upgrade offers.

- A conversation is Personal when the person put it there (`Meeting.placement == .personal`: filed, dragged, or recorded from the window while Personal was shown) or when its kind says so. For such a conversation:
  - Under Always, the summary counts down as Offer First does (default here). After P1, on a Mac without a local summarizer, it waits ("Waiting to summarize" with Use the Cloud).
  - The cloud's Upgrade offers are never made (`UpgradeOffer` filters `UpgradeRanks.isCloud`).
  - Explicit choices still work, per conversation: Use the Cloud in the countdown, or Summarize Again after picking the cloud. They're the person's decision about that one conversation.
- The kind comes from the summary, so an automatically-Personal conversation can't be honoured before its first summary. Accept that: the person chose Always, and the first summary is the first moment Daybook knows. From then on, summaries again, template changes, and upgrades of that conversation stay on the device. Where small tasks (Apple Foundation Models, on device) can classify the kind before the summary step, do it there and honour it from the first summary.
- The planner is shared (DaybookKit), so one `Inputs.isPersonal` makes both apps agree. The iPhone's Lock Screen follows the same rule (uxf-16).

*Why:* "Always" is a cost and quality preference. Personal is the one signal the person gives about sensitivity, and Daybook's promise is "Transcribed and summarized on your devices, unless you choose a cloud model" (`WelcomeWords.swift:26`). For a Personal conversation, "you choose" should mean this conversation, not a setting chosen weeks ago. With P5 in place, a work call can no longer become Personal by accident, so the rule doesn't strand work summaries.

### ux-mac-14: Fresh-install preset

**Recommendation: start a fresh Mac on this Mac's recommended preset, never "Custom".** When no model selections are stored, apply `ModelPreset.recommended` at first launch (Mac only; `initialSelection` stays for the iPhone and for migrations).

*Why:*
- The only difference on most tiers is the speaker model: Nemotron 3 (0.20 GB) instead of Community-1 alone (0.02 GB), plus the preset's speaker quality.
- That's about 1–3% of a 7.6–16.5 GB first download, and models.md ranks Nemotron as the better speaker model for Balanced and Detailed.
- Welcome already applies the recommended preset when the person chooses Download (`WelcomeWindow.swift:69-74`). So today "Custom" appears only for people who skipped Welcome's quality page: the people least likely to understand it (`settings-models-light/Models.png`: "Quality · Custom · 16.3 GB · 32 GB memory").

With P1, the transcribing set they wait for grows from 0.65 to 0.85 GB, which is still minutes.

### ui-iphone-23: Two search entries in the pocket library

**Recommendation: close it as decided. Keep the thumb Search beside Record as the only entry.**

The code already attaches `.searchable` only while search is presented (`SearchWhilePresented`, `LibraryPage.swift:77-79,501-520`). docs/iphone.md line 23 says "Search opens from Search beside Record (or on the status sheet), and its field is there only while search is up, at the thumb". The captures show one entry at rest (`pro-library-light.png`) and the field at the thumb while searching (`pro-search-light.png`). Remove the row from the audit README's open table.

### xdev-settings-03: Settings structure on Mac and iPhone

**Recommendation: keep each platform's structure, which is already in place, and make the words mean the same thing.**

- The Mac is now a System Settings–style window with a searchable sidebar (General, Recording; Devices, Library; Models, Cloud; `SettingsView.swift:13`, docs/interface.md:87). The iPhone is a root list with iCloud at the top, as iOS Settings puts the account. Both are the platform's convention. Rebuilding either into the other's shape costs more than it gives.
- What still confuses is **Library**:
  - On the Mac it's the folder, storage, iCloud Sync, imports, and the privacy statement.
  - On the iPhone it's a section header over Templates, Vocabulary, and Speaker Profiles.
  - The Mac hides those three under Models.
- Make **Library = the library's own things** on both apps:
  - The Mac's Library page gains a group with Summary Templates…, Vocabulary…, and Speaker Profiles… (keep the Edit… links in Models as shortcuts).
  - The iPhone moves Storage into its Library section.
  - iCloud stays the iPhone's top row and the Mac's Library › iCloud Sync group.
- Add the missing search keywords (P7).

### xdev-settings-08: Per-device processing preferences

**Recommendation: split by what the setting describes.**

- **Transcription language becomes a library setting, synced, on both apps.**
  - It describes the person's conversations, not a device. Today a person who sets German on their Mac gets Automatic on their iPhone and on a second Mac (`ProcessingPreferences.transcriptionLanguage`, Mac UserDefaults).
  - The iPhone shows it as Settings › Models › Transcription › Language, the same list.
  - The "other languages" model (`otherLanguagesModelID`) stays per device, because it names a model that device downloads.
- **Speaker settings stay per device, Mac only.**
  - The speaker model, quality, and matching thresholds are bound to the models and hardware of the device that runs them.
  - docs/iphone.md's rule that the iPhone transcribes "with speakers and voice profiles, as the Mac does, or not at all" stands.
  - The iPhone gets no "Tell speakers apart" switch.
  - Speaker *profiles* are already synced library data, which is what a person means by "speakers" across devices.

## 5. Not findings

These were checked and are fine; the next pass needn't repeat them.

- **Mac first run.**
  - Welcome's quality page defaults to the recommended preset.
  - It refuses a download that doesn't fit ("Needs 16.5 GB · 12 GB free").
  - Every page can be skipped (Esc, Not Now).
  - Allow shows the real permission state and refreshes on return from System Settings.
  - Skipping everything still leads somewhere: the first recording's page offers "Download models to transcribe this conversation" with the size, Choose Models…, and Download (`ConversationStatusPresentation.swift:393-401`).
- **Call prompt.** It drains over 15 s and holds under the pointer. Unanswered means Not Now (to record) or Keep Recording (to stop). Per-app Always/Never are in its menu and Settings › Recording. Its words are short and right (`callprompt-*`).
- **Unexpected stops on the Mac.** The panel's "Recording stopped" with Record Again into the same conversation works (only the notification is wrong, uxf-02). Failure to start leaves no empty conversation behind (`discardUnrecorded`).
- **Mac first.** The waiting line ("Waiting for audio from Soundcore Work" with Don't Wait), its two-day lifetime, and re-summarizing when the late recording arrives match docs/multipoint.md on both apps.
- **iPhone pairing.** Copy names the other device's exact control ("On your Mac, open Daybook › Settings › Devices and click Pair with iPhone…"). Local Network denial has its own line with Open Settings. A new device waiting for an encrypted library's key offers "Get Key from <Mac>" and Enter Recovery Key… (`ICloudSyncSection.swift:274-283`), so that first-week dead end is handled.
- **iPhone recording.**
  - The after-Stop moment with Open and Keep Recording, its 10 s linger that writing holds, and haptics on the result all hold up.
  - The offline audio notice ("The audio isn't on this iPhone yet. It downloads when you're online.") is right.
  - "Recording with Your Mac" now dims each Mac's Can start recording and refuses in one sentence naming the setting (ux-iphone-09 is complete).
- **Reading and editing.**
  - A speaker's name in the transcript renames them in place.
  - Undo covers renames, ticks, labels, bookmarks, and Trash on both apps.
  - Search hits open at the passage.
  - The Mac list row now uses the shared `ConversationStatusPresentation.row` (`MacRowStatus`, `ConversationList.swift:135-146`), so ux-mac-09's "Requested from <this Mac>" is fixed.
- **Organizing.** Trash with Restore and the notice's Undo exists on both apps (`trash-1440`, `pro-trash`). Multi-select acts through `ConversationActions` on both.
- **Cloud.** Failure words, Summarize on This Mac, and the countdown's choices on the page, the row, the chip, and connected phones are consistent. Settings › Cloud's one footer, "Sends the transcript and notes, never audio.", is the right amount.
- **Not in this lane.** `window-3.png` (280×168, "untitled", blank) isn't one of Daybook's own windows: no `NSWindow`/`NSPanel` of that size is made in `Sources/Daybook` (Floating Notes' minimum is 280×196, the call prompt 340×108). It's likely an AppKit-owned helper window; left to the UI lane.
- **Screenshot artifact.** The `countdown-1440` capture shows list rows mid-crossfade to "Waiting for models" over other states. `page-1280` shows the same rows settled with their right words, so this is the capture timing plus the demo machine having no models, not a logic error.
