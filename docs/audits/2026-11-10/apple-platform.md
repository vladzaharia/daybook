# Apple platform features: macOS and iOS 27.2, and what 27.3 adds

Reviewer lane: how Daybook uses what Apple's platforms offer a meeting recorder and notes app. Ground truth is the
installed SDK: Xcode 27.2 (27B52), `MacOSX27.2.sdk` and `iPhoneOS27.2.sdk`. Every symbol below was found in a
`.swiftinterface` or header there, with the `@available` version recorded as found. 27.3 items come from Apple's
developer news (the 27.2 SDK contains no 27.3 symbols: a grep of every framework's modules for `27.3` finds none).
Deployment targets: macOS 15.0 (`Apps/macOS/project.yml:18`), iOS 26.0 (`Apps/iOS/project.yml:8`), so every
recommendation is `#available`-guarded.

## Summary

Daybook already uses more of the platform than most apps. It reads the Duo's hinge through both `onHingeChange` and
`UIHingeInteraction` (27.1), recognizes handwriting with `PKStrokeRecognizer` (27.0), and keeps processing alive with
`BGContinuedProcessingTask` (26). It records AirPods with `.bluetoothHighQualityRecording` (26) and offers
`AudioRecordingIntent`/`LiveActivityIntent` recording intents, a `ControlWidget`, and Live Activities. It indexes
conversations as `IndexedEntity`s, captures calls through private Core Audio process taps, falls back to
`SpeechTranscriber` for live captions, and names conversations with Foundation Models `@Generable` output.

The gaps are in three places.

1. **The system's own models are used only at the edges.** A new person still meets "Download models to transcribe
   this conversation" before their first transcript, and the Mac's Welcome asks for up to "Needs 16.5 GB". Yet
   `SpeechTranscriber`/`SpeechAnalyzer` (26) transcribe a file on device with nothing for Daybook to download.
2. **Conversations are opaque to the system.** The entities carry a title and date (plus a gist on the Mac). There is
   no content, no `NSUserActivity` (so no Handoff or onscreen awareness), and no intent that returns a summary or next
   steps. The iOS/macOS 27.3 Siri AI Developer Preview works entirely through App Intents and the Spotlight semantic
   index, so today it would find almost nothing of Daybook's.
3. **A handful of 26.2–27.1 APIs fix real problems or replace custom code.**
   - AirPods far-field and dual-route input (26.2) and the system input picker (26), so an iPhone with AirPods in
     records the room, not just the wearer.
   - The Duo's reserved division region (27.1) and sheet placement (27.0), so sheets stop straddling the crease.
   - Core Audio tap bundle IDs with process restore (macOS 26), which replace a 3‑second poll.

There is also a compliance gap: neither app ships a `PrivacyInfo.xcprivacy`, though both use required-reason APIs.

## The five adoptions with the best value for the person

1. **Transcripts without a download** (Mac and iPhone, 26+): a system speech engine on `SpeechTranscriber`, used
   whenever the chosen model isn't on the device yet. The existing Upgrade offer redoes the transcript later.
   Proposal 1.
2. **Conversations the system understands** (both, 15.2/18.2+, more on 27): one shared `ConversationEntity` with
   content, plus content-returning intents, Handoff and onscreen awareness through `NSUserActivity.appEntityIdentifier`,
   and the `AppSchema.notes` domain (27.0). This is the prerequisite for Siri AI in 27.3. Proposal 3.
3. **Record the room, not just your AirPods** (iPhone): the input picker on the recorder's input name
   (`AVInputPickerInteraction`, 26.0), then far-field AirPods capture (`.farFieldInput`, 26.2), then a second "You"
   track (`.dualRoute`, 26.2). Proposal 4.
4. **Let the Duo's system place the crease and the sheets** (27.0/27.1): `reservedRegions(kind: .division)` and
   `presentationPlacement(.trailing)` replace the half-width crease math and the hand-made right-page card. Proposal 5.
5. **Translate a conversation on device** (both, 26+): batch `TranslationSession` over transcript and summary, with
   names kept untranslated (26.4). Data detection on summaries (iOS 27.0, macOS 27.2) comes with it. Proposal 6.

## Redesign proposals

### 1. Transcripts without a download: a system speech engine

**What and why.** On both apps a conversation with no installed transcription model stops at "Download models to
transcribe this conversation" (`Sources/DaybookKit/ConversationStatusPresentation.swift:399`, `:540`). The iPhone's
Welcome says "Start a conversation now. Download models in Settings to transcribe it."
(`Sources/DaybookUI/Welcome/WelcomeWords.swift:79`), and on screenshot `ios/pro-not-transcribed-light.png` an
18-second recording waits behind "Not transcribed yet · Transcribe". The Mac's Welcome quality page sizes its download
up to "Needs 16.5 GB" (`Sources/Daybook/UI/WelcomeWindow.swift:110-124`).

Apple's `SpeechAnalyzer` + `SpeechTranscriber` run on device in every language Apple supports. Their assets are
installed and shared by the system (`AssetInventory`), so Daybook downloads nothing. Daybook already trusts them for
live captions (`Sources/DaybookCaptions/LiveCaptioning.swift:182-242`). docs/models.md:363 already calls it "the
fallback (no download, every language Apple supports)", but only live captions use it. Principle: the first recording
should produce a result. A system model is how Apple's own apps do it, and Daybook's provenance and "Upgrade" machinery
(docs/models.md, "Quality ranks") already handles a better model arriving later.

**Design.**

- **Engine.** A new engine `appleSpeech` (`ModelEngineID`, `Sources/DaybookKit/Models/ModelIdentity.swift:66-80`)
  shaped exactly like `AppleFoundationModelsEngine`:
  - residency `.system`, a `systemProvided` variant (`Families/apple-speech.json`), role `transcription`, platforms
    macOS and iOS;
  - availability from `SpeechTranscriber.isAvailable` and `supportedLocale(equivalentTo:)`;
  - runtime recorded as "Speech, macOS 27.2" (the OS version, as the Foundation Models engine records it).
- **Mapping onto `Transcribing.transcribe(url:glossary:language:progress:)`**
  (`Sources/DaybookIntelligence/Engines/ModelEngine.swift:66-72`):
  - modules: `SpeechTranscriber(locale:transcriptionOptions:[], reportingOptions:[], attributeOptions:[.audioTimeRange,
    .transcriptionConfidence])`;
  - the file: `SpeechAnalyzer(inputAudioFile:modules:finishAfterFile:)` on 26, or `AssetInputSequenceProvider.provider(
    from:compatibleWith:)` on 27.0;
  - the glossary: `AnalysisContext.contextualStrings[.general]` through `setContext(_:)`;
  - the language hint: `supportedLocale(equivalentTo:)`;
  - first use: `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`, shown in the model row
    as the system preparing its speech model.
- **When it runs.** Insert it as the interim choice: when the selected transcription model isn't installed, the job
  transcribes with `appleSpeech` instead of waiting. Give it a quality rank below Parakeet Redux, so the existing
  Upgrade offer appears once the chosen model downloads. Speakers still come from the small diarizers (Nemotron
  Compact 102 MB, Community-1 22 MB). Until one is installed the transcript is unattributed, exactly as a one-speaker
  transcript reads today.
- **What the person gets.** Record, stop, read. On the iPhone, the 4–6 GB tiers that have no summary model still get
  transcripts in any Apple-supported language. The Mac's Welcome no longer gates the first recording on a multi-GB
  download.

**Privacy.** Runs on device. The system downloads its own speech assets, and no audio leaves the device.

**Touches.** `Sources/DaybookIntelligence/Engines/` (new `AppleSpeechEngine.swift`), the catalog
(`Families/apple-speech.json`), `ModelRecommendations`, `ConversationStatusPresentation.swift`, `WelcomeWords.swift`,
docs/models.md.

**Risks.**

- Accuracy against Parakeet and Whisper is unmeasured on Daybook's validation set. Measure before ranking.
- `SpeechTranscriber` wants a locale. Use `TranscriptionRouting`'s language detection, or the device locale.
- The OS can change the model silently. Provenance records the OS, as it does for Foundation Models.
- First use needs the network for the system's assets.

**Size:** L.

### 2. A first summary and photo captions from Apple Intelligence, with 27's larger model

**What and why.** Foundation Models serves only titles, kinds, and vocabulary. docs/models.md:64 records why it doesn't
write summaries: a 4,096-token context on 26, and in October it invented an action item. The 27.x framework changes the
inputs to that decision:

- `contextSize` is 8,192 on 27 (the property is `@backDeployed`; the SDK body returns 4,096 before 27);
- `SystemLanguageModel.variant` (27.0) and `Variant.core3` / `.coreAdvanced3` (27.0);
- `ContextOptions.reasoningLevel` (27.0);
- exact `tokenCount(for:)` (26.4);
- image input: `Transcript.ImageAttachment` (27.0), `Attachment(_ uiImage:)` in `_FoundationModels_UIKit` (iOS 27.0),
  and `LanguageModelCapabilities.Capability.vision` (27.0).

A person with Apple Intelligence on, and no local summary model yet (the Mac before its download, or an 8 GB iPhone
before Gemma E2B), gets no summary today.

**Design.**

- **When it applies.** Only where the transcript fits (`tokenCount(for:)` of the prompt ≤ `contextSize` minus the
  instructions and answer). Generate the existing summary shape as `@Generable` with greedy sampling.
- **Guard against invented actions.** Every next step must quote a passage that exists in the transcript. Drop any
  that don't. This is the October failure, checked mechanically.
- **Label and rank.** Label it with provenance "Apple Intelligence". Rank it lowest on the `summaryQuality` scale, so
  the Upgrade offer appears automatically once a local model or a cloud key is there.
- **Photos.** Where `SystemLanguageModel.default.capabilities.contains(.vision)` (27.0), add an `imageDescription`
  variant to the `appleFoundationModels` engine for one-line photo captions, beside Apple Vision's OCR. Today a caption
  needs Gemma through MLXVLM on the Mac.
- **Not for long meetings.** No map-reduce over long meetings.

**Privacy.** On device: `SystemLanguageModel` only, never `PrivateCloudComputeLanguageModel` (see "Not worth it").
Personal conversations are fine because nothing leaves.

**Touches.** `Sources/DaybookIntelligence/Engines/AppleFoundationModelsEngine.swift` (add the `summarization` and
`imageDescription` roles), `SummaryPlacementPlanner`, the catalog, docs/models.md:64 (rewrite the deviation).

**Risks.** It reverses a documented decision, so it needs the October evaluation rerun on the 27.2 model first. It can
also hit guardrail refusals; `.permissiveContentTransformations` is already used.

**Size:** L (photo captions alone: M).

### 3. Conversations the system understands: one entity, content intents, Handoff, and the notes schema

**What and why.** Each app defines its own `ConversationEntity`, and they have drifted.

- The Mac's has `title`, `date`, and `gist` as plain stored properties, not `@Property`, so Shortcuts can't read them
  (`Sources/Daybook/App/Intents/ConversationEntity.swift:15-19`). Its Spotlight `attributeSet` fills title, gist, and
  dates (`:37-44`).
- The iPhone's has `@Property` title and date, no gist, and no `attributeSet` override
  (`Apps/iOS/DaybookPhone/App/ConversationEntity.swift:8-27`).
- No intent returns content. The intents start, stop, bookmark, open, and make a new note
  (`Sources/Daybook/App/Intents/DaybookIntents.swift`, `Apps/iOS/Shared/RecordingIntents.swift`).
- Neither app creates an `NSUserActivity`. Neither Info.plist declares `NSUserActivityTypes`, so there is no Handoff
  between the Mac and iPhone (one bundle ID, `local.daybook`, makes it free) and no onscreen awareness.

Siri AI in 27.3 works through exactly these: App Intents, and "any entity in the Spotlight semantic index" (Apple
developer news, 2026-11-03).

**Design.**

- **(a) One entity.** Move `ConversationEntity` into DaybookKit for both apps, conforming to `AppEntity`,
  `IndexedEntity`, and `Transferable`, and to `SyncableEntity` on 27.0 (the passthrough case: the UUID is already
  stable across devices).
  - `@Property`: title, date, duration, folder, tags, people (speaker names).
  - `@DeferredProperty` (26.0): summary overview, open next steps, notes text.
  - `attributeSet`: `textContent` (overview, notes, next steps; not the whole transcript), `participants`, `duration`,
    `recordingDate`, `containerTitle` (folder), `keywords` (tags).
  - Make the query an `IndexedEntityQuery` on 27.0 so Spotlight can ask for a reindex (`reindexAllEntities`).
- **(b) Intents that return things.**
  - "Get Summary" returns the text and the entity, and "Get Next Steps" returns a list.
  - "Find Conversations" filters by person, date, and folder (`EntityPropertyQuery`).
  - "Append to Notes" stamps the recording time if the conversation is recording.
  - "Transcribe Audio File" uses `LongRunningIntent` (27.0) with `performBackgroundTask(options:)`; on 26 it opens the
    app.
  - Content-returning intents set `authenticationPolicy = .requiresAuthentication`.
- **(c) The notes domain.** On 27.0, `@AppIntent(schema: .notes.createNote)`, `.notes.appendText`, and
  `.notes.updateNote`, with `@AppEntity(schema: .notes.note)` for a conversation's notes. Siri and Apple Intelligence
  can then add to a Daybook note in natural language.
- **(d) Handoff and onscreen awareness.**
  - The reading page publishes `.userActivity("local.daybook.conversation", isActive:)` with `targetContentIdentifier`,
    `isEligibleForHandoff = true`, and `appEntityIdentifier = EntityIdentifier(for:)` (`AppEntityAnnotatable`, macOS
    15.2 / iOS 18.2).
  - Both apps handle `.onContinueUserActivity`.
  - Add `NSUserActivityTypes` to `Resources/Info.plist` and `Apps/iOS/DaybookPhone/Resources/Info.plist`.

The person can then pick up the conversation they're reading on the other device, ask Siri to "send this summary to
Priya", and build Shortcuts like "after a meeting ends, append its next steps to my Reminders".

**Privacy.**

- Personal conversations keep today's rule (`ConversationIndex.isShown`): never indexed, never suggested, never
  advertised by an activity, and with no content properties filled.
- Everything here is on-device indexing. Siri AI's own server-side features are the person's request, not Daybook's.

**Touches.** `Sources/Daybook/App/Intents/*`, `Apps/iOS/DaybookPhone/App/ConversationEntity.swift`,
`DaybookShortcuts.swift` (both), the reading page in DaybookUI, both Info.plists, docs/interface.md.

**Risks.**

- The index size: keep the transcript out of `textContent`.
- The schema macros enforce required properties at compile time.
- A shared entity type must keep each app's `defaultQuery` reading its own library.

**Size:** L.

### 4. iPhone: record the room, not just your AirPods

**What and why.** The session is `.playAndRecord` with `[.allowBluetoothHFP, .bluetoothHighQualityRecording,
.defaultToSpeaker]` and no preferred input (`Apps/iOS/DaybookPhone/Recording/AudioSession.swift:114-115`).
With AirPods connected, iOS routes input to the AirPods. Their microphones beam-form to the wearer, so in a meeting at
a table the other people are faint. The recorder shows the input's name ("RECORDING · Synthetic Microphone" on
`ios/pro-recording-light.png`; `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift:26`) but offers no way to
change it. The SDK now covers this.

