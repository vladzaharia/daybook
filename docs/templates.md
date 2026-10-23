# Editable summary templates

Daybook includes twelve original formats: meeting notes, 1:1, daily standup, therapy reflection, personal conversation, interview, lecture, planning, retrospective, customer discovery, design review, and decision memo. They specify what to retain and how to organize it. They do not add facts to the recording.

The template editor supports changing a built-in format, duplicating one, creating a custom format, removing a custom format, and resetting a built-in to its original instructions. Edits save when the user chooses Save, switches templates, or closes the editor. Each conversation can select a template ID; refreshing the summary applies that format while retaining the original notes, transcript runs, and summary history through the application's existing processing flow.

`SummaryTemplate` contains a stable string ID, name, base `MeetingKind`, instructions, and update date. `SummaryTemplate.catalog(templates:)` merges saved templates with defaults and keeps the newest version of duplicate IDs. `resolved(id:kind:templates:)` uses an explicit selection first, then the default for the detected conversation type. A removed or unavailable custom ID falls back to that conversation type. Removing a built-in override restores the bundled original. `duplicated()` assigns a new custom identity.

The app stores edited templates in its library settings. This module makes no network requests. Root application settings/synchronization own persistence; the editor uses `AppState.templates`, `saveTemplate(_:)`, and `removeTemplate(_:)`.

Useful templates describe the purpose and context, requested detail and tone, and the sections to produce. This structure follows the public guidance in [Granola's template documentation](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates); Daybook's included prompt wording is original. Test a format on an existing conversation and refine its instructions based on the resulting notes.

Therapy reflection is a record of the conversation, using the participant's own account and explicitly discussed practices. Its prompt avoids inventing diagnoses, treatment plans, or explanations of motives. Every format asks the model to preserve uncertainty, supported attribution, and concrete commitments. User notes and marked moments should receive additional relevant context. Model output still requires review, and a template cannot reconstruct missing audio or resolve unknown speakers.

Tests cover stable defaults, unique IDs, editing and duplicate resolution, explicit selection, missing-ID fallback, independent copies, and Unicode/multiline persistence.
