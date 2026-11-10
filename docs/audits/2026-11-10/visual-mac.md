# Visual UI of the Mac app (lane: visual-mac)

Reviewer: visual-mac. Screens judged from `shots/mac/` plus my own captures. Paths below starting `vm/` are under
`(scratch)/` (see "Capture caveats": the shared set does not show the shipping chrome).

## Capture caveats (read before using `shots/mac`)

1. **No Liquid Glass anywhere in `shots/mac`.** `swift build` links the debug binary with SDK version 15.0
   (`otool -l .build/out/Products/Debug/Daybook` → `sdk 15.0`; the packaged app says `sdk 27.0`; docs/validation.md:394
   already notes it for the title bar). AppKit therefore draws the pre-Tahoe chrome: flat toolbar with a hairline, square
   segmented control, no glass capsules. In addition `--snapshot` renders with `cacheDisplay` (DaybookApp.swift:467-473),
   which cannot draw glass or out-of-process views. To judge the real chrome I re-tagged a copy of the same debug binary
   with `vtool -set-build-version macos 15.0 27.0` (`scratchpad/vm/tahoe/Daybook`, symlinked resource bundles, ad-hoc
   signed) and captured windows through the window server (`screencapture -l`): `scratchpad/vm/real/*/`. Those are the
   images to look at for chrome, glass and inactive-window appearance.
2. **Seeding race.** Many shared captures were taken before the demo library settled (3 s delay under load): every row
   says "Waiting for models", the selection is "Roadmap review" and the page shows "Download models to transcribe this
   conversation · 16.3 GB": `page-1440-inspector`, `failed-1440`, `recording-1440`, `transcript-*` partly, and the first
   `summary-*` pass. My captures use 9-20 s.
3. **`failed-1440` selects "Offsite retro", which isn't failed.** The failed demo rows are "Board prep", "Interview with
   Sam" and "Interview debrief". The failed page state is therefore not in the set.
4. **Floating Notes states are mostly not captured.** After `notes-recording-compact` (`--notes-size 340x228`), every later
   `notes-*` run opened at 340×228 (their `windows.txt`), because the panel autosaves its frame in the process's standard
   defaults (`NotesPanel.swift:83 setFrameAutosaveName("FloatingNotes")`), not in the per-library suite that
   `LaunchOptions.defaults` promises ("runs on different libraries side by side don't share settings or panels").
   `notes-failed`, `-multipoint`, `-paused`, `-processing`, `-stopped` show the compact **home**, not their scenario.
   Floating Notes and the call prompt can't be captured through the window server at all (`sharingType = .none`), by design.
5. **All captures show an inactive window** (grey traffic lights, grey selection, grey checkboxes in Light). That is a fair
   test of the inactive appearance; it can't show the accent-coloured selection.
6. **`window-3.png` (untitled, 280×168, visible) is not Daybook's window.** Attaching lldb to a page scenario shows
   `NSApp.windows` = SwiftUI `AppKitWindow`, `NSStatusBarWindow`, `TUINSWindow` (text input UI, 500×500, hidden) and
   **`NSCampoLightweightUIHostWindow`**, 280×168, whose content view is a single `NSRemoteView`. Campo is the system's
   Siri AI framework (`/System/Library/PrivateFrameworks/CampoUIServices.framework`; its launch agent
   `com.apple.campo` runs `Siri AI.app` behind the `IntelligenceFlow/Campo` flag). It is created for an empty editable
   text view on screen (the "Add a note…" notes editor) and appears/disappears with it (absent in transcript scenarios,
   0×0 or hidden at other times). `cacheDisplay` can't draw a remote view, hence the blank white PNG. **Not a Daybook
   bug, but two consequences:** (a) `WindowSnapshot.write` (DaybookApp.swift:465-473) snapshots every visible window,
   system ones included; (b) in the live window this affordance draws a small round glyph **in the page's time margin**,
   just left of "Add a note…" (`vm/real/failed-dark/12582-All_Conversations.png`, `vm/real/countdown-light/12588-…png`,
   `vm/probe-main.png`), exactly where note times hang. See VM-21.