**Design, in three steps.**

- **(S) Pick the input.** Make the input name in the recorder's status line a button that presents the system input
  picker, `AVInputPickerInteraction` (AVKit, iOS 26.0).
- **(M) Far-field AirPods.** On 26.2, when the current Bluetooth input's
  `bluetoothMicrophoneExtension?.farFieldCapture.isSupported` (`AVAudioSessionPortExtensionBluetoothMicrophone`, 26.0)
  is true, add `.farFieldInput` (`AVAudioSessionCategoryOptionFarFieldInput`, iOS 26.2; requires `.allowBluetoothHFP`).
  The AirPods then capture the room.
- **(L) Two tracks, as the Mac records.** On 26.2, `.multiRoute` with `.dualRoute` (`AVAudioSessionModeDualRoute`,
  iOS 26.2) records the built-in microphone (the room) and the AirPods (you) at once. That is the Mac's design, where
  the microphone is "You" and the call is "Call", so fusion gets a known "You" channel.

**Privacy.** On device. The header's own warning for dual route is "may not be used to enable recordings of others
without their awareness". Daybook's recording is overt: the recorder screen, the Live Activity, and the system
microphone indicator.

**Touches.** `AudioSession.swift`, `PhoneRecorder.swift`, `PhoneTrackWriter.swift` (step C), `RecordingStatusWords`,
docs/capture.md and docs/iphone.md.

