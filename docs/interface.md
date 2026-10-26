# Interface

Daybook's interface follows one idea: **a conversation is a page**. You open it to a calm, typeset document. It has the title, one byline, what happened, the next steps, the template's sections, and then your own notes with their recording times in the margin. The transcript is the evidence behind the page: one switch away, with the same margin of times. The window around the page is a frame, not a feature list.

The redesign was planned from UX, platform (macOS 26/27 Human Interface Guidelines and Liquid Glass), and wearable-companion research, and then two competing design directions. This document records the result so future changes stay consistent.

## Principles

1. **One thing on screen per moment.**
   - During a call: a notepad, Bookmark, and Stop.
   - Afterwards: the gist and the next steps.
   - Weeks later: search that opens at the exact passage.
2. **Status speaks only when there is something to say.**
   - When everything is fine, nothing reports status.
   - Working or needing attention shows one line in place: in the page, and in the list row.
   - A working state is a bare line. A state that needs the person is a quiet filled box with at most two actions.
   - Processing is never a toolbar button. It starts by itself after recording and import, and reprocessing lives in menus.
3. **Chrome is a frame.**
   - The main toolbar shows at most three groups plus search, and never overflows at 1280 pt. Its groups never come and go: what doesn't apply is dimmed, so Record stays under the pointer.
   - Liquid Glass appears only on the control layer: the system toolbar, sidebar and inspector, and the player capsule.
   - Content is never glass.
   - Chrome uses system semantic colours only (so vibrancy, Increase Contrast and inactive windows keep working). Paper uses the Ink scale.
4. **Colour has a job.** Neon marks what is live or what you can act on, in dark mode, at small sizes. Each colour means one thing:

   | Colour | Means | Appears |
   |---|---|---|
   | Red (`Ink.record`) | Recording, right now | The recording dot in the byline and list row; the Floating Notes clock; Stop (panel and toolbar pill); the Record button's dot. |
   | Amber (`bookmark`) | Something you marked | Bookmark glyphs, the transcript's bookmark label and 2 pt rule, count badges. Nothing else. |
   | Teal (`accent` fills / `Ink.link` text) | Selected, or you can act on it | Selection, focus, checkboxes, every link and text button in content, tag chips, the play pill, the transcript note rule, "Saved ✓". |
   | Neon mint | Playing now | Playhead rule and wash, slider, play button, byline waveform. Inserted words in Version History. |
   | Brand gradient (mint → cyan → violet) | Daybook itself, or work in progress | Mark, Welcome bullets, the Settings privacy lock, progress bars (including the 2 pt line in a list row that is transcribing). |
   | Orange (`Ink.warning`) | Needs you | Failure glyphs, problem boxes, "Recording stopped", "No conversations". |
   | Speaker inks | A person | Speaker names, owner chips, inspector dots and bars. |

   System blue never appears in content: text links use `.buttonStyle(.daybookLink)`.
5. **Nothing a person reads on paper goes below 4.5:1.** Only placeholders and disabled text (`Ink.faint`) are exempt. Chrome never puts a time, a control, or a preview in `.tertiary`.
6. **Facts, not slogans.** Privacy and provenance appear where a reader expects them. "Summarized on this Mac" sits at the foot of the page, and the full statement is in Settings › Library.
7. **Say what's happening, not how it works.** No subtitle, footer, notice, or empty state explains mechanics: sync, iCloud, the Wi‑Fi link, where audio travels, which model runs where, or what Daybook never does. Keep status values, a next step that matters, a problem and its fix in one short sentence, and a destructive action's consequence; prefer a label to a sentence, and explanation belongs only in Welcome.

## Window structure