## Summary

The Mac app is close to a genuinely good, calm macOS 26/27 app. In the real (SDK 27) chrome the toolbar reads native:
Record, the Summary | Transcript capsule, More and Inspector as glass controls, the title and "Transcribing 1 of 2"
over the list, a sidebar that matches Finder's and System Settings' on this macOS 27 build, and an inspector that looks
like a proper grouped form. Colour discipline mostly holds: red only for recording, amber only for bookmarks, orange for
"Couldn't finish", the gradient only on progress and the mark, and the page keeps its teal while the chrome stays system
grey when inactive. The weak point is the page itself. It is typeset like a well-made form, not a beautiful document: a
14 pt body on a 640 pt measure runs to about 97 characters a line (I measured 60 characters = 394 pt), the lede (16)
outranks the section headings (15), bullets indent the text away from the shared left edge, and next steps put their
times at the far right while notes put theirs in the left margin. At large sizes the window simply has nothing to say:
at 2560 pt the 640 pt page floats in roughly 500 pt of empty paper on each side while a 300 pt list column stays
cramped, even though the shared code already has a tested two-page spread (`PageSpread`) the Mac never uses. The list
column is tidy but uneven (tagged rows are a line taller, status glyphs mix a "new"-looking teal dot with clocks and
bars, and the subtitle "Transcribing 1 of 2" names the wrong step and an ambiguous count). Smaller surfaces (compact
Floating Notes, the call prompt, empty library) each have one visible layout slip. Finally, the design tooling itself
misrepresents the product (SDK 15, cacheDisplay, a seeding race), so anyone judging the app from `shots/mac` is judging
macOS 15 chrome; fixing that is cheap and should come first.

## Redesign proposals

### P1. A two-page spread when the window is wide (large sizes)

