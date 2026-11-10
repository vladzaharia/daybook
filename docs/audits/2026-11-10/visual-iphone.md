# Visual UI: iPhone 18 Pro and iPhone Duo (design pass 2026-11-10)

Reviewer lane: the iPhone app's visual UI on the 18 Pro and the Duo (cover, notebook, table mode), Dynamic Type and Dark Mode. Read all 142 captures in `shots/ios/`, then the code that draws them (`Apps/iOS/DaybookPhone/**`, `Sources/DaybookUI/**`, `Sources/DaybookDesign/**`). Extra captures I took are in `scratchpad/vi-shots/` (`duo-open-library-recap.png`, `duo-closed-ink.png`, `duo-open-ink-after-unfold.png`, `duo-flex-preview.png`, `pro-landscape-library.png`). Contact sheets of the shots are in `scratchpad/vi-sheets/`. Nothing in the repository was changed.

## Summary

The reading surface is the strongest part of the app: a New York title, a calm SF body at Dynamic Type sizes, the Ink scale on warm paper, speaker inks, the amber bookmark rule and the mint playhead all read as one system in light and dark. The page could sit beside Apple's own apps. The chrome around it is weaker, and the open Duo has real breakage.

1. **The open Duo's library has no navigation bar.** There's no place menu, New Note, Select, or Settings, and the Trash has no title. The most likely cause is the status tray's own `NavigationStack`, which sits inside the left page's stack and hides its bar (VI-01). The same code path runs on any iPhone turned on its side.
2. **Handwriting sometimes draws blank.** It happened on both Duo displays in 3 of the 6 renders I checked, and the strokes come back after a relayout (VI-02).
3. **The library's bottom tray is too heavy.** It is a persistent Maps-style sheet that covers about 27% of the 18 Pro's list and 36% of the Duo's cover. It always reports "Recorder · None added" and fine-state lines, against principle 2. A modern iOS 26 list app would use a bottom toolbar with Record, a minimized system search, and New Note or Import, plus one status strip that appears only when something is happening (P1).
4. **The notebook doesn't read as a bound book yet.** The tray floats with list rows showing under it. The spine's bookmark ticks are placed by recording time but sit beside transcript passages placed by scroll, so they suggest links that aren't there. While recording, the right page is mostly blank above a one-row recorder (P2).
5. **The pocket recorder's resting state is under-informative.** It hides the title, the record-along chips (the multipoint capture shows no "Studio Mac" chip at all), captions, and the camera. Meanwhile a floating glass "Write by Hand" button sits on every notes area, previews included, and covers notes at accessibility sizes (P3, P4).

Dynamic Type is in good shape after the last audit: Bookmark and Stop keep their glyphs, titles wrap, and rows stack. What's left is small: an empty band in the compact tray, a status dot that doesn't scale, and the handwriting button over the text. Dark Mode is good throughout. Neon is used where the tokens say, and the glass stays legible.

## Redesign proposals

### P1. The library's foot as an iOS 26 toolbar with one status strip, instead of a standing status sheet (L)

- **What changes and why.**
  - Today the library always presents a detented sheet. Its compact detent holds Record, Import, and Search, then three or four status lines (`StatusSheetHost`, `StatusSheet.swift:113-193`; `StatusCompactDetent`, `:42-97`). On the 18 Pro it covers about 235 pt of 874 (`pro-library-light.png`; the tray starts at y = 1462 of 2000 px). On the Duo's cover it covers 36% (`duo-closed-library-light.png`).
  - The "Recorder · None added" line (`StatusSheetModel.swift:385-388`) and the iCloud and Mac lines always show, even when everything is fine. That breaks principle 2, "When everything is fine, nothing reports status." ux-flows' uxf-10 and P4 cover the words; this proposal is about the form.
  - Maps and Find My use a standing sheet because the map is the content and the sheet holds the list. In Daybook the list *is* the content, so a standing sheet permanently hides it.
  - iOS 26's own list apps (Notes, Mail, Reminders) put search and compose in the bottom toolbar, as glass groups split by `ToolbarSpacer`. The app uses neither `ToolbarSpacer` nor `DefaultToolbarItem(kind: .search)` anywhere (grep).
