# Consistency: reading

Audit of 2026-11-01 against main at 57ed5eb. 23 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| xdc-read-10 | high | The Mac has no Trash: conversations trashed on the Mac can be restored only on an iPhone | `Sources/Daybook/UI/SidebarView.swift:15` | w2-library-list | fixed |
| xdc-read-01 | medium | There's no shared screens module, and the iPhone doesn't link DaybookDesign | `Package.swift:54` | w1-design-system | partial |
| xdc-read-02 | medium | Three copies of the design tokens, and the iPhone's copy isn't tested; speaker inks, type, geometry, glow, and progress diverge | `Apps/iOS/Shared/PhoneStyle.swift:10` | w1-design-system | fixed |
| xdc-read-03 | medium | Processing status is presented twice: the same state reads, looks, and acts differently on each device | `Sources/Daybook/UI/ConversationList.swift:184` | w1-shared-words | fixed |
| xdc-read-07 | medium | The conversation list row is two implementations that differ in content, glyphs, and density | `Sources/Daybook/UI/ConversationList.swift:227` | w2-library-list | fixed |
| xdc-read-08 | medium | Search results differ, and Mac summary snippets show raw Markdown | `Sources/Daybook/UI/ConversationList.swift:346` | w2-library-list | fixed |
| xdc-read-11 | medium | Page header: Mac title edits save per keystroke and accept an empty title; the byline and play pill differ | `Sources/Daybook/UI/ConversationPage.swift:125` | w2-summary-page | fixed |
| xdc-read-12 | medium | Summary body: the Mac lede ignores Markdown, and evidence links and the arrival reveal exist on one side only | `Sources/Daybook/UI/SummaryPage.swift:99` | w2-summary-page | fixed |
| xdc-read-13 | medium | Your notes and bookmarks: Mac labels save per keystroke; expand and Show in Transcript differ; iPhone empty labels sit a line low | `Sources/Daybook/UI/SummaryPage.swift:261` | w2-summary-page | fixed |
| xdc-read-14 | medium | Transcript page: times, taps, corrections, notes, notices, and recording names all differ | `Sources/Daybook/UI/TranscriptPage.swift:95` | w2-transcript-page | fixed |
| xdc-read-18 | medium | People: the Mac hides background-only speakers, the iPhone lists them, and the row and identity line are implemented twice | `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift:138` | w2-inspector-people | fixed |
| xdc-read-20 | medium | Conversation actions are hand-written per surface, and the More menus disagree in items, order, and words | `Sources/Daybook/UI/MeetingDetailView.swift:135` | w1-shared-words | fixed |
| xdc-read-21 | medium | Review Corrections, Adjust Timing, Original Transcript, and Add Recording from a file exist only on the Mac | `Sources/Daybook/UI/ConversationSheets.swift:227` | w2-transcript-page | fixed |
| xdc-read-04 | low | The summary Markdown parser is duplicated; evidence index, snippet cleanup, and find highlight are one-sided or differ | `Apps/iOS/DaybookPhone/Reading/Model/TranscriptModel.swift:107` | w1-shared-words | fixed |
| xdc-read-05 | low | The demo libraries and launch flags differ, so Mac and iPhone snapshots can't be compared | `Sources/Daybook/App/LibraryDemo.swift:26` | w1-shared-words | fixed |
| xdc-read-06 | low | Two page-geometry systems: the Mac's hanging margin and the iPhone's lane lay out differently at the same width | `Sources/Daybook/UI/ConversationPage.swift:50` | w1-design-system | partial |
| xdc-read-09 | low | Library list chrome differs: empty places, batch actions, row menus, and the trash confirmation | `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift:204` | w2-library-list | fixed |
| xdc-read-15 | low | Colophon: the model name, ink, and Summarize placement differ, and the device glyph is wrong for another device's kind | `Sources/Daybook/UI/ConversationPage.swift:558` | w2-summary-page | fixed |
| xdc-read-16 | low | Photos: strip, tiles, viewer, and actions are implemented twice with different actions and delete rules | `Sources/Daybook/UI/PhotoViews.swift:144` | w2-transcript-page | fixed |
| xdc-read-17 | low | The Mac inspector and the iPhone's Info are two forms with different rows, words, and actions | `Sources/Daybook/UI/MeetingInspector.swift:8` | w2-inspector-people | fixed |
| xdc-read-19 | low | Speaker Profiles is the same logic twice: conversations open only on the Mac, and the merge wording differs | `Sources/Daybook/UI/SpeakerProfilesView.swift:116` | w2-inspector-people | fixed |
| xdc-read-23 | low | Saved live captions show on the Summary page on the Mac and in the transcript's place on the iPhone | `Sources/Daybook/Captions/LiveCaptionViews.swift:102` | w2-engines-captions | partial |
| xdc-read-24 | low | The iPhone's own TimeLabel prints '−0:00' where the Mac and VoiceOver say '0:00' | `Apps/iOS/Shared/PhoneStyle.swift:183` | w1-design-system | fixed |

## Notes on partial fixes

- **xdc-read-01:** Built as DaybookUI (the planner's name for DaybookScreens), wired into Package.swift, both projects, the Daybook executable, DaybookTests, and DaybookUITests. ReadingContext and the readingWidth and creaseEdge environment values are in place. Not done: moving glassSurface, topBar, and bottomBar into DaybookDesign, which the planner didn't list, and the screens themselves, which are wave 2.
- **xdc-read-06:** One ReadingPage/MarginRow geometry. At 600 pt and wider, a 56 pt margin hangs left of a measure of min(640, width minus gutters). Narrower, the iPhone's lane is used (50 pt, scaled up to 1.9x). creaseEdge adds clearance. Tested at 402, 466, 475.5, 391.5, 580, 620, 867, and 1000 pt. Not done: the byline and next-step ViewThatFits fallbacks, which belong to the page files in wave 2.
- **xdc-read-23:** SavedCaptions (mayStandIn, shown, recording(of:), playback, playing, hits) and SavedCaptionsView now live in DaybookUI/Captions. The view has playable time buttons, a mint playhead rule, the name before the words, and the header and row scroll IDs. Plain-value helpers (LiveCaptions.segment(at:), firstMatch, hasWords) are in DaybookCaptions. When captions have no trackID, the recording is matched by start time, so Mac captions play too. On the iPhone, CaptionRows and SavedCaptions are typealiases to the shared types, with screenshots before and after. The Mac's Summary-page section now shows captions only while that conversation is recording, as the plan says. Integrator glue still needed (w2-transcript-page and w2-conversation-chrome files): Mac saved captions currently appear nowhere until it lands. The Mac transcript page, when SavedCaptions.shown(...) is non-nil, should render SavedCaptionsView(meeting:captions:playing:play:) with readingWidth set from pageIsNarrow, reloading on captions.lastSave and transcripts; the Transcript switch should be enabled in that case; Mac search should add SavedCaptions.hits.
