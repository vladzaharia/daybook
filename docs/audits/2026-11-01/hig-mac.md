# HIG: macOS

Audit of 2026-11-01 against main at 57ed5eb. 26 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| HIG-01 | high | The Mac can't restore a trashed conversation, and Move to Trash has no Undo | `Sources/Daybook/App/AppState.swift:1249` | w2-mac-app | partial |
| HIG-02 | high | Speaker profiles delete instantly on a Delete keystroke, with no confirmation or Undo | `Sources/Daybook/UI/SpeakerProfilesView.swift:34` | w2-inspector-people | fixed |
| HIG-03 | high | Floating Notes' Open and Open Summary do nothing when the main window is closed | `Sources/Daybook/UI/FloatingNotes/FloatingNotesView.swift:222` | w2-recorder-surface | — |
| HIG-04 | medium | Opening the inspector in a narrow window crushes the page to about 140 pt | `Sources/Daybook/UI/LibraryView.swift:161` | w2-conversation-chrome | fixed |
| HIG-05 | medium | Organizing and editing actions in the main window can't be undone | `Sources/Daybook/UI/SidebarView.swift:95` | w2-library-list | partial |
| HIG-06 | medium | Esc doesn't close read-only sheets, and Review Earlier Corrections can't be closed without deciding | `Sources/Daybook/UI/ConversationSheets.swift:264` | w2-transcript-page | fixed |
| HIG-07 | medium | Conversation menu commands act on the library's selection when another window is frontmost or the library is closed | `Sources/Daybook/App/DaybookApp.swift:161` | w2-mac-app | fixed |
| HIG-08 | medium | No Find within a conversation (⌘F, ⌘G), and search highlighting misses notes and headings | `Sources/Daybook/App/DaybookApp.swift:217` | w2-transcript-page | partial |
| HIG-09 | medium | Note times in the margin are invisible to VoiceOver and unreachable from the keyboard | `Sources/Daybook/UI/MarginNotesEditor.swift:345` | w2-recorder-surface | — |
| HIG-10 | medium | Transcript passages are mouse-only: Correct, Copy, Add Bookmark Here and Play from Here | `Sources/Daybook/UI/TranscriptPage.swift:258` | w2-transcript-page | fixed |
| HIG-14 | medium | No notifications when a recording stops unexpectedly or starts automatically | `Sources/Daybook/App/AppState.swift:1311` | w2-mac-capture-welcome | fixed |
| HIG-15 | medium | No Open at Login option, though Record calls automatically and the menu bar item need Daybook running | `Sources/Daybook/UI/SettingsView.swift:186` | w2-settings-library | fixed |
| HIG-11 | low | Dragging a conversation carries only its UUID string, and ⌘C copies nothing | `Sources/Daybook/UI/ConversationList.swift:50` | w2-library-list | fixed |
| HIG-12 | low | A root .tint overrides the person's accent colour in the main window | `Sources/Daybook/UI/LibraryView.swift:66` | w2-conversation-chrome | fixed |
| HIG-13 | low | No App Intents or App Shortcuts on the Mac, though the iPhone has them | `Sources/Daybook/App/DaybookApp.swift:179` | w2-mac-capture-welcome | fixed |
| HIG-16 | low | Window state isn't restored: place, selection, page and a hidden sidebar reset every launch | `Sources/Daybook/App/AppState.swift:577` | w2-conversation-chrome | fixed |
| HIG-17 | low | The transcript offers no VoiceOver rotors for bookmarks, notes, or speakers | `Sources/Daybook/UI/TranscriptPage.swift:29` | w2-transcript-page | fixed |
| HIG-18 | low | List rows' VoiceOver label leaves out the visible preview line | `Sources/Daybook/UI/ConversationList.swift:281` | w2-library-list | fixed |
| HIG-19 | low | Add Bookmark (⌘D) is disabled during playback, though the player can add one | `Sources/Daybook/App/DaybookApp.swift:266` | w2-mac-app | fixed |
| HIG-20 | low | Controls menu: Play/Pause has no shortcut, and playback speed isn't in the menus | `Sources/Daybook/App/DaybookApp.swift:287` | w2-mac-app | fixed |
| HIG-21 | low | Reduce Motion: transcript follow-scroll, the player and notices still slide | `Sources/Daybook/UI/TranscriptPage.swift:83` | w2-transcript-page | fixed |
| HIG-22 | low | The toolbar can't be customized, though View › Customize Toolbar… is listed | `Sources/Daybook/UI/MeetingDetailView.swift:83` | w2-conversation-chrome | not_fixed |
| HIG-24 | low | After Move to Trash, the selection jumps to the top of the list | `Sources/Daybook/App/AppState.swift:1248` | w2-mac-app | fixed |
| HIG-26 | low | The app icon is a flat .icns with a baked-in shadow, not a layered macOS 26 icon | `scripts/make-icon.swift:4` | w2-scripts-release | fixed |
| HIG-27 | low | Record moves about 300 pt between conversation and device pages | `Sources/Daybook/UI/MeetingDetailView.swift:90` | w2-conversation-chrome | fixed |
| HIG-28 | low | "Back to Playing" floats over the transcript in a material capsule instead of Liquid Glass | `Sources/Daybook/UI/TranscriptPage.swift:67` | w2-transcript-page | fixed |

