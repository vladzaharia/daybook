# Security and privacy: recordings, transcripts, keys (Mac and iPhone)

Reviewer lane: security and privacy of sensitive content. Reviewed the working tree on `design-pass-2026-11` (HEAD `1f6f1ba0`) against `docs/audits/2026-11-01/security.md` and `icloud.md`. I didn't re-report anything those audits fixed. Everything here was checked against code; anything that needs a device or a signed build says so.

## 1. Summary

The cryptographic core is in good shape, and I found no exploitable flaw in it:
- **Link pairing** uses passkey entry modelled on Bluetooth LE Secure Connections: P‑256, 20 commit/reveal rounds, codes burned after any failure, and pairing closes after 5 failures. Sessions run over TLS 1.2 ECDHE‑PSK with ChaCha20, and session authentication is bound to the TLS exporter.
- **Sync sealing (DBSEAL‑1)** derives a key per object with HKDF, uses the chunk index as the AES‑GCM nonce, and authenticates the header.
- **Keys** use sensible keychain classes. Model downloads are pinned to a commit and checked against SHA‑256, cloud requests use an ephemeral session, and there's no telemetry anywhere.

The risk sits around that core, in four places where a sensitive conversation reaches somewhere the person wouldn't expect:
1. **Personal conversations and the cloud.** "Use the cloud: Always" still sends a conversation the app already knows is Personal (filed there, or given the Therapy or Personal template) to Anthropic or OpenAI, and cloud upgrades are still offered for it. This is the open owner decision ux-mac-10. I recommend closing it as described in section 4.
2. **iPhone backups of an encrypted library.** Folders and files outside the four excluded folders still go into iCloud Backup in plaintext. That includes `library.json`: speaker names, voiceprints (biometric voice embeddings) and the vocabulary.
3. **Surfaces outside the app don't share one rule.** Spotlight and two widgets keep Personal out, but the Recorder widget shows the newest conversation's title whatever it is. The live transcript on the Lock Screen depends on a `.privacySensitive()` redaction that hasn't been checked on a device, and the Mac's Spotlight index holds summary text.
4. **Capture scope.** With no call app known, "Include computer audio" (on by default) records everything the Mac plays through ScreenCaptureKit, while the recorder only says "Call".

At rest, both platforms rely on the operating system's weakest useful default:
- On iPhone, every file is protection class C (readable from a locked phone after its first unlock).
- On Mac, the unsandboxed Developer ID library can be read silently by any process the user runs.