**Risks.**

- Far-field support exists only on some AirPods.
- Multi-route needs AVAudioEngine channel mapping per route.
- Battery use.
- Every step needs device testing; the simulator has no Bluetooth routes.

**Size:** S, then M, then L.

### 5. iPhone Duo: let the system place the crease and the sheets

**What and why.**

- `CreaseSplit` puts the crease at half the full display width, and docs/iphone.md:306 says "The system adds no inset
  for the fold" (`Apps/iOS/DaybookPhone/UI/CreaseSplit.swift:7-11`, `:53-60`). That's true of safe areas, but iOS 27.1
  reports the fold as a reserved region:
  - SwiftUI: `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` with `ReservedRegion.Kind.division`
    ("a region where an element should divide into two separate regions") and `ReservedRegion.margins` ("for
    interactive content"), anyAppleOS 27.1;
  - UIKit: `UIView.reservedRegionsOfKind:` (`UIViewReservedRegion.h`, iOS 27.1).
- Sheets: "On the open iPhone Duo a sheet is a card centred across the crease"
  (`Apps/iOS/DaybookPhone/Settings/SheetPages.swift:6-10`). Daybook works around it with a hand-made `PageCard` on the
  right page (`:41-44`, `Reading/LibraryBrowser.swift:65-66`). `View.presentationPlacement(_:)` with
  `PresentationPlacement.leading/.trailing` (anyAppleOS 27.0) places a real system sheet on one page.

The Duo always runs 27.1 or later, so these guards are always true there.

**Design.**

- Record `reservedRegions(kind: .division)` in `GeometryProbe` on the Duo simulator in both open postures.
- Where the probe finds a division, use its `frame` for the crease and its `margins` for the clearance, keeping today's
  math as the fallback.
- Present reading sheets and Settings' `pageSheet` with `.presentationPlacement(.trailing)` instead of `PageCard`. They
  keep the system's dismissal, detents, Liquid Glass, and VoiceOver containment.
- Evaluate `ArrangementView(primary:secondary:)` with `.arrangementViewStyle(.split)` (anyAppleOS 27.1) as the
  two-page container in place of `CreaseSplit`'s `HStack`.
- On 27.3, verify the pocket recorder's edge controls against the new cover-display Reachability edge swipe.

**Privacy.** No change.

**Touches.** `CreaseSplit.swift`, `SheetPages.swift`, `LibraryBrowser.swift`, `GeometryProbe.swift`, docs/iphone.md
("Measured").

**Risks.** The simulator's reports may differ from hardware. `presentationPlacement` on the Duo's inner display is
unverified; measure before deleting `PageCard`.

**Size:** M.

### 6. Translate a conversation, and make dates and places actionable

**What and why.** Daybook routes and transcribes many languages, but a person can't read a colleague's meeting in their
own language. The Translation framework isn't imported anywhere, and summary text can't even be selected on the iPhone
(a press opens the block menu: `Sources/DaybookUI/Reading/Summary/SummaryBody.swift:370-378`).

**Design.**

- **Where.** "Translate…" goes in the conversation's More menu and in each block's press menu (iPhone) or context menu
  (Mac).
- **How.**
  - Choose a target language with `LanguageAvailability`.
  - Translate the transcript in one batch: `TranslationSession(installedSource:target:)` (26.0) with
    `translations(from:)`, each `Request`'s `clientIdentifier` set to the segment ID.
  - Translate the summary with `Strategy.highFidelity` (26.4).
  - Keep speaker names and approved vocabulary as written, using `AttributeScopes.TranslationAttributes.skipsTranslation`
    on `AttributedString` requests (26.4).
  - First use: `.translationTask` lets the system offer the language download.
- **Display and storage.** The translation shows in place with an "Original" toggle. It is stored as a derived artifact
  with its provenance; the original transcript is never replaced (AGENTS.md: preserve originals).
- **Selections.** A selection gets `.translationPresentation(isPresented:text:)` (iOS 17.4 / macOS 14.4).
- **Dates and places.** Put `.dataDetection(_:options:)` (`_DataDetection_SwiftUI`: iOS 27.0, macOS 27.2) on the
  summary's next steps and body. "Thursday at 3" or an address then gets the system's Add to Calendar and Maps actions.

**Privacy.** The Translation framework translates on device once the language assets are installed. Confirm that
`Strategy.highFidelity` stays on device; use the default strategy if it doesn't.

**Touches.** DaybookUI's reading page (`Reading/Summary`, `Reading/Transcript`), DaybookCore (a stored translation
artifact), the iPhone's block menu.