- **Touches.**
  - `LibraryPage.swift`: `bottomBar` (:426-475), the `toolbar` (:355-421), `SearchWhilePresented` (:505-527).
  - `StatusSheet.swift`: the `StatusSheetHost` presentation, `StatusQuickActions`, and `StatusCompactDetent`.
  - `StatusSheetModel` (a "most pressing line" already exists for the accessibility sizes: `compactLines`).
  - `RecordStartButton.swift`, docs/iphone.md "Status sheet", `StatusSheetModelTests`.
- **Sketch (18 Pro, upright).**
  ```
  All Conversations ⌄                                   (⋯)  (⚙︎)
  Yesterday
  Roadmap review                                      11:28 PM …
  …
  ┌───────────────────────────────────────────────────────────┐   status strip, only when there's
  │ ▬▬▬▬▬▬▬▬▬▬▬▬ Transcribing on Studio Mac · 55%         ›   │   something to say; tap = status sheet
  └───────────────────────────────────────────────────────────┘
  ( ● Record )                                     ( 🔍 )  ( + )   bottom toolbar, glass
  ```
  - Record is the toolbar's leading item: a wide capsule with the red dot, in its own glass group.
  - Then `ToolbarSpacer(.flexible)`.
  - Then `DefaultToolbarItem(kind: .search, placement: .bottomBar)` with `.searchToolbarBehavior(.minimize)`. The system draws the magnifier and expands it into the field at the thumb. That is the one search entry ui-iphone-23 asked for.
  - Then a "+" menu: New Note and Import Audio….
  - The status strip is the one line `StatusSheetModel` ranks highest, in its own words, ink, and progress line. In order:
    - what needs the person: "iCloud · Signed out" in warning ink;
    - what's recording elsewhere: "Recording on Studio Mac" with the red dot;
    - what's working: "Transcribing on Studio Mac · 55%" with the gradient line;
    - otherwise nothing.
  - Tapping the strip presents today's status sheet at medium (the Recorders, Macs, and This iPhone cards), as an ordinary dismissible sheet.
  - When everything is calm, the cards are reached from a "Devices" item in the top bar's ⋯ menu, which sits beside Settings.
  - On the Duo's cover the same bar fits in the 382 pt column. On the open Duo it sits at the foot of the left page (P2).