- **Main window** (`Window`, id `library`): a three-column `NavigationSplitView`.
  - **Sidebar:** All Conversations, Work, and Personal, then Folders (once one exists), then Devices (once a recorder is added; see [devices.md](devices.md)). There are no counts and nothing pinned to the bottom.
    - Rows use `SidebarLabelStyle`: every symbol centred in one column, then the title. It follows System Settings › Sidebar icon size: column 16 / 20 / 24 pt, symbol 12 / 15 / 18 pt, gap 6 / 7 / 8 pt (small / medium / large). Row height, selection and icon tint stay the system's.
    - Section headers start on the icon column's edge; their `+` appears on hover (11 pt semibold, 20 pt hit area).
  - **List column:** two-line rows grouped Today / Yesterday / Previous 7 Days / Previous 30 Days / months / years.
    - The date reads in `.primary`, the preview in `.secondary`. A first note line that repeats the title is skipped.
    - A trailing glyph appears only when a conversation isn't ready: recording, transcribing (a 2 pt gradient line), waiting, waiting for models, paused, couldn't finish, or not transcribed.
    - The column's subtitle speaks only while work is happening. In an empty library the column says what will appear there.
  - **Detail:** the page, on the Paper reading surface.
  - **Inspector:** hidden by default (⌃⌘I). It holds Details, People, Audio, and Processing. When opening it would leave the page under 560 pt, the sidebar steps aside. Tags sit under their label, like Finder's Get Info; Template is a picker whose first item carries the guess ("Automatic (Meeting)").
- **Detail toolbar:** declared once on the stable detail column (`DetailToolbar`), never inside the per-conversation view. Its groups are always present, dimmed when they don't apply:
  - Record (the red elapsed-time pill while recording)
  - the Summary | Transcript switch (disabled until a transcript exists; Bookmark replaces it while that conversation is recording) and More
  - Inspector
  - search