**Risks.**

- Long transcripts mean many requests; batch them and show progress.
- Data detection taps may compete with the touch block menu. Apply it to next steps first.

**Size:** M.

### 7. The Mac gets the iPhone's widgets and a Control Center control; the Watch gets the Live Activity

**What and why.**

- The iPhone has Recorder, Next Steps, Recent Conversations, and New Note widgets, a `RecordConversationControl`, and
  two Live Activities (`Apps/iOS/DaybookPhoneWidgets/`). The Mac has none of them: `Apps/macOS/project.yml` has a single
  target.
- On macOS 26 a `ControlWidget` sits in Control Center and the menu bar (`ControlWidgetToggle`,
  `StaticControlConfiguration`: macOS 26.0 in WidgetKit). Desktop widgets have been interactive since macOS 14.
- On the iPhone, `ActivityConfiguration` doesn't declare `.supplementalActivityFamilies([.small])` (iOS 18.0;
  `RecordingLiveActivity.swift:13`, `RecorderLiveActivity.swift:10`), so the Watch Smart Stack and CarPlay get no
  layout of Daybook's own.

**Design.**

- **Mac.** A Mac widget extension sharing the iPhone's widget views (moved to a shared target):
  - a Record control toggling `StartRecordingIntent`/`StopRecordingIntent`;
  - Next Steps and Recent Conversations on the desktop.
- **iPhone.** `.small` families with the clock and Bookmark/Stop, which run on the iPhone as `LiveActivityIntent`s.
  On iOS 27, read `isDynamicIslandLimitedInWidth` (WidgetKit, iOS 27.0) in the compact clock
  (`RecordingLiveActivity.swift:51-55` caps it at 52 pt with `showsHours: true`).

**Privacy.** Keep `.privacySensitive()` as on the iPhone, and keep Personal titles out of the widgets.

**Touches.** A new target in `Apps/macOS/project.yml`, an App Group on the Mac (the account owner signs), shared widget
views, `RecordingLiveActivity.swift`.

**Risks.** Signing and App Group setup is owner-only work, and the extension must be sandboxed.

**Size:** L (the Watch families alone: S).

### 8. Personal stays personal: Touch ID on the Mac, a Focus filter on both

**What and why.** Personal holds the most sensitive recordings (ux-mac-10 mentions therapy sessions). The iPhone has
the system's "Require Face ID" for apps. The Mac has nothing, and anyone at an unlocked Mac can open Personal.

**Design.**

- **Mac.** A setting "Lock Personal with Touch ID". The Personal place shows a lock and a `LocalAuthenticationView`
  (`_LocalAuthentication_SwiftUI`, macOS 13.0), or calls `LAContext.evaluatePolicy(.deviceOwnerAuthentication…)`. It
  relocks on sleep, screen lock, or after an idle time.
- **Both.** A `SetFocusFilterIntent` (macOS 13 / iOS 16) "Daybook" filter: Show Personal (on/off), and Ask to record
  meetings (on/off). In a Work Focus, Personal leaves the library, the widgets, and the call prompt's suggestions.

