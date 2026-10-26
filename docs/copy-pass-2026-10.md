# Copy pass, October 2026

The owner's note: "We don't need unnecessary subtitles like 'Its recordings arrive via sync'." This pass went through every person-facing string in the Mac app (`Sources/Daybook`, and the words that `DaybookDevices`, `DaybookKit`, and `DaybookCore` put on screen) and the iPhone app (`Apps/iOS`: the app, widgets, Live Activity, and App Intents). It removed text that explains mechanics and tightened what remained. The rule is now principle 7 in [interface.md](interface.md).

## The rule

- **Cut:** subtitles, footers, notices, and empty-state lines that explain how things work: sync, iCloud, the Wi‑Fi link, where audio travels, what Daybook reads or never does, which model runs where, and reassurance or marketing.
- **Keep:**
  - status values ("Connected · 80% · 1 new", "Transcribing · 40%", "Up to date");
  - a next step that matters ("Not transcribed yet", "Waiting for your Mac · last seen 2 h ago");
  - a problem and its fix, in one short sentence, with the button doing the rest;
  - a destructive action's consequence;
  - permission strings, which are tightened;
  - Welcome, which is trimmed;
  - the "tentative" live-captions label;
  - legal attributions.
- **Prefer:** one short line over two, labels over sentences, and nothing that repeats what the screen already shows.

## Result

- 312 string literals were touched outside Floating Notes. About 220 were tightened, and about 90 were removed outright, along with the footer, box, or line that held them.
- Removed surfaces:
  - the device page colophon: `DeviceKind.promise` is deleted, with its rendering on both apps;
  - the Settings › Devices footers;
  - the Add Device subtitles and the "only reads" line;
  - the pairing success box;
  - the Listen Live intro;
  - the Models, Live Captions, and iCloud footers (the iCloud footer now speaks only when iCloud is off or signed out);
  - the drop-outline details;
  - the iPhone's Recorders, Macs, Library, Storage, and Devices footers;
  - the iPhone's handoff explainer and About › Recorders.
- Wording fixes found on the way:
  - the pairing instructions pointed at Settings panes that don't exist ("Settings › iPhone" on the Mac, "Settings › Mac" on the iPhone). They now say **Settings › Devices** on the Mac and **Settings › Pair with Your Mac** on the iPhone;
  - two notices told people to "choose Process", a command that no longer exists.
- Arrows in System Settings paths are now `›` everywhere, not `→`.

## Deliberately kept

- **Provenance colophons.** "Summarized on this Mac · *model* · *date*" and, on the iPhone, "Summarized on your Mac · *date*". These are the facts interface.md principle 6 places at the foot of the page.
- **One privacy statement per app**, each tightened to one or two sentences: Settings › Library on the Mac, and About › Privacy on the iPhone. This is where a reader looks for it.
- **Device Details › Technical Details** (`technicalNotes`) and the Soundcore protocol `errorDescription`s, which appear only there. Both are an opt-in technical disclosure.
- **Remote devices in status lines**: "Transcribing on Studio Mac · 40%" and "The models it needs aren't on Studio yet". On the iPhone, the Mac's name is the status. On the Mac, "on this Mac" was dropped and other devices are still named.
- **Consequences and next steps:**
  - "Recording on this Mac only.";
  - "Its recording will be added here.";
  - "Stopping here doesn't stop your Soundcore recording.";
  - the pause box's "Everything so far is saved; resume when you're ready.";
  - "Everything up to then is saved." after a failed recording;
  - "The recording is still on your Soundcore." after a failed import;
  - "Keep your Soundcore near this Mac."
- **Destructive confirmations** keep their consequence, tightened. For example: "Its audio, notes, and summary go with it.", "Its recordings stay in your library.", "What's there now stays in Version History.", and "*Recorder* may not answer this Mac until *owner* lets go. Nothing on *recorder* is lost."
- **Pre-permission notes**: "macOS asks to allow Bluetooth." and "iOS asks to allow Bluetooth when you search."
- **Conditions for an action**: "Listen Live works while Soundcore is recording.", "Looking for Macs… Both need to be on the same Wi‑Fi.", and "The audio isn't on this iPhone yet. It downloads when you're online."
- **The inspector's source timing lines** ("Lined up by shared phrases · starts 0:12 · 92% sure"). The inspector is the place for that detail.
- **Empty states that name what to do**: "Record a conversation, or drop audio files here.", "Drag conversations here, or choose Move to Folder.", "Add names, acronyms, and terms so Daybook spells them correctly.", and "Press its button once to start recording, and again to stop."
- **Model prompts and Markdown export text** (`MeetingEvidence`, `MeetingExport`). They aren't interface.

## Not changed here: Floating Notes

`Sources/Daybook/UI/NotesPanel.swift` is being redesigned separately and was left untouched. These are the changes to carry over:

| Line | Before | After |
|---|---|---|
| 224 | Type a note. It's stamped with the time you write it. | Add a note… |
| 624 | Summarizing on this Mac… | Summarizing… |
| 626 | Transcribing on this Mac · 40% | Transcribing · 40% |
| 630 | Transcribes once the models are on this Mac | Waiting for models |
| 772 (help) | Your microphone isn't picking anything up. Check that it isn't muted or unplugged. | Check that your microphone isn't muted or unplugged. |

The Floating Notes footer in interface.md still quotes "Transcribing on this Mac · 40%" until that change lands.

## Tests and docs updated

- Exact-string tests now expect the new copy, and each still checks the same behaviour:
  - `SoundcoreSimulatorTests` ("Managed by Alex's iPhone");
  - `DeviceFrameworkTests` (the "no Experimental" check moved from the deleted `promise` to `summary`);
  - `PhoneLinkTests` and `MultipointRecordingTests` (companion status lines);
  - `LinkServicesTests` (a Mac row reads "Connected"; `canProcess` is still asserted);
  - `ShellTests` and `SyncServicesTests` (the signed-out iCloud line);
  - `StatusSheetModelTests` ("Waiting for iCloud");
  - `ReadingTests` ("Not transcribed yet", and "No Mac has checked in yet. Open Daybook on your Mac.").
- Docs:
  - interface.md (principle 7);
  - devices.md (no promise);
  - iphone.md (the recorded state's words);
  - link.md (the local-network string).
- `Apps/iOS/project.yml` carries the same permission strings as the iPhone's Info.plist.

## Verification

- `swift test`: 478 passed, 0 failed.
- `scripts/build-ios.sh --test` on a new iPhone Duo simulator (iOS 27.1): 71 passed. The simulator was shut down afterwards.
- Mac `--snapshot` captures, in light and dark:
  - the Soundcore device page (connected, low storage, and not connected);
  - the iPhone device page;
  - Listen Live and pairing;
  - Add Device;
  - Settings › Devices, General, and Library;
  - a summarized conversation and an untranscribed one.
- iPhone simulator captures, in light and dark:
  - the status sheet;
  - a recorder's page;
  - Settings;
  - Pair with Your Mac.

  The foot of the recorder's page, "How Recordings Arrive", needs a scroll that the simulator can't make, so only its code was checked.

## Code written after the pass (2026-10-26)

The App Sandbox, the cross-stream follow-ups, and sync encryption added interface after this pass. A second sweep of
every string in the same places found these, and fixed them:

- **Encryption.**
  - The waiting line is "Waiting for this library’s key." on both apps, not "Your library in iCloud is encrypted.
    Waiting for its key from iCloud Keychain.". On the Mac, under the headline, it gives the fix: "Turn on iCloud
    Keychain, or get the key from another device."
  - Every place says "this library’s key", including the Mac headline and the iPhone's "Sent this library’s key to …".
  - "Couldn’t Create a Recovery Key" matches its button (it was "Make").
  - The iPhone's items that open a sheet or a confirmation have their ellipses (Encrypt Library in iCloud…, Enter
    Recovery Key…, Create Recovery Key…, Erase Deleted Conversations from iCloud…). Its sheet is titled "Encrypt Library
    in iCloud", and its section header reads "Stop Syncing Until Updated".
  - The iPhone's problem lines open the same Details sheet as every other problem there.
  - The Mac's rows are sentence case ("Recovery key", "Previous sync folder").
  - A recording whose key hasn't arrived says "This recording plays once this device has the library’s key."; it used
    to be a capitalised fragment after "iCloud couldn’t download this recording:".
