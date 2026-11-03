# UX: Mac

Audit of 2026-11-01 against main at 57ed5eb. 23 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| ux-mac-01 | high | First Record fails outright without Screen & System Audio permission; no microphone-only fallback, no permission step in Welcome | `Sources/Daybook/Capture/CaptureSources.swift:69` | w2-mac-capture-welcome | fixed |
| ux-mac-03 | high | Floating Notes' Record records into whatever finished conversation the panel was opened on | `Sources/Daybook/UI/FloatingNotes/FloatingSurfaces.swift:375` | w2-recorder-surface | — |
| ux-mac-05 | high | Move to Trash is one-way on the Mac: no Trash place, no Restore, no Undo, while the iPhone has all three | `Sources/Daybook/App/AppState.swift:1249` | w2-library-list | fixed |
| ux-mac-02 | medium | A recording that fails to start leaves an empty conversation that says 'Couldn't finish transcribing · The recording is saved' | `Sources/Daybook/App/AppState.swift:1287` | w2-mac-app | fixed |
| ux-mac-04 | medium | Floating Notes 'Open' / 'Open Summary' / ⌘O / Recent rows do nothing when the main window is closed or minimized | `Sources/Daybook/UI/FloatingNotes/FloatingNotesView.swift:216` | w2-recorder-surface | — |
| ux-mac-06 | medium | Cloud summary failures read 'Something went wrong'; the plain reason is hidden behind Details and there's no 'Summarize on This Mac' | `Sources/Daybook/UI/ConversationPage.swift:535` | w2-summary-page | fixed |
| ux-mac-07 | medium | Work interrupted by quit, restart or crash never resumes; recovered recordings and ones waiting for models aren't transcribed after relaunch | `Sources/Daybook/App/AppState.swift:1366` | w2-mac-app | fixed |
| ux-mac-08 | medium | An unexpected stop mid-call looks like a normal '✓ SAVED' in Floating Notes, and Record then splits the call | `Sources/Daybook/UI/FloatingNotes/FloatingStatusFeed.swift:68` | w2-recorder-surface | — |
| ux-mac-11 | medium | No way to remove or move a recording out of a conversation; a mistaken drop or attach is permanent | `Sources/Daybook/UI/MeetingInspector.swift:236` | w2-inspector-people | fixed |
| ux-mac-12 | medium | Deleting a speaker profile or voiceprints is instant, unconfirmed and undoable on neither app, including the Delete key | `Sources/Daybook/UI/SpeakerProfilesView.swift:185` | w2-inspector-people | fixed |
| ux-mac-13 | medium | Search opens at the exact passage only for transcript hits; matches in your notes aren't scrolled to or highlighted | `Sources/Daybook/UI/ConversationList.swift:118` | w2-transcript-page | partial |
| ux-mac-16 | medium | No free-space check before multi-GB model downloads; a full disk is reported as 'Check your internet connection' | `Sources/Daybook/App/AppState.swift:1040` | w2-models-processing | fixed |
| ux-mac-17 | medium | The main window never says sync has stopped | `Sources/Daybook/UI/FloatingNotes/FloatingStatus.swift:246` | w2-library-list | fixed |
| ux-mac-18 | medium | Corrections, speaker renames and bookmark deletions have no Undo; deleted bookmarks aren't even in Version History | `Sources/Daybook/UI/SummaryPage.swift:307` | w2-summary-page | fixed |
| ux-mac-09 | low | Upgrade 'Waiting for Studio Mac…' has no way out, and the list row names this Mac as the requester | `Sources/Daybook/UI/ConversationPage.swift:328` | w2-summary-page | partial |
| ux-mac-15 | low | Compact Floating Notes drops the notepad and leaves empty space | `Sources/Daybook/UI/FloatingNotes/FloatingSurfaces.swift:64` | w2-recorder-surface | — |
| ux-mac-19 | low | 'Waiting for audio from Soundcore Work' can't be dismissed and lingers for two days | `Sources/Daybook/UI/ConversationPage.swift:338` | w2-summary-page | fixed |
| ux-mac-20 | low | Sharing differs between Mac and iPhone: no share sheet or audio export on the Mac, and no 'Copied' feedback | `Sources/Daybook/UI/MeetingDetailView.swift:140` | w2-conversation-chrome | fixed |
| ux-mac-21 | low | A transient call-detection error ends an automatic recording mid-call and starts a second conversation | `Sources/Daybook/Capture/MeetingDetection.swift:197` | w2-mac-capture-welcome | fixed |
| ux-mac-22 | low | 'Couldn't Open Your Library' is a dead end with a blank window | `Sources/Daybook/App/AppState.swift:590` | w2-mac-app | fixed |
| ux-mac-23 | low | Quitting during a recording stops it without asking | `Sources/Daybook/App/DaybookApp.swift:353` | w2-mac-app | fixed |
| ux-mac-24 | low | Adding a device uses five names: Add Device, Add Recorder, Set Up a Recorder, Add iPhone, Daybook on iPhone | `Sources/Daybook/Devices/UI/AddDeviceSheet.swift:123` | w2-devices-screens | fixed |
| ux-mac-25 | low | Small copy and consistency slips: Welcome tagline, ⌥⌘N, a mechanics subtitle, queue wording | `Sources/Daybook/UI/WelcomeWindow.swift:117` | w2-mac-app | partial |

## Notes on partial fixes

- **ux-mac-13:** My half is done: Find in Conversation marks matches in passages, your notes and photo captions in the transcript. It washes the current match, shows a count, and steps by row ID with ⌘G/⇧⌘G. A library search hit still lands the transcript on its passage, which now flashes too. Other packages own the rest: marking matches in the notes editor (w2-recorder-surface), in summary headings (w2-summary-page), and scrolling to a notes hit (ConversationList.open, w2-library-list).
- **ux-mac-09:** Cancel is on the Mac's upgrade waiting line for an upgrade this Mac accepted; it withdraws the request so the offer returns. The shared ConversationRowStatus already says 'Waiting for Studio Mac'. The Mac list row is still ConversationList's own RowStatus (w2-library-list), which says 'Requested from <this Mac>' until it moves to ConversationStatusPresentation.row or uses request.upgrade?.shortLine.
- **ux-mac-25:** (b) AppState.floatingNotesFocus is the one rule: the recording, else the conversation the library window shows, else the panel's home. Window › Floating Notes and the Dock menu use it. MenuBarView (w2-status-sheet) should call state.showFloatingNotes(focus: state.floatingNotesFocus). (d) AppState.waitingWords(for:) words the wait through ProcessingWords.waitingHere and waitingHereShort, by the job's mode, including 'after the download'. queuedMode(_:) and queueWaitsForDownload feed ConversationStatusPresentation.Inputs. These are tested. The owners of the drawing still need to adopt them: ConversationList RowStatus ('Waiting'), ConversationPage's waitingText, FloatingStatus, and AppState+Devices:83/86. (a) and (c) belong to w2-mac-capture-welcome and w2-models-processing, as planned.