- **Floating Notes:** a non-activating `NSPanel` (`.floating`, on every Space and over full-screen apps) that sits over someone else's call without taking focus from it. Panels normally hide when their app is inactive; this one deliberately doesn't, because that is its whole job. It shows your notes and live captions over the call, so it's left out of screen sharing and screenshots (`sharingType = .none`). It's a floating version of the iPhone's main screen: the iPhone's recording surface while recording, and a small home in the language of its status sheet otherwise. It's one sheet of paper with no glass and no toolbar, so it keeps the smaller titlebar-only corner radius. It opens from Window › Floating Notes (⌥⌘N), the menu bar extra, and the Dock menu: on the recording, else the selected conversation, else its home. The views are in `Sources/Daybook/UI/FloatingNotes/`; the pieces it shares with the iPhone are in `DaybookDesign` (see Design tokens).
  - **Title band:** the system's 28 pt band, transparent and without a separator. Close (left) and Compact (right, mirroring it) fade in only while the pointer is over the panel; minimize and zoom are hidden. Between them, centred like a window title, the phase in the iPhone's words: "● RECORDING · MacBook Pro Microphone" (the input device; "Microphone silent" in `Ink.warning` when the microphone hears nothing, as on the iPhone, with the fix in its tooltip), "✓ SAVED · 12:41", or "⚠ STOPPED".
  - **Status chips:** a glyph and a short label in a quiet capsule, each a menu whose first line is the whole status in a sentence (also its tooltip and VoiceOver label), then what you can do. In order:
    - Call (while recording): teal when call audio is detected, calm when it's quiet, and "No call audio" in warning ink with the fix when it should be captured and isn't.
    - Each recorder: "Soundcore · 80%" with the red dot while it records along; "Soundcore on Alex's iPhone" when the iPhone manages it (Use on This Mac in its menu, with Show Soundcore Work); "Moving…" during a handoff; "Not recording" when it was asked to record along and didn't start.
    - Each paired iPhone that's connected or part of the recording: the red dot when it records too, "Paused" in warning ink when it paused.
    - After Stop, the conversation's processing: "Transcribing · 40%" over the 2 pt gradient line (another device is named: "Transcribing on Studio Mac · 40%"), "Summarizing…", "Waiting for models", "Summary ready". Its menu pauses, resumes, or tries again.
    - iCloud, only when sync is a problem: "Not syncing", with Open Sync Settings….

    Labels shorten, then give way to glyphs, as the panel narrows; processing and anything that needs you keep their words longest. Full, the chips are a row of their own under the band; compact, they share the band with the phase. The words come from `FloatingStatus`, plain values from plain inputs like the iPhone's `StatusSheetModel` (tests in `FloatingNotesStatusTests`). The facts come from `RecordingController.levels` (call detected, microphone silent), the device hub's sessions (connection, battery, recording, `managedElsewhere`), `RecorderHandoff`, `PhoneLink.recordingStates`, the conversation's `CompanionRecording`s, `ProcessingStatus`, and the sync status. `FloatingStatusFeed` merges and throttles them, so the bar never redraws at meter speed.
  - **Recording:** the title in New York 17 pt (scaling to 1.3× at most); the red elapsed clock (34 pt) beside rolling You and Call meters, the iPhone's meter sampled 15 times a second from `RecordingController.levels` (only the meters redraw); "● Also recording on Alex's iPhone and Soundcore Work", and "Alex's iPhone paused · This Mac keeps recording", as on the iPhone; a hairline; your notes with their time lane; live captions; and Bookmark and Stop side by side, 44 pt tall.
  - **Live captions:** a fixed strip above the controls, so the notes never move as words arrive: "LIVE CAPTIONS · TENTATIVE", then the newest two lines, each with You or Call right-aligned in the time lane. The newest is larger and in Body ink, the one above in Secondary, words still being revised in Meta. They're never the transcript.
  - **Bookmark and Stop:** the iPhone's controls. Bookmark is amber with a count pill and bounces when one lands. Stop is a red tile with its own colours rather than a system prominent style, so it stays red when the panel isn't key, which is its normal state during a call (and while it saves).
  - **After Stop:** the band says Saved and the chips say what's becoming of the recording. The title, when it was, and your notes stay; Open (link teal, "Open Summary" once there is one) takes Bookmark's place and Record takes Stop's, for the next call. A recording that failed shows "Recording stopped" in a quiet warning box and Record Again; a conversation that couldn't finish shows "Couldn't finish transcribing" with Try Again.
  - **Home** (nothing recording): status lines in the status sheet's language, one each for every recorder ("Soundcore Work  Connected · 80% · 1 new"), every paired iPhone ("Alex's iPhone  Connected"), this Mac's queue while there's work ("This Mac  Transcribing · 40% · 2 waiting"), and iCloud when it's a problem. A line opens its device page. Then Recent: five conversations in the iPhone's row style (the title; the day and what's happening, or the gist; a glyph only when it isn't ready), each opening in Daybook. Opened for a conversation, its title and notes take Recent's place, and "Recent" goes back. Record (a capsule; it records into a conversation that has only notes) and Import (a circle) sit at the foot.
  - **Sizes:** 360 × 560 by default, at least 280 × 196. Below 380 pt tall the panel is compact: the band carries the phase and the chips, then the clock with small meters, the newest caption line, and the controls at 34 pt (after Stop, the title and Open and Record; at home, Record and Import). The Compact button snaps to 212 pt and back; dragging the bottom edge does the same.
  - **Grid:** content keeps a 16 pt inset on both sides. Note times and caption sources are right-aligned at x = 44 (fixed 11 pt, so "1:02:03" fits), and text starts at x = 52.
  - **Keys:** ⌘D bookmark, ⇧⌘R stop (or record), ⌘O open in Daybook, ⌘W hide (the recording continues), ⌘+ / ⌘− / ⌘0 text size. There is no Esc binding, so a stray Escape during a call does nothing.
  - **Accessibility:** under Reduce Motion the meters stop scrolling (their bars light from the left up to the level), the clock fades rather than rolls, and surfaces fade. Increase Contrast uses the Ink scale's contrast values and outlines the chips, controls, and Stop; it and Reduce Transparency drop the neon glows.
