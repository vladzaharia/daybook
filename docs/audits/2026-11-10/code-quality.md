# Code quality and a unified codebase

Reviewer lane: code quality, duplication between the Mac and iPhone apps, module boundaries, dead code, consistency of patterns, tests, build hygiene. Checked against the working tree at `1f6f1ba0` (branch `design-pass-2026-11`). Every claim below was checked with grep, `diff`, a clean `swift build` into a scratch path, a strict-concurrency build of `DaybookUI` and what it depends on, and `swift test --filter "MotionAuditTests|SharedNameTests"`. My scripts and logs are in `.../scratchpad/cq/` (`dead-types.txt`, `dead-funcs.txt`, `clean-build.log`, `strict-ui.log`, `test-audits.log`).

## 1. Summary

The move to one codebase is much further along than the brief assumed. Most of the pairs it names are already thin adapters over DaybookUI: the Mac's `MarginNotesEditor`, `TemplatesView`, `GlossaryView`, and `SpeakerProfilesView` are 5 to 34 lines each, and both apps' summary page, transcript page, photos, player, Welcome, recorder, and device pages are built from DaybookUI blocks. Exact copy-paste between the apps is almost gone: a 5-line clone scan finds only three file pairs (App Shortcut phrases, the Cloud settings wrapper, and `WordDiff`). The package builds with **one** first-party warning (`CallPrompt.swift:60`), `@Observable` is used everywhere (no `ObservableObject`, `@Published`, or `@StateObject` remain), and no Combine is left outside two DaybookKit files.

What's left is not copied code but **parallel implementations, and leftovers of moves that were never finished**:
- Dormant copies are kept alive only by tests that pin them. The iPhone's whole `StatusPresentation`/`RowStatus` status model is one; the Mac's `WordDiff` is another.
- Each app has two action dispatchers for the same `ConversationAction`, and they have drifted: Work/Personal from the More menu can't be undone on either app.
- A finished audit fix was never wired in: Edit › Find in Conversation is built but not in the menu bar.
- Three vocabularies name the same design tokens: DaybookStyle on the Mac, PhoneStyle on the iPhone, and DaybookDesign's own names in DaybookUI.
- The ratchets that would stop drift are soft. `MotionAuditTests` skips with 12 hits instead of failing. `SharedNameTests.movingOver` still lists 7 names whose moves are done. No CI step fails on a new warning, and only Core and Kit build with strict concurrency.

The biggest opportunities, in value per hour:
1. Delete the dormant code and move its tests onto the shipped types.
2. Merge the action dispatchers.
3. Turn the soft checks into failing ones.
4. Collapse the token aliases.
5. Lift the last few parallel features into DaybookUI or DaybookKit: Version History, Spotlight indexing, the level meter, the calendar row, the device glyph, and the problem words.

`AppState` is 4,810 lines across 15 `AppState*.swift` files (7,631 lines across every file that extends it), with about 150 stored or forwarding properties. It has natural seams and should be split last, once the code that reads it has shrunk.

## 2. Redesign proposals: refactor packages, ranked by value per hour

Each package keeps both apps building at every step. Prove each one with `swift build`, `swift test` (the suite named in the package), and `scripts/build-ios.sh --test` for anything that touches `Apps/iOS`.

### P1. Finish the moves already started: delete dormant code, re-point its tests (S to M, about 3 h)

**What and why.** The direction in docs/architecture.md, "Layers", says each app keeps only what must differ. Code that production no longer reaches, but tests still exercise, gives false confidence: a regression in the shipped words passes, because the tests read a copy. Rule of thumb: one implementation per behaviour, and its tests sit next to it.

**Files, in order.**

1. **iPhone status copy.** `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift:19-221`: `StatusPresentation` with `page`, `placement`, `upgrade`, `placementRow`, `row`, `waitingTitle`, `workingTitle`, plus `RowStatus` at :207, `MacSighting.line` and `ago` at :247-262, and `FriendlyError` at :265.
   - Also `ConversationRow` and `ConversationRow.shared` at `Reading/Library/ConversationRow.swift:78-99`, and `SearchSnippet` at :14.
   - Before deleting, port the assertions that test behaviour to `Tests/DaybookKitTests/ConversationStatusPresentationTests.swift` against `ConversationStatusPresentation.page`/`.row` with `DeviceWords.iPhone(id:)`. They live in `ReadingTests.swift` (24 references), `PhoneSummaryPlacementTests.swift:148-470`, `AwaitingRecordingStatusTests.swift:27-40`, `PhoneUpgradeTests.swift:131-148`, and `LibraryListPhoneTests.swift`.
   - The copy has already drifted from what ships. It has no `.requested(.models)` box and no Cancel on your own request (compare with `Sources/DaybookKit/ConversationStatusPresentation.swift:367-420`).
2. **Mac leftovers.**
   - `FriendlyError.message` (`Sources/Daybook/UI/ConversationPage.swift:382`) is unused. Its `isNoSpeech` caller (`FloatingNotesView.swift:361`) should read `ProcessingRequest.FailureKind.noSpeech`, as the iPhone's `StatusSheetModel.swift:481` half-does already: it checks both.
   - `WordDiff` (`ConversationSheets.swift:138`) is used only by `Tests/DaybookTests/WordDiffTests.swift`. Point that test at `WordChanges`/`RevisionMarks`.
   - Also unused: `MarginTime` (`ConversationPage.swift:72`), `GlassGroup`/`glassSurface`/`glassButtonStyle`/`topBar` (`DaybookStyle.swift:111-197`), the `*NS` inks, `narrowWidth`, `brandGradient` (`DaybookStyle.swift:39,57-61`), `DeviceBox` (`DeviceComponents.swift:99`), `deviceNotice` (:138), `PlacementInspectorRow` (`SummaryPlacementViews.swift:49`), `AudioSource.systemImage` (`StyleExtensions.swift:10`, the same map as `RecordingWords.symbol`, DaybookKit `RecordingWords.swift:110`), `takeOverRecorder`/`cancelRecorderHandoff` (`AppState+Devices.swift:214-217`), `pipelineOrder` (`ModelManager.swift:17`), `processingQueueState` (`ProcessingQueue.swift:390`), and `currentURL` (`AudioPlayback.swift:19`).