- **App Sandbox.**
  - The library-move sheet's titles are title case.
  - Its error is one sentence, with the system's words behind Details….
  - "Can’t open the folder this Mac synced through before." matches the line under it.
  - The development panel's prompt is "Connect Library".
  - A launch-path message uses a curly apostrophe.
- **Words.**
  - The Conversation menu says Transcribe New Audio, Summarize Again, Identify Speakers Again, and Transcribe
    Everything Again, as the page and the iPhone do. It used to say Process New Audio, Refresh Summary, Re-label
    Speakers, and Re-transcribe Audio.
  - The folder menu's New Folder has no ellipsis: it names the folder in place.
  - The iPhone's Unpair … and Add Term… have their ellipses.
  - Models › "On This Mac" is title case.
- **System words behind Details.** These now follow the pattern:
  - On the Mac: exporting a conversation, adding an iPhone recording to another conversation, recovering an
    interrupted recording, installing a model update or removing a model (the alert's title had been the whole raw
    sentence), adding a model, playback (the system's words are in the tooltip), the vocabulary notice, and the Floating
    Notes sync chip (which gives a reason only when it's Daybook's own).
  - On the iPhone: a recording that couldn't continue (the encoder's step goes to Details), and what Shortcuts, the
    control, and Live Activity buttons say when recording couldn't start or resume.
  - Daybook's own sync sentences (`LibrarySyncError.isPlainSentence`) show as they are on both apps.

Finished afterwards:

- The Mac's capture warnings (`RecordingController`, `CaptureSources`, `CaptureRecovery`, `CaptureFinalizer`,
  `PCMTrackWriter`) are one plain sentence each; the system's words go in the affected track's capture notes
  (the call audio's `fallbackDetail`, the echo removal report), which the conversation's capture details show.
  Daybook's own recording errors (`RecordingError`, `PCMTrackWriterError`) already read plainly and stay as written.
- The sync engine's per-pass warnings use `SyncWarningWords`: a plain sentence, with the error's own text behind
  Details in Settings › Library. Only warnings it composed are split, so a title with a colon is never cut.

Left as is, by choice: the iPhone's Details buttons have no ellipsis. They show more of what's already there and
ask for nothing, and they're consistent across the iPhone.

## Every change

Line numbers are the line before the change. Interpolations appear as in the source, so a string split by `\(…)` can show as two pieces.

| File | Line | Before | After |
|---|---|---|---|
| `Sources/Daybook/App/AppState+Devices.swift` | 62 | Choose where you save recordings exported from \(source). A folder named “Daybook Import” in iCloud Drive works well: your phone can save to it directly. | Choose where you save recordings exported from \(source), such as a “Daybook Import” folder in iCloud Drive. |
| `Sources/Daybook/App/AppState+Phone.swift` | 177 | Daybook on this Mac hasn’t been allowed to use the microphone yet. Start a recording on the Mac once to allow it. | Start a recording on the Mac once to allow its microphone. |
| `Sources/Daybook/App/AppState+Phone.swift` | 180 | Daybook isn’t allowed to use this Mac’s microphone. Allow it in System Settings › Privacy & Security › Microphone. | Allow the Mac’s microphone in System Settings › Privacy & Security. |
| `Sources/Daybook/App/AppState+Phone.swift` | 263 | Added the iPhone recording to “\(title)”. “\(meeting.title)” stays as it is, with your notes; move it to the Trash if you don’t need it. | Added the iPhone recording to “\(title)”. “\(meeting.title)” stays, with your notes. |
| `Sources/Daybook/App/AppState+Sources.swift` | 474 | Added this recording to “\(target)”. “\(meeting.title)” stays as it is; move it to the Trash if you don’t need it. | Added this recording to “\(target)”. “\(meeting.title)” stays as it is. |
| `Sources/Daybook/App/AppState.swift` | 288 | Import audio exported by Soundcore or any other recorder. | *(removed)* |
| `Sources/Daybook/App/AppState.swift` | 288 | Daybook will align this source with the existing transcript and preserve both originals. | *(removed)* |
| `Sources/Daybook/App/AppState.swift` | 583 | Download cancelled. You can try again in Models. | Download cancelled. |
| `Sources/Daybook/App/AppState.swift` | 672 | Moved conversation to the library’s Trash folder. Original audio and notes are preserved there. | Moved to the Trash. |
| `Sources/Daybook/App/AppState.swift` | 801 | Recovered an interrupted recording. Select it and choose Process to continue. | Recovered an interrupted recording. |
| `Sources/Daybook/App/AppState.swift` | 801 | A recording is still in recovery storage: \(error.localizedDescription) | Couldn’t recover a recording: \(error.localizedDescription) |
| `Sources/Daybook/App/LibrarySyncController+Mac.swift` | 9 | Choose or create a private Daybook folder in iCloud Drive. Choose the same folder on your other Macs. All conversations, original recordings, notes, and library settings will sync there. | Choose or create a private Daybook folder in iCloud Drive. Choose the same folder on your other Macs. |
| `Sources/Daybook/App/MultiSourceCoordinator.swift` | 196 | \(link.deviceName) is still recording. Its recording will be added here when it arrives. | \(link.deviceName) is still recording. Its recording will be added here. |
| `Sources/Daybook/App/MultiSourceCoordinator.swift` | 268 | Couldn’t reach \(name) to stop it. Stop it on the recorder; its recording will still be added here. | Couldn’t reach \(name) to stop it. Stop it on the recorder. |
| `Sources/Daybook/App/MultiSourceCoordinator.swift` | 275 | \(name) didn’t confirm it stopped. Stop it on the recorder; its recording will still be added here. | \(name) didn’t confirm it stopped. Stop it on the recorder. |
| `Sources/Daybook/App/MultiSourceCoordinator.swift` | 337 | \(name) stopped. Its recording will be added here when it syncs. | \(name) stopped. Its recording will be added here. |
| `Sources/Daybook/App/MultiSourceCoordinator.swift` | 340 | Couldn’t reach \(name) to stop it. Stop it on the iPhone; its recording will still be added here. | Couldn’t reach \(name) to stop it. Stop it on the iPhone. |
| `Sources/Daybook/App/PhoneLink.swift` | 154 | Daybook couldn’t open pairing on this Mac. Check that it’s connected to a network, then try again. | Couldn’t start pairing. Check this Mac’s network connection, then try again. |
| `Sources/Daybook/App/PhoneLink.swift` | 271 | The code expired before an iPhone used it. Show a new code to pair. | The code expired. Show a new code to pair. |
| `Sources/Daybook/App/PhoneLink.swift` | 271 | Pairing closed after too many tries. Start again when you’re ready. | Too many tries. Start again when you’re ready. |
| `Sources/Daybook/App/PhoneLinkConnection.swift` | 63 | Connected. It records along with this Mac and shows transcription progress. | Connected |
| `Sources/Daybook/App/PhoneLinkConnection.swift` | 63 | Not paired. Pair it again to record together. | Not paired |
| `Sources/Daybook/App/PhoneLinkConnection.swift` | 63 | Not connected. It connects when Daybook is open on the iPhone and both are on the same Wi‑Fi. | Not connected |
| `Sources/Daybook/App/PhoneLinkConnection.swift` | 82 | Recordings from Daybook on iPhone arrive through sync. | Nothing to import from iPhone. |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 41 | Downloading captions for \(LiveCaptionAvailability.name(locale))\(percent). The recording isn’t affected. | Downloading captions for \(LiveCaptionAvailability.name(locale))\(percent) |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 43 | Captions stopped. The recording continues. | Captions stopped |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 98 | Heard on this Mac as it records. The transcript replaces them. | *(removed)* |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 98 | Made live on this Mac while it recorded. The transcript replaces them once it’s ready. | *(removed)* |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 212 | Tentative captions of you and the call, made on this Mac as you record. | *(removed)* |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 241 | Shown in Floating Notes and on the conversation page, and when you listen live to a recorder. They stay on this Mac, and the transcript replaces them. | *(removed)* |
| `Sources/Daybook/Captions/LiveCaptionViews.swift` | 245 | \(about) Captions for \(LiveCaptionAvailability.name(locale)) download from Apple the first time you record with them on. | Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on. |
| `Sources/Daybook/Capture/CaptureModels.swift` | 160 | Allow Daybook to use the microphone in System Settings → Privacy & Security → Microphone. | Allow Daybook to use the microphone in System Settings › Privacy & Security › Microphone. |
| `Sources/Daybook/Capture/CaptureModels.swift` | 163 | This recording folder already contains captured audio. A new folder is required to preserve the existing recording. | This recording folder is already in use. Start the recording again. |
| `Sources/Daybook/Capture/CaptureModels.swift` | 163 | The audio device supplied an unsupported audio buffer. | The audio device sent audio Daybook can’t use. |
| `Sources/Daybook/Capture/CaptureModels.swift` | 163 | The audio device changed during recording. The completed audio has been preserved; start a new recording with the new device. | The audio device changed. Everything up to then is saved; start a new recording to continue. |
| `Sources/Daybook/Capture/CaptureSources.swift` | 93 | System audio is unavailable. Allow Daybook in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch if macOS requests it. \(error.localizedDescription) | System audio is unavailable. Allow Daybook in System Settings › Privacy & Security › Screen & System Audio Recording. \(error.localizedDescription) |
| `Sources/Daybook/Capture/MeetingDetection.swift` | 123 | Listening for Zoom, Teams, Slack huddles, and calls in your browser. | Listening for calls |
| `Sources/Daybook/Capture/MeetingDetection.swift` | 160 | Needs Screen & System Audio Recording permission to notice calls. | Needs Screen & System Audio Recording permission. |
| `Sources/Daybook/Capture/PCMTrackWriter.swift` | 176 | The \(role.rawValue) audio clock was interrupted. Recorded audio has been preserved. | The \(role.rawValue) audio clock was interrupted. Everything up to then is saved. |
| `Sources/Daybook/Capture/PCMTrackWriter.swift` | 301 | The disk could not keep up with audio recording. Captured audio has been preserved. | The disk couldn’t keep up with the recording. Everything up to then is saved. |
| `Sources/Daybook/Capture/RecordingController.swift` | 94 | Recording stopped because the Mac is going to sleep. Recorded audio has been preserved. | Recording stopped because the Mac went to sleep. Everything up to then is saved. |
| `Sources/Daybook/Capture/RecordingController.swift` | 225 | The call stayed silent for a long time while the app was playing. If the call audio is missing, allow Daybook under System Settings → Privacy & Security → Screen & System Audio Recording. | The call stayed silent. If its audio is missing, allow Daybook in System Settings › Privacy & Security › Screen & System Audio Recording. |
| `Sources/Daybook/Devices/UI/AddDeviceSheet.swift` | 128 | Bring its recordings into Daybook and transcribe them on this Mac. | *(removed)* |
| `Sources/Daybook/Devices/UI/AddDeviceSheet.swift` | 137 | Daybook only reads from recorders. It never changes them. | *(removed)* |
| `Sources/Daybook/Devices/UI/AddDeviceSheet.swift` | 171 | Add another way to bring in its recordings. | Add another way to import. |
| `Sources/Daybook/Devices/UI/AddDeviceSheet.swift` | 210 | Bring its recordings into Daybook and transcribe them here. | *(removed)* |
| `Sources/Daybook/Devices/UI/AddDeviceSheet.swift` | 377 | Connecting only reads from your \(session.kind.shortName). It stays linked to your phone. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 183 | Managed by \(owner.ownerName) · Its recordings arrive through sync | Managed by \(owner.ownerName) |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 260 | \(StorageFormat.room(storage)). When it’s full, \(session.kind.shortName) records over its oldest recordings. Free up space in the \(session.kind.shortName) app. | When it’s full, \(session.kind.shortName) records over its oldest recordings. Free up space in the \(session.kind.shortName) app. |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 322 | They import when your \(name) reconnects. They’re still on your \(name). | They import when your \(name) reconnects. |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 322 | Keep your \(name) near this Mac. You can keep using Daybook while it imports. | Keep your \(name) near this Mac. |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 322 | You can keep using Daybook while it imports. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicePage.swift` | 418 | This Mac takes over the recorder. Your other device stops connecting to it. | Your other device stops connecting to it. |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 64 | Daybook connects to your \(session.kind.shortName) to import it. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 202 | \(TimeLabel.short(live.receivedSeconds)) saved to this Mac | \(TimeLabel.short(live.receivedSeconds)) saved |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 214 | Audio is saved to this Mac as it arrives. Stopping here doesn’t stop your \(session.kind.shortName) recording. | Stopping here doesn’t stop your \(session.kind.shortName) recording. |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 233 | Follow what’s being recorded in live captions.  | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 233 | Audio is saved to this Mac as it arrives, and becomes a conversation when you stop. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 252 | Saved \(DurationLabel.format(saved.seconds)) as a new conversation. When you import the full recording later, Daybook adds it to the same conversation. | Saved \(DurationLabel.format(saved.seconds)) as a new conversation. |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 286 | The recording from \(recordings[0].title) joins the conversation as another recording of it. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingPages.swift` | 286 | The \(recordings.count) recordings join the conversation as other recordings of it. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 65 | Set up \(kind.name) to see its recordings here. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 73 | Recordings from your iPhone arrive through iCloud sync. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 79 | Daybook isn’t watching \((primary as? ImportFolderWatcher)?.folderDisplayName ??  | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 79 | ) right now. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 159 | Everything in the folder is in Daybook. | *(removed)* |
| `Sources/Daybook/Devices/UI/DeviceRecordingsList.swift` | 159 | Everything on your \(session.kind.shortName) is in Daybook. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 46 | Daybook only reads from recorders. It never deletes, resets, or updates them, and audio goes straight to this Mac. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 111 | Imports go straight from the recorder to this Mac. Automatic imports bring in recordings made since you added it, then let it go so your phone can connect. The import folder works with every firmware version. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 111 | Over Wi‑Fi, this Mac and the iPhone start and stop recordings together, and the iPhone shows how transcription is going. Audio never travels over Wi‑Fi: recordings arrive through iCloud. | *(removed)* |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 137 | This Mac and the iPhone stop recording together. Its recordings stay in your library and keep arriving through iCloud. | This Mac and the iPhone stop recording together. Its recordings stay in your library. |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 270 | Sync is off, so they can’t arrive | Sync is off |
| `Sources/Daybook/Devices/UI/DevicesSettingsPane.swift` | 270 | Arrive through iCloud sync | Recordings |
| `Sources/Daybook/Devices/UI/PhoneDevicePage.swift` | 19 | This Mac isn’t paired with \(session.device.name) any more. Its recordings still arrive through iCloud; pair it again to record together. | This Mac isn’t paired with \(session.device.name) any more. |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 32 | Record together, and see transcription progress on your iPhone. | *(removed)* |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 61 | This Mac and the iPhone stop recording together. Its recordings stay in your library and keep arriving through iCloud. | This Mac and the iPhone stop recording together. Its recordings stay in your library. |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 81 | On your iPhone, open Daybook, choose Settings › Mac, choose “\(link.identity.name)”, and enter this code. | On your iPhone, open Daybook › Settings › Pair with Your Mac, choose “\(link.identity.name)”, and enter this code. |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 97 | \(device.name) records along with this Mac when both are on the same Wi‑Fi, and shows how transcription is going. Its recordings arrive through iCloud. | *(removed)* |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 124 | This code works for about a minute more. | Expires in about a minute |
| `Sources/Daybook/Devices/UI/PhonePairingView.swift` | 124 | This code works for \(minutes) more minutes, once. | Expires in \(minutes) minutes |
| `Sources/Daybook/Devices/UI/RecorderHandoffViews.swift` | 149 | This Mac finishes any import in progress and lets go; \(peer.name) connects and imports what was waiting. | This Mac finishes any import first. |
| `Sources/Daybook/Devices/UI/RecorderHandoffViews.swift` | 188 | A recorder connects to one device at a time. The one that manages it imports; the others get its recordings through iCloud. | *(removed)* |
| `Sources/Daybook/UI/ConversationList.swift` | 27 | Each file becomes a new conversation. | *(removed)* |
| `Sources/Daybook/UI/ConversationList.swift` | 67 | Conversations about work appear here automatically. You can also drag any conversation here. | Conversations about work appear here automatically. |
| `Sources/Daybook/UI/ConversationList.swift` | 70 | Therapy sessions and personal conversations appear here automatically. They stay on this Mac like everything else. | Personal conversations appear here automatically. |
| `Sources/Daybook/UI/ConversationPage.swift` | 221 | Playback is off while recording, so it isn't captured in the recording. | Playback is off while recording |
| `Sources/Daybook/UI/ConversationPage.swift` | 254 | Transcribing on this Mac | Transcribing |
| `Sources/Daybook/UI/ConversationPage.swift` | 318 | Transcription starts when the download finishes. | *(removed)* |
| `Sources/Daybook/UI/ConversationPage.swift` | 329 | \(ByteCountFormatter.string(fromByteCount: missingBytes, countStyle: .file)) · runs on this Mac | *(removed)* |
| `Sources/Daybook/UI/ConversationPage.swift` | 337 | A recording was added and isn’t transcribed yet | A new recording isn’t transcribed yet |
| `Sources/Daybook/UI/ConversationPage.swift` | 353 | Summarizing on this Mac… | Summarizing… |
| `Sources/Daybook/UI/ConversationPage.swift` | 355 | Transcribing on this Mac · \(Int(state.processingProgress.fraction * 100))% | Transcribing · \(Int(state.processingProgress.fraction * 100))% |
| `Sources/Daybook/UI/ConversationPage.swift` | 469 | No speech was found in the audio. The recording is saved, so nothing is lost. | No speech was found. The recording is saved. |
| `Sources/Daybook/UI/ConversationPage.swift` | 469 | The models it needs aren’t on this Mac yet. The recording is saved. | Its models aren’t downloaded yet. The recording is saved. |
| `Sources/Daybook/UI/ConversationPage.swift` | 472 | Something went wrong on this Mac. The recording is saved. | Something went wrong. The recording is saved. |
| `Sources/Daybook/UI/ConversationSheets.swift` | 105 | The text from before this change comes back. What’s there now is kept in Version History, so you can return to it. | What’s there now stays in Version History. |
| `Sources/Daybook/UI/ConversationSheets.swift` | 216 | Daybook lines recordings up by matching what was said. If it got this one wrong, set where it starts. | *(removed)* |
| `Sources/Daybook/UI/ConversationSheets.swift` | 230 | Couldn’t line up automatically: too little of the speech matched the other recordings. | Couldn’t line up automatically. |
| `Sources/Daybook/UI/GlossaryView.swift` | 57 | Daybook uses these to spell names and terms correctly. | *(removed)* |
| `Sources/Daybook/UI/LibraryView.swift` | 75 | They move to the Trash folder inside your Daybook library, with their audio, notes, and summaries. | Their audio, notes, and summaries go with them. |
| `Sources/Daybook/UI/LibraryView.swift` | 75 | It moves to the Trash folder inside your Daybook library, with its audio, notes, and summary. | Its audio, notes, and summary go with it. |
| `Sources/Daybook/UI/LibraryView.swift` | 249 | Transcription starts when the download finishes. | *(removed)* |
| `Sources/Daybook/UI/LibraryView.swift` | 261 | Each file becomes a new conversation. | *(removed)* |
| `Sources/Daybook/UI/LibraryView.swift` | 305 | The audio joins this conversation as another recording of it. | *(removed)* |
| `Sources/Daybook/UI/MeetingDetailView.swift` | 112 | The transcript appears once the audio is transcribed. | Not transcribed yet |
| `Sources/Daybook/UI/MeetingDetailView.swift` | 223 | Playback is off while recording, so it isn't captured in the recording. | Playback is off while recording |
| `Sources/Daybook/UI/MeetingInspector.swift` | 86 | Speakers appear after the audio is transcribed. | No speakers yet |
| `Sources/Daybook/UI/SettingsModelsPane.swift` | 173 | Models run on this Mac. Nothing is sent anywhere to be transcribed or summarized. | *(removed)* |
| `Sources/Daybook/UI/SettingsView.swift` | 87 | Records the other people on a call, not just you. | Records the other people on a call. |
| `Sources/Daybook/UI/SettingsView.swift` | 124 | Needed for computer audio. Until it’s allowed, Daybook records only your microphone. | Needed to record computer audio. |
| `Sources/Daybook/UI/SettingsView.swift` | 247 | Recording starts a few seconds after a call begins and stops when it ends. | *(removed)* |
| `Sources/Daybook/UI/SettingsView.swift` | 288 | Recordings, transcripts, and summaries are made and kept on this Mac. Daybook doesn’t upload anything. With iCloud sync on, your library is stored in your own iCloud Drive. | Transcripts and summaries are made on this Mac. Nothing is uploaded except to your own iCloud, when sync is on. |
| `Sources/Daybook/UI/SummaryPage.swift` | 209 | Notes you type here are timed to the recording. | *(removed)* |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 38 | This library synced with a different iCloud account. Syncing now adds its conversations to the iCloud account you’re signed in to. | Its conversations are added to the iCloud account you’re signed in to. |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 83 | Daybook can’t find the folder this Mac synced through before, so it can’t move it to iCloud yet. | Can’t find the folder this Mac synced through before. |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 137 | Keeps recordings, notes, folders, and templates the same on your Macs and iPhone. Every Mac runs its own models. | *(removed)* |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 137 | Moving your library from the folder it synced through to Daybook’s iCloud storage. That folder isn’t changed or deleted. | *(removed)* |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 142 | Turn on iCloud Drive in System Settings › Apple Account › iCloud to sync your library. | Turn on iCloud Drive in System Settings › Apple Account › iCloud. |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 144 | Sign in to iCloud in System Settings to keep your library the same on your Macs and iPhone. | Sign in to iCloud to sync your library. |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 144 | This build isn’t signed for iCloud. Your library stays on this Mac. | *(removed)* |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 144 | Your library stays on this Mac. Turn sync on to keep it the same on your Macs and iPhone. | *(removed)* |
| `Sources/Daybook/UI/SyncSettingsView.swift` | 179 | ) from the folder this Mac synced through before. | ) from the previous sync folder |
| `Sources/Daybook/UI/TemplatesView.swift` | 145 | When a conversation’s template is Automatic, Daybook picks the template for the kind of conversation it detects. | Chosen automatically for this kind of conversation. |
| `Sources/Daybook/UI/TemplatesView.swift` | 168 | Daybook follows these instructions when it summarizes. Describe the purpose, the sections you want, and the tone. | Describe the purpose, the sections you want, and the tone. |
| `Sources/Daybook/UI/TranscriptPage.swift` | 27 | The transcript appears here once the audio is transcribed. | Not transcribed yet. |
| `Sources/Daybook/UI/TranscriptPage.swift` | 87 | Couldn’t line up the \(name) recording with the others, so its passages are listed separately. | Couldn’t line up the \(name) recording with the others. |
| `Sources/Daybook/UI/TranscriptPage.swift` | 361 | Return to save · Esc to cancel · The original stays in Version History. | Return to save · Esc to cancel |
| `Sources/Daybook/UI/WelcomeWindow.swift` | 106 | Everything is transcribed and summarized here. Nothing is uploaded. | Transcribed and summarized here. Nothing is uploaded. |
| `Sources/Daybook/UI/WelcomeWindow.swift` | 166 | Daybook downloads its models once and runs them on this Mac. | Models download once and run on this Mac. |
| `Sources/Daybook/UI/WelcomeWindow.swift` | 277 | Start a conversation now. Daybook transcribes it as soon as the models finish downloading. | Start a conversation now. It’s transcribed once the models download. |
| `Sources/Daybook/UI/WelcomeWindow.swift` | 277 | Start a conversation now. Daybook transcribes and summarizes it on this Mac. | Start a conversation now. |
| `Sources/Daybook/UI/WelcomeWindow.swift` | 277 | Start a conversation now. Daybook transcribes it once you download models in Settings. | Start a conversation now. Download models in Settings to transcribe it. |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 25 | Record with Daybook on your iPhone. Its recordings arrive through iCloud, and it can record along with this Mac. | Record on your iPhone, on its own or along with this Mac. |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 28 | Recordings made with Daybook on the iPhone arrive with the rest of your library. There’s nothing to set up here. | Nothing to set up. |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 31 | Pair the iPhone to start and stop recordings together and to see transcription progress on it. | Pair the iPhone to record together. |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 38 | Your iPhone keeps its own recordings. This Mac only asks it to start or stop, and audio never travels over Wi‑Fi: it arrives through iCloud. | *(removed)* |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 44 | Recordings you make with Daybook on this iPhone appear here once they sync. | *(removed)* |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 93 | Its recordings arrive with your library’s iCloud sync. | On |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 93 | Sync is off, so its recordings can’t arrive. Turn it on in Settings › Library. | Sync is off |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 113 | Recordings from your iPhone arrive through iCloud sync. Turn it on in Settings › Library. | Turn on sync to get your iPhone’s recordings. |
| `Sources/DaybookDevices/DaybookPhone/DaybookPhone.swift` | 124 | Recordings from Daybook on iPhone arrive through sync. | Nothing to import from iPhone. |
| `Sources/DaybookDevices/Files/ImportFolderWatcher.swift` | 68 | Export recordings and save them to a folder. Daybook imports new audio from it. | No folder chosen |
| `Sources/DaybookDevices/Files/ImportFolderWatcher.swift` | 291 | Daybook can’t find the import folder. It may have been moved or renamed. | Choose it again if it was moved or renamed. |
| `Sources/DaybookDevices/Framework/DaybookError.swift` | 9 | Local changes could not be saved:  | Couldn’t save changes:  |
| `Sources/DaybookDevices/Framework/DaybookError.swift` | 12 | No speech was recognized. Your recording is saved; check the source audio or try another transcription model. | No speech was recognized. |
| `Sources/DaybookDevices/Framework/DeviceSession.swift` | 574 | Nothing from this transfer was saved. The recording is still on your \(name). | The recording is still on your \(name). |
| `Sources/DaybookDevices/Framework/DeviceSession.swift` | 578 | Some audio didn’t arrive intact, so Daybook didn’t save it. The recording is still on your \(name). | Some audio didn’t arrive intact. The recording is still on your \(name). |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | 1 recording imported from \(device). | 1 recording imported. |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | \(count) recordings imported from \(device). | \(count) recordings imported. |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | Your Mac transcribes it once it syncs. | *(removed)* |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | Your Mac transcribes them once they sync. | *(removed)* |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | It’s being transcribed on this Mac. | *(removed)* |
| `Sources/DaybookDevices/Framework/DeviceSupport.swift` | 57 | They’re being transcribed on this Mac. | *(removed)* |
| `Sources/DaybookDevices/OtherRecorder/OtherRecorder.swift` | 18 | Any recorder that saves audio files. Daybook imports new audio from a folder. | Any recorder that saves audio files. |
| `Sources/DaybookDevices/OtherRecorder/OtherRecorder.swift` | 21 | Save or export recordings to a folder, for example in iCloud Drive. Daybook imports new audio from it, and your files stay where they are. | Save or export recordings to a folder, such as one in iCloud Drive. |
| `Sources/DaybookDevices/OtherRecorder/OtherRecorder.swift` | 26 | Your files stay where they are. Daybook copies new audio into your library and never changes the folder. | *(removed)* |
| `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift` | 191 | Managed by \(owner.ownerName). Its recordings arrive through sync. | Managed by \(owner.ownerName) |
| `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift` | 194 | Connected. New recordings import on their own. | Connected |
| `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift` | 194 | Connected. New recordings import when you choose. | *(removed)* |
| `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift` | 199 | Import straight from the recorder, without your phone. | Not set up |
| `Sources/DaybookDevices/Soundcore/SoundcoreConnection.swift` | 202 | Connects on its own when it’s nearby. | Connects when it’s nearby. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 17 | Imports straight from the recorder over Bluetooth, or from the Soundcore app. | Over Bluetooth, or from the Soundcore app. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 20 | Import straight from the recorder, without your phone or the cloud. New recordings arrive on their own when it’s nearby. | Straight from the recorder. New recordings import on their own when it’s nearby. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 24 | Export recordings in the Soundcore app and save them to a folder. Daybook imports new audio from that folder. Works with every firmware version. | Export recordings from the Soundcore app to a folder. Works with every firmware version. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 27 | Not supported: Daybook never sends audio off this Mac to be processed. | Not supported. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 32 | Recordings stay on your Soundcore. Daybook only reads from it. It never deletes, resets, or updates it. | *(removed)* |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 34 | Take it out of its case. It sleeps while it’s in the case. | Take it out of its case. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 34 | Close the Soundcore app on your phone. The recorder connects to one device at a time. | Close the Soundcore app on your phone. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 84 | Its firmware may work differently from what Daybook expects. The import folder still works. | Use the Soundcore app and an import folder instead. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 87 | Nothing from this transfer was saved. The recording is still on your Soundcore, and importing continues when it reconnects. | The recording is still on your Soundcore. Importing continues when it reconnects. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 87 | Nothing from this transfer was saved. The recording is still on your Soundcore. | The recording is still on your Soundcore. |
| `Sources/DaybookDevices/Soundcore/SoundcoreWork.swift` | 90 | Some audio didn’t arrive intact, so Daybook didn’t save it. The recording is still on your Soundcore. | Some audio didn’t arrive intact. The recording is still on your Soundcore. |
| `Sources/DaybookKit/LibraryController.swift` | 69 | The previous session was interrupted. Your saved audio and notes are intact; choose Process to continue. | Processing was interrupted. Your audio and notes are saved. |
| `Sources/DaybookKit/LibraryController.swift` | 720 | Turn off sync to restore a conversation from the Trash. Sync keeps deletions final. | Turn off sync to restore a conversation from the Trash. |
| `Sources/DaybookKit/RecorderHandoff.swift` | 841 |  (\(parts.joined(separator:  | *(removed)* |
| `Sources/DaybookKit/RecorderHandoff.swift` | 841 | An import in progress\(what) can’t move between devices, so it finishes first. Then \(recorder) moves to \(here). | *(removed)* |
| `Sources/DaybookKit/RecorderHandoff.swift` | 847 | What it heard is saved as a conversation. \(recorder) keeps recording. | \(recorder) keeps recording. |
| `Sources/DaybookKit/RecorderHandoff.swift` | 850 | \(owner) hasn’t answered since \(since.formatted(date: .omitted, time: .shortened)). It may be asleep, closed, or offline. You can take over now. | \(owner) hasn’t answered since \(since.formatted(date: .omitted, time: .shortened)). |
| `Sources/DaybookKit/RecorderHandoff.swift` | 850 | \(owner) isn’t on this network, so the request goes through iCloud. It lets go the next time it syncs. | *(removed)* |
| `Sources/DaybookKit/RecorderHandoff.swift` | 855 | \(from) let go. \(recorder) connects here as soon as it answers; keep it nearby. | Keep \(recorder) nearby. |
| `Sources/DaybookKit/RecorderHandoff.swift` | 855 | It can’t move to \(to) part-way, so it finishes here. Recordings still waiting import on \(to). | *(removed)* |
| `Sources/DaybookKit/RecorderHandoff.swift` | 870 | \(here.capitalizedFirstLetter) manages \(recorder) from now on. If \(owner) is still connected to it, \(recorder) may not answer here until \(owner) hears about this and lets go, finishing any import first. Nothing on \(recorder) is lost. | \(recorder) may not answer \(here) until \(owner) lets go. Nothing on \(recorder) is lost. |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | iCloud reported conflicting sync library identities. Synchronization paused; the existing manifest versions were preserved. | iCloud has two conflicting copies of this library, so sync is paused. |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | This sync library uses unsupported version \(version). Update Daybook before synchronizing. | This library was synced by a newer Daybook (version \(version)). Update Daybook to sync. |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | A sync journal entry failed validation: \(name). | A synced change couldn’t be read: \(name). |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | An audio sync object failed its SHA-256 integrity check: \(name). | A synced recording was damaged: \(name). |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | The original recording is missing or changed: \(name). It has not been marked as uploaded. | The original recording is missing or changed: \(name). |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | The local sync checkpoint is unreadable. Synchronization stopped to preserve its causal history. | Sync stopped: this device’s sync record is unreadable. |
| `Sources/DaybookCore/LibrarySync.swift` | 32 | This sync result has been superseded. Synchronize again before acknowledging local changes. | Sync again to finish. |
| `Sources/DaybookCore/LibrarySync.swift` | 153 | Some sync journal ancestors are not available yet. Dependent changes will wait for the next sync. | Some changes are waiting for the next sync. |
| `Sources/DaybookCore/LibrarySync.swift` | 276 | The same recording appears in multiple conversations. They remain separate so unrelated conversations are not combined automatically. | The same recording is in more than one conversation. They stay separate. |
| `Sources/DaybookCore/LibrarySync.swift` | 283 | Library organization and templates are waiting for sync metadata ancestors. | Folders and templates are waiting for the next sync. |
| `Sources/DaybookCore/LibrarySync.swift` | 638 | iCloud is downloading a sync object. Changes will be retried when it becomes available. | Waiting for iCloud to download a change. |
| `Sources/DaybookCore/MeetingStore.swift` | 8 | Meeting \(id.uuidString) has no readable metadata or recovery copy. Its recordings remain on disk. | A conversation couldn’t be read. Its recordings are still in the library folder. |
| `Sources/DaybookCore/MeetingStore.swift` | 8 | This library uses newer metadata version \(version). Update Daybook before opening it. | This library was made by a newer Daybook. Update Daybook to open it. |
| `Sources/DaybookCore/MeetingStore.swift` | 8 | \(name) is not a readable, nonempty recording file. | \(name) has no readable audio. |
| `Sources/DaybookCore/MeetingStore.swift` | 13 | Meeting \(id.uuidString) is in Daybook's local Trash. Restore it before editing. | This conversation is in the Trash. Restore it to edit it. |
| `Sources/DaybookCore/MeetingStore.swift` | 13 | Meeting \(id.uuidString) was not found in the local library. | This conversation isn’t in the library. |
| `Sources/DaybookCore/MeetingStore.swift` | 85 | Recovered \(meeting.title) from the previous saved metadata; original audio is unchanged. | Recovered “\(meeting.title)” from its last saved copy. |
| `Sources/DaybookCore/SyncReplica.swift` | 240 | \(name) can’t be downloaded: its sync reference is invalid. | \(name) can’t be downloaded. |
| `Sources/DaybookCore/SyncReplica.swift` | 242 | The copy of \(name) in iCloud didn’t match its fingerprint, so it wasn’t installed. Nothing in your library changed. | The copy of \(name) in iCloud is damaged. Nothing in your library changed. |
| `Sources/DaybookCore/SyncReplica.swift` | 244 | This recording hasn’t finished uploading from the device that made it. | This recording hasn’t finished uploading. |
| `Resources/Info.plist` | 13 | Daybook connects to your Soundcore Work recorder to show device status and import recordings you choose. | Daybook connects to your Soundcore Work to import its recordings. |
| `Resources/Info.plist` | 13 | Daybook records your voice during meetings you choose to capture. Audio is processed locally and can sync through iCloud when you enable it. | Daybook records your voice in the conversations you record. |
| `Resources/Info.plist` | 13 | Daybook records meeting audio from your Mac so both sides of a conversation can be transcribed locally. | Daybook records call audio so both sides of a conversation are transcribed. |
| `Resources/Info.plist` | 13 | Daybook shows tentative live captions on this Mac while it records. The transcript, made on this Mac, replaces them. | Daybook shows live captions while it records. |
| `Resources/Info.plist` | 13 | Daybook uses macOS system audio capture for online meetings. No screen video is saved. | Daybook records call audio. No screen video is saved. |
| `Resources/Info.plist` | 21 | Daybook connects to Daybook on your iPhone over your local network to record together and share progress. | Daybook finds your iPhone on this network to record together. |
| `Apps/iOS/DaybookPhone/App/MacPresence.swift` | 61 | Waiting for iCloud. Your Mac transcribes it once this iPhone syncs. | Waiting for iCloud |
| `Apps/iOS/DaybookPhone/App/MacPresence.swift` | 77 | \(name) is connected and transcribes your recordings. | \(name) is connected. |
| `Apps/iOS/DaybookPhone/App/MacPresence.swift` | 81 | A Mac with an earlier version of Daybook syncs this library. | A Mac with an earlier Daybook syncs this library. |
| `Apps/iOS/DaybookPhone/App/MacPresence.swift` | 81 | No Mac has synced this library yet. Open Daybook on your Mac to transcribe recordings. | No Mac has synced this library yet. Open Daybook on your Mac. |
| `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift` | 185 | Not transcribed yet. Your Mac will transcribe it. | Not transcribed yet |
| `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift` | 540 | A recording is still in recovery storage: \(error.localizedDescription) | Couldn’t recover a recording: \(error.localizedDescription) |
| `Apps/iOS/DaybookPhone/App/PhoneSync.swift` | 118 | iCloud isn't available for Daybook right now (\(controller.status)). Recordings stay on this iPhone until it is. | iCloud isn't available for Daybook right now. Try again in a moment. |
| `Apps/iOS/DaybookPhone/Captions/LiveCaptionsView.swift` | 94 | Downloading captions for \(LiveCaptionAvailability.name(model.settings.captionLocale))\(percent). The recording isn't affected. | Downloading captions for \(LiveCaptionAvailability.name(model.settings.captionLocale))\(percent) |
| `Apps/iOS/DaybookPhone/Captions/LiveCaptionsView.swift` | 96 | Captions stopped. The recording continues. | Captions stopped |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 20 | Bring in recordings from Soundcore Work over Bluetooth, or from any recorder that saves audio files. They sync to your Mac to be transcribed. | Add Soundcore Work, or any recorder that saves audio files. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 20 | New recordings import on their own and sync to your Mac to be transcribed. | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 166 | With automatic import on, new recordings come in when the recorder is near this iPhone, even while Daybook is closed. Recordings from before you added it are listed above to import by choice. Hand back returns a recorder you took from your Mac when that Mac is on the same Wi‑Fi and the recorder is idle here. | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 203 | Recordings already imported stay in your library. Another device can then manage this recorder. | Recordings already imported stay in your library. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 395 | Daybook only reads from recorders. It never deletes recordings or changes a recorder's settings. | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 439 | Import straight from the recorder, without the Soundcore app or the cloud. New recordings arrive on their own when it's near this iPhone. | Straight from the recorder. New recordings import on their own when it’s near this iPhone. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 488 | Save or export recordings to a folder in Files, such as one in iCloud Drive. Daybook imports new audio from it; your files stay where they are. | Save or export recordings to a folder in Files, such as one in iCloud Drive. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 538 | without your phone | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 538 | without the Soundcore app | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 543 | Imports straight from the recorder over Bluetooth, even while Daybook is closed. | Over Bluetooth, even while Daybook is closed. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 553 | Take it out of its case. It sleeps while it's in the case. | Take it out of its case. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 553 | Close the Soundcore app. The recorder connects to one device at a time. | Close the Soundcore app. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 553 | If your Mac manages it, it lets go after a few idle minutes. | If your Mac manages it, wait a few minutes. |
| `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift` | 571 | Its firmware may work differently from what Daybook expects. Export from the Soundcore app and import the file instead. | Export from the Soundcore app and import the file instead. |
| `Apps/iOS/DaybookPhone/Devices/UI/RecorderHandoffViews.swift` | 65 | A recorder connects to one device at a time. \(owner.ownerName) imports its recordings; they reach this iPhone through iCloud. | *(removed)* |
| `Apps/iOS/DaybookPhone/Devices/UI/RecorderHandoffViews.swift` | 73 | This iPhone finishes any import and lets go; \(mac.name) connects | This iPhone finishes any import first |
| `Apps/iOS/DaybookPhone/Library/CloudAvailability.swift` | 18 | iCloud isn't set up for this build, so recordings stay on this iPhone. | iCloud isn't set up for this build. |
| `Apps/iOS/DaybookPhone/Library/CloudAvailability.swift` | 42 | iCloud isn't available, so recordings stay on this iPhone until you sign in to iCloud Drive. | Sign in to iCloud Drive to sync your recordings. |
| `Apps/iOS/DaybookPhone/Library/CloudAvailability.swift` | 46 | iCloud isn't available for Daybook on this iPhone, so recordings stay here for now. | Turn on iCloud Drive for Daybook in Settings to sync your recordings. |
| `Apps/iOS/DaybookPhone/Link/PhoneLink.swift` | 38 | Connected · transcribes recordings | Connected |
| `Apps/iOS/DaybookPhone/Link/PhoneLink.swift` | 198 | The Mac isn't showing a code. Open Daybook › Settings › iPhone on your Mac. | The Mac isn't showing a code. On your Mac, open Daybook › Settings › Devices and add your iPhone. |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 21 | Pairing lets your Mac record together with this iPhone and show transcription progress live, on the same Wi-Fi. Everything else syncs through iCloud. | *(removed)* |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 21 | On the same Wi-Fi, a paired Mac can record with this iPhone and shows its progress live. | *(removed)* |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 84 | Unpairing stops this iPhone and the Mac from connecting directly. Sync through iCloud continues. Pair again with a new code from the Mac. | *(removed)* |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 101 | This Mac is no longer paired. | *(removed)* |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 136 | On your Mac, open Daybook › Settings › iPhone and choose Pair iPhone. It shows a six-digit code. | On your Mac, open Daybook › Settings › Devices and add your iPhone. It shows a six-digit code. |
| `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift` | 266 | Codes work once. If one doesn't match, your Mac shows a new one. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Captions/SavedCaptions.swift` | 66 | Live captions from this iPhone · tentative. Your Mac will replace these with the full transcript. | Live captions · tentative |
| `Apps/iOS/DaybookPhone/Reading/Conversation/ConversationScreen.swift` | 41 | The transcript appears once your Mac transcribes the audio. | Not transcribed yet |
| `Apps/iOS/DaybookPhone/Reading/Conversation/ConversationScreen.swift` | 49 | It may have been moved to the Trash on another device. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Conversation/SummaryPage.swift` | 433 | Choosing another template asks your Mac to summarize again. | Choosing another template summarizes again. |
| `Apps/iOS/DaybookPhone/Reading/Conversation/TranscriptPage.swift` | 116 | ) in this conversation. The old name stays in Version History. | ) in this conversation. |
| `Apps/iOS/DaybookPhone/Reading/Conversation/TranscriptPage.swift` | 154 | Couldn’t line up the \(name) recording with the others, so its passages are listed separately. | Couldn’t line up the \(name) recording with the others. |
| `Apps/iOS/DaybookPhone/Reading/Conversation/TranscriptPage.swift` | 425 | This conversation is notes only. Record into it on your Mac to add a transcript. | Record into it on your Mac to add a transcript. |
| `Apps/iOS/DaybookPhone/Reading/Conversation/TranscriptPage.swift` | 430 | Your Mac will transcribe this recording. Until then you can play it, add notes and bookmarks, and file it. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Conversation/YourNotes.swift` | 25 | Add a note. Notes are yours; your Mac reads them when it summarizes. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift` | 62 | Folders sync to your Mac. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift` | 70 | Their audio and notes are kept in the Trash. | Their audio and notes go with them. |
| `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift` | 198 | Recordings you make here appear in this list, and on your Mac once they sync. | Conversations you record or import appear here. |
| `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift` | 205 | Conversations about work appear here automatically. You can also move any conversation here. | Conversations about work appear here automatically. |
| `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift` | 208 | Therapy sessions and personal conversations appear here automatically. | Personal conversations appear here automatically. |
| `Apps/iOS/DaybookPhone/Reading/Library/LibrarySheets.swift` | 34 | Conversations in the Trash keep their audio and notes. Swipe right to restore one. | Swipe right to restore a conversation. |
| `Apps/iOS/DaybookPhone/Reading/Library/LibrarySheets.swift` | 44 | Conversations you move to the Trash appear here, with their audio and notes. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/LibraryBrowser.swift` | 208 | Its page opens here, beside the list. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift` | 48 | Not transcribed yet. Your Mac will transcribe it. | Not transcribed yet |
| `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift` | 143 | No Mac has checked in yet. Open Daybook on your Mac to transcribe. | No Mac has checked in yet. Open Daybook on your Mac. |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift` | 24 | Recordings of the same conversation are lined up on one timeline, by their sound or by what was said. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift` | 93 | Speakers appear after your Mac transcribes the audio. | No speakers yet |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift` | 249 | In iCloud · downloads when played (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) | In iCloud · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift` | 249 | In iCloud · downloads when played | In iCloud |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift` | 91 | Restored. What was there is kept in Version History. | Restored |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift` | 118 | The text from before this change comes back. What’s there now is kept in Version History, so you can return to it. | What’s there now stays in Version History. |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift` | 173 | The original stays in Version History. | *(removed)* |
| `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift` | 237 | The transcript shows this passage once, worded by the recordings that heard it best. | *(removed)* |
| `Apps/iOS/DaybookPhone/Recording/CaptureJournal.swift` | 163 | This recording folder already holds a recording; a new folder keeps it safe. | This recording folder is already in use. Start the recording again. |
| `Apps/iOS/DaybookPhone/Recording/CaptureJournal.swift` | 163 | The audio encoder couldn't continue (\(detail)). Recorded audio has been kept. | Recording couldn't continue (\(detail)). Everything up to then is saved. |
| `Apps/iOS/DaybookPhone/Recording/CaptureJournal.swift` | 163 | Storage couldn't keep up with the recording. Recorded audio has been kept. | Storage couldn't keep up with the recording. Everything up to then is saved. |
| `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift` | 356 | Tap Bookmark to mark a moment. It's kept with its time, here and on your Mac. | Tap Bookmark to mark a moment. |
| `Apps/iOS/DaybookPhone/Resources/Info.plist` | 56 | Daybook connects to your Soundcore Work recorder to bring its recordings into your library. | Daybook connects to your Soundcore Work to import its recordings. |
| `Apps/iOS/DaybookPhone/Resources/Info.plist` | 62 | Daybook finds your Mac on this network to record together and to show transcription progress. | Daybook finds your Mac on this network to record together. |
| `Apps/iOS/DaybookPhone/Resources/Info.plist` | 64 | Daybook records your conversations with the microphone. Recordings stay on your devices and are transcribed by your Mac. | Daybook records your conversations with the microphone. |
| `Apps/iOS/DaybookPhone/Resources/Info.plist` | 66 | Daybook shows tentative live captions on this iPhone while it records. Your Mac's transcript replaces them. | Daybook shows live captions while it records. |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 42 | A conversation is summarized with the template chosen for it, or one picked from what it's about. Changes reach your Mac with the next sync. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 78 | This template was deleted on another device. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 108 | Conversations of this kind use this template when none is chosen. | Chosen automatically for this kind of conversation. |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 117 | Your Mac follows these when it writes the summary. Start with the purpose, then the sections to use. | Start with the purpose, then the sections to use. |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 180 | Add names, products, and words your Mac should spell your way. Summaries also suggest terms here. | Add names, products, and words to spell your way. |
| `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift` | 218 | Found in your summaries. A suggestion is used only for its own conversation until you add it. | Found in your summaries. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 51 | Templates and vocabulary sync with your Mac, which uses them when it transcribes and summarizes. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 88 | Your Mac transcribes each recording | Transcribes automatically |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 88 | Recordings wait until you ask | Transcribes when you ask |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 163 | Each recording asks your Mac to transcribe and summarize it. The conversation says \u{201C}Waiting for your Mac\u{201D} until it does. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 163 | Recordings say \u{201C}Not transcribed yet\u{201D} until you choose Transcribe. A Mac that processes new audio on its own may still transcribe them. | Recordings wait until you choose Transcribe. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 170 | When a paired Mac starts recording, it can start this iPhone too, and both recordings join one conversation. While recording here, you can ask a connected Mac to record too. | A paired Mac can start and stop recordings on this iPhone. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 176 | Shows the clock, Bookmark, and Stop while recording. Recordings started from Siri, the Action button, or your Mac always show it, as iOS requires. | Shows the clock, Bookmark, and Stop while recording. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 185 | iPhone records its own microphone only: iOS doesn't let apps record another app's audio or phone calls. On a call, your Mac records the call. | Records this iPhone’s microphone only, not calls or other apps. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 206 | Recordings, notes, and transcripts stay on your devices and in your iCloud. Transcription, speaker identification, and summaries run on your Mac; nothing is sent to a server. | Recordings, notes, and transcripts stay on your devices and in your iCloud. |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 206 | Your iPhone and Mac talk directly on your Wi-Fi only for recording together and showing progress, encrypted with a key made when you paired them. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 206 | Daybook reads recordings from Soundcore Work directly over Bluetooth. It never deletes, resets, or updates the recorder. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 256 | Tentative captions made on this iPhone show that it's hearing the conversation. They stay on this iPhone, and your Mac's transcript replaces them. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift` | 261 | \(about) Captions for \(LiveCaptionAvailability.name(locale)) download from Apple the first time you record with them on. | Captions for \(LiveCaptionAvailability.name(locale)) download the first time you record with them on. |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 51 | Recording, notes, and playback of recordings made here keep working. Everything syncs once iCloud is available. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 51 | Conversations, notes, and summaries arrive at once. Audio downloads when you play it, and recordings made here upload in the background. \(model.macPresence.summary()) | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 103 | Each device writes a small record when it syncs. A Mac with an earlier version of Daybook appears without a name. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 167 | Played recordings stay here for next time, up to this much. The least recently played go back to iCloud first and download again when played. Recordings made here stay until iCloud has them. | *(removed)* |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 186 | Freed \(bytes(cleared)). It downloads again when you play it. | Freed \(bytes(cleared)). |
| `Apps/iOS/DaybookPhone/Settings/SyncSettings.swift` | 188 | Conversations, transcripts, and notes stay. Only downloaded audio is removed, and it's still in iCloud. | Only downloaded audio is removed. |
| `Apps/iOS/DaybookPhone/Status/StatusSheet.swift` | 310 | Off · recordings stay on this iPhone | Off |
| `Apps/iOS/DaybookPhone/Status/StatusSheet.swift` | 469 | Add Soundcore Work to import over Bluetooth, even while Daybook is closed. | *(removed)* |
| `Apps/iOS/DaybookPhone/Status/StatusSheet.swift` | 507 | Tentative captions from this iPhone. Your Mac transcribes the recording properly. | Live captions · tentative |
| `Apps/iOS/DaybookPhone/Status/StatusSheet.swift` | 714 | Pair your Mac to start recordings together and see transcription as it happens. | *(removed)* |
| `Apps/iOS/DaybookPhone/Status/StatusSheetModel.swift` | 267 | Reachable once iCloud is | Waiting for iCloud |
| `Apps/iOS/DaybookPhone/UI/RecorderControls.swift` | 78 | Your Mac transcribes recordings after they sync. | *(removed)* |
| `Apps/iOS/DaybookPhoneWidgets/RecordingLiveActivity.swift` | 160 | Saved to Daybook. Your Mac will transcribe it. | Saved to Daybook |
| `Apps/iOS/Shared/RecordingIntents.swift` | 50 | Records a conversation with the iPhone's microphone. Your Mac transcribes it. | Records a conversation with the iPhone's microphone. |