- **What and why.** Once the detail column is at least 1120 pt (a 1920 window without the inspector, any 2560 window),
  show the Summary and the Transcript side by side instead of one 640 pt column in a sea of paper. Principle 1 ("one
  thing on screen per moment") still holds: it is one conversation; the transcript is "the evidence behind the page",
  and at this size the evidence can sit beside the claim. Mac precedent: Preview's two-page view, Xcode's assistant
  editor, Books' spread. The infrastructure exists and is tested for exactly this: `PageSpread` / `PageSpreadLayout`
  (`Sources/DaybookUI/ReadingPage.swift:192-241`, `ReadingGeometryTests` "A full-screen Mac column"), and
  `PassageLinks(onTap:)` (`SummaryBody.swift:3-18`) already says "with two pages side by side a tap on the block does it".
- **Touches.** `MeetingDetailView.swift:28-31` (the `switch mode` becomes `PageSpread { SummaryPage } trailing:
  { TranscriptPage } single: { current switch }`), `SummaryPage` (pass `PassageLinks(onTap: true)` when spread),
  `TranscriptPage` (scroll target from the summary instead of a mode change; `AppState.showPassage` sets
  `pageScrollTarget` without flipping `pageMode` when spread), `DetailToolbar`/`PageSwitch` (MeetingDetailView.swift:140-178),
  View menu commands (⌘1/⌘2), find bar and search jump (`summaryJumps`, `MacSearch.open`).
- **Sketch.** Two columns of paper separated by a hairline (as `PageSpread` draws), each with its own 56 pt margin and
  a measure of min(560, half − gutters). Left: title, byline, summary, notes, colophon. Right: the transcript, scrolled
  independently, following the playhead. Clicking a next step, decision or note time scrolls the right page and flashes
  the passage (the transcript's existing flash). The toolbar's Summary | Transcript becomes a pair of toggles in the
  same capsule: both lit when spread; clicking one lit segment collapses to that single page (and the window remembers
  the choice per scene); below 1120 pt it behaves as today's radio switch. The player stays one bar under both.
- **Risks.** Two scroll views and the playhead-follow logic (transcript follow-scroll must not steal focus from the
  summary); find (⌘F) must target the page that has focus; memory for very long transcripts (TranscriptPage is already
  lazy). The header (title + byline) should appear once, over the left page only; the right page starts with speakers.
- **Size.** L.

### P2. Typeset the summary as a document: measure, sizes, hierarchy, hanging marks

- **What and why.** (a) The measure claim is false: `ReadingPage.swift:31` and `DaybookStyle.swift:50` say "about 72
  characters at the body size" but 14 pt SF on 640 pt gives about 97 (6.56 pt per character measured in
  `vm/real/sum-1280-dark`); the lede at 16 pt gives about 89. Long lines are why the page feels like a form at 1280 and
  up, while the 760 window (≈410 pt measure, ≈63 characters) actually reads best. (b) The hierarchy is inverted: lede 16 >
  heading 15 > body 14 (`Type.swift:119-122`), so "Next steps" and "Decisions" are smaller than the paragraph above them
  and read as labels. (c) Bullets and numbers sit inside the measure (a 16 pt column, `SummaryBody.swift:298-308`), so
  bullet text starts 16 pt right of the headings and the lede, against the documented rule "things that mark text hang
  outside" the shared left edge.
- **Proposed type scale (window density only; touch keeps Dynamic Type):** title 30-32 New York semibold; lede 19
  regular `Ink.body`, 26 pt line; section heading 17 semibold `Ink.body` (keep 32 pt above, 10 below); body 15 on a
  24 pt line (`bodyLineSpacing` 6); margin times 11.5-12; measure **560 pt** (≈80 characters at 15 pt; at the 640 pt
  maximum the next readingScale step would still fit). Bullets hang 14 pt into the gutter (dot at x = −10), numbers
  right-aligned in the gutter, so lede, headings, bullet text and next-step text share x = 0 (checkboxes are controls
  and stay at x = 0 per the doc; their text follows them). Keep New York only in the title unless the owner wants section
  headings in New York 17 as well (I would try it: it is what makes a page read as a document rather than settings).
- **Touches.** `Sources/DaybookDesign/Type.swift:111-126` (`.window` sizes), `ReadingGeometry.measure`
  (`ReadingPage.swift:32`) and its tests, `SummaryMarkdownMetrics.bullet` and the item `HStack` (SummaryBody.swift:298-330),
  `NextStepRow`, docs/interface.md "Geometry"/"Type", Floating Notes uses `.panel` sizes (unchanged).
- **Sketch.** At 1280: title, a quiet byline, a 19 pt lede that reads as the gist, then clearly separated sections whose
  17 pt headings sit on the same edge as every line of text; bullets in the margin like a printed report; ~80
  characters a line; notes and bookmarks with times in the margin as now.
- **Risks.** Every page gets longer (≈10%); `ReadingScale.steps` (DaybookStyle.swift:74) assume 14 as "Actual Size" and
  should be rebased; the transcript shares body size; the Duo/iPhone are unaffected (touch).
- **Size.** M.

### P3. One lane of times: next-step evidence in the left margin

- **What and why.** Next steps put their "said at" time at the far right of the measure (`SummaryBody.swift:181-193`,
  a `QuietLink` after a `Spacer`), 400-500 pt from the step at 1280-2560 (`vm/real/sum-2560-dark`: "0:27" and "0:31" sit at
  the right edge, far from their lines), while notes, bookmarks and the transcript hang their times in the left margin.
  docs/interface.md opens with "your own notes with their recording times in the margin… the transcript… with the same
  margin of times". Two time positions on one page break that, and the right-edge times read as orphaned numbers.
- **Touches.** `NextStepRow` (SummaryBody.swift:151-200): pass the time as the `MarginRow`'s margin (it is empty for
  next steps today), right-aligned at x = −8 like notes; optionally decisions/questions with evidence get the same
  margin time via `EvidenceLink` (SectionMarkdown, SummaryBody.swift:286-318). iPhone lane already exists in `MarginRow`.