3. **iPhone dead views.**
   - `LiveCaptionsView.swift` (the whole file: `LiveCaptionsView`, `HorizontalCreaseSplit`).
   - `PageComponents.swift:46,69` (`TimeButton`, `PageHeading`), `PlayerViews.swift:92` (`PlayPill`), `StatusSheet.swift:831` (`NamePhrase`).
   - `ReadingSupport.swift:10-60` (`WordDiff`, which hand-rolls the marks `RevisionMarks` already gives, and `SourceDescription`).
   - `PhoneDevices.swift:263` (`endHandoff`), and `PhoneStyle.UIInk` (`Shared/PhoneStyle.swift:64`, used by tests only).
4. **Shared libraries.** `ModelQualityRow` (`DaybookUI/Settings/Models/ModelRows.swift:344`), `SettingsMetrics.tileLimit` (`SettingsRows.swift:12`), `laneMarks` (`MarginNotesEditor+UIKit.swift:431`), the `ReadingPlayer` requirements `playingMeetingID`/`playbackPosition` that nothing reads (`ReadingSeams.swift:51-53`), and `DaybookPalette.ownerInk` (`Palette.swift:195`).
5. **The last Mac `MarginRow`.** Swap the Mac's `MarginRow` (`ConversationPage.swift:37`) for DaybookUI's (`ReadingPage.swift:132`). All four Mac uses have an empty margin (`ConversationPage.swift:165,222`, `SummaryPage.swift:45`, `LiveCaptionViews.swift:31`), so the two lay out identically: edge to edge when narrow, 56 pt indent when regular. Then empty `SharedNameTests.movingOver` (`Tests/DaybookUITests/SharedNameTests.swift:17-22`). `ProblemLine`, `DetailsButton`, `SettingsFooter`, `StatusCard`, `StatusCardMetrics`, `StatusDivider`, and `StatusRow` are already gone from the apps. Delete the allowlist and its "Remove a name here" comment.

**Keeping both apps building.** Delete one file or type per commit. Port the tests before deleting. Steps 1 to 4 change no behaviour. Step 5 changes no pixels; confirm with `--snapshot` `page-760` and `page-1000`.

**Proof.** `swift test --filter "DaybookKitTests|DaybookUITests|DaybookTests"` and `scripts/build-ios.sh --test`. Rerunning `scratchpad/cq/scripts/deadtypes.py` lists only protocol requirements and test doubles. `SharedNameTests` passes with no allowlist.

**Risks.** Very low. The only behaviour touched is the no-speech check, which becomes the typed kind instead of a substring match.

### P2. One action dispatcher per app, with the library's half shared (M)

**What and why.** `ConversationActions` (DaybookKit) and `ConversationActionMenuItems` (DaybookUI) are shared. Carrying out an action is written four times: Mac row and batch actions (`MacActions`, `Sources/Daybook/UI/ConversationList.swift:442-517`), Mac More menu (`MoreMenuActions`, `MeetingDetailView.swift:232-295`), iPhone row (`PhoneActions`, `LibraryPage.swift:619-…`), and iPhone More (`ConversationMoreActions`, `ConversationScreen.swift:109-…`). The copies have drifted in ways a person sees:
- **Work/Personal from the More menu isn't undoable on either app.** It is undoable everywhere else: `MeetingDetailView.swift:263` and `ConversationScreen.swift:133` pass no undo manager, while `ConversationList.swift:469`, `LibraryPage.swift:656`, `DaybookCommands.swift:251`, and `SidebarView.swift:117` do.
- **Copy Summary** confirms "Copied" from the iPhone's More menu (`ConversationScreen.swift:121`) but not from a row (`LibraryPage.swift:641`).
- **Move to Folder on the Mac** builds its folder menu inline in `MacActions.custom` (`ConversationList.swift:484-494`), while More uses `FolderMenuItems` (`DaybookCommands.swift:358`).
- **The same `context` function** is written twice in the Mac app (`ConversationList.swift:444`, `MeetingDetailView.swift:234`).
- **Two undo paths for placement:** `AppState.setPlacement` (`AppState+Actions.swift:22`, with its own `placementActionName`) duplicates `LibraryController.setPlacement(_:_:undoManager:)` (`LibraryController+Filing.swift:26`, `filingActionName`).

**Sketch.**
- In DaybookUI, a `ConversationActionPerformer` carries out the library-level cases once over a `LibraryController` and an `UndoManager`: `.process`, `.moveTo`, `.moveToTrash` request, `.tags`, `.versionHistory`, `.moveToFolder`, and `.copySummary` with its confirmation.
- Each app supplies a closure for its platform cases: share, export, Show in Finder, camera, Floating Notes, rename.
- Each app has one entry point, `MacActions.perform(id, on: ids, …)` and `PhoneActions.perform(id, on: ids, …)`, and the More menu calls it with `[meeting.id]`.
- Delete `MoreMenuActions` and `ConversationMoreActions`, and delete `AppState.setPlacement` in favour of the library's.