**Privacy.** Improves it; all local.

**Touches.** Sidebar places (Mac), `ConversationIndex` (already excludes Personal), the call prompt
(`Sources/Daybook/UI/CallPrompt.swift`), Settings.

**Risks.** A lock that's easy to bypass through Spotlight or Shortcuts. Personal is already excluded from both, and
intents should honor the lock.

**Size:** M.

## Findings

| ID | Severity | Finding | Evidence | Proposed change | Size |
|---|---|---|---|---|---|
| AP-01 | medium | Neither app has a `PrivacyInfo.xcprivacy`, though both use required-reason APIs. App Store Connect flags iOS uploads (ITMS-91053), and the App Store is the stated plan. Known since docs/research/one-bundle.md:487-489 and still open. | UserDefaults in 39 files, including the widgets' app-group suite (`Apps/iOS/Shared/SharedRecordingState.swift:38`). File timestamps: `PhoneLibrary.swift:295`, `AppState+Sources.swift:247`, `LibraryMoves.swift:28`, `AudioFeatureCache.swift:65`. Disk space: `PhoneWelcome.swift:120`, `PhoneNotices.swift:106`, `WelcomeWindow.swift:124`. Boot time: `mach_absolute_time` in `RecorderClock.swift:30` and `AudioInput.swift:98`. `git ls-files` finds no xcprivacy. | Add manifests to the Mac app, the iPhone app, and the widgets extension. `NSPrivacyAccessedAPICategoryUserDefaults`: CA92.1, plus 1C8F.1 for the app group. `NSPrivacyAccessedAPICategoryFileTimestamp`: C617.1, plus 3B52.1 for the Mac's user-chosen library folder. `NSPrivacyAccessedAPICategoryDiskSpace`: E174.1 and 85F4.1. `NSPrivacyAccessedAPICategorySystemBootTime`: 35F9.1. `NSPrivacyTracking` false, no collected data types. | S |
| AP-02 | medium | A first recording can't be transcribed without a model download. The system's speech model, already used for live captions, isn't offered for processing. | `ConversationStatusPresentation.swift:399`, `:540` ("Download models to transcribe this conversation"); `WelcomeWords.swift:79`; `ios/pro-not-transcribed-light.png`; docs/models.md:363 | Proposal 1 (`SpeechTranscriber` engine, 26.0) | L |
| AP-03 | medium | With AirPods connected, the iPhone records the AirPods' wearer-focused microphones, with no way to choose another input. | `AudioSession.swift:114-115` (no `setPreferredInput`, no picker); `RecordingComponents.swift:26` shows the name only; `ios/pro-recording-light.png` | Proposal 4 (`AVInputPickerInteraction` 26.0, `.farFieldInput` 26.2, `.dualRoute` 26.2) | S→L |
| AP-04 | medium | Conversations expose no content to Shortcuts, Siri, or Spotlight, and no intent returns a summary or next steps. | `Sources/Daybook/App/Intents/DaybookIntents.swift` (start, stop, bookmark, new note, Floating Notes); `Apps/iOS/DaybookPhone/App/ConversationEntity.swift:8-27` | Proposal 3 (b, c) | L |
| AP-05 | medium | No `NSUserActivity` anywhere, so no Handoff between the Mac and iPhone and no onscreen awareness. | No `NSUserActivityTypes` in `Resources/Info.plist` or `Apps/iOS/DaybookPhone/Resources/Info.plist`; zero `userActivity` matches in Sources/Apps | Proposal 3 (d) | M |
| AP-06 | low | The two `ConversationEntity`s have drifted. The Mac's properties aren't `@Property`, so Shortcuts can't read Title or Date. The iPhone's Spotlight items have no description. | `Sources/Daybook/App/Intents/ConversationEntity.swift:15-19`, `:37-44` vs `Apps/iOS/DaybookPhone/App/ConversationEntity.swift:13-14` (no `attributeSet`) | One shared entity in DaybookKit (Proposal 3a). Until then, `@Property` on the Mac and `attributeSet` on the iPhone. | S |
| AP-07 | medium (verify on device) | Writing Tools can act on the notes in ways the editor doesn't expect. On the iPhone each ink block is an attachment character in the text, so a Writing Tools "Replace" over a range containing one drops the block. During a recording, a restructuring rewrite (Key Points, List) yields new paragraphs that `reconcile` stamps with the current recording time. | `Sources/DaybookUI/Notes/NotesInk+TextView.swift:7-8`; `Sources/DaybookCore/TimedNotes.swift:63-68`; TextKit 1 views at `MarginNotesEditor+UIKit.swift:167-169` and `+AppKit.swift:197-199`; no `writingTools` symbol in the repository | Implement `textView(_:writingToolsIgnoredRangesInEnclosingRange:)` (UITextViewDelegate iOS 18.0, NSTextViewDelegate macOS 15.0) to return the ink ranges. Pass `captureTime: nil` while `isWritingToolsActive` (UITextView iOS 18.0, NSTextView macOS 15.0). | S |
| AP-08 | medium | Call capture follows a call app's helper processes by polling every 3 s and rewriting the tap. If the rewrite fails, it rebuilds capture ("capture restarted to include it"). | `Sources/Daybook/Capture/ProcessTapSource.swift:244-277` | On macOS 26, set `CATapDescription.bundleIDs` and `isProcessRestoreEnabled` (both `API_AVAILABLE(macos(26.0))`, `CATapDescription.h:135`, `:167`), so Core Audio adds new and restarted processes itself. Keep the poll on 15. | S |
| AP-09 | low | The live-caption fallback (`SpeechTranscriber`) ignores the approved vocabulary. The live models use it. | `Sources/DaybookCaptions/LiveCaptioning.swift:182-184`, `:242` (no `AnalysisContext`) | `analyzer.setContext` with `AnalysisContext.contextualStrings[.general] = approved terms` (anyAppleOS 26). | S |
| AP-10 | medium | On the open Duo, a system sheet is a card straddling the crease. Daybook replaces it with a hand-built right-page card. | `Apps/iOS/DaybookPhone/Settings/SheetPages.swift:6-10`, `:41-44`; `Reading/LibraryBrowser.swift:65-66` | `.presentationPlacement(.trailing)` (anyAppleOS 27.0), Proposal 5 | M |
| AP-11 | low | The crease is computed as half the full width with a fixed clearance, and the docs say the system reports nothing. 27.1 reports a division region with margins. | `Apps/iOS/DaybookPhone/UI/CreaseSplit.swift:7-11`, `:53-60`; docs/iphone.md:306 | `GeometryProxy.reservedRegions(kind: .division)` / `UIView.reservedRegionsOfKind:` (27.1); probe first; Proposal 5 | S |
| AP-12 | low | `BGTaskScheduler.submit(_:)` is deprecated in iOS 27.0 "to capture all error conditions". `ContinuedProcessing.begin` returns true before the system accepts the request. | `Apps/iOS/DaybookPhone/Processing/ContinuedProcessing.swift:56-66`, `:127`; `App/PhoneSync.swift:285`; `BGTaskScheduler.h:106-110` | On 27, `try await BGTaskScheduler.shared.submitTaskRequest(_:)` (iOS 27.0), and report a refusal through `begin`. | S |
| AP-13 | low | A comment says the Mac lacks `AudioRecordingIntent`. The SDK has it from macOS 15.0 (only `LiveActivityIntent` is iOS-only). | `Sources/Daybook/App/Intents/DaybookIntents.swift:7-9` | Adopt `AudioRecordingIntent` for the Mac's Start, Stop, and Resume intents, as on the iPhone, and fix the comment. | S |
| AP-14 | low | The Foundation Models excerpt is sized at "three characters per token" and retried at half size on overflow. | `AppleFoundationModelsEngine.swift:174`, `:183-191` | `SystemLanguageModel.tokenCount(for:)` (26.4) to fill the context exactly in one call; keep the estimate on 26.0–26.3. | S |
| AP-15 | low | Live Activity: no layout for the Watch Smart Stack or CarPlay, and the compact clock doesn't adapt to a width-limited island. | `RecordingLiveActivity.swift:13`, `:51-55`, `:101` | `.supplementalActivityFamilies([.small])` (iOS 18.0); `@Environment(\.isDynamicIslandLimitedInWidth)` (iOS 27.0) shows the glyph and minutes only | S |
| AP-16 | low | Photo text uses the legacy `VNRecognizeTextRequest`, which flattens whiteboards and slides into lines. | `Sources/DaybookIntelligence/Engines/AppleVisionEngine.swift:105-129` | On 26+, `RecognizeDocumentsRequest` (26.0: paragraphs, lists, tables) and `DetectLensSmudgeRequest` (26.0) beside sharpness. Keep VN* on 15. | M |
| AP-17 | low | Dates, times, and addresses in next steps and summaries are inert text. | `Sources/DaybookUI/Reading/Summary/SummaryBody.swift` | `.dataDetection(_:options:)` (iOS 27.0, macOS 27.2); Proposal 6 | S |
| AP-18 | low (verification) | Floating Notes and the call prompt rely on `sharingType = .none` to stay out of screen shares. This is unverified against current Zoom, Meet, and Teams sharing on macOS 27.2, and the notes are the most sensitive thing on screen during a call. | `Sources/Daybook/UI/NotesPanel.swift:106`; `Sources/Daybook/UI/CallPrompt.swift:203` | Test a full-screen share in each app on 27.2. If any captures the panel, say so in docs/interface.md and in the panel's first-use words. | S |
| AP-19 | low | The Mac has exactly one library `Window`. A conversation can't open in its own window or tab to read beside another one or during a recording, as Mail and Notes items can. | `Sources/Daybook/App/DaybookApp.swift:110` | `WindowGroup(for: UUID.self)` with `openWindow(value:)` ("Open in New Window", ⌘-double-click), reusing the reading page | L |

