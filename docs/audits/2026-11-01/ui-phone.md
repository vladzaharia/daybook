# UI: iPhone

Audit of 2026-11-01 against main at 57ed5eb. 23 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| ui-iphone-01 | high | Bookmark and Stop truncate to "B…" / "S…" at accessibility text sizes | `Apps/iOS/DaybookPhone/Recording/UI/RecordingSurface.swift:67` | w2-recorder-surface | — |
| ui-iphone-02 | high | Status-line glyphs overlap their labels, and the lines truncate, at accessibility sizes | `Apps/iOS/DaybookPhone/Status/StatusSheet.swift:459` | w2-status-sheet | fixed |
| ui-iphone-03 | medium | FlowLayout clips items wider than the row: byline date and Add Tag run off the page | `Apps/iOS/DaybookPhone/Reading/Components/PageComponents.swift:273` | w1-design-system | partial |
| ui-iphone-04 | medium | Recording notes' time lane has no cap, so notes get half the width at large sizes | `Apps/iOS/DaybookPhone/UI/TimedNotesView.swift:13` | w2-recorder-surface | — |
| ui-iphone-05 | medium | Library row previews and search snippets are 3.96:1 on paper (system .secondary) | `Apps/iOS/DaybookPhone/Reading/Library/ConversationRow.swift:40` | w2-library-list | fixed |
| ui-iphone-06 | medium | A done next step's owner is faded to 2.7:1 | `Apps/iOS/DaybookPhone/Reading/Conversation/SummaryPage.swift:339` | w2-summary-page | fixed |
| ui-iphone-07 | medium | Text on teal, speaker and amber washes falls below 4.5:1 (tags, owner chips, bookmark count, action tiles) | `Apps/iOS/DaybookPhone/Reading/Components/PageComponents.swift:251` | w1-design-system | partial |
| ui-iphone-10 | medium | On the Duo spread, a failed transcription is explained twice, in different words | `Apps/iOS/DaybookPhone/Reading/Conversation/TranscriptPage.swift:455` | w2-transcript-page | fixed |
| ui-iphone-08 | low | An unlabeled bookmark's placeholder drops a line below its time | `Apps/iOS/DaybookPhone/Reading/Conversation/YourNotes.swift:84` | w2-summary-page | fixed |
| ui-iphone-09 | low | Toolbar and thumb-row glyphs mix teal and ink: back chevron, Info/More, Import vs Search | `Apps/iOS/DaybookPhone/UI/RootView.swift:51` | w2-conversation-chrome | fixed |
| ui-iphone-11 | low | Mac detail shows a clock offset ("12 ms ahead (±4 ms)") | `Apps/iOS/DaybookPhone/Link/UI/MacsSettings.swift:93` | w2-link-pairing | fixed |
| ui-iphone-12 | low | Group headings: all caps in the status sheet and pairing, title case in Settings; names get uppercased | `Apps/iOS/DaybookPhone/Status/StatusSheet.swift:550` | w2-status-sheet | fixed |
| ui-iphone-13 | low | Info: People separators start under the duration; Created and Edited break the Details text edge | `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift:241` | w2-inspector-people | fixed |
| ui-iphone-15 | low | Macs card: queue rows keep an empty glyph column when no Mac row sits above them | `Apps/iOS/DaybookPhone/Status/StatusSheet.swift:1034` | w2-status-sheet | fixed |
| ui-iphone-16 | low | Models: each model is named twice, and Download appears in two styles | `Apps/iOS/DaybookPhone/Settings/ModelsSettings.swift:71` | w2-models-processing | fixed |
| ui-iphone-17 | low | A refused cloud key doesn't use the shared ProblemLine (no glyph, orange sentence, "Details") | `Apps/iOS/DaybookPhone/Settings/CloudSettings.swift:199` | w2-settings-sync-cloud | fixed |
| ui-iphone-18 | low | Duo: the selected-row wash runs to 6 pt from the crease, outside the page's margins | `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift:157` | w2-library-list | fixed |
| ui-iphone-19 | low | Selection bar labels don't share a baseline | `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift:431` | w2-library-list | fixed |
| ui-iphone-20 | low | Device page action tiles sit as cards inside a white list cell | `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift:109` | w2-devices-screens | fixed |
| ui-iphone-21 | low | SF Symbol choices diverge: ellipsis.circle, gear, two kinds sharing recordingtape, laptop for Reprocess | `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift:161` | w2-devices-screens | fixed |
| ui-iphone-22 | low | Byline length and player length disagree ("42 sec" vs "0:41") | `Sources/DaybookDevices/Framework/DeviceFormatting.swift:197` | w2-devices-core | fixed |
| ui-iphone-24 | low | Info tag chips: the remove glyph overlaps the tag at accessibility sizes | `Apps/iOS/DaybookPhone/Reading/Sheets/ConversationInfo.swift:404` | w2-inspector-people | fixed |
| ui-iphone-25 | low | Add Term placeholder truncates on the Duo's right page | `Apps/iOS/DaybookPhone/Settings/LibrarySettings.swift:282` | w2-settings-library | fixed |

## Notes on partial fixes

- **ui-iphone-03:** The shared FlowLayout now offers an item wider than its row the row's width, so it wraps or truncates there, and passes nil width when the proposal is infinite. The iPhone's copy is deleted. A unit test covers this, and the AX5 screenshot now wraps the byline date to "Sun, November 1 / at 8:49 AM" instead of cutting it off. Not done: removing .fixedSize() from the Add Tag field in ConversationInfo.swift. That file isn't mine, and a fixed-size view ignores any proposal, so that one-line change is wave 2.
- **ui-iphone-07:** Tokens added with contrast tests in every appearance: Ink.onWash (#006B5E light), owner-chip text inks (the Tailwind 800s, through ownerInk), Ink.bookmarkCount (#8A5200), and Ink.onAttention for warning chips. The shared BookmarkControlLabel count, StatusChip's attention text, the Mac TagChip, DaybookChip, and .daybookTinted now use them. Not done: the iPhone call sites, namely TagChip and OwnerChip (PageComponents.swift, where only FlowLayout removal was mine), BookmarkControl (RecordingComponents.swift), ActionTile (StatusSheet.swift), and TagEditor (ConversationInfo.swift). Those are wave 2.