- **Principles.** Principle 2 (status only when there's something to say), principle 3 (chrome is a frame, at most three groups), and the platform's bottom-toolbar search convention. It gives back about 135 pt of list on the 18 Pro and about 90 pt on the cover.
- **Against the documented design.** docs/iphone.md argues the compact surface should "keep the three things a recording here depends on visible". None of the three is needed to record on the iPhone: it records with its own microphone. A problem that would affect a recording still shows, because the strip shows problems first.
- **Risks.**
  - The status sheet loses its "always there" affordance: someone who wants to see a healthy Mac takes one more tap.
  - Tests that assume the compact detent need rewriting.
  - The Duo tray (`StatusPanel`) must follow, or the two postures diverge.
  - `ToolbarSpacer` and `DefaultToolbarItem` are iOS 26 APIs, which is fine: the floor is iOS 26.

### P2. The Duo notebook, bound like a book (L)

- **What changes and why.** Five changes. Each removes something on the spread that is broken or that reads like a tablet app rather than a book.
  1. **Restore the left page's navigation bar (VI-01).** The tray (`StatusPanel`, `StatusSheet.swift:213-252`) hosts `StatusSheetView`. That view wraps its sections in a `NavigationStack(path:)` with `.toolbar(.hidden, for: .navigationBar)` (`StatusSheet.swift:377-386`), and it sits inside the left page's own `NavigationStack` (`LibraryBrowser.swift:252-255`). SwiftUI doesn't support nested stacks. The screenshots match that explanation: the bar is missing whenever the tray is up (`duo-open-library`, `duo-open-trash`, `duo-open-status`, `vi-shots/duo-open-library-recap.png`) and back whenever the tray steps aside (`duo-open-search` shows the field in the bar). The fix:
     - In the notebook, give `StatusPanel` the sections without a stack of their own (a `StatusSheetView(embedsNavigation: false)`).
     - Push a device's, Mac's, or Settings screen from the panel as a `PageSheet` on the right page, which is where every other sheet goes on two pages.
  2. **The left page's foot is a bar, not a floating card.** Today the tray is a `.safeAreaInset` with `.padding(.bottom, s2)` and no scroll edge effect while it shows (`LibraryPage.swift:69`, `:178`; `StatusSheet.swift:250-251`). A list row shows beneath the card ("Customer call with Northwind Traders…", bottom of `duo-open-library-light.png`), and the grabber sits between the buttons and the lines (`StatusSheet.swift:241-249`), where the 18 Pro has it on top.
     - Use P1's bar.
     - If the tray stays, extend its glass to the display's bottom edge, as the recorder's sheet does (`RecorderSheet.swift:231`, `ignoresSafeArea(.container, edges: .bottom)`), and put the grabber on top.
  3. **Make the spine a gutter, not a timeline.** `SpineTimeline` (`CreaseSplit.swift:98-125`) places amber ticks at a fraction of the recording's length along the crease, next to transcript text that is laid out by scrolling.
     - In `duo-open-page-light.png` the 0:14 bookmark's tick sits beside "Your note 0:02", and the 0:32 tick sits beside the 0:13 bookmark. Two vertical scales sit side by side, and the eye links them.
     - Keep the crease's shading and hairline (`CreaseSpine`), which is what makes it a book. Move the bookmark ticks and the playhead onto the player's scrubber, which already measures time.
     - If a timeline overview is wanted, make it a minimap of the transcript itself: ticks where the bookmarked passages *are* in the scroll, plus a viewport bracket.
  4. **Recording across the spread: the whole recorder on the right page at rest.** On `.spread` the sheet rests at mini (`RecorderSheet.swift:49`). With captions off and no bookmarks yet, the right page is about 85% blank paper above a one-row recorder (`duo-open-recording-ink-light.png`, `vi-shots/duo-open-ink-after-unfold.png`).
     - Rest at `.expanded`: chips, the 76 pt clock, meters, and the live timeline.
     - Let the captions, or the bookmark log, fill the space above (the `captionsFill` look already does this).
     - Keep mini only while the keyboard is up.
     - The left page keeps the title and notes. This is what docs/iphone.md's notebook table promises: "the recorder's sheet at the foot of the right page, with the captions or the bookmark log above it".
  5. **One right-page card.** Reading sheets use `PageSheet` (`LibraryBrowser.swift:342-399`): a 26 pt literal radius, material plus 12% black over the right page only, and a `systemBackground` card. Settings' sheets use `PageCard` (`SheetPages.swift:81-130`): `DaybookRadius.panel`, and 20% black over the whole display. Merge them into one component:
     - the radius token;
     - the dim on the right page only, so the left page stays in reach, as docs/iphone.md says of reading sheets;
     - `secondarySystemBackground` in place of the cold `systemBackground` on warm paper (`duo-open-info-light.png`).
- **Smaller notebook polish.**
  - "Open" on the preview is a `.glassProminent` teal pill in the back button's slot (`LibraryBrowser.swift:294-297`), louder than the title under it. Make it a `.glass` "Open" with `book.pages` in the trailing group beside Info and More; a second tap on the row still opens.
  - The empty right page shows a lone gradient glyph (`NotebookPlaceholder`, `:418-437`). Show nothing, or the mark at 40% opacity.
- **Sketch.**
  - Library spread, left page: "All Conversations ⌄" and (⋯)(⚙︎) at the top; the list (wash 16 pt from the crease, as now); the P1 bar on the page's floor, its glass to the bottom edge, controls 24 pt from the crease.
  - Library spread, right page: the preview with (Open 📖)(ⓘ)(⋯).
  - Conversation spread: summary | transcript, the crease a soft gutter, the player docked at the right page's foot, its scrubber carrying amber ticks and the mint head.
  - Recording spread: title and notes on the left; on the right, captions above and the whole recorder below.
- **Risks.**
  - The spine rail was added deliberately (PR #56). Moving its data to the scrubber changes `PlayerBar`, which the Mac shares.
  - Resting at expanded on the Duo changes the documented sheet sizes and their tests (`RecorderSheetSize.resting`).

### P3. The pocket recorder at rest says what it's recording (M)

- **What changes and why.** In the hand the sheet rests at collapsed, which shows the phase, clock, meter, Bookmark, and Stop.
  - The title, the chips, and the camera appear only at expanded (`RecorderSheet.swift:397-399`, `:439-442`). Captions appear only at expanded or full (`:343`).
  - The notes page above has no header at all (`RecorderSheetColumn`, `RecorderSheet.swift:153-172`).
  - The result: in `pro-recording-light.png` there's no way to tell which conversation is recording. In `pro-recording-multipoint-dark.png`, run with `--demo-multipoint "Studio Mac"`, nothing says the Mac is recording along. With `--demo-captions` no caption is visible.
  - The Duo's spread already has the header the pocket lacks (`SpreadNotesPage`, `RecorderSurface.swift:307-333`: the title over "Today · 12:44 AM").
- **Sketch (upright, at rest).**
  ```
  Conversation at 12:18 AM              ← RecorderTitle, tap to rename (New York, sheetTitle)
  Today · 12:18 AM · Studio Mac ●        ← byline; chips folded in when something records along
  0:03  Agenda: what the phone app records…
  …
  ‹ It keeps recording with the screen locked… ›   ← newest caption, one line, Meta ink, only when captions are on
  ╭─ ● RECORDING · iPhone Microphone ───────── 📷 ─╮
  │ 0:08  ▮▮▮▯▮▮▮▮                                  │
  │ [ Bookmark 1 ]          [ ■ Stop ]              │
  ╰────────────────────────────────────────────────╯
  ```
  - The camera moves into the collapsed sheet's phase row as a glyph button, so taking a photo doesn't mean expanding the sheet first.
- **Touches.** `RecorderSheetColumn` and `RecorderSheetContent` (`RecorderSheet.swift`), `RecorderSurface`'s slots, `RecordingSurface.swift:115-125`.
- **Risks.** It takes about 60 pt from the notes in the hand. At the accessibility sizes the header should collapse to the title alone, and the caption line should go first, as it does now.

### P4. Handwriting tools in the control layer, not on the page (M)

- **What changes and why.**
  - `WritableNotes` overlays `InkTools` at the notes' bottom-trailing corner on every notes area: the page, the Duo's read-only preview, the recorder, and after Stop (`HandwritingNotes.swift:46-54`). At rest it is a lone glass circle with an unlabeled `pencil.tip` glyph (`NotesInk+UIKit.swift:337-338`), which reads as a compass or an "A".
  - It floats under "Add a note…" on an otherwise empty page (`pro-failed-light.png`, `pro-not-transcribed-dark.png`) and on the Duo's preview (`duo-open-library-light.png`).
  - At accessibility sizes it sits on the notes' text (`pro-recording-accessibility-extra-extra-extra-large.png`, over "Recording").
  - Principle 3 says Liquid Glass belongs to the control layer and content is never glass. A finger-handwriting toggle on a phone is a secondary tool, and Apple Pencil already brings the tools up by itself (docs/iphone.md, "Handwriting").
- **Sketch.**
  - On the page: no button at rest. "Write by Hand" goes in the keyboard's accessory bar (`UIToolbar` input accessory, or `.toolbar { ToolbarItemGroup(placement: .keyboard) }`) beside Done, and in the More menu under Take Photo.
  - While recording: a `pencil.tip.crop.circle` glyph in the sheet's control row, between Bookmark and Stop, at collapsed and above.
  - While writing: today's tool capsule (pen, highlighter, eraser, lasso, undo, redo, keyboard) docks above the keyboard area at the foot of the column, never over text.
- **Risks.** Finger handwriting gets one tap further away. On the Duo with Pencil nothing changes.

### P5. One status glyph per state, sized with the text (S)

This agrees with visual-mac VM-14.

- **What changes and why.**
  - "Not transcribed yet" is a fixed 8 pt teal dot in the row (`ConversationRowView.swift:182-185`). It is the Mail and Podcasts "unread" idiom, in the colour that means "you can act on it". It stays 8 pt at AX5 while the title around it triples (`pro-library-accessibility-extra-extra-extra-large.png`).
  - The page shows the same state with a waveform glyph in a teal box (`pro-not-transcribed-dark.png`).
  - docs/iphone.md says "Recorded but not processed is a normal, complete state."
- **Sketch.** No glyph for "Not transcribed yet": the words already say it. If one is kept, use `waveform` in `Ink.secondary` at the row's footnote style, the same symbol the page's `StatusBlock` uses. Draw the other glyphs (clock, pause, warning) with `@ScaledMetric` sizes, and give the 44 pt progress line a scaled width.
- **Touches.** `RowGlyph` (`ConversationRowView.swift:150-205`), shared with the Mac.
- **Size.** S.

### P6. Next steps on touch: one meta line for owner and time (S)

- **What changes and why.** `NextStepRow` puts the owner chip beside a short step and under a long one (`ViewThatFits`, `SummaryBody.swift:166-178`), so one list mixes both. In `duo-open-page-light.png`, Daniel is inline and Priya is below. The time hangs at the trailing edge in its own column (`:180-191`), which takes about 60 pt of measure on a 402 pt page. A done step's owner becomes plain blue text after the step ("Maya", `pro-page-light.png`).
- **Sketch.**
  ```
  ○  Post a status update on the conflict fix
     Daniel · 0:27
  ○  Finish the release notes, including Markdown export
     Priya · 0:31
  ✓  Book the beta review
     Maya
  ```
  - The owner chip and the time link sit on one footnote line under the step, the same for every step and every width. The step gets the full measure.
  - On the Mac's window density, follow visual-mac P3: the time in the left lane.
- **Size.** S.

### P7. Top bar and sheet chrome on iOS 26 terms (S)

- **What changes and why.**
  - The library's title is `.inline` (`LibraryPage.swift:76`), so the system moves it: leading in All Conversations, where three glyphs fill the trailing side (`pro-library-light.png`), centred in the Trash, where there's one (`pro-trash-light.png`).
  - The three trailing glyphs share one glass group. Select uses `checkmark.circle`, which reads as "done" (`:395-419`).
- **Sketch.**
  - `.toolbarTitleDisplayMode(.inlineLarge)` for a stable leading "All Conversations ⌄" in every place.
  - Trailing: a ⋯ menu (Select Conversations, New Folder…, Devices) and Settings, split by `ToolbarSpacer(.fixed)`. New Note moves to the bottom bar's "+" (P1).
  - Info, Version History, and Settings sheets: `Button(role: .close)` (the iOS 26 xmark) instead of a text "Done" in a capsule (`ConversationInfo.swift:40`, `SettingsScreen.swift:142`, `ReadingSheets.swift:66,191`). Keep text buttons where the sheet edits something (Cancel, Save).
- **Size.** S.

## Findings

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| VI-01 | high | On the open Duo the library's left page has no navigation bar. There's no place menu ("All Conversations ⌄"), New Note, Select, or Settings, so a person can't change places or reach Settings without folding. The Trash's page has no title. The same code path runs on any iPhone on its side (`DevicePosture.layout` → notebook); not seen on screen there because the debug flag didn't rotate the 18 Pro. | `duo-open-library-*`, `duo-open-trash-*`, `duo-open-status-*`, `vi-shots/duo-open-library-recap.png`; the bar returns with the tray hidden: `duo-open-search-light.png`. Cause (most likely): `StatusSheetView`'s `NavigationStack` with `.toolbar(.hidden, for: .navigationBar)` (`StatusSheet.swift:377-386`) nested in the left page's stack (`LibraryBrowser.swift:252-255`) through `StatusPanel` (`StatusSheet.swift:245-248`) | Don't nest a stack in the panel; push its screens as a right-page `PageSheet` (P2.1). Add a UI test that the library's title menu exists on two pages | M |
| VI-02 | high | Handwriting sometimes draws blank: the lane's times show with empty space where the ink should be. Both blocks were blank on the open Duo in light and dark, and the first block was blank on the cover. Both drew after an unfold forced a relayout, and on the 18 Pro. It's intermittent and seen in the simulator, but a person would think their writing was lost. | `duo-open-recording-ink-light.png`, `duo-open-recording-ink-dark.png`, `vi-shots/duo-closed-ink.png` (blank) vs `vi-shots/duo-open-ink-after-unfold.png`, `pro-recording-ink-*` (drawn). `InkBlockView` loads the drawing when it's created (`NotesInk+TextView.swift:258-275`) and scales `PKCanvasView` with a transform in `layoutSubviews` (`NotesInk+UIKit.swift:288-300`) | Reassign the drawing and `setNeedsDisplay` when the canvas's bounds first become non-zero or the scale changes. When the canvas isn't being edited, draw a `PKDrawing.image` snapshot instead of a transformed canvas. Verify on a device | M |
| VI-03 | medium | During "Saving…" after Stop, the notes the person just wrote disappear: the page is blank under the title, and the button reads "Record", not "Keep Recording", until filing finishes. | `pro-after-stop-dark.png` (Saving… with an empty page) vs `pro-after-stop-light.png` (Saved with notes); `AfterStop.swift:182-206` (`Color.clear` while there's no meeting), `:158` | Show the recording's notes read-only (`model.recorder.notes`, ink, marks) while saving, then swap to the conversation's editor | S |
| VI-04 | medium | The library tray takes about 27% of the 18 Pro's screen and 36% of the Duo's cover. It always reports devices and fine states ("Recorder · None added", "iCloud · Up to date"). | `pro-library-light.png`, `duo-closed-library-light.png`; `StatusSheet.swift:42-97`, `StatusSheetModel.swift:385-388` (see uxf-10) | P1 | L |
| VI-05 | medium | The Duo's tray floats over the page: a list row shows under it, and its grabber sits between the buttons and the status lines (it's on top on the 18 Pro). | `duo-open-library-light.png` (the "Customer call…" row under the tray), `duo-open-status-light.png`; `LibraryPage.swift:69`, `:178`; `StatusSheet.swift:241-251` | Glass to the bottom edge and grabber on top, or P1's bar (P2.2) | S |
| VI-06 | medium | The spine's bookmark ticks are placed by recording time, but they sit beside transcript passages laid out by scrolling, so they suggest links that don't exist. | `duo-open-page-light.png`, `duo-open-page-notes-light.png` (ticks at y ≈ 523 and 1025 beside unrelated passages); `CreaseSplit.swift:98-125` | Move the ticks and playhead to the player's scrubber; keep the crease as a gutter (P2.3) | S–M |
| VI-07 | medium | While recording on the open Duo, the right page is mostly blank above a one-row recorder. | `duo-open-recording-ink-light.png`, `duo-open-recording-light.png`; `RecorderSheet.swift:49` (`.spread → .mini`) | Rest at `.expanded` on the spread (P2.4) | S |
| VI-08 | medium | At rest in the hand the recorder hides the title, the record-along chips, captions, and the camera, and the notes page has no header. Nothing says which conversation is recording or that a Mac records along. | `pro-recording-light.png`, `pro-recording-multipoint-dark.png` (no Studio Mac chip), `pro-recording-dark.png` (`--demo-captions`, no caption); `RecorderSheet.swift:343`, `:397-399`, `:439-442` | P3 | M |
| VI-09 | medium | A glass "Write by Hand" button floats on every notes area, including the Duo's preview and empty pages. Its glyph is unlabeled, and at accessibility sizes it covers notes. | `pro-page-notes-light.png`, `pro-failed-light.png`, `duo-open-library-light.png`, `pro-recording-accessibility-extra-extra-extra-large.png`; `HandwritingNotes.swift:46-54`, `NotesInk+UIKit.swift:326-345` | P4 | M |
| VI-10 | medium | The library's title moves between places (leading in All Conversations, centred in the Trash). New Note, Select, and Settings are three glyphs in one glass group, and Select's `checkmark.circle` reads as "done". There's no `ToolbarSpacer` anywhere. | `pro-library-light.png` vs `pro-trash-light.png`; `LibraryPage.swift:76`, `:355-421` | P7 | S |
| VI-11 | low | The "Not transcribed yet" row glyph is a fixed 8 pt teal dot (the unread idiom). It doesn't scale with Dynamic Type and differs from the page's waveform glyph for the same state. | `pro-library-light.png`, `pro-library-accessibility-extra-extra-extra-large.png`, `pro-not-transcribed-dark.png`; `ConversationRowView.swift:182-185` | P5 (with VM-14) | S |
| VI-12 | low | At accessibility sizes the compact tray reserves four rows for its one line even when the line takes two, leaving an empty band of glass with blurred rows behind it. | `pro-library-accessibility-extra-large.png`, `pro-library-accessibility-extra-extra-extra-large.png`; `StatusSheet.swift:65-67` (`StatusMetrics.stackedRows`) | Measure the chosen line's actual rows (title and words), or make the detent `.height` of the measured content | S |
| VI-13 | low | The Summary \| Transcript switch disappears when there's no transcript, so the bar's centre comes and goes. The Mac dims it (principle 3: "what doesn't apply is dimmed"). | `pro-failed-light.png`, `pro-not-transcribed-dark.png` vs `pro-page-light.png`; `ConversationScreen.swift:44-46` | Always show it; disable Transcript | S |
| VI-14 | low | A next step's owner is inline beside a short step and under a long one, so one list is ragged. The time is a trailing column on a narrow page. | `duo-open-page-light.png` (Daniel inline, Priya below), `pro-page-light.png`; `SummaryBody.swift:166-191` | P6 | S |
| VI-15 | low | An offline photo in the transcript wraps "Try / Again" inside its 80 pt tile. | `pro-offline-audio-light.png`; `PhotoImage.swift:69-73` | In tiles under about 120 pt use the `arrow.clockwise` glyph alone (label for VoiceOver), via `ViewThatFits` | S |
| VI-16 | low | After Stop, "Open ↗" uses `arrow.up.forward`, the iOS convention for leaving the app, for in-app navigation. | `pro-after-stop-light.png`; `RecorderAfterStop.swift:200`, `:247` | No glyph, or `chevron.forward` | S |
| VI-17 | low | The two hand-made right-page cards differ. Reading sheets dim the right page with material, use a literal 26 pt radius, and a white card. Settings' sheets dim the whole display 20% black and use `DaybookRadius.panel`. Both are cold `systemBackground` on warm paper. | `duo-open-info-light.png`; `LibraryBrowser.swift:342-372`, `SheetPages.swift:81-117` | One `PageCard` (P2.5) | S |
| VI-18 | low | The status sheet's medium and large detents repeat the compact lines above the cards ("Recorder · None added", then "Recorders › Add Recorder…"). At large, Record sits at the top of the screen. | `pro-status-medium-light.png`, `pro-status-large-light.png`; `StatusSheet.swift:458-470` | Past compact, drop the lines (each card's header says it) and the Record row | S |
| VI-19 | low | On the open Duo the search field opens at the top of the left page, not at the thumb as on the 18 Pro and as docs/iphone.md says. | `duo-open-search-light.png`; `LibraryPage.swift:513-520` (`.navigationBarDrawer`) | The bottom-bar search item (P1) on both postures | S |
| VI-20 | low | The recorder's labels are tracked capitals ("RECORDING", "SAVED", "LIVE CAPTIONS · TENTATIVE"). iOS 26 dropped uppercase headers, and the last audit removed them from group headings (ui-iphone-12). | `pro-recording-sheet-full-light.png`, `pro-after-stop-light.png`; `ElapsedClock.swift:177`, `LiveCaptionStrip.swift:205` | Sentence case semibold ("Recording" in record red; "Live captions · tentative" in Meta), on both apps | S |
| VI-21 | low | Section headers in one Settings sheet mix cases: device pages ("Recent imports", "New on Soundcore", "Options") vs Settings ("Live Captions", "On This iPhone", "Built-in"). | `pro-device-sim-light.png`, `pro-settings-recording-light.png`, `pro-settings-storage-light.png` | One rule for headers in both, per `SettingsWords` | S |
| VI-22 | low | Models' download rows have no name: "Not downloaded yet · 853 MB" under Processing and under Live. | `pro-settings-models-light.png`, `duo-open-settings-models-dark.png`; `ModelRows.swift:293` | Title the row with what it downloads ("Transcription and speakers"), status under it | S |
| VI-23 | low | The Duo preview's "Open" is a prominent teal pill in the back button's slot, louder than the title. | `duo-open-library-light.png`; `LibraryBrowser.swift:294-297` | `.glass` "Open" with `book.pages` in the trailing group (P2) | S |

## Decisions recommended

- **ui-iphone-23 (two search entry points).**
  - Settled in code: the field exists only while search is presented (`SearchWhilePresented`, `LibraryPage.swift:505-527`), and `pro-library-*` shows no resting field.
  - Recommendation: keep one entry at the thumb, but draw it as the system's: `DefaultToolbarItem(kind: .search, placement: .bottomBar)` with `.searchToolbarBehavior(.minimize)` (P1). That is iOS 26's one-entry search, it removes the custom Search circle, and it puts the Duo's field at the thumb too (VI-19).
- **xdev-settings-03 (Settings organised differently on each app).**
  - From the iPhone's side: keep each platform's native structure. A grouped list with tiles is right for iOS (`pro-settings-root-light.png`), and Mac tabs are right for macOS. Don't restructure the Mac into a sidebar to match.
  - Take the minimal alternative: one meaning for "Library". The iPhone's "Library" section is Summary Templates, Vocabulary, and Speaker Profiles (`SettingsScreen.swift:118-130`); give the Mac a pane or group with the same name and contents (ux-flows proposes the same).
  - Make section names identical across both apps.

## Not findings (checked, fine)

- **The page.**
  - New York title, SF body at Dynamic Type, the lede a step larger, headings `Ink.body` semibold.
  - About 45 characters a line on the 18 Pro, 55 on the Duo's left page, 45 on its right.
  - Bullets teal, the byline's play pill teal on a 14% wash, decisions with bold emphasis, photos with times.
  - Reads well in both appearances (`pro-page-*`, `duo-open-page-*`).
- **The transcript.** Speaker names in speaker inks with times; the note rule teal and the bookmark rule amber hanging in the gutter; the mint playhead rule and wash; the dark-mode glow on the play button is restrained (`pro-transcript-*`).
- **The player bar.** Rewind and forward 15, play, rate, bookmark, and close on one row, the scrubber with elapsed and remaining time and the source; the content fades hard under it (`pro-transcript-play-*`).
- **Sheets.** Info, Version History, the selection bar, Trash with Restore, and search results with scopes and a highlighted match.
- **Settings.** Grouped lists with tiles in one column; device pages on paper with action tiles; iCloud's paused and signed-out states; the Cloud keys page.
- **Welcome on the 18 Pro (light and dark).**
- **Duo crease clearances.** As documented: the list wash and reading column 16 pt from the crease, controls 24 pt. The Settings spread splits list | screen cleanly (`duo-open-settings-*`).
- **Table mode.** Book and flex stages both read from across a table; the dim is by design (`duo-book-table-*`, `vi-shots/duo-flex-preview.png`).
- **Accessibility sizes.** Bookmark and Stop keep their glyphs and the count; the recorder's header holds its size; page titles and row titles wrap; the byline stacks (`pro-*-accessibility-*`). The previous audit's ui-iphone-01, -02, and -03 hold.
- **Dark Mode.** Owner chips, tags, warning ink, the bookmark amber, and the record red all read at their documented contrast; the glass tray and sheets stay legible over the list.
- **Not judged.**
  - `pro-page-colophon-*` is identical to `pro-page-notes-*`: the scroll didn't reach the colophon.
  - `duo-open-welcome-*` shows the empty library, because Welcome had already been completed on that simulator (`PhoneWelcome.completedKey`).
  - `duo-open-landscape-library-*` equals `duo-open-library-*`: the inner display is already landscape. Neither the cover nor the 18 Pro on its side was captured; `--interface-orientation landscape` didn't rotate the 18 Pro.