## Decisions recommended (owner decisions this lane touches)

- **hig-ios-14 (Time Sensitive for "the recorder is recording, this iPhone isn't"): yes.**
  - The owner adds `com.apple.developer.usernotifications.time-sensitive` to `local.daybook` (both apps share the ID).
  - Daybook sets `interruptionLevel = .timeSensitive` on that notification and the meeting-start prompt only.
  - Add a foreground "Record" `UNNotificationAction`.
  - A recording that's silently missing is exactly what Time Sensitive exists for.
- **MSCQ-25 (iCloud token archived with secure coding off): close it, keep the code.**
  - Nothing is decoded any more: the account is compared as bytes or a SHA-256 digest
    (`LibrarySyncController+Container.swift:431-439`).
  - The SDK declares the token as `id<NSObject,NSCopying,NSCoding>`, not `NSSecureCoding` (`NSFileManager.h:857`). So
    archiving with `requiringSecureCoding: true` (`LibrarySyncController.swift:141`) could fail, produce nil, and pause
    sync as "the iCloud account changed".
  - Archiving with secure coding off is not a decoding risk.
- **ux-mac-14 (fresh install on "Custom" vs the recommended preset): start on the recommended preset.** Make it cheap
  with Proposal 1: the first recordings transcribe with the system speech model while the preset downloads. The lean
  selection's reason (avoiding a second download before anything works) then goes away.
- **ux-mac-10 (Personal and "Use the cloud: Always"): Personal never goes to the cloud automatically.**
  - Personal counts down as Offer First and gets no cloud upgrade offers.
  - The same rule applies to every system surface added here: Personal never in Spotlight, never in entity suggestions
    or Siri AI context, never advertised by Handoff, never in widgets during a Work Focus (Proposal 8).
  - Never send it to Private Cloud Compute (below).

## Adopt now (27.2 SDK), with the symbols verified

