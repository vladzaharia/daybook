# UI: Mac

Audit of 2026-11-01 against main at 57ed5eb. 17 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| ui-design-mac-01 | medium | With the inspector open below about 1140 pt, the page shrinks to about 150 pt: the title breaks mid-word and the play pill shows "▶ 2" | `Sources/Daybook/UI/LibraryView.swift:159` | w2-conversation-chrome | fixed |
| ui-design-mac-02 | medium | Toolbar groups vanish on device pages, so Record moves about 300 pt and the view switch and inspector toggle disappear | `Sources/Daybook/UI/MeetingDetailView.swift:90` | w2-conversation-chrome | fixed |
| ui-design-mac-07 | medium | Deleting a speaker profile is immediate, while Merge asks first | `Sources/Daybook/UI/SpeakerProfilesView.swift:86` | w2-inspector-people | fixed |
| ui-design-mac-03 | low | The toolbar Stop pill loses its red when the window isn't key, which is the normal state during a call | `Sources/Daybook/UI/LibraryView.swift:234` | w2-conversation-chrome | fixed |
| ui-design-mac-04 | low | A done next step's owner name is drawn at 50% opacity, about 2.1:1 on light paper and 4.1:1 on dark | `Sources/Daybook/UI/SummaryPage.swift:153` | w2-summary-page | fixed |
| ui-design-mac-05 | low | In the inspector, labels are 13 pt but values, speaker names and the Tags label are 11 pt, so labels outrank values | `Sources/Daybook/UI/MeetingInspector.swift:32` | w2-inspector-people | fixed |
| ui-design-mac-06 | low | The Vocabulary table's columns are wider than the window's minimum, so Used In is clipped | `Sources/Daybook/UI/GlossaryView.swift:77` | w2-settings-library | fixed |
| ui-design-mac-08 | low | Models › Quality rows truncate the model list exactly where the presets differ | `Sources/Daybook/UI/ModelManagerViews.swift:143` | w2-models-processing | fixed |
| ui-design-mac-10 | low | Floating Notes reads "SAVED · 18:00", which looks like 6 PM; the page says "18 min" | `Sources/Daybook/UI/FloatingNotes/FloatingStatus.swift:220` | w2-recorder-surface | — |
| ui-design-mac-11 | low | "Record" looks different on each surface; the empty library and Welcome lose the red dot | `Sources/Daybook/UI/LibraryView.swift:254` | w2-conversation-chrome | fixed |
| ui-design-mac-12 | low | Bookmark glyphs in Your notes float with the time's width instead of sitting in one column | `Sources/Daybook/UI/SummaryPage.swift:271` | w2-summary-page | fixed |
| ui-design-mac-13 | low | Tag chips are lopsided because the hidden remove button still takes its space | `Sources/Daybook/UI/DaybookStyle.swift:597` | w2-inspector-people | fixed |
| ui-design-mac-14 | low | The Version History sheet has no visible title, and its bullets don't match the page's | `Sources/Daybook/UI/ConversationSheets.swift:118` | w2-transcript-page | fixed |
| ui-design-mac-15 | low | Add Device steps use three different header layouts, and the main action sits top-right | `Sources/Daybook/Devices/UI/AddDeviceSheet.swift:310` | w2-devices-screens | fixed |
| ui-design-mac-16 | low | Soundcore Work and Other Recorder share the same glyph everywhere | `Sources/DaybookDevices/OtherRecorder/OtherRecorder.swift:17` | w2-devices-core | fixed |
| ui-design-mac-17 | low | "This Mac" switches between a laptop and a desktop glyph, and the colophon shows a laptop for an iPhone summary | `Sources/Daybook/UI/ConversationPage.swift:558` | w2-summary-page | fixed |
| ui-design-mac-20 | low | The inspector repeats the page's waiting line, with a trailing period the page doesn't use | `Sources/Daybook/UI/SourceHooks.swift:73` | w2-inspector-people | fixed |