- **Sketch.** Every timestamp on the Summary page sits in one ragged-left column of meta-ink times; the right edge of the
  page is just text. Hover turns a time to link ink, click shows the passage (or scrolls the spread's transcript, P1).
- **Risks.** At narrow widths the lane eats 50 pt; acceptable (it already does for notes).
- **Size.** S-M.

### P4. The list column as a calm index (list column)

- **What and why.** Rows are well built (DaybookUI `ConversationRowView`), but the column reads uneven and noisy:
  - Tagged rows are a line taller (`RowTags` on a third line, ConversationRowView.swift:54), so heights alternate 55/77 pt
    (`vm/real/sum-1280-dark`).
  - The trailing slot mixes five shapes at different visual weights: a 44 pt gradient line, a 7 pt teal dot, a clock, an
    arrow-down circle, a pause circle, an orange triangle. The teal dot for "Not transcribed yet"
    (ConversationRowView.swift:182) is the Mail/Notes "unread" idiom, so it reads as "new" rather than "needs a step".
  - The subtitle "Transcribing 1 of 2" (ConversationList.swift:115) always says "Transcribing" whatever the running step
    is, and "1 of 2" counts this Mac's queue while two rows on screen show transcription bars (one on Studio Mac), so the
    person can't map it to rows. It also shows in the Trash (`vm/real/trash-dark`).
  - The column never grows past 380 pt (LibraryView.swift:73) and keeps one line of gist even at 2560.
- **Proposal.**
  - Tags inline at the end of the date line when they fit, else dropped to a single "＋2" chip, so every row is two
    lines (the iPhone can keep its third line).
  - One 16 pt trailing slot with a single visual language: monochrome secondary symbols for waiting states (clock,
    pause, arrow-down), the gradient line only while work runs, red only recording, orange only failure, mint only
    playing. Replace the teal dot with `waveform` in secondary ink (or no glyph, since the words already say "Not
    transcribed yet").
  - Subtitle from `QueueStatusWords.line(...).shortText` (DaybookKit/QueueStatusWords.swift:37), the words Floating Notes'
    home and the menu bar already use: "Summarizing · 1 waiting", "Transcribing · 1 waiting". Hide it in the Trash.
  - Column `max` 440 pt; at ≥ 360 pt show two lines of gist (Mail's "Preview: 2 lines") so a wide window gets a better
    index instead of more empty paper.
  - Optional: the length on the date line ("10:21 PM · 41 min"), which VoiceOver already reads (ConversationRowView.swift:137).
- **Touches.** `Sources/DaybookUI/Library/ConversationRowView.swift`, `RowGlyph`, `RowTags`, `ConversationList.swift:105-117`,
  `LibraryView.swift:73`, docs/interface.md "List column".
- **Risks.** The iPhone shares the row (density-gated changes only); tag discoverability drops slightly.
- **Size.** M.

### P5. Status that sits with its words

- **What and why.** Bare status lines push their actions to the far end of the measure with a `Spacer`
  (`StatusBlock.swift:66-70`): "⬆ Upgrade transcript ……………… Upgrade  Dismiss" spans ~640 pt
  (`vm/real/upgrade-dark`). Boxes do the same with their prominent button ("Not transcribed yet ……… Transcribe",
  `vm/real/countdown-light`). The eye has to cross the page to find what to press. Boxes also decide to stack by a fixed
  520 pt (`Boxes.swift:112`), so at 545 pt (1440 + inspector) the title "Download models to transcribe this conversation"
  wraps beside its two actions (`shots/mac/page-1440-inspector-dark`).
- **Proposal.** Lines: actions follow the words after a 16 pt gap ("Upgrade transcript   Upgrade · Dismiss"), wrapping
  under only when needed (ViewThatFits already there). Boxes: hug their content up to the measure; the prominent action
  sits after the message with 16 pt, not at the far edge; stack when the title would wrap (ViewThatFits on the HStack)
  rather than below a fixed width. Trash: put "In the Trash · Restore" under the byline like every other status, not above
  the title (`vm/real/trash-dark`), and use the byline's date format.
- **Touches.** `Sources/DaybookUI/Reading/Status/StatusBlock.swift`, `Sources/DaybookDesign/Boxes.swift`
  (`AttentionBoxLayout.stackBelow`), `Sources/Daybook/UI/ConversationPage.swift:306-376` (`StatusBox`),
  `Sources/DaybookUI/Library/TrashViews.swift`.
- **Risks.** Countdown lines change width every second; give the words a fixed digit width (already monospaced).
- **Size.** S-M.

### P6. Make design captures tell the truth

- **What and why.** Every screenshot a reviewer, the owner, or the next fixer sees today is macOS 15 chrome, often of
  an unsettled demo (Caveats 1-4). That is how Liquid Glass regressions, toolbar grouping and inactive-window looks go
  unseen.
- **Proposal.** (1) Link debug builds with the current SDK version: add to the executable target
  `linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "27.0"])]`
  (debug-only), or make the snapshot script run `vtool -set-build-version macos 15.0 <sdk>` on a copy as I did.
  (2) `WindowSnapshot` captures each window through the window server (ScreenCaptureKit
  `SCScreenshotManager.captureImage` with an `SCContentFilter(desktopIndependentWindow:)`), falling back to
  `cacheDisplay` for `sharingType = .none` panels; skip windows the app didn't create (`NSCampoLightweightUIHostWindow`,
  `TUINSWindow`, status bar) by class or by `window.identifier == nil && !(window is NSPanel)`.
  (3) Snapshot on a "ready" signal (LibraryDemo's `seeding` finished + `settle` applied) instead of a fixed delay.
  (4) Autosave the Floating Notes frame in `LaunchOptions.defaults` (NotesPanel.swift:83).
- **Touches.** `Package.swift` (Daybook target), `Sources/Daybook/App/DaybookApp.swift:326-332, 462-476`,
  `Sources/Daybook/App/LibraryDemo.swift`, `Sources/Daybook/UI/NotesPanel.swift:83`, docs/interface.md "Checking the
  interface…".
- **Risks.** ScreenCaptureKit needs Screen Recording permission (the snapshot path then can't run while locked; keep
  cacheDisplay as fallback). `unsafeFlags` is fine in a root package.
- **Size.** S-M.

### P7. Floating Notes compact and the call prompt: one grid, one control language

- **Compact panel** (`shots/mac/notes-recording-compact-*`): the layout puts a flexible `Spacer` between the clock row
  and the note field (`RecorderSurface.swift:243`), leaving a ~50 pt dead band, and the note field is inset 16 pt
  (`RecorderInsets.panel`, :245-247) while the caption beneath starts its words at x = 52 with "You" in the lane, so the
  panel has two left edges ("Add a note…" at 16, caption at 52). The documented grid is "times and caption sources
  right-aligned at x = 44, text at x = 52". Proposal: note field text at x = 52 with a small pencil or the next time in the
  lane (as the full panel's notes do), field directly under the clock row, the spacer moved above the controls; caption
  line truncates with a trailing fade, not a hard clip (full panel: "…before the end" cut at the edge, `notes-recording-dark`).
- **Call prompt** (`CallPrompt.swift:236-310`): a hard-coded 14 pt radius (:293, :308) instead of `DaybookRadius` (the
  panel kind is 26), an opaque paper card where macOS 26 notifications and Daybook's own "control layer" are glass, and
  in the "call ended" variant **Stop** uses `.borderedProminent` (:286), which draws as a plain grey button in a never-key
  panel (`callprompt-ended-light`: "Keep Recording" and "Stop" look identical) even though the comment ten lines above
  explains exactly this problem for Record. Proposal: Stop gets the same red-dot treatment (or `DaybookControlStyle` with
  the record fill), the card takes `glassSurface(in: RoundedRectangle(cornerRadius: DaybookRadius.panel))`, and the
  draining hairline uses `Ink.meta` (a countdown is calm, and teal means "act on this" in the colour table).
- **Size.** S each.

### P8. Empty places that look intentional

- **Empty library** (`empty-1280-*`): the list column is 300 pt of blank white while the welcome sits centred in the page
  only, so the composition is off-centre and the blank column reads as "failed to load". Mac convention (Mail, Notes) puts
  the empty message in the list. Proposal: the list column shows "No Conversations" (as for other empty places,
  `LibraryEmptyPlaceView`), and the page keeps the mark, title and actions; or hide the list column while the library is
  empty (`columns = .doubleColumn`-style) so the welcome is centred in the window. This argues against docs/interface.md
  "the column stays empty".
- **Its buttons** (`LibraryView.swift:583-589`): Record is a `DaybookControlStyle` capsule, Import Audio… a `.bordered`
  rounded rectangle at a different height. Use one shape for both (capsules, Import secondary).
- **Size.** S.

## Findings

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| VM-01 | medium | Every `shots/mac` capture shows pre-Tahoe chrome: the SwiftPM debug binary links SDK 15.0 and `--snapshot` uses `cacheDisplay`, which can't draw glass or remote views | `otool -l .build/out/Products/Debug/Daybook` (sdk 15.0) vs `dist/Daybook.app` (27.0); DaybookApp.swift:467-473; compare `shots/mac/page-1280-dark` with `vm/real/sum-1280-dark` | P6 | S-M |
| VM-02 | medium | Body measure ≈97 characters (14 pt on 640 pt); the doc comment's "about 72 characters" is wrong; the lede ≈89 | ReadingPage.swift:31-32, DaybookStyle.swift:50-51; measured in `vm/real/sum-1280-dark` (60 chars = 394 pt) | P2: body 15/24, measure 560, fix the comment | M |
| VM-03 | medium | Hierarchy inversion: lede 16 pt is larger than section headings 15 pt, so headings read as labels | Type.swift:119-120; `vm/real/sum-1440i-dark` | P2: lede 19, headings 17 | S |
| VM-04 | medium | Next-step times sit at the far right of the measure while notes, bookmarks and transcript hang theirs in the left margin | SummaryBody.swift:181-193; `vm/real/sum-2560-dark` ("0:27", "0:31" at the right edge) | P3 | S-M |
| VM-05 | medium | At large widths the page is a 640 pt island (≈500 pt of empty paper each side at 2560); the tested `PageSpread` is never used for reading on the Mac | ReadingPage.swift:192-241; MeetingDetailView.swift:28-31; `vm/real/sum-2560-dark`, `shots/mac/page-2560-*` | P1 | L |
| VM-06 | medium | List subtitle "Transcribing 1 of 2" names "Transcribing" whatever step runs, counts only this Mac's queue while another device's bar is on screen, and shows in the Trash | ConversationList.swift:105-115; `vm/real/sum-1280-dark`, `vm/real/trash-dark` | Use `QueueStatusWords.line(...).shortText` ("Transcribing · 1 waiting"); hide in Trash | S |
| VM-07 | low | Bullet and number text is indented 16 pt inside the measure, so it doesn't share the left edge with the lede and headings ("marks hang outside") | SummaryBody.swift:298-308, 327-330 | Hang the dot/number into the gutter (P2) | S |
| VM-08 | medium | Compact Floating Notes has a dead band under the clock and two left edges (note field at 16 pt, caption words at 52 pt) | RecorderSurface.swift:243-247; `shots/mac/notes-recording-compact-*` | P7 | S |
| VM-09 | medium | Call prompt "call ended": Stop is `.borderedProminent`, which renders as a plain grey button in the never-key panel, identical to Keep Recording | CallPrompt.swift:283-287 (and the comment at :276-277); `shots/mac/callprompt-ended-light` | Red-dot Stop / `DaybookControlStyle` (P7) | S |
| VM-10 | low | Call prompt uses a hard-coded 14 pt radius and an opaque card; draining hairline is link teal | CallPrompt.swift:293, 297-298, 308 | `DaybookRadius.panel`, `glassSurface`, `Ink.meta` hairline (P7) | S |
| VM-11 | low | Status-line actions and a box's prominent button sit at the far end of the measure, up to ~600 pt from their words | StatusBlock.swift:66-70, :130-133; `vm/real/upgrade-dark`, `vm/real/countdown-light` | P5 | S |
| VM-12 | low | Attention box stacks by a fixed 520 pt, so at 545 pt the title wraps beside its two actions | Boxes.swift:112-116; `shots/mac/page-1440-inspector-dark` | Stack when the title would wrap (ViewThatFits) | S |
| VM-13 | low | List row heights alternate 55/77 pt because tags take a third line | ConversationRowView.swift:54-57; `vm/real/sum-1280-dark` | Inline tags (P4) | S |
| VM-14 | low | "Not transcribed yet" row glyph is a teal dot, the Mail/Notes unread idiom | ConversationRowView.swift:182-185 | Secondary `waveform` glyph or none (P4) | S |
| VM-15 | low | List column capped at 380 pt and one gist line even at 2560; sidebar + list are ~500 pt of a 2560 window | LibraryView.swift:67, 73; `shots/mac/page-2560-*` | max 440, two gist lines ≥ 360 pt (P4) | S |
| VM-16 | low | Countdown disagrees with itself: subtitle "Summarizing in 7 s" while the row says "Summarizing in 6 s" in the same frame (two `TimelineView`s started at different `.now`) | ConversationList.swift:158; ConversationRowView.swift:101; `vm/real/countdown-light` | Schedule both on the deadline's phase (`.periodic(from: deadline - ceil(remaining), by: 1)`) | S |
| VM-17 | low | Inspector uses two date formats: Created/Edited "Nov 9 at 10:21 PM", Processing "Nov 9, 2026 at 10:41 PM", which wraps in the 280 pt inspector | ConversationInfoForm.swift:146-147 vs :229, :245; `shots/mac/summary-speakers-inspector-light` | `InfoDate.format` for both | S |
| VM-18 | low | Empty library: blank 300 pt list column beside an off-centre welcome; Record (capsule) and Import Audio… (rounded rect) differ in shape and height | LibraryView.swift:572-610 (583-589); `shots/mac/empty-1280-*` | P8 | S |
| VM-19 | low | Trash page puts its status box above the title (every other page puts status under the byline) and uses a different date format | TrashViews.swift; `vm/real/trash-dark` | Status under the byline; byline date format (P5) | S |
| VM-20 | low | Templates editor's help line is truncated: "Describe the purpose, the sections you want, and…" | TemplateEditor.swift:189, 219-224; `shots/mac/templates-dark` | `.fixedSize(horizontal: false, vertical: true)` | S |
| VM-21 | low | The system's Siri AI ("Campo") affordance draws a round glyph in the page's time margin beside an empty notes field; the snapshot tool writes its host window as a blank `window-3.png` | `vm/real/failed-dark/12582-…png` (glyph left of "Add a note…"); lldb: `NSCampoLightweightUIHostWindow` 280×168 with an `NSRemoteView`; DaybookApp.swift:467 | Skip foreign windows in `WindowSnapshot` (P6); check whether the notes `NSTextView` can opt out (e.g. `writingToolsBehavior`) or whether the glyph should be accepted; at least keep note times clear of it | S |
| VM-22 | low | Floating Notes' frame autosave is in the standard defaults, so `--library` runs share panel frames, contrary to `LaunchOptions.defaults`' stated intent; it silently changed the size of every later `notes-*` capture | NotesPanel.swift:83; `shots/mac/notes-*/windows.txt` (340×228) | Autosave via `LaunchOptions.defaults` key, or only without `--library` | S |
| VM-23 | low | Settings › Recording keeps a mechanics footer ("Captions for English (United States) download the first time you record with them on."), which principle 7 rules out | LiveCaptionWords.swift:117; `shots/mac/settings-recording-light` | Drop it, or say it only while a download is pending | S |
| VM-24 | low | Docs drift: Welcome is four steps (intro, quality, allow, ready), the doc says three; `DaybookStyle.paper`'s comment says `#1E1E1E`, the token is `#18181B` | WelcomeWindow.swift:12; docs/interface.md:102; DaybookStyle.swift:17-18 vs Palette.swift:78 | Fix the doc and comment | S |
| VM-25 | low | Speaker Profiles: the Merge Into menu button is inset ~8 pt from the grouped row's leading edge, and "Named" repeats on each conversation row | SpeakerProfiles.swift:355-375; `shots/mac/speakers-dark` | Borderless menu aligned to the row edge; drop "Named" from conversation rows (verify on SDK 27) | S |

## Decisions recommended (open owner decisions this lane touches)

- **ux-mac-14 (fresh install on "Custom" models):** start on the recommended preset. The visible consequence today is
  the first page a new person sees on a real conversation: "Download models to transcribe this conversation · 16.3 GB"
  (`shots/mac/page-1440-inspector-*`), and Settings › Models opening on "Quality: Custom · 16.3 GB · 32 GB memory"
  (`shots/mac/settings-models-dark`). A named, recommended preset with its size reads as a choice; "Custom" reads as
  something already went wrong.
- **xdev-settings-03 (Settings organisation):** on the Mac this is effectively decided: Settings is now a System
  Settings-style window with a searchable sidebar (General, Recording; Devices, Library; Models, Cloud), and it looks
  native in every capture (consistent grouped rows, labels left, controls right, section headers only where a pane has
  several groups). Recommend closing it on the Mac side and keeping Vocabulary, Summary Templates and Speaker Profiles as
  separate windows reachable from Settings › Models; the remaining question is naming parity with the iPhone, outside
  this lane.

## Not findings (checked, fine)

- Toolbar in the real (SDK 27) chrome: Record, the Summary | Transcript capsule, More, Inspector and search sit as glass
  controls, nothing overflows at 760 pt (search collapses to a button), groups stay put and dim when they don't apply,
  and the recording Stop pill keeps its red in an inactive window (`shots/mac/recording-1440-dark`).
- Sidebar: flush, full height, the same treatment as Finder and System Settings on this macOS 27 build
  (`vm/ref-finder.png`, `vm/ref-settings.png`); icons in one column; "Folders" header aligned to the icon column.
- Inactive window: chrome greys out (selection, segmented control) while the page keeps its teal and the record dot its
  red, as the doc intends.
- Colour meaning holds across the captures: red only for recording, amber only bookmarks, orange only failures,
  gradient only progress/mark/Welcome, mint the live glyph, speaker inks only on names and chips.
- 760 pt: the sidebar steps aside, the page folds to a narrow layout, owner chips wrap under long next steps, nothing
  clips (`vm/real/sum-760-light`). The inspector at 1440 keeps the page above 560 pt (measure 545).
- The inspector's grouped form (Details, People with speaker dots and bars, Audio, Processing) is consistent and calm in
  SDK 27 (`vm/real/sum-1440i-dark`).
- Transcript page: speaker names in their inks, notes and bookmarks interleaved with their 2 pt rules in the gutter,
  photos inline; times in one margin (`vm/shots/tr-1280-dark`).
- Batch selection page, search results with scopes and highlighted matches, the notice with Undo, Vocabulary's table,
  Welcome's first step, and the call prompt's record/meeting variants look finished.
- `window-3.png` is a system window, not a Daybook bug (Caveat 6).