| API | Availability found | For |
|---|---|---|
| `SpeechTranscriber`, `SpeechAnalyzer(inputAudioFile:modules:…)`, `AssetInventory.assetInstallationRequest(supporting:)`, `AnalysisContext.contextualStrings` / `.general` | anyAppleOS 26 | Proposal 1, AP-09 |
| `AssetInputSequenceProvider`, `AnalyzerInputConverter`, `SpeechAnalyzer.Options.ignoresResourceLimits` | anyAppleOS 27 | Proposal 1 on 27 (measure `ignoresResourceLimits` before use) |
| `SystemLanguageModel.tokenCount(for:)` | iOS/macOS 26.4 | AP-14, Proposal 2 |
| `SystemLanguageModel.variant`, `Variant.core3`/`.coreAdvanced3`, `ContextOptions.reasoningLevel`, `LanguageModelCapabilities.Capability.vision`, `Transcript.ImageAttachment`, `Attachment(_ uiImage:)` (`_FoundationModels_UIKit`) | iOS/macOS 27.0 | Proposal 2 |
| `IndexedEntity`, `@Property(indexingKey:)` (15.4/18.4), `@DeferredProperty`, `@ComputedProperty` (anyAppleOS 26), `CSSearchableItemAttributeSet.textContent/participants/duration/recordingDate/containerTitle` | macOS 15 / iOS 18 and up | Proposal 3a |
| `IndexedEntityQuery` (`reindexAllEntities`), `SyncableEntity`, `LongRunningIntent` / `performBackgroundTask(options:)`, `CSSearchableItemAttributeSet.relatedAppEntityIdentifier` | anyAppleOS 27.0 | Proposal 3 |
| `AppSchema.notes`: `.createNote`, `.updateNote`, `.appendText`; entities `.note`, `.folder`, `.account` (with `@AppIntent(schema:)`, `@AppEntity(schema:)`) | anyAppleOS 27.0 | Proposal 3c |
| `AppEntityAnnotatable.appEntityIdentifier` (on `NSUserActivity`) | macOS 15.2, iOS 18.2 | Proposal 3d |
| `AudioRecordingIntent` | macOS 15.0, iOS 18.0 | AP-13 |
| `SetFocusFilterIntent` | macOS 13, iOS 16 | Proposal 8 |
| `AVInputPickerInteraction` (AVKit) | iOS 26.0 | Proposal 4a |
| `AVAudioSessionPortDescription.bluetoothMicrophoneExtension` → `farFieldCapture` | iOS 26.0 (class) | Proposal 4b |
| `AVAudioSession.CategoryOptions.farFieldInput`, `AVAudioSession.Mode.dualRoute` (with `.multiRoute`) | iOS 26.2 | Proposal 4b, 4c |
| `CATapDescription.bundleIDs`, `isProcessRestoreEnabled` | macOS 26.0 | AP-08 |
| `GeometryProxy.reservedRegions(kind:)`, `ReservedRegion.Kind.division`, `UIView.reservedRegionsOfKind:`, `ArrangementView` + `.arrangementViewStyle(.split)` | anyAppleOS / iOS 27.1 | Proposal 5 |
| `View.presentationPlacement(_:)`, `PresentationPlacement.leading/.trailing` | anyAppleOS 27.0 | Proposal 5, AP-10 |
| `TranslationSession(installedSource:target:)` (26.0), `translations(from:)` (18/15), `Strategy.highFidelity`, `skipsTranslation` (26.4), `.translationPresentation` (iOS 17.4, macOS 14.4) | as listed | Proposal 6 |
| `View.dataDetection(_:options:)` (`_DataDetection_SwiftUI`) | iOS 27.0, macOS 27.2 | AP-17 |
| `ControlWidget`, `StaticControlConfiguration`, `ControlWidgetToggle` | macOS 26.0 | Proposal 7 |
| `supplementalActivityFamilies(_:)` (iOS 18.0), `isDynamicIslandLimitedInWidth` (iOS 27.0) | as listed | AP-15 |
| `RecognizeDocumentsRequest`, `DetectLensSmudgeRequest` | iOS/macOS 26.0 | AP-16 |
| `BGTaskScheduler.submitTaskRequest(_:)` async | iOS 27.0 | AP-12 |
| `textView(_:writingToolsIgnoredRangesInEnclosingRange:)`, `isWritingToolsActive` | iOS 18.0, macOS 15.0 | AP-07 |
| `LocalAuthenticationView` | macOS 13.0 | Proposal 8 |

## Adopt when 27.3 ships

- **Siri AI Developer Preview** (iOS, iPadOS, macOS, and visionOS 27.3 betas, announced 2026-11-03).
  - Apps bring content and actions into Siri AI through App Intents. Siri AI "can now surface any entity in the
    Spotlight semantic index, not just the ones that fit an existing schema", and "skills" combine several actions.
  - It requires an Apple Intelligence device in a supported language. It is unavailable in the EU on iOS, has daily
    server-side usage limits, opens App Store submission in spring, and reaches customers "in a few months".
  - Daybook's part is Proposal 3. Once it's done, "What did Priya say about pricing last week?" works through Siri
    without Daybook building its own question answering.
  - The 27.2 SDK has no 27.3 symbols, so nothing more can be verified yet. Re-check the App Intents interface in the
    Xcode 27.3 SDK for new entity, skill, or "personal context" types before building beyond Proposal 3.
- **iPhone Duo Reachability** on the cover display (27.3: an edge swipe from left or right). Verify the pocket
  recorder's controls and the library's edge gestures (Proposal 5).
- **StandBy for every iPhone** (27.3, per the 27.3 beta coverage). The Recorder and Next Steps `systemSmall` widgets
  appear in StandBy. Check them with the container background removed.

## Not worth it, and why

- **`PrivateCloudComputeLanguageModel` (27.0).** A server model behind a managed entitlement with eligibility
  requirements and a per-user quota (`QuotaUsage`). It would send transcripts off the device without the person adding
  a key, against docs/cloud.md's rule. If the owner ever wants a keyless cloud option, it belongs in Settings › Cloud as
  an explicit choice, never automatic, never for Personal.