- **Menu bar extra:** a standard menu (`.menuBarExtraStyle(.menu)`). Its label is a symbol only, because a ticking text label re-lays out the status item every second. Personal conversations are never named in it.
- **Settings** has four panes: General, Models, Devices, and Library.
  - **Models** is the model manager ([models.md](models.md#the-model-manager)), a grouped form generated from the catalog:
    - Quality: Quick, Balanced, and Detailed as radio rows, each with its models, size, and memory, and this Mac's recommendation marked; Custom appears when the choices match none.
    - A section per role (Transcription with its language rows, Speakers with the speaker settings, Summaries with titles and tags), each with a model pop-up whose items carry their state underneath.
    - Words and Templates.
    - Model Library (disk use, old revisions, updates), then every model grouped by family, ending with Acknowledgements… and Add Model….
    - A row speaks only when something isn't ready: "Not downloaded · 1.6 GB" with Download, "Downloading · 40%" with Cancel. Labels are facts ("Non-commercial", "Added by you", "Recommended"); "In use" and "Update available" are teal because you can act on them; "Needs downloading again" is a warning.
    - Details, Add Model, and Acknowledgements are sheets. Removal is an alert that states what it frees and what each role will use.
  - The About Daybook panel's credits carry the same acknowledgements.
- **Vocabulary** and **Summary Templates** are separate single windows.
- **Welcome** is a three-step first-run window.

## Design tokens

Tokens live in `Sources/Daybook/UI/DaybookStyle.swift`. The values the Mac and the iPhone share are also in the `DaybookDesign` library (`DaybookPalette`, `DaybookSpacing`, `DaybookMotion`, `DaybookType`), with the components both draw: `RollingLevelMeter` and `LevelTrail`, `ElapsedClock`, `RecordingPhaseLabel`, `LiveCaptionStrip`, `StatusLineView` and `StatusChip`, `WorkProgressLine`, `AttentionBox`, and the Record, Bookmark, and Stop labels with `daybookControl(_:shape:)` (Liquid Glass on iPhone, Daybook's own fills on the Mac). Its public API is SwiftUI and plain values only. `DaybookDesignTokenTests` keeps `DaybookStyle`'s values equal to `DaybookPalette`'s in light and dark, and the two resolving alike under Increase Contrast. Floating Notes uses the library now; the iPhone's own copies move to it in a later pass.

- **Colour:** each token is dynamic, with light, dark, and increased-contrast values. `Color(light:dark:…)` and `NSColor.daybook(light:dark:…)` are one implementation, so SwiftUI and the notes `NSTextView` draw the same ink.

  | Token | Light / dark | Used for | Never for |
  |---|---|---|---|
  | `accent` (Electric Teal) | `#00806F` / `#00A3A0` | selection and focus (through the `AccentColor` asset), checkboxes and switches, the byline play pill's fill, the transcript's note rule, tag chip fills (14%), accent status boxes (8% fill), page bullets | text (use `Ink.link`), body text, headings, toolbar glyphs |
  | `prominentFill` | `#00796B` / `#007F73` | prominent buttons, so white labels keep 4.5:1 | anything that isn't a filled button |
  | `neonMint` | `#00B894` / `#3DFFD0` | "playing now": the playhead rule and wash, the player slider, the dark play button, the auto-record Listening dot | text (2.5:1 in light mode) |
  | `neonCyan` | `#0096C7` / `#33E1FF` | the glow under progress and the mark | standalone fills or glyphs |
  | `neonViolet` | `#7C3AED` / `#B388FF` | inside `brandGradient` only | anything else (it sits beside the plum speaker ink) |
  | `neonMagenta` | `#D6249F` / `#FF4FD8` | removed words in Version History | the main window |
  | `brandGradient` | mint → cyan → violet | the mark (icon, Welcome, empty library; its bars are always the dark neon, glow included, because the tile is always dark), progress bars, Welcome's bullets, the Privacy lock | text, buttons, glyphs under 16 pt, more than two objects per window |
  | `bookmark` (Amber) | `#A86400` / `#FFD23F` | bookmarks only | warnings (use `Ink.warning`) |
  | `paper` | `#FDFCFA` / `#18181B` | the reading surface; dark is one step below the list column, so the page recedes and neon reads brighter | chrome |

- **Ink:** text on paper (`DaybookStyle.Ink`, also `Ink`). Each has an `NSColor` twin (`Ink.bodyNS` …) for AppKit text views. Contrast is against `paper`.

  | Token | Light / dark | Contrast | Used for |
  |---|---|---|---|
  | `Ink.title` | `#1A1917` / `#F5F4F0` | 17.1 / 15.5 | page title, empty-library and batch titles, Floating Notes title |
  | `Ink.body` | `#2B2A26` / `#DFDDD7` | 14.0 / 12.5 | everything you read on the page: lede, summary, next steps, passages, notes, bookmark labels, quotes. set explicitly on each text and field, never inherited from the page, because an inherited style also recolours button labels in status boxes. Headings are Body at semibold |
  | `Ink.secondary` | `#66625A` / `#A29F98` | 5.9 / 6.4 | byline, status lines and box messages, completed next steps, ordered-list numbers, Version History's Before / After |
  | `Ink.meta` | `#78736A` / `#8A877F` | 4.6 / 4.7 | margin times, byline separators, the colophon, hints, the provenance glyph |
  | `Ink.faint` | `#B4AFA5` / `#5A5853` | 2.1 / 2.4 | placeholders, disabled text, the colophon rule. Never information |
  | `Ink.link` | `#00796B` / `#34D9C3` | 5.2 / 9.6 | every text link and text button in content (`.daybookLink`), margin times and `HoverLink` on hover, search matches in list snippets, tag-chip text |
  | `Ink.warning` | `#B45309` / `#FFB054` | 4.9 / 9.4 | every warning glyph and warning text; replaces `.orange` everywhere |
  | `Ink.error` | `#C4271D` / `#FF6961` | 5.6 / 6.0 | destructive text buttons, unrecoverable errors. Not recording |
  | `Ink.record` / `recordFill` | `#D92D20` / `#FF453A`, fill `#E5243B` dark | white on fill 4.8 / 4.5 | the recording dot, Stop fills, the Record button's dot. Nothing else is red |

  - In chrome, the roles are system colours: `.primary` for titles, values, and the list row's date; `.secondary` for row previews, search snippets and locations, inspector labels, and captions; `.tertiary` only for decoration that repeats information; `.quaternary` for fills.

  - `neonGlow` adds a soft halo in Dark Mode only. Light Mode, Increase Contrast, and Reduce Transparency get none, because there it reads as blur rather than light.
  - `quietFill` is `quaternarySystemFill`.
  - Speaker inks (six; Tailwind 700s in light, 300s in dark) are used only for speaker names, owner chips (text only once a next step is done), and the inspector dots.
  - `DaybookLinkStyle` (`.buttonStyle(.daybookLink)`) is the text link in content: `Ink.link`, no underline, a little brighter on hover.
  - Everything else uses semantic system colours.
  - The app icon (`scripts/make-icon.swift`) and `DaybookMark` are the same drawing. Change them together.
- **Type:**
  - New York (serif) appears only in titles.
  - Everything else is SF, with monospaced digits for every time.
  - The reading surface (page, transcript, floating notes) scales with View › Make Text Bigger / Smaller / Actual Size. Chrome text never scales.
- **Geometry:**
  - The text measure is 640 pt, with a 56 pt time margin hanging to its left. Times end 8 pt before the text.
  - One left edge per column: text, controls, boxes and headings share x = 0. Things that mark text hang outside it: times in the margin, and the playhead, bookmark and note rules centred in the 8 pt gutter (x = −4). Bezels (the play pill, status boxes) align their outer edge, not their label.
  - Below a 600 pt detail width, times fold inline. Below 520 pt, a status box's actions move under its message.
  - Spacing follows `Space.s1…s8` (4–64 pt). Summary headings sit 32 pt below the block before them; the lede 24 pt below the byline.
- **Words:**
  - Conversation; Bookmark; Recording / Audio; Version History; Template.
  - Transcribe, Summarize Again, Identify Speakers Again, Transcribe Everything Again (never "Transcribe Now").
  - New Note (File › New Note, ⌘N; the library's New Note on the iPhone) starts a conversation that's only your notes, titled "Note at 10:15 AM" on both apps; Record records into it.
  - Record calls automatically (Settings › General and the menu bar extra), beside "Listening for calls".
  - Add Photos… everywhere; Photo Deleted for a photo that's gone; Microphone silent, never "Mic silent".
  - Errors: the alert's title names what couldn't be done ("Couldn’t Import Audio"), its message is one plain sentence with what to do, and the system's own words are behind Details… (`AppState.report`, `AppProblem`).
  - Diarization, alignment, offset, and provenance never appear in the main interface.

## Motion

Animations go through `.motion(_:value:)`, which falls back to a short fade under Reduce Motion. There are three curves (`Motion.hover`, `.state`, `.page`), and motion only answers something the person did or a change of state. Nothing loops except work in progress and the Listening dot.

| Moment | Motion |
|---|---|
| Hovering a margin time, folder header, or row | `Motion.hover` fade or tint (0.12 s) |
| Bookmark added | the Bookmark symbol bounces; the new bookmark slides in |
| A bookmark opens | its chevron rotates and the quote expands (`Motion.state`) |
| Record starts or stops | Record, the red pill, and Saving… blur into each other; Stop bounces once |
| A summary arrives while the page is open | the lede, next steps, and sections fade up 40 ms apart (up to six); the colophon glyph bounces. Opening a page never animates |
| Summarize Again | the old summary dims to half while the new one is written |
| A row finishes work | the gradient progress line becomes an accent checkmark for 1.5 s, then fades |
| Playing | the byline waveform animates; the playhead rule glows mint |
| Processing or downloading | the gradient progress bar fills |
| Template edited | the Edited capsule scales in |
| Auto-record is listening | the mint dot in Settings › General pulses |

### Deliberate departures from Direction A

- Bookmark bounces when added. Direction A said "no bounces"; the bounce confirms an action made without looking, during a call.
- The idle Record button has a red dot, so the one red control is findable before it's needed.
- Next-step owners are chips in their speaker ink, tying a task to the person in the transcript.

## Behaviour worth knowing

- The page's time margin is drawn by `MarginGutterView`, a subview of the notes text view. `NSTextView` clips drawing done in its own `draw(_:)`.
- Note times come from `Meeting.paragraphTimes()`, which matches the saved anchors to paragraphs by text. A paragraph without a matching anchor shows no time; it never hides everyone else's.
- Times in the interface use `TimeLabel.short` (`0:14`). Model evidence and exports keep `TimeLabel.format` (`00:14`), so summaries aren't affected by display changes.
- Playback is disabled while recording, so computer-audio capture doesn't record it.
- A conversation whose kind isn't known yet appears only in All Conversations, never in Work or Personal. The person's placement (`Meeting.placement`) always wins and never changes the template.
- Choosing a different template summarizes again right away. The earlier summary stays in Version History.
- Version History can put back the text from before a change (notes, a corrected passage, a speaker's name, or a summary). The restore is itself a change, so the text it replaces stays in Version History.

## Checking the interface without recording or clicking

Debug builds accept launch arguments that open a specific surface against a separate library with its own preferences:

```
.build/debug/Daybook --library <dir> [options]
  --place work|personal|all|device|device:<name>|folder:<name>
  --select "<conversation title>"     --page transcript     --inspector
  --search "<query>"                  --sheet history|timing|corrections
  --open-settings general|models|devices|library
  --open-window vocabulary|templates|welcome
  --show-notes   --show-setup (Add Device)
  --device-demo <scenario>            device surfaces with an inert transport; see devices.md
  --simulate-recording "<title>"      fakes the recording state; no microphone
  --notes-after-stop   --notes-hover  Floating Notes as after Stop; with its hover-only chrome showing
  --notes-demo multipoint|paused|processing|stopped|failed|home
                                      Floating Notes states; see FloatingNotesDemo.swift
  --notes-size <W>x<H>                Floating Notes' size, such as 340x228 (compact)
  --notes-contrast                    Floating Notes as Increase Contrast draws it (simulated: the shared tokens and SwiftUI's contrast)
  --play-muted                        plays the selected conversation silently
  --model-demo <step,…>               Settings › Models states without the network; see models.md
  --snapshot <dir> [--snapshot-delay <seconds>]
```

`--snapshot` renders every visible window to PNG from inside the app, then exits. It works while the screen is locked, when `screencapture` can't. Put flags that take no value last: AppKit reads the arguments as `-key value` pairs, so one in the middle turns the next value into a file to open, and no window appears.