**Order.** Each step builds on its own.
1. Add the performer and test it.
2. Point the Mac's More menu at `MacActions`.
3. Point the iPhone's More menu at `PhoneActions`.
4. Move the library cases into the performer.
5. Delete the duplicates.

**Proof.** A new `ConversationActionPerformerTests` (DaybookUITests) asserts that every `ConversationAction.ID` the performer owns registers an undo when given an `UndoManager`, and that `.moveTo` from a single conversation and from a batch both name the undo "Move to Personal". `ConversationActionsTests` keeps the availability rules.

**Risks.** Menu wiring on the Mac (the window's undo manager versus `NSApp.keyWindow`); keep `FolderMenuItems`' fallback.

### P3. Make the drift checks fail, not report (S to start, then small steps)

**What and why.** The repo already has the right tests. They just don't stop anything.

**Steps.**
1. **Motion.** `MotionAuditTests.swift:127-131` throws `XCTSkip` unless `DAYBOOK_ENFORCE_MOTION_TOKENS=1`, and no workflow sets it. 12 curves remain:
   - `PlayerBar.swift:470`, `MeetingDetailView.swift:35`, and `ConversationScreen.swift:34`. The last two are the same page-mode crossfade on both apps; add a `DaybookMotion.pageTurn` token.
   - `CallPrompt.swift:300`, `ConversationList.swift:647`, `AddDeviceSheet.swift:122` (×2), `DeviceRecordingPages.swift:24`, `DeviceSidebar.swift:75,76,183`, `DeviceDetailsView.swift:69`.
   
   Move them to tokens, then delete the env-var gate so the test fails.
2. **Warnings.** Fix `CallPrompt.swift:60` (an unused `call` binding). Add a CI step after `swift build --build-tests` in `.github/workflows/ci.yml:143` that fails when `build.log` has a `warning:` under `Sources/` or `Apps/iOS/`. Dependencies emit 76 warnings, so `-warnings-as-errors` can't be used globally.
3. **Strict concurrency, target by target.** Only DaybookCore and DaybookKit set `StrictConcurrency` (`Package.swift:58,72-74`). A `-strict-concurrency=complete` build of DaybookUI and its dependencies found:
   - **DaybookCaptions and DaybookDesign: 0.** Turn it on today.
   - **DaybookLink: 4**, in `LinkService.swift`.
   - **DaybookDevices: 16**, 7 of them in `DeviceConnection.swift` and 4 in `ObservationWatch.swift`.
   - **DaybookUI: 45**, of which 18 are in `MarginNotesEditor+AppKit.swift` and 17 in `RecorderSurface.swift`.
   
   Turn it on per target as each reaches zero. The Mac and iPhone apps still use `NSLock` plus `@unchecked Sendable` (8 `NSLock`s and 10 `@unchecked` on the Mac, 6 and 8 on the iPhone) where the libraries moved to `Mutex`.
4. **App-against-app names.** Extend `SharedNameTests` with a check that no name is declared in both `Sources/Daybook` and `Apps/iOS/DaybookPhone`, seeded with today's 28 names as an allowlist that may only shrink. The names are `AddBookmarkIntent`, `AddDeviceSheet`, `AudioLevelMeter`, `CaptionQuery`, `ConversationEntity`, `ConversationMoreMenu`, `ConversationQuery`, `DaybookShortcuts`, `DeviceGlyph`, `DevicePage`, `DevicePageContent`, `FriendlyError`, `HandoffDemo`, `KeyEditing`, `LiveCaptionsController`, `LocalPasteboard`, `LocalPasteboardWriting`, `NewNoteIntent`, `OpenConversationIntent`, `PageColophon`, `PageHeader`, `PhoneLink`, `ReprocessMenu`, `RowMenu`, `StartRecordingIntent`, `StopRecordingIntent`, `SummaryPage`, and `WordDiff`. A same-named pair is either a seam that should be named for its platform (`MacPageHeader`) or a duplicate to lift.

**Proof.** The tests themselves. CI goes red on the next raw curve, new warning, or new duplicate name.

**Risk.** Hosted-runner logs. Grep paths, not counts.

### P4. Small features still drawn twice: lift each into the library (M in total; each item S)

**What and why.** These are the parallel implementations left. Each is small, and each already shows drift.

- **Level meter.** `AudioLevelMeter` exists on the Mac (`Sources/Daybook/Capture/PCMTrackWriter.swift:6`) and the iPhone (`Apps/iOS/DaybookPhone/Recording/AudioLevelMeter.swift:17`). Both are `NSLock` with `@unchecked Sendable`, over DaybookCore's `AudioBufferLevel`, with different reading types. Move one to DaybookCore, next to `AudioBufferLevel`, held in a `Mutex`.
- **Version History.** Mac `VersionHistorySheet` (`ConversationSheets.swift:36-135`) and iPhone `VersionHistoryView`/`RevisionDetail` (`ReadingSheets.swift:12-155`) both draw `RevisionText` and `RevisionComparison` with the same restore alert ("Restore the previous version?", "What’s there now stays in Version History."). Add a DaybookUI `VersionHistoryScreen`, laid out as `TemplatesScreen` is: a split view on the Mac (`#if os(macOS)` content), a push list on the iPhone.
- **Use Calendar.** The rule is the same on both apps, but the refusal UI differs. The Mac shows `ProblemLine("Daybook can’t read your calendars.")` with Open System Settings… (`SettingsView.swift:229-242`); the iPhone shows a bare button, "Allow Calendars in Settings", with no problem line (`SettingsScreen.swift:351-361`). Add a DaybookUI `CalendarSettingsRow(isOn:access:set:openSettings:)`.
- **Device glyph.** The Mac draws a bare 28 pt symbol in teal or secondary (`Devices/UI/DeviceComponents.swift:61`, whose comment "as on the iPhone" is now false); the iPhone draws a `DaybookTile` (`DeviceScreens.swift:54`). Pick the tile and delete the Mac's.
- **Mac `StatusBox`.** `StatusBox`/`StatusBoxKind` (`ConversationPage.swift:301-375`) re-implement DaybookDesign's `AttentionBox` and are used once, through `DeviceAttentionBox` (`DeviceComponents.swift:111`) in `PhonePairingView.swift:98`. Use `AttentionBox`.
- **Spotlight indexing.** The Mac's `ConversationSpotlight` (`App/Intents/ConversationEntity.swift:139`) and the iPhone's `ConversationIndex` (`App/ConversationEntity.swift:106`) are two diffing indexers for the same rule (`isShown`: not Personal). The entities differ: the Mac's carries the gist and the iPhone's uses `@Property`.
  - Move the pure plan to DaybookKit: what to index, what to remove, and when to start over.
  - Keep each `AppEntity` in its app, since App Intents metadata is extracted per target.
  - Add a test that the two `DaybookShortcuts` phrase lists agree. They don't today: the Mac says "Start a \(.applicationName) note" (`DaybookIntents.swift:194`), the iPhone "Start a note in \(.applicationName)" (`DaybookShortcuts.swift:23`).
- **Problem words.** The Mac's `AppProblem.speaksPlainly` (`App/AppProblem.swift:41`) and the iPhone's `PlainError.message` (`ReadingStatus.swift:280`) both list which error types "speak plainly". Add a `PlainSentenceError` protocol in DaybookCore (`LibrarySyncError` and `AudioFetchError` already have `isPlainSentence`) and one `ProblemWords(title:fallback:error:)` in DaybookKit.
- **Countdown words.** The sentence "Summarizing in N s" is built in at least seven places:
  - `SummaryPlacementPlanner.swift:189,203`.
  - `ConversationStatusPresentation.swift:122,669,676,701`.
  - `QueueStatusWords.swift:47`.
  - `FloatingStatus.swift:130-131`.

  Make it one `ProcessingWords.summaryCountdown(secondsLeft:where:)`.

**Order.** One item per PR. Add the shared type, switch the Mac, switch the iPhone, delete the copy. Each step builds.

**Proof.** A unit test per lifted type in DaybookKitTests or DaybookUITests. The name check from P3 drops the matching entries.

**Risk.** Low. Spotlight changes need a run with a real index; keep `--library` scratch runs.

### P5. One token vocabulary (M; mechanical)

**What and why.** DaybookUI writes `DaybookPalette`, `DaybookSpacing`, `DaybookMotion`, and `DaybookFont` (444, 378, 89, and 76 uses). The Mac writes `DaybookStyle.` (47), `TypeStyle.` (31), `Space.` (158), `Motion.` (18), and `Ink.` (49), all aliases in `Sources/Daybook/UI/DaybookStyle.swift`. The iPhone writes `PhoneStyle.` (195 in the app, 65 in the widgets), aliases in `Apps/iOS/Shared/PhoneStyle.swift`. Moving a view between an app and DaybookUI therefore means renaming every token.

The aliases have already gone wrong once. `PhoneStyle.brandGradient` is `.progress` (left to right) while `DaybookStyle.brandGradient` is `.mark` (corner to corner). The iPhone's notebook placeholder draws its "mark" with the progress direction (`Reading/LibraryBrowser.swift:424`; the comment above says "shows only the mark"). Meanwhile the Mac's alias is unused.

The alias layer also costs a test, `DaybookDesignTokenTests` (`Tests/DaybookTests/FloatingNotesStatusTests.swift:402`), which exists to prove the Mac's names resolve to the shared values. Other aliases to remove: about 20 typealias shims kept so that a file needn't `import DaybookUI`, some of which rename the type (`CaptionRows = SavedCaptionsView`, `LevelHistory = LevelTrail`, `TimeLabel = DaybookKit.TimeLabel`). Inline `#if os(...)` single-modifier shims in DaybookUI (`.navigationBarTitleDisplayMode` 9, `.help` 8, `.textInputAutocapitalization` 6, `.controlSize` 5, `.submitLabel` 4) can become three or four cross-platform `View` helpers in DaybookDesign.

**Order.**
1. File by file, replace alias uses with the DaybookDesign names. Aliases and real names are the same types, so every intermediate state builds.
2. Delete `DaybookStyle`/`TypeStyle`/`Space`/`Motion` and `PhoneStyle`'s alias members.
3. Keep the few roles that really are per app, as DaybookDesign API: the iPhone's serif `Typeface.title(_:)`, used 7 times, mostly in widgets.
4. Update docs/interface.md:210, which names three spellings of `DaybookMotion`.

**Proof.** A source test in the spirit of `SharedNameTests` that fails on `DaybookStyle.`, `PhoneStyle.`, or a typealias to `DaybookUI.`/`DaybookDesign.` in an app folder. Delete `DaybookDesignTokenTests`.

**Risk.** Diff noise in open branches. Land it between feature merges.

### P6. Status overview on the Mac: one model, both apps (L)

**What and why.** docs/interface.md:122 says Floating Notes' home "moves onto `StatusOverview` at `.lines` later". Today the iPhone builds its status from `StatusInputs` and `StatusSheetModel` (`Apps/iOS/DaybookPhone/Status/StatusSheetModel.swift`, 680 lines, plus `StatusSheetInputs` inside `StatusSheet.swift:577-735`). The Mac builds its status from `FloatingStatusInputs` and `FloatingStatus` (`Sources/Daybook/UI/FloatingNotes/FloatingStatus.swift`, 198 lines, and `FloatingStatusFeed.swift`, 211 lines). `FloatingStatusInputs.Work` (FloatingStatus.swift:17-41) is a third per-conversation processing enum beside `ProcessingStatus` and `ConversationStatusPresentation`. Both apps already share the words: `RecorderStatusWords`, `QueueStatusWords`, `PeerStatusWords`, `ProcessingWords`.

**Sketch.** In DaybookKit, a `StatusOverviewInputs` (recorders, peers, this device's queue, sync problem, the recording) and `StatusOverviewModel.lines/sections` (today's `StatusSheetModel` statics). Each app keeps only its gatherer: the iPhone's `StatusSheetInputs.make`, and the Mac's `FloatingStatusInputs.make` renamed. Floating Notes' home and the menu bar extra draw `StatusOverview(density: .lines)`. `FloatingStatusInputs.Work` gives way to `ConversationStatusPresentation`.

**Order.**
1. Move `StatusSheetModel` to DaybookKit unchanged, with its tests (`StatusSheetModelTests.swift`, 1,157 lines, moves to DaybookKitTests, where it also runs under `swift test`).
2. Add the Mac gatherer.
3. Switch the home's lines.
4. Retire `FloatingStatus.homeLines`.

**Proof.** The moved `StatusSheetModelTests`. A parity test feeds `ReadingDemo`'s states to both gatherers and asserts the same line titles.

**Risks.** The Mac's compact panel (340×228) has less room. Keep `StatusDensity.lines` and test the compact layout with `--snapshot notes-recording-compact`.

### P7. Status inputs out of views, so the page's status can be tested on both apps (M)

**What and why.** The shared presentation is well tested. Its inputs, though, are assembled in private view methods: the Mac's `ConversationStatus.inputs(for:)` and `perform` (`ConversationPage.swift:247-293`) and the iPhone's `SummaryPage.inputs(for:now:)`, `local`, and `perform` (`Reading/Conversation/SummaryPage.swift:169-268`). Nothing tests that a Mac with a download running, or an iPhone with processing turned off, produces the right box. The `perform` switches also overlap with P2.

**Sketch.**
- Add `ConversationStatusPresentation.Inputs.mac(state:meeting:)` and `.phone(model:meeting:placement:now:)` as testable functions in each app.
- Add a shared `ConversationStatusPresentation.Action` handler protocol that both apps implement once (`MacStatusActions`, `PhoneStatusActions`).
- Move `templateTitle` there too. It is written three times: `SummaryPage.swift` on the Mac (`PageColophon.templateTitle`), the iPhone's `PageColophon`, and its `TemplatePicker.automaticTitle`. Make it a DaybookKit `TemplateWords.title(for:resolved:)`.

**Proof.** `DaybookTests` and `DaybookPhoneTests` cases over `ReadingDemo` conversations, asserting the presentation's title and actions.

**Risk.** Low.

### P8. Split `AppState` along its existing seams (L, in four independent steps)

**What and why.** `AppState.swift` is 1,615 lines with about 150 properties: navigation, the processing queue, models, capture, calendar, call policy, phone link, cloud, placements, photos, and shared notes. 25 more `extension AppState` blocks bring it to 7,631 lines across files. Views read it in 90 files. The split has started (`ProcessingQueue` holds the queue's state), but `AppState` keeps 25 `get { queue.… }` forwarders "as they always have" (`AppState.swift:120-160`). The processing orchestration (`process`, `runQueue`, claims) is still `extension AppState` inside `ProcessingQueue.swift:237+`. MSQ-20 (god object) was reported as fixed; this is what remains.

**Seams and order.** Each step keeps forwarding properties during the move so that both apps build, then deletes them.
1. **Library window navigation.** Extract `LibraryWindowModel` from `selectedID` (38 reads), `place` (47), `pageMode` (17), `pageScrollTarget` (6), `search`, `searchTokens`, `searchScope` (23), `multiSelection` (16), `activeSheet` (15), `trashRequestIDs` (11), `titleFocusRequest`, `confirmation`, and `readingScale`.
   - Name members as the iPhone's `ReadingSession` names them (`Reading/ReadingSession.swift:20-82`: `place`, `openID`, `pageMode`, `searchText`, `selection`, `sheet`, `confirmation`, `confirmingTrash`).
   - Replace the `SummaryJump.window` singleton (`Sources/Daybook/UI/TranscriptPage.swift:89-110`) with the token request `ReadingSession.summaryRequest` uses. That leaves one jump mechanism on both apps, and a later shared `ReadingNavigation` in DaybookUI becomes a rename.
2. **Processing.** Move `process`, `runQueue`, `enqueue`, and claim renewal into a `MacProcessor` that owns `ProcessingQueue`, the twin of the iPhone's `PhoneProcessor`, and delete the forwarders.
3. **Library launch and migration.** Lines 560-680 (`LegacyLibraryReturn`, `SandboxMigration`, `MovedLibrary`) go to `LibraryLaunchCheck`.
4. **Test seams.** Replace `NSClassFromString("XCTestCase")` checks (`Captions/LiveCaptionsController.swift:304`, used at `AppState.swift:255` and `AppState+Calendar.swift:50`) with an injected `MacEnvironment`, as the iPhone injects `PhoneAppEnvironment`.

**Proof.** `DaybookTests` unchanged, plus `WindowInvalidationTests`, which counts redraws, to confirm that reading the navigation model doesn't redraw for queue progress.

**Risks.** Wide diffs. Do it after P2 and P7 have shrunk the code that reads `AppState`.

## 3. Findings

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| CQ-01 | medium | Edit › Find in Conversation, Find Next, and Find Previous are built but never added to the menu bar, so ⌘F does nothing on the summary page and the items can't be discovered. Audit fix HIG-08 was left "partial"; the integrator step that adds `ConversationFindCommands(state:)` to `DaybookCommands` was missed. | `Sources/Daybook/UI/TranscriptPage.swift:143` (declared, 0 uses); `Sources/Daybook/App/DaybookCommands.swift:16-33`; `docs/audits/2026-11-01/hig-mac.md:14,38` | Add `ConversationFindCommands(state: state)` to `DaybookCommands.body`. | S |
| CQ-02 | medium | Work/Personal chosen from a conversation's More menu can't be undone on either app. The same action from a row, a sidebar drop, the menu bar, or an iPhone swipe can. | `MeetingDetailView.swift:263`; `ConversationScreen.swift:133`; compare `ConversationList.swift:469`, `LibraryPage.swift:656`, `DaybookCommands.swift:251`, `SidebarView.swift:117` | P2: one dispatcher per app, with the library's cases shared. | M |
| CQ-03 | medium | Each app has two dispatchers for the same `ConversationAction`, and they've drifted: placement undo, Copy Summary's "Copied" confirmation, and the Move to Folder menu. `MacActions.context` and `MoreMenuActions.context` are identical. | `ConversationList.swift:442-517` vs `MeetingDetailView.swift:232-295`; `LibraryPage.swift:619-…` vs `ConversationScreen.swift:109-…`; `ConversationScreen.swift:121` vs `LibraryPage.swift:641` | P2. | M |
| CQ-04 | medium | The iPhone's old status model (`StatusPresentation`, `RowStatus`, `ConversationRow`, `MacSighting.line`, `FriendlyError`) is no longer used in production but is pinned by 25 test lines. Those tests check a copy that has already drifted from what ships, while `ConversationStatusPresentation` ships. | `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift:19-275`; `Reading/Library/ConversationRow.swift:78-99`; tests `ReadingTests.swift`, `PhoneSummaryPlacementTests.swift:148-470`, `AwaitingRecordingStatusTests.swift:27-40`, `PhoneUpgradeTests.swift:131-148` | P1: port the assertions to `ConversationStatusPresentationTests`, then delete the copy. | S–M |
| CQ-05 | medium | MSCQ-09 is still open, and even the interim fix wasn't done. SNR weighting is unreachable: nothing produces a `SignalQualityProfile`. `MeetingAudioAlignment` (the writer of stored alignments) is test-only. The docs still describe both as working. | `Sources/DaybookCore/MultiSourceFusion.swift:598-599`; `Alignment/SignalQuality.swift` (whole file); `Alignment/MeetingAudioAlignment.swift` (test-only); `FusionSummary.swift:141-144`; `docs/alignment.md:25,127` | See the decision in section 4. | S |
| CQ-06 | low | `SharedNameTests.movingOver` still lists 7 names whose app copies are gone (`ProblemLine`, `DetailsButton`, `SettingsFooter`, `StatusCard`, `StatusCardMetrics`, `StatusDivider`, `StatusRow`). The 8th, the Mac's `MarginRow`, lays out like DaybookUI's in all four places it's used. | `Tests/DaybookUITests/SharedNameTests.swift:17-22`; `Sources/Daybook/UI/ConversationPage.swift:37` | P1 step 5: delete the copy and the allowlist. | S |
| CQ-07 | low | The motion audit only reports: 12 raw curves remain, and the test skips unless an env var no workflow sets. Two of them are the same page-mode crossfade on both apps. | `Tests/DaybookDesignTests/MotionAuditTests.swift:127-131`; `scratchpad/cq/test-audits.log`; `MeetingDetailView.swift:35`, `ConversationScreen.swift:34` | P3 step 1: add a `DaybookMotion.pageTurn` token and make the test fail. | S |
| CQ-08 | low | Only DaybookCore and DaybookKit check concurrency strictly. Under complete checking, DaybookCaptions and DaybookDesign already have 0 warnings, DaybookLink 4, DaybookDevices 16, and DaybookUI 45 (35 of them in two files). | `Package.swift:59-67`; `scratchpad/cq/strict-ui.log` | P3 step 3: enable target by target. | S, then M |
| CQ-09 | low | No CI gate on first-party warnings. There is exactly one today. | `Sources/Daybook/UI/CallPrompt.swift:60` (unused `call`); `.github/workflows/ci.yml:143` | Fix it, and add a grep gate over `Sources/` and `Apps/iOS/` in `build.log`. | S |
| CQ-10 | low | Dead code in the Mac app (listed in P1 step 2), the iPhone app (P1 step 3), and the shared libraries (P1 step 4). | `scratchpad/cq/dead-types.txt`, `dead-funcs.txt` | P1. | S |
| CQ-11 | low | The design tokens have three names: DaybookStyle/TypeStyle/Space/Motion/Ink on the Mac, PhoneStyle on the iPhone, DaybookDesign's own in DaybookUI. One alias has a different value on each app: `brandGradient` is `.mark` on the Mac and `.progress` on the iPhone. The iPhone's notebook placeholder draws its "mark" in the progress direction. | `Sources/Daybook/UI/DaybookStyle.swift:39`; `Apps/iOS/Shared/PhoneStyle.swift:34`; `Apps/iOS/DaybookPhone/Reading/LibraryBrowser.swift:424` | P5. | M |
| CQ-12 | low | `AudioLevelMeter` is written twice (`NSLock` and `@unchecked Sendable`, different reading types) over the same `AudioBufferLevel`. | `Sources/Daybook/Capture/PCMTrackWriter.swift:6`; `Apps/iOS/DaybookPhone/Recording/AudioLevelMeter.swift:17` | P4: one meter in DaybookCore, held in a `Mutex`. | S |
| CQ-13 | low | Version History is drawn twice over the same shared parts, with the same alert words. | `Sources/Daybook/UI/ConversationSheets.swift:36-135`; `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift:12-155` | P4: a DaybookUI `VersionHistoryScreen`. | M |
| CQ-14 | low | The Use Calendar row is written twice, and when calendar access is refused the iPhone shows no problem line, only a button. | `Sources/Daybook/UI/SettingsView.swift:229-242`; `Apps/iOS/DaybookPhone/Settings/SettingsScreen.swift:351-361` | P4: a DaybookUI `CalendarSettingsRow` with `ProblemLine`. | S |
| CQ-15 | low | The same device kind gets two glyphs: a bare symbol on the Mac, a `DaybookTile` on the iPhone. The Mac's comment "as on the iPhone" is now false (xdevice-ds-15 regressed or was never finished). | `Sources/Daybook/Devices/UI/DeviceComponents.swift:61`; `Apps/iOS/DaybookPhone/Devices/UI/DeviceScreens.swift:54` | P4: one glyph. | S |
| CQ-16 | low | The Mac's `StatusBox` re-implements DaybookDesign's `AttentionBox`, and is used once, through `DeviceAttentionBox`. | `Sources/Daybook/UI/ConversationPage.swift:301-375`; `Devices/UI/DeviceComponents.swift:111`; `PhonePairingView.swift:98` | Use `AttentionBox`; delete both. | S |
| CQ-17 | low | Spotlight indexing is written twice, as `ConversationSpotlight` on the Mac and `ConversationIndex` on the iPhone. The App Shortcut phrases differ for the same intent. | `Sources/Daybook/App/Intents/ConversationEntity.swift:104-188`; `Apps/iOS/DaybookPhone/App/ConversationEntity.swift:101-209`; `DaybookIntents.swift:194` vs `DaybookShortcuts.swift:23` | P4: the plan in DaybookKit, plus a phrase parity test. | M |
| CQ-18 | low | Whether an error "speaks plainly" is decided twice, by type lists that differ. | `Sources/Daybook/App/AppProblem.swift:41-50`; `Apps/iOS/DaybookPhone/Reading/Model/ReadingStatus.swift:280-297` | P4: a `PlainSentenceError` protocol and `ProblemWords`. | S |
| CQ-19 | low | "Summarizing in N s" is assembled in seven or more places. | `SummaryPlacementPlanner.swift:189,203`; `ConversationStatusPresentation.swift:122,669,676,701`; `QueueStatusWords.swift:47`; `FloatingStatus.swift:130-131` | P4: one `ProcessingWords.summaryCountdown`. | S |
| CQ-20 | low | The status overview has two models: the iPhone's `StatusSheetModel` and `StatusInputs`, and the Mac's `FloatingStatusInputs` with a third per-conversation work enum. The Mac doesn't draw the shared `StatusOverview`, which docs/interface.md:122 says it will. | `Apps/iOS/DaybookPhone/Status/StatusSheetModel.swift:135,229`; `Sources/Daybook/UI/FloatingNotes/FloatingStatus.swift:15-55` | P6. | L |
| CQ-21 | low | `AppState` is a god object: about 150 properties, 25 forwarders to `ProcessingQueue`, and library migration and test-host checks inline. The audit's MSQ-20 was only partly addressed. | `Sources/Daybook/App/AppState.swift:120-160,560-680`; `Captions/LiveCaptionsController.swift:304` | P8. | L |
| CQ-22 | low | DaybookUI is the least-tested module, at a test-to-source ratio of 0.09 (2,183 / 22,146), against Core 0.64, Kit 0.65, Mac app 0.57, and iPhone 0.51. Several types with rules have no test: `StatusBlock` actions, `RecorderAfterStopState`, `WelcomePermissionState`, `PhotoWords`, `TrashWords`. DaybookModelStore has no test target (its tests run in DaybookIntelligenceTests). | `wc` over `Sources/` and `Tests/`; `Package.swift:123-150` | Test the rule types as they move in. Add a DaybookModelStoreTests target. | M |
| CQ-23 | low | The iPhone test target re-implements `DaybookTestSupport`'s waits. Because the iPhone's tests can't link it, test doubles ship in production modules: `InMemoryCourier`, `MemoryLibraryKeyStore`, and `ArraySampleSource` are used only by tests. | `Apps/iOS/DaybookPhoneTests/TestSupport.swift:133-160`; `Tests/DaybookTestSupport/Waiting.swift:36-64`; `Apps/iOS/project.yml:236-254`; `Sources/DaybookKit/InMemoryCourier.swift` | Add `../../Tests/DaybookTestSupport` as sources of `DaybookPhoneTests`, then move the doubles there. | S |
| CQ-24 | low | Debug launch flags are parsed in 24 Mac files, against a single `DebugLaunch` on the iPhone (fixed there by MODERN-iOS-19). `--library-demo` and `--demo-library` are both kept on both apps. | `grep LaunchOptions Sources/Daybook` (24 files); `Apps/iOS/DaybookPhone/App/DebugLaunch.swift:261`; `Sources/DaybookKit/ReadingDemo.swift:30` | A Mac `DebugLaunch` struct; drop `--demo-library`. | M |
| CQ-25 | low | `ObservationWatch`, a general observation utility (64 uses across apps), lives in the device framework. | `Sources/DaybookDevices/Framework/ObservationWatch.swift:14` | Move it to DaybookCore. | S |

## 4. Decisions recommended (owner decisions this lane touches)

- **MSCQ-09 (SNR weighting and stored audio alignment): delete the unreachable parts and keep reading what shipped files hold.**
  - Remove `SignalQualityProfile`, `AudioAligner.signalQuality(of:)` (`SignalQuality.swift`), the SNR factor in `MultiSourceFusion.swift:598-599`, the `signalQuality` input (`FusionSummary.swift:144`, `TranscriptFusion.swift:68`), and the test-only writer `MeetingAudioAlignment`.
  - **Keep** decoding `Meeting.audioAlignments` and fusion's use of stored alignments (`MultiSourceFusion.swift:276`): v0.2.2 wrote them (`Tests/DaybookTests/Fixtures/Shipped/v0.2.2/.../meeting.json`).
  - Keep `AudioAligner.align`, which the Mac's live alignment uses (`MultiSourceCoordinator.swift:48`).
  - Correct `docs/alignment.md:25,127` and `docs/architecture.md`, "Transcript clocks and fusion".
  - Why: the iPhone fuses too (`LibraryController.realign`) without local audio. Wiring SNR in would make the two devices' wording differ unless per-track profiles were synced. Deleting changes nothing that ships today. Size S.
- **xdev-settings-08 (processing settings only on the Mac): the code half.**
  - `ProcessingPreferences` lives in the Mac app (`Sources/Daybook/App/ProcessingPreferences.swift:9`), so the iPhone can't share it even if the product decision allows it.
  - Move the value type to DaybookKit unchanged, keeping per-device storage, and move `TranscriptionLanguageSettings` (`Sources/Daybook/UI/TranscriptionLanguageSettings.swift`, 80 lines) to DaybookUI.
  - Then offer the transcription language on the iPhone, which the audit called the least contentious part. Keep speaker detection fixed there, as docs/iphone.md says.
- **xdev-settings-03 (Settings organised differently): from the code side, take the minimal alternative now.**
  - 4,585 lines of Settings sections are already shared (Cloud, iCloud, Storage, Models, Templates, Vocabulary, About, Captions, Recorder preferences), so whichever layout wins, the sections stay.
  - What's left per app is the frame (the Mac's 5-pane `SettingsView.swift:12-130`, the iPhone's root list) plus the Recording and General rows. Lift the Recording rows (`CalendarSettingsRow`, CQ-14) so both frames hold the same sections, and rename so "Library" means the same on both.
  - Revisit the Mac's sidebar layout as a design call later. It is then a change to the frame only.

## 5. Not findings (checked and fine)

- **Shared already.** Notes editor, Templates, Vocabulary, Speaker Profiles, Welcome (`WelcomePager`/`WelcomeWords`), player (`PlayerBar` over DaybookKit's `PlaybackEngine`), recorder (`RecorderSurface`/`RecorderAfterStop` on both), transcript (`TranscriptPage`), summary blocks, photos, a recorder's page and recordings, pairing, Cloud settings (`CloudSettingsForm`; each app keeps a 40-line wrapper), conversation rows (`ConversationRowView` with `ConversationStatusPresentation.row` on both), and summary placement (`SummaryPlacements` in DaybookKit).
- **Module boundaries hold.** DaybookCore imports no UI frameworks. DaybookKit imports UIKit only under `#if canImport(UIKit)` for background time, and no SwiftUI. DaybookDesign and DaybookUI import AppKit and UIKit only behind platform checks. DaybookUI never reaches app types; it goes through seams (`ReadingContext`, `TranscriptHost`, `RecorderServices`).
- **Observation is uniform.** `@Observable` throughout, 0 `ObservableObject`, 0 `@Published`; Combine survives only in `LibraryController.swift:54` and `LibrarySaveQueue.swift:117` (an app-lifecycle sink).
- **Demo and debug code** is behind `#if DEBUG` in every demo file checked.
- **Scripts** all use `set -euo pipefail` and share `scripts/lib/build-common.sh` and `scripts/ci/lib/asc.sh`. CI already runs the iPhone tests (`ci.yml:255-281`).
- **No `@testable import` in production sources.** Tests use `@testable` on library modules only.
- **`LibraryController` is in a good shape:** 1,047 lines plus 11 focused extension files (2,324 total). The large functions are in DaybookCore's domain code (`MeetingMerge.merge` 206 lines, `MultiSourceFusion.align` 155), not in views.
- **The bundle-ID carry-over** (`PreferencesCarryOver.swift`) and sandbox migration are recent (since 2026-11-01) and still needed. Give them a removal version in docs/release.md rather than deleting them now.
- **Fixed font sizes in DaybookUI** (`TagEditor.swift:68,116`, `TemplatesScreen.swift:275`) are in Mac-only branches. The touch branches use tokens, so Dynamic Type isn't affected. One exception: `RecommendedLabel` (`RecorderDevicePage.swift:813`, 10 pt) also shows on the iPhone's recorder page.