- **`SpotlightSearchTool` "Ask your library" (`_CoreSpotlight_FoundationModels`, 27.0).** It works (a Foundation
  Models `Tool` over the app's own Core Spotlight index), but Siri AI in 27.3 does the same over the same index once
  Proposal 3 fills it. Build the index first and revisit only if Siri AI falls short.
- **The `LanguageModel` / `LanguageModelExecutor` protocols (27.0)** for wrapping MLX behind `LanguageModelSession`.
  Architectural tidiness with no change for the person, and 27-only.
- **Background Assets** (`BADownloaderExtension`, essential `BAURLDownload` from macOS 13.3/iOS 16.4; `AssetPackManager`
  26). Pre-installing models at app install mostly matters for the first transcript, which Proposal 1 solves. The model
  store's pinned commits and digest checks would need re-plumbing into an extension. Revisit if Apple-hosted packs
  become attractive under App Store distribution.
- **TipKit.** Teaching tips contradict the owner's minimal-copy rule (no explanatory subtitles).
- **Voice Processing, microphone modes, and `AVAudioApplication` input-mute gestures on the Mac.** Deliberately off
  because they duck and alter audio that Daybook's own echo removal and alignment handle
  (`Sources/Daybook/Capture/MicrophoneSource.swift:5-9`).
- **Call recording on iPhone.** Still no API in 27.2: CallKit and LiveCommunicationKit (`ConversationManager`,
  `TelephonyConversationManager`) are for calling apps, and TelephonyMessagingKit is SMS/RCS for default messaging
  apps. docs/iphone.md:51 still holds. The Phone app's own recordings can come in through the share sheet
  (`CFBundleDocumentTypes` public.audio in the iPhone Info.plist).
- **Visual Intelligence** (`AppSchema.visualIntelligence.semanticContentSearch`: iOS 26.0, macOS 27.0). Nobody finds a
  meeting by pointing a camera at something.
- **SuggestedActions (27.0).** Built around email and messages (`SuggestedActionsMessage` sender/recipients) and gated
  by the `com.apple.developer.suggested-actions` entitlement. Data detection (AP-17) covers the useful part.
- **PermissionKit** (family "ask to communicate"), **MediaIntelligence** `FaceGroupAnalyzer` (faces in photos),
  **StateReporting** (diagnostic state reporting), **CoreAI** (the 27.2 interface declares nothing), and **`AssistiveAccess`**
  scenes (a separate simplified app experience; low reach for a meeting recorder).
- **Genmoji and adaptive image glyphs in notes.** Notes are plain text by design (`isRichText = false`,
  `MarginNotesEditor+AppKit.swift:40`) and sync as text.
- **TextKit 2 for inline Writing Tools.** The lane's per-paragraph times read TextKit 1 baselines
  (`MarginNotesEditor+AppKit.swift:197`). The limited Writing Tools panel already works; AP-07 makes it safe.
- **Liquid Glass catch-up.** Not needed. Glass is widely adopted: `glassEffect` in 8 files, `GlassEffectContainer` in 4,
  `.glass` button styles in 8, `safeAreaBar` in 5, `scrollEdgeEffect` in 6, and `toolbarMinimizationBehavior` (27.0)
  already in `MacsSettings.swift:198`. `tabViewBottomAccessory` stays unused on purpose: the iPhone's combined tray is a
  documented design (docs/iphone.md:342). SwiftUI 27's `reorderable`, `alert(error:)`, `TabsPickerStyle`, and
  `ToolbarTitleAlignment` (27.2) have no clear Daybook use.

## Not findings (checked and fine)

- **Hinge.** `onHingeChange` and `UIHingeInteraction` (27.1) both feed `DevicePosture`, with the launch-posture gap
  handled (`Apps/iOS/DaybookPhone/Posture/DevicePosture.swift:129-199`). `DeviceHinge.angle` is used.
- **Handwriting.** `PKStrokeRecognizer` (actor, iOS/macOS 27.0) with a Vision fallback for other languages
  (`Sources/DaybookUI/Notes/NotesInk+UIKit.swift:131-160`), `UIScribbleInteraction`, and `UIPencilInteraction`.
- **The iPhone's audio session.**
  - `.bluetoothHighQualityRecording` (iOS 26.0), `setPrefersNoInterruptionsFromSystemAlerts`, and
    `setPrefersInterruptionOnRouteDisconnect(false)` (`AudioSession.swift:114-118`).
  - The 27.0 resumption-recommendation API (`AVAudioSessionResumptionRecommendationNotification`) is already noted in
    `AudioSession.swift:75-76` as a drop-in once the target reaches 27.
- **Background work.** `BGContinuedProcessingTask` with the `.fail` strategy (iOS 26.0) for processing; the GPU
  resource needs the owner's entitlement (docs/iphone.md:164).
- **Recording intents on the iPhone.** `AudioRecordingIntent` and `LiveActivityIntent`, plus `ToggleRecordingIntent`
  behind `RecordConversationControl` (`ControlWidgetToggle`).
- **Widgets and Live Activities.** `.privacySensitive()` on titles in the widgets and Live Activities.
- **Spotlight and Siri.** `CSSearchableIndex.indexAppEntities` and `deleteAppEntities` with a fresh start each run, and
  `updateAppShortcutParameters` debounced (`Apps/iOS/DaybookPhone/App/ConversationEntity.swift:106-207`). Personal is
  excluded from Spotlight and Siri on both apps.
- **Mac capture.** Core Audio process taps with `isPrivate` and `.unmuted` (`ProcessTapSource.swift:129-137`), and
  ScreenCaptureKit only as the display-audio fallback.
- **Continuity Camera on the Mac.** Take Photo, Scan Documents, and Add Sketch through `ImportFromDevicesCommands`
  (`Sources/Daybook/App/DaybookCommands.swift:24-26`).
- **Foundation Models for small tasks.** `@Generable` with `.anyOf` and `.maximumCount` guides, greedy sampling, and
  `.permissiveContentTransformations`, behind a 5-second availability cache.
- **Live captions.** `SpeechTranscriber` with `.volatileResults` and `.fastResults`, assets through `AssetInventory`,
  and nothing downloaded unasked.
- **Calendar access.** EventKit full access is required (event reads). Neither the iOS nor the macOS 27.2 SDK adds
  anything to EventKit.
- **A required change.** `submit(_:)` in BackgroundTasks is the only deprecation that affects Daybook in 27.0 (AP-12).
- **Obsoleted API.** `SystemLanguageModel.Adapter` is obsoleted in 27.0, and Daybook doesn't use it.