## Notes on partial fixes

- **HIG-01:** trashMeetings(_:undoManager:) registers 'Move to Trash' with Edit › Undo, and Redo works too, following the new ID when a synced deletion comes back. The notice reads 'Moved “X” to the Trash.' with Undo; using it withdraws the registration and restores the conversation. The undo takes its line out of the notice. LibraryView's alert passes the window's undoManager (minimal edit). The automatic trash in trashWhenIdle gets the notice's Undo too. Tested in AppStateTests. Not done here: the sidebar Trash place with Restore belongs to w2-library-list. I kept the single-item confirmation, which the finding calls optional. Removing it is up to the list owner (ConversationList's onDeleteCommand and the context menus).
- **HIG-05:** Done in my files, through the new LibraryController+Filing.swift (w1 undo helper): undo for sidebar drops, Move to Folder, Work/Personal, tags, batch actions, New Folder, Rename Folder, and Delete Folder. Delete Folder's undo restores the folder and its conversations, except ones filed elsewhere since. Each event is one Undo step, with Redo. Applies to both apps. Left to other packages per the plan: inspector pickers (w2-inspector-people), menu-bar and More menus (w2-mac-app), bookmarks and passages (w2-summary-page and w2-transcript-page).
- **HIG-08:** Find in Conversation is built: a ConversationFind model and a find bar pinned to the top of the page as a safeAreaBar on macOS 26 (safeAreaInset before), showing a count. ⌘F, ⌘G and ⇧⌘G work while the transcript shows (shortcuts in the window). The Mac's menu items are ready as ConversationFindCommands(state:) in Sources/Daybook/UI/TranscriptPage.swift. The integrator must add that to DaybookApp's .commands (w2-mac-app owns the file); it opens the transcript from the summary too. Notes usesFindBar is w2-recorder-surface's.
- **HIG-22:** I implemented .toolbar(id:) with Record reorderable but not removable, then reverted it. In 760 pt windows, activated at launch, the customizable toolbar intermittently crashed with NSGenericException 'more Layout Window passes than there are views': 5 of 56 runs across variants, still crashing with no spacers, no shared background and no fixedSize. The plain toolbar with the same items crashed 0 of 38 times, and wave1 0 of 4. DetailToolbar stays plain, with a comment and a doc line saying why. Recommendation for w2-mac-app (DaybookCommands): replace ToolbarCommands() with a Show/Hide Toolbar item only, or accept that Customize Toolbar… stays disabled.
