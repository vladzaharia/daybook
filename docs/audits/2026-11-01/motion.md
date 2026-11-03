# Motion and delight

Audit of 2026-11-01 against main at 57ed5eb. 15 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| motion-01 | medium | Reduce Motion keeps the slides: .motion() swaps the curve but not the transition | `Sources/Daybook/UI/DaybookStyle.swift:253` | w1-design-system | partial |
| motion-02 | medium | Progress still animates on every report on the iPhone and in Floating Notes, the cost the Mac window removed | `Apps/iOS/DaybookPhone/Reading/Conversation/SummaryPage.swift:98` | w1-design-system | partial |
| motion-03 | low | Stop's success haptic plays at the tap, before anything is saved, and even when saving fails | `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift:267` | w2-recorder-surface | — |
| motion-04 | low | Bookmark, next-step, and photo feedback fires for changes the person didn't make, and for removals | `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift:187` | w2-recorder-surface | — |
| motion-05 | low | Number rolls that never play: the iPhone clock, bookmark counts, and every countdown | `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift:23` | w2-recorder-surface | — |
| motion-06 | low | Three copies of the motion tokens, 83 hard-coded curves, and two Reduce Motion fallbacks | `Sources/DaybookDesign/Palette.swift:145` | w1-design-system | fixed |
| motion-07 | low | Reduce Motion gaps: ungated bounces, scroll animations, and a toolbar clock that rolls | `Sources/Daybook/UI/MeetingDetailView.swift:102` | w1-design-system | partial |
| motion-08 | low | A list row's done checkmark appears with no animation; only its exit animates | `Sources/Daybook/UI/ConversationList.swift:275` | w2-library-list | fixed |
| motion-09 | low | Table mode snaps to black under Reduce Motion, and waking takes as long as dimming | `Apps/iOS/DaybookPhone/Recording/UI/RecordingSurface.swift:214` | w2-recorder-surface | — |
| motion-11 | low | Stopped and saved: one short "Saved" beat with a checkmark on both apps | `Apps/iOS/DaybookPhone/Recording/UI/RecordStartButton.swift:37` | w2-recorder-surface | — |
| motion-13 | low | A summary arriving on the iPhone reveals block by block, as on the Mac | `Apps/iOS/DaybookPhone/Reading/Conversation/SummaryPage.swift:240` | w2-summary-page | fixed |
| motion-17 | low | Pairing succeeds: the iPhone glyph becomes Mac and iPhone together, with a checkmark and a success haptic on the iPhone | `Sources/Daybook/Devices/UI/PhonePairingView.swift:30` | w2-link-pairing | fixed |
| motion-19 | low | Work finishes: one shared draw-on checkmark, and the iPhone list row gets it too | `Apps/iOS/DaybookPhone/Reading/Library/ConversationRow.swift:66` | w2-library-list | fixed |
| motion-22 | low | A model download finishes: the bar turns into a checkmark for a moment | `Sources/Daybook/UI/ModelManagerViews.swift:268` | w2-models-processing | fixed |
| motion-25 | low | Skip back and forward 15 s turn their arrows, and the Mac's playback bookmark bounces like the iPhone's | `Sources/Daybook/UI/MeetingDetailView.swift:288` | w2-conversation-chrome | fixed |

## Notes on partial fixes

- **motion-01:** Added daybookTransition(_:), which becomes .opacity under Reduce Motion, and DaybookMotion.resolved(_:reduceMotion:) for withAnimation. The .motion facades on both apps now share one implementation that uses DaybookMotion.reduced. Not done: adopting these at the listed sites (TranscriptPage, SummaryPage, MeetingDetailView, LibraryPage, PlayerViews, and others), which is wave 2.
- **motion-02:** Fixed for the bars I own: WorkProgressLine, the iPhone's GradientProgressBar (deleted), and WorkProgress, which never animates even inside an animated transaction. The fill step under the iPhone page's animation is covered by that. Not done: phrase-keyed page and row status animation, and the iPhone's StatusProgressLine. Those are wave 2, as the planner said.
- **motion-07:** Added daybookBounce(value:), which stays still under Reduce Motion, and DaybookMotion.scrollAnimation(reduceMotion:), which returns nil under it. The shared BookmarkControlLabel uses daybookBounce, and ElapsedClock uses DaybookMotion.tick. Not done: the ungated sites in app files (MeetingDetailView, ConversationPage, iPhone SummaryPage, PlayerViews, RecordingComponents, RecordingSurface, TranscriptPage, LibraryView ElapsedTime), which are wave 2.