Neither app has a lock for Personal conversations. The biggest opportunities, in order:
1. A single "Personal stays on this device and out of sight" rule, enforced in code everywhere.
2. Closing the backup gap.
3. Shipping the Mac sandbox (it brings macOS's App Data protection).
4. An optional Face ID / Touch ID lock for Personal conversations.

### Threat model at a glance

| Attacker has | What they get today | After the proposals |
|---|---|---|
| The unlocked Mac (a family member, an unattended desk) | Everything: the library opens without authentication, Personal included. The menu bar and notifications hide Personal titles, but the app doesn't. | Personal conversations stay behind Touch ID or the login password (P5). |
| Code running as the user on the Mac (a malicious npm/pip package, a compromised app) | Every recording, transcript and voiceprint in `~/Library/Application Support/Daybook`, with no prompt (not sandboxed). | A sandboxed container: other apps reading it trigger macOS's "access data from other apps" prompt (P6). |
| A locked iPhone after its first unlock, via a forensic extraction | Everything (class C). | Recordings in progress use class B, and an opt‑in mode protects the library while the phone is locked (P4). |
| The iPhone's iCloud Backup (Apple, legal process, or a compromised Apple Account without Advanced Data Protection), with an encrypted library | Voiceprints, people's names, vocabulary, templates and folders (`library.json`), recordings still in `Staging/`, the widgets' app‑group state (titles) | Library settings stay out like the rest (P2). |
| The Apple Account password, but no trusted device's passcode | Sealed files only, plus the plaintext presence essentials docs/icloud-sync.md lists. iCloud Keychain protects the keys. | Same. |
| A passer‑by at the locked iPhone | Recording state and the Stop and Bookmark buttons (by design). Titles and captions only if redaction fails (unverified). | Captions are dropped from the Live Activity at lock, whatever each surface does (P3). |
| Participants in a screen share | Possibly Floating Notes (your notes and live captions), if ScreenCaptureKit ignores `sharingType = .none` (public reports say it does on macOS 15+). | Checked before relying on it, with a fallback (F‑06). |

## 2. Redesign proposals

### P1. Personal never leaves the device by itself (closes ux-mac-10) — S

**What.** A conversation whose placement is Personal is never summarized in the cloud automatically and gets no cloud upgrade offers. That covers an explicit placement and the Therapy or Personal template (`LibraryPlaces.swift:28-35`, `case .therapy, .personal: return .personal`). The cloud stays available through an explicit tap: the existing **Use the Cloud** action on the countdown. After the first local summary finds a conversation Personal, it stops offering cloud upgrades too.

**Why.** docs/cloud.md promises that "Everything else stays on the device", and the app's own Personal rule says Personal is never named outside the app. Sending a therapy session to a third party because of a global preference set for work calls breaks the person's mental model. Privacy by default says the safer choice wins where the app already knows the content is personal.

**Where.**
- `Sources/DaybookKit/SummaryPlacementPlanner.swift:170`: `if preferences.policy == .always, let cloud { return .started(.cloud(cloud)) }` becomes `… let cloud, !isPersonal`. Personal then falls through to the existing local target and countdown; with no local target it goes to `.waitingForMac`, which still shows Use the Cloud.
- `SummaryOptions` (`CloudInterfaces.swift`) gains `isPersonal`, filled from `meeting.effectivePlacement == .personal` where the placements are updated (`Sources/Daybook/App/AppState+SummaryPlacement.swift:37` and the iPhone's equivalent).
- `Sources/DaybookKit/Upgrades.swift:199`: skip the `.cloud` candidate when the conversation is Personal.

**Sketch.** For a Personal conversation under Always, the status line reads "Summarizing on this Mac in 15 s", with Use the Cloud beside it as today in Offer First. A Personal conversation's page never shows "Upgrade with Claude …".

**Risk.** A conversation of automatic kind (no template, no placement) still goes to the cloud under Always before its kind is known. That's inherent, and acceptable because the person chose Always. A person who wants the cloud for Personal taps it each time. Tests: the `SummaryPlacementPlanner` and `Upgrades` suites.

### P2. Keep an encrypted library's settings out of iPhone backups — S

**What.** When `BackupExclusion.Library` is `.withoutEncryptedFolders`, the files listed under Where also stay out of backups. They are already in the sealed journal as settings versions, so they're restorable exactly as `Meetings/` is: the stated reason for excluding the four folders (docs/iphone.md:46-47).

**Why.** `encryptedLibraryFolders` is only `["Meetings", "Trash", "Sync", "LiveCaptions"]` (`Apps/iOS/DaybookPhone/Library/BackupExclusion.swift:35-36`). `library.json` sits at the library root (`Sources/DaybookCore/MeetingStore+Library.swift:26-27`) and holds `speakerProfiles` and `voiceprints` (`LibraryMetadata.swift:277-281`), vocabulary, templates and folders. So an iCloud Backup without Advanced Data Protection hands Apple, in plaintext, the most sensitive library‑wide data: names of the people in the person's life, and voice embeddings that identify them. The test asserts the four folders only (`BackupExclusionTests.swift:46-73`).

**Where.**
- Exclude `library.json`, `library.recovery.json`, any `library.damaged-*.json`, and `glossary.json` / `glossary.recovery.json` when present.
- `isExcludedFromBackup` is an attribute of the file, and every save replaces the file:
  - `saveLibraryMetadata` swaps a new inode in with `renamex_np(… RENAME_SWAP)` (`MeetingStore+Library.swift:73`).
  - `LocalFiles.atomicWrite` writes a new file (`MeetingStore.swift:482`).
  
  Re‑applying after each sync pass leaves a window after every edit. Use the pattern `SharedWidgetCache.save` already has (`Apps/iOS/Shared/SharedWidgetCache.swift:46-53`): mark the temporary file excluded **before** the rename, so the attribute moves with the inode. Concretely, an optional `backupExcluded: Bool` on `LocalFiles.atomicWrite` and on `saveLibraryMetadata`'s temporary file, driven by a store flag the iPhone sets from `BackupExclusion.library(…)`. Keep `BackupExclusion.apply` re‑setting it as a safety net.
- docs/iphone.md "Backups": list the settings files with the four folders.

**Risk.** Restoring a backup to a new iPhone then gets folders, templates, vocabulary and voiceprints from iCloud rather than from the backup, the same as conversations. A person with an encrypted library who never syncs again would lose them, which is the same trade the doc already makes for conversations. `Staging/` stays in deliberately (docs/iphone.md:47); leave it, but say so in Settings' footer only if the person asks for it.

### P3. One rule for every surface outside the app — S to M

**What.** Personal conversations never appear outside Daybook's windows, and what does appear there stays on this device. Make `ConversationIndex.isShown` (iPhone) / `ConversationEntity.isShown` (Mac) the single gate, and apply it to every surface that currently skips it:

| Surface | Today | Change |
|---|---|---|
| Recorder widget (Home Screen small, Lock Screen rectangular, StandBy) | `state.lastRecordingTitle = latest.title` for the newest conversation, Personal or not (`Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:1048-1049`; shown at `RecorderWidget.swift:101-103,150-152`) | Use `library.conversations.first(where: ConversationIndex.isShown)`. Also clear it when the newest conversation becomes Personal, which `publish()` already does on library change. |
| Live Activity live caption (Lock Screen, Dynamic Island, and wherever the system mirrors Live Activities: Apple Watch Smart Stack, CarPlay, the Mac's menu bar in macOS 26) | Hidden only by `.privacySensitive()` (`RecordingLiveActivity.swift:177-185`). On‑device behavior is still "to check" (docs/validation.md:2710). | At the source: in `activityCaption(…)` (`PhoneAppModel.swift:1025`) return nil unless `UIApplication.shared.isProtectedDataAvailable`. Push an update on `protectedDataWillBecomeUnavailableNotification` / `…DidBecomeAvailable`. The caption then never leaves the app while the phone is locked, whatever any surface does with redaction. |
| Mac Spotlight | Indexes the summary overview (`attributes.contentDescription = gist`, `Sources/Daybook/App/Intents/ConversationEntity.swift:28-43`); the iPhone indexes titles only (`Apps/iOS/DaybookPhone/App/ConversationEntity.swift:6-7`) | Titles and dates only, as on iPhone. Summary text is then never copied into the system index, where the library's encryption, a future app lock (P5) and Trash don't reach. |
| Ink "Copy Text" (new in this branch) | `UIPasteboard.general.string = words` (`Sources/DaybookUI/Notes/NotesInk+TextView.swift:580`), so the words go to Universal Clipboard | `setItems([[UTType.utf8PlainText.identifier: words]], options: [.localOnly: true])`, as every other content copy does (`Apps/iOS/DaybookPhone/Reading/Model/ReadingSupport.swift:63-64`, `Sources/DaybookUI/ReadingSeams.swift:167`). |

**Why.** The app already has the right rule. The Mac's notifications and menu bar follow it (`MacNotifications.swift:148-151`, `MenuBarView.swift:245`), as do Recent Conversations, Next Steps and Spotlight on iPhone. These four surfaces predate the rule or were missed. A rule enforced in one helper can be tested once.

**Sketch.** The Recorder widget at rest reads "Daybook · Weekly product sync · 2 h ago", skipping the therapy session recorded since. A locked phone's Live Activity shows the clock, the hearing dot and the buttons, with no caption.

**Risk.** Almost none. A person who wants captions on a locked phone during a meeting loses them, but that's already the documented intent ("hidden while locked", docs/iphone.md:397). Add a `DesignParityTests` / `RecordingSurfacesTests` case for each surface.

### P4. iPhone Data Protection: stronger classes where they cost nothing, opt‑in where they do — S, then L

**What.** Today every file is class C (`completeUntilFirstUserAuthentication`). That's explicit for captures (`Apps/iOS/DaybookPhone/Recording/PhoneRecorder.swift:190-193`, `:401`), the capture journal (`Recording/CaptureJournal.swift:184`) and live captions (`Sources/DaybookCaptions/LiveCaptionStore.swift:160`), and it's the default everywhere else, since there's no `com.apple.developer.default-data-protection` entitlement. Anything that extracts a locked phone after first unlock (AFU) reads every recording and transcript.

1. **Recordings in progress (S):** create `Staging/<id>` with `FileProtectionType.completeUnlessOpen` (class B). The open writer keeps writing while locked, and class B lets new files (atomic journal writes, photos) be created while locked. Files keep their class when the conversation is filed into `Meetings/`, so its audio stays class B afterwards.
2. **Opt‑in "Protect while iPhone is locked" (L):**
   - The library's text (`meeting.json`, `library.json`, `LiveCaptions/`) gets `.complete` (class A), and audio gets `.completeUnlessOpen`.
   - Background sealing, sync and processing check `UIApplication.shared.isProtectedDataAvailable` before opening a file and wait for `protectedDataDidBecomeAvailableNotification`.
   - Settings › Storage gets one toggle. Its footer says only the cost: "Syncs and transcribes while unlocked."

**Why.** Class C protects only a phone that hasn't been unlocked since it restarted. For therapy and personal recordings, AFU extraction (law enforcement, border searches, a stolen phone sent to a forensic service) is the realistic threat. Apple's guidance is to use the strongest class the app's background work allows.

**Risk.**
- Step 1: crash recovery that relaunches in the background while the phone is locked can't read a closed journal until unlock. Recovery must wait for protected data rather than treat the journal as missing (`CaptureRecovery`). Also check interruption/resume and a route change while locked on a device.
- Step 2: sync and on‑device processing stop while the phone is locked, so iCloud receives a recording only after unlock, and the Mac's courier gets it later.

Device testing needed; this can't be verified in the Simulator.

### P5. A lock for Personal conversations (Mac and iPhone) — M per platform

**What.** An optional "Require Touch ID for Personal" (Mac) / "Require Face ID for Personal" (iPhone).
- Personal conversations stay listed (title hidden) and their pages, search hits and Floating Notes stay locked until `LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show Personal conversations")` succeeds.
- The unlock lasts until the screen locks:
  - Mac: `com.apple.screenIsLocked` (a `DistributedNotificationCenter` notification), sleep, or 10 minutes idle.
  - iPhone: `scenePhase == .background`.
- On iPhone, also cover Personal pages when `scenePhase != .active`, so the app switcher snapshot doesn't show them.
- For the whole app on iPhone, point to the system's own lock (iOS 18+: long‑press › Require Face ID) and test that Daybook's widgets, Live Activity and notifications behave under it, rather than building a second one.

**Why.** The table in section 1 shows the unlocked Mac and the unlocked iPhone as the most likely exposure for a therapy library, and nothing in the app addresses it today (no `LocalAuthentication` anywhere in `Sources/` or `Apps/iOS/`). It follows the pattern of Notes' locked notes.

**Where.**
- `LibraryPlaces.swift` (a `LibrarySection.personal` gate).
- Reading pages in `Sources/DaybookUI/Reading/`, search rows in `Sources/DaybookUI/Library/SearchResultRows.swift`, Floating Notes in `Sources/Daybook/UI/FloatingNotes/`.
- The iPhone needs `NSFaceIDUsageDescription` added to `Apps/iOS/project.yml` / `Info.plist`.

**Risk.** This is a UI lock, not encryption: it doesn't stop file access (that's P4 and P6) and must not block background processing. A forgotten password can't lock the person out, because `.deviceOwnerAuthentication` falls back to the device passcode or login password. It's off by default, and Settings says what it covers in one line.

### P6. Ship the Mac sandbox for what it protects — L (already planned)

**What.** Treat the Release N+1 sandbox switch (docs/sandbox.md) as a security fix too, and schedule it accordingly.

**Why.**
- The Developer ID build isn't sandboxed (`Resources/Daybook.entitlements` has no `com.apple.security.app-sandbox`). Its library is `~/Library/Application Support/Daybook` (`MeetingStore.swift:24-27`).
- Files are 0600 in 0700 folders, which only stops other user accounts. Any process the person runs (an npm `postinstall`, a CLI an agent runs, a compromised app) reads every recording, transcript and voiceprint with no prompt.
- Since macOS 14, sandboxed apps' containers (`~/Library/Containers/<id>`) are behind the "App Data" privacy prompt for other apps. No equivalent exists for an unsandboxed app's Application Support.

**Interim.** Nothing cheap gives the same protection. Encrypting the library at rest with a data‑protection‑keychain key would (other apps can't read Daybook's keychain group), but it's a larger change than the sandbox.

**Risk.** As docs/sandbox.md lists: process taps under the sandbox are unverified, and the move is one‑way. Needs signed builds and the owner's hardware.

### P7. Say what "computer audio" records, and record less when there's no call — M

**What.** When no call app is known, `SystemAudioSelector` records all Mac playback: `SCContentFilter(display:excludingApplications: [], …)` at `Sources/Daybook/Capture/CaptureSources.swift:98`, documented at docs/capture.md:43. "Include computer audio" defaults on (`Sources/Daybook/App/AppState.swift:476`), described as "Records the other people on a call." (`SettingsView.swift:205-206`). During an in‑room conversation (the therapy‑session case), any sound another app plays is recorded, transcribed and possibly sent to the cloud: a voice message, a video, another call Daybook didn't detect. Meanwhile the recorder's chip says "Call" / "Call audio detected" (`Sources/DaybookUI/Recording/RecordingStatusWords.swift:224-226`).

1. **Without a call app, record the microphone only** unless the person turns computer audio on for this recording. Floating Notes gets a chip, "Microphone only · Add computer audio".
2. **When ScreenCaptureKit does record everything,** the chip says "All Mac sound", not "Call".
3. **Always exclude** Messages, FaceTime when it isn't the call, and Music/Podcasts. Use `SCContentFilter(display:excludingApplications:exceptingWindows:)` with those apps' `SCRunningApplication`s; ScreenCaptureKit excludes an excluded app's audio too.

**Why.** Recording other apps' private audio without a signal is a capture‑privacy problem. Honest indicators are an Apple platform expectation (HIG: Privacy).

**Risk.** Someone recording a browser call Daybook can't name loses the far side unless they turn it on. Floating Notes' "No call audio" fix already covers that path (`RecordingStatusWords.swift:228-229`).

## 3. Findings

Ranked by exploitability × sensitivity.

| ID | Severity | Finding | Evidence (file:line or screenshot) | Proposed change | Size |
|---|---|---|---|---|---|
| F-01 | high | "Use the cloud: Always" sends conversations already known to be Personal (placed there, or with the Therapy/Personal template) to Anthropic or OpenAI, and offers cloud upgrades for them | `Sources/DaybookKit/SummaryPlacementPlanner.swift:170`; `Sources/DaybookKit/Upgrades.swift:199`; `Sources/DaybookKit/LibraryPlaces.swift:28-35` | P1 | S |
| F-02 | medium | With an encrypted library (default: not included in backups), `library.json` and `library.recovery.json` still go into iCloud and computer backups: voiceprints, speaker names, vocabulary, templates, folders. Per‑file exclusion would also be lost on every save (RENAME_SWAP / atomic write). | `Apps/iOS/DaybookPhone/Library/BackupExclusion.swift:35-36`; `Sources/DaybookCore/MeetingStore+Library.swift:26-27,73`; `Sources/DaybookCore/LibraryMetadata.swift:277-281`; `Apps/iOS/DaybookPhoneTests/BackupExclusionTests.swift:46-73` | P2: exclude the settings files, marking the temporary file before rename as `SharedWidgetCache.swift:46-53` does | S |
| F-03 | medium | Recorder widget (Home Screen, StandBy, Lock Screen rectangular) shows the newest conversation's title even when it's Personal; Recent Conversations, Next Steps and Spotlight exclude it. The title is also kept in the app group's UserDefaults (`recording-state`), which backups include. | `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:1048-1049`; `Apps/iOS/DaybookPhoneWidgets/RecorderWidget.swift:101-103,150-152`; compare `Apps/iOS/DaybookPhone/App/RecentConversations.swift:6-10` | P3: `first(where: ConversationIndex.isShown)` | S |
| F-04 | medium (needs device check) | The live transcript line in the Live Activity is hidden only by `.privacySensitive()`. Redaction is unverified on a locked Lock Screen (validation.md:2710), and Live Activities are also mirrored to Apple Watch, CarPlay and the Mac's menu bar. | `Apps/iOS/DaybookPhoneWidgets/RecordingLiveActivity.swift:177-185`; `Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:1017,1025-1028` | P3: no caption in `ContentState` unless `isProtectedDataAvailable`; update on the protected‑data notifications | S |
| F-05 | medium | With no call app known and the default "Include computer audio" on, ScreenCaptureKit records every app's sound during in‑room recordings, while the chip says "Call" | `Sources/Daybook/Capture/CaptureSources.swift:98`; `Sources/Daybook/Capture/RecordingController.swift:129,165-170`; `Sources/Daybook/App/AppState.swift:476`; `Sources/DaybookUI/Recording/RecordingStatusWords.swift:224-226`; docs/capture.md:43 | P7 | M |
| F-06 | medium (needs device check) | Floating Notes (notes and live captions) and the call prompt rely on `sharingType = .none` to stay out of screen shares. Public reports (Tauri #14200, Electron #48258) say ScreenCaptureKit on macOS 15+ ignores it, and Zoom, Meet and Teams use ScreenCaptureKit. docs/interface.md:65-66 asserts it as fact. | `Sources/Daybook/UI/NotesPanel.swift:104-106`; `Sources/Daybook/UI/CallPrompt.swift:202-203`; pending check at docs/validation.md:2648-2653 | Run the pending check on macOS 15 and 26 before release. If the panel is captured: (a) state it in docs; (b) offer Hide Captions, a blur of the captions and notes body toggled from the panel's menu, since there's no public API to detect another app's capture | S (check), M (fallback) |
| F-07 | medium | Unsandboxed Developer ID build: any process the user runs reads the whole library without a prompt | `Resources/Daybook.entitlements` (no app‑sandbox); `Sources/DaybookCore/MeetingStore.swift:24-27`; docs/sandbox.md | P6 | L |
| F-08 | medium | Every iPhone file is class C: AFU extraction of a locked phone reads all recordings and transcripts | `Apps/iOS/DaybookPhone/Recording/PhoneRecorder.swift:190-193,401`; `Apps/iOS/DaybookPhone/Recording/CaptureJournal.swift:184`; `Sources/DaybookCaptions/LiveCaptionStore.swift:160`; no `default-data-protection` in `Apps/iOS/DaybookPhone/Resources/DaybookPhone.entitlements` | P4: `.completeUnlessOpen` for `Staging/<id>` now; opt‑in class A later | S / L |
| F-09 | medium | No authentication anywhere: whoever is at an unlocked Mac or iPhone reads Personal conversations, and the app switcher snapshot shows the last page | No `LocalAuthentication` in `Sources/` or `Apps/iOS/` (grep); `Apps/iOS/DaybookPhone/App/DaybookPhoneApp.swift:106` handles `scenePhase` with no cover | P5 | M |
| F-10 | low | Ink "Copy Text" puts recognized handwriting on Universal Clipboard; every other content copy is local‑only (new in this branch) | `Sources/DaybookUI/Notes/NotesInk+TextView.swift:580` vs `Apps/iOS/DaybookPhone/Reading/Model/ReadingSupport.swift:63-64` | `setItems(…, options: [.localOnly: true])` | S |
| F-11 | low | The Mac indexes each non‑Personal conversation's summary overview into Spotlight (`contentDescription`); the iPhone indexes titles only. Summary text is copied where the library's encryption and a future lock don't reach. | `Sources/Daybook/App/Intents/ConversationEntity.swift:28-43`; `Apps/iOS/DaybookPhone/App/ConversationEntity.swift:6-7` | Titles and dates only, as on iPhone | S |
| F-12 | low | Parakeet writes a full mono copy of a multichannel recording to the temporary folder and removes it only in a `defer`. A crash or kill leaves the conversation's audio outside the library, surviving deletion of the conversation (Mac `/var/folders/…/T`, iPhone `tmp`). | `Sources/DaybookIntelligence/Engines/ParakeetEngine.swift:116-120`; launch cleanup covers only `ExportFiles` (`Sources/Daybook/App/DaybookApp.swift:314-316`) | Write into a Daybook‑owned temp folder (e.g. `tmp/Daybook Processing/`) cleared at launch the way `ExportFiles.clear()` is, or into the library's `Staging/` | S |
| F-13 | low | Logs mark error descriptions `.public`. Cocoa errors embed file names, and `LibraryError.unsafePath` embeds a full path, so conversation‑named files can reach sysdiagnose. | `Sources/Daybook/App/AppState+Sources.swift:520`; `Sources/Daybook/App/AppState.swift:1301,1466`; `Apps/iOS/DaybookPhone/Library/PhoneLibrary.swift:352,367`; `Sources/DaybookCore/MeetingStore.swift:9` | Log `domain` and `code` `.public` and the description `.private` | S |
| F-14 | low | The Cloud footer says "Sends the transcript and notes, never audio.", but the request also carries bookmarks, template instructions and the vocabulary (which can hold people's names and conditions) | `Sources/DaybookUI/Settings/Cloud/CloudSettingsForm.swift:39`; screenshot `shots/mac/settings-cloud-keys-light/Cloud.png`; docs/cloud.md:11-13 | "Sends the transcript, notes, and vocabulary, never audio." | S |
| F-15 | low | No update channel for the Developer ID build: a security fix reaches people only if they download it again | Release scripts; Polaris Key planned (owner memory) | When the updater lands: signed updates (EdDSA or the Developer ID signature checked before install), HTTPS only, and no `disable-library-validation` / `allow-unsigned-executable-memory` added for it | M |

## 4. Decisions recommended

- **ux-mac-10 (Personal and "Always"): Yes, Personal is exempt.**
  - A conversation that is Personal before summarizing (placed there, or given the Therapy or Personal template) is never sent automatically. Under Always it behaves like Offer First: the countdown goes to this device or a Mac, and Use the Cloud is a tap.
  - No cloud upgrade offers for Personal, including conversations found Personal by a local summary.
  - The automatic case (kind unknown until the first summary) stays as the person's Always choice; no new copy.
  
  Implementation: P1. This is the one change in my lane with a real chance of harm if left.
- **MSCQ-25 (iCloud account token unarchived without secure coding): Close it; nothing for the owner to verify.**
  - The current code never decodes the token. It archives the system's own object (`Sources/DaybookKit/LibrarySyncController.swift:141`) and compares bytes or a SHA‑256 digest (`Sources/DaybookKit/LibrarySyncController+Container.swift:406-438`). The comment there says why: preferences another process can write never instantiate anything.
  - `requiringSecureCoding: false` on *archiving* is harmless. Don't flip it: if the token's class isn't `NSSecureCoding`, archiving would fail, and changed bytes would read as "the iCloud account changed".
  - Update the README's "Needs the owner" table.
- **hig-ios-14 (Time Sensitive for the "recorder is recording" notice): Add the capability.**
  - From a privacy standpoint it's neutral. The two notices that would use it name only the recorder ("Soundcore Work is recording") or nothing ("Recording stopped · Everything up to 12:04 is saved."), never a conversation (`Apps/iOS/DaybookPhone/App/PhoneNotices.swift:50-52,68-74`).
  - Keep meeting reminders at the default level: they carry the calendar title.
  - Owner action: enable Time Sensitive Notifications on the App ID, and add `com.apple.developer.usernotifications.time-sensitive` to `DaybookPhone.entitlements` and `Apps/iOS/project.yml`.

## 5. Not findings (checked, fine)

- **Link pairing and sessions** (`Sources/DaybookLink/LinkPairing.swift`, `LinkTransport.swift:84-100`, `LinkDiscovery.swift`, `LinkService.swift:300-310,476-490`):
  - Passkey commit/reveal over 20 rounds, so a MITM succeeds with probability ≈2⁻²⁰ per attempt.
  - Codes are burned as salted digests on the phone, last 5 minutes, and pairing closes after 5 failures. Refusals are believed only before the first commit.
  - Reflection checks; HKDF over the transcript.
  - TLS 1.2 ECDHE‑PSK‑ChaCha20 with tickets and resumption off; session authentication bound to the RFC 5705 exporter.
  - Local‑network filter before TLS; salted TXT tags; the Mac advertises only while pairing or paired. Its Bonjour name is the computer name, like any Mac service.
- **DBSEAL‑1** (`Sources/DaybookCore/SealedObject.swift:11-16,98-100,187-199`): per‑object HKDF key from a content‑derived salt, nonce = chunk index (never reused under a key), header, index and final flag in the AAD. Deterministic naming leaks only equality within a library. The recovery key is 128 bits; wrapped keys can't be brute‑forced.
- **Keychain:**
  - Library keys: synchronizable, `kSecAttrAccessibleAfterFirstUnlock`, data‑protection keychain, shared group (`KeychainLibraryKeyStore.swift:41-80`).
  - Cloud keys: the same, plus masked descriptions and no logging (`CloudKeyStore.swift:1-60,186-190`).
  - Pairing keys and the device ID: `AfterFirstUnlockThisDeviceOnly`, never synced (`LinkKeyStore.swift:311,368`; `SyncDeviceIdentityStore.swift:70`).
  - UserDefaults hold no content or secrets (checked the simulator plist and every preference key).
- **Network:**
  - No ATS exceptions, no `http://`, no analytics or telemetry SDKs (`Package.resolved`; dependency sources searched).
  - Cloud requests use an ephemeral `URLSession` with no cache or cookies (`CloudClient.swift:84-93`), and OpenAI's carries `store: false` (`:198`). Key prefixes are checked before anything is sent.
  - Models: pinned commits, every file checked by size and SHA‑256 or git OID, refused without a digest (`Sources/DaybookModelStore/ModelFileDigest.swift`, `ModelStore.swift:110-120`). `HubApi` gets an empty token. Engines load from local folders only (`ParakeetEngine.swift:86`, `MLXLanguageEngine.swift:132`, `MLXLocalTokenizer.swift:12`). Update checks are opt‑in.
- **Speech, OCR and calendar:** live captions use `SpeechTranscriber` on device (`LiveCaptioning.swift:183`); handwriting and photo OCR use Vision on device. Only the attendee *count* is kept from the calendar (`MeetingCalendar.swift:17,149-153`).
- **Input handling:**
  - Every track and photo path goes through `LocalFiles.relativeURL` / `requireContained`, which refuse `..`, absolute paths, NUL and dangling symlinks (`MeetingStore.swift:452-481`).
  - Files are 0600 in 0700 folders.
  - Highlight sidecars are user‑chosen and validated for finite times.
  - Model text drops links and images in the app and escapes Markdown in exports (`ModelText.swift`).
  - The `daybook://` scheme parses strictly (`SharedRecentConversations.swift` `WidgetLink`).
  - There is no share extension: "Open in Daybook" copies, and the Inbox copy is removed after import.
- **Exports and copies:** photos are re‑encoded without GPS, maker or camera metadata; the export folder is cleared after the share and at launch. Content copies are `.currentHostOnly` / `.localOnly` (except F‑10).
- **Lock Screen and notifications:**
  - Mac notifications and the menu bar never name a Personal conversation.
  - "Recording stopped" on iPhone never names a conversation.
  - Recent Conversations and Next Steps exclude Personal, have no Lock Screen sizes, and their cache is excluded from backups.
  - No App Intent returns summary or transcript text to Siri.
  - Stop and Bookmark from the Lock Screen are by design, like Voice Memos.
  - The meeting reminder shows the calendar's own title, subject to the system's Show Previews.
- **Capture defaults:** the call policy defaults to Ask (`CallPolicy.swift:63-66`). Process taps exclude Daybook and other apps.
- **Platform:**
  - Hardened runtime with no `com.apple.security.cs.*` exceptions; MLX needs no JIT entitlement.
  - Debug diagnostics (`--cloud-check`, `--capture-probe`, the iPhone's `--caption-probe`) are compiled out of release.
  - The single‑instance check uses no lock file (no /tmp race).
  - `/private/tmp/daybook/` appears only in ad hoc builds' entitlements.
- **Previous audit's fixes, spot‑checked:**
  - Soundcore Wi‑Fi: join checks plus payload encryption with the BLE key. The vendor's unauthenticated ECDH is outside Daybook's control.
  - Unsolicited key grant and recovery‑key clipboard: not re‑reviewed in depth.
  - `SyncConflicts/` lives inside the conversation's folder, so it goes with it.
- **Export compliance (owner to confirm, not a finding):** both apps declare `ITSAppUsesNonExemptEncryption = false` while implementing end‑to‑end encryption with CryptoKit. CryptoKit is the OS's own encryption, which Apple treats as exempt in most cases, but the App Store Connect questionnaire answer should be checked once.

Sources for F-06: [Tauri #14200](https://github.com/tauri-apps/tauri/issues/14200), [Electron #48258](https://github.com/electron/electron/issues/48258), [pierce.dev, "Building a (kind of) invisible mac app"](https://pierce.dev/notes/building-a-kind-of-invisible-mac-app); a contrary report: [getdusky.app](https://getdusky.app/blog/is-cluely-detectable/).
