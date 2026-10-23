# Notes, timestamps, and highlighted moments

Research checked against the official product documentation on 23 October 2026. This record separates documented behavior from Daybook's design choices and from device behavior that still needs a physical-device test. It is not a claim of feature parity with Granola or Soundcore.

## What Granola documents

### Notes guide the result

Granola's live note editor is a freeform space. What the user writes influences the enhanced notes; headings and bullets can also guide their structure. The user can leave the editor blank. The documentation therefore supports a combined workflow in which a transcript supplies conversational evidence while personal notes tell the system what matters. It does not document a timestamp for every typed paragraph. Daybook's paragraph timestamps are an additional design choice, not a claimed reproduction of a documented Granola feature. [Writing your own notes](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola)

Granola describes enhanced notes as a combination of the user's notes and the meeting transcript. Its raw and enhanced views provide separate ways to inspect those forms. This supports retaining original notes as independently editable material instead of replacing them with generated prose. Daybook preserves the raw notes, annotations, transcript runs, and generated summary as distinct records. [AI-enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)

### Detection and capture are different actions

Granola uses its own popup windows in the upper-right of the screen. A calendar reminder appears a minute before a meeting; clicking it opens the call and the corresponding note. Its documentation says the app can reposition its window beside a call, with a preference to disable that behavior. For ad hoc calls, microphone use triggers a prompt inviting the user to take notes. None of those statements establishes an always-visible floating panel across all macOS Spaces. [Notifications](https://docs.granola.ai/help-center/taking-notes/notifications)

Granola explicitly ties transcription to entering a note: clicking a notification, opening an already-started meeting, creating a new note, or remaining in an upcoming meeting's note until its scheduled start. It does not describe unattended transcription of every detected call. Its desktop capture uses microphone and system audio without a meeting bot. Daybook's user-enabled automatic recording is a separate requirement, with its own detection and stopping rules. [How transcription works](https://docs.granola.ai/help-center/taking-notes/transcription)

### Templates communicate purpose and structure

Granola permits choosing a template during a call or changing it afterward to regenerate notes. Its template guidance covers purpose and context, desired detail and style, and useful sections; it recommends testing and refining the result. Daybook uses those broad prompt-design principles with twelve original templates, editable instructions, and explicit per-meeting selection. No Granola template text is copied into Daybook. [Customize notes with templates](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates)

## What Soundcore documents

The official Work product page says a double tap marks important content, a vibration acknowledges the gesture, and highlighted content appears at the top of its summary. The same page says recordings cannot be exported over USB, initial setup uses its app, and Online Hub playback requires enabling cloud sync. Its transcription service temporarily processes audio in the cloud; the stated immediate deletion condition applies when Cloud Storage is disabled. These are vendor statements about its product, not validation of a third-party connection. [Soundcore Work product details](https://www.soundcore.com/products/d3200-soundcore-work-ai-voice-recorder)

The reviewed official page does **not** establish a public recording-download API, a marker export schema, the duration of the speech interval associated with each double tap, or whether an exported audio file carries marker metadata. Audio import alone must therefore not be described as importing device highlights. A direct Bluetooth implementation and any sidecar importer need their own fixture and hardware validation. The app should report the markers it actually receives and preserve their source timestamps; it must not synthesize missing device marks from unusually loud audio or apparent importance.

## Daybook implementation decisions

### One clock for local capture and annotations

The capture session records a shared monotonic host-clock origin. Microphone and computer audio remain separate files with offsets relative to that origin. The notes panel timer, new note anchors, and live highlight button use the recorder's elapsed time from the same clock. A wall-clock adjustment must not shift their positions in the recording.

Each nonempty note paragraph has a persistent identity and an optional meeting timestamp. A new paragraph typed while that meeting is recording receives the current capture time. Editing the paragraph keeps its original anchor. Insertions and deletions preserve unaffected neighbors; splitting existing text retains its originating anchor, and joining paragraphs retains the first originating anchor. A pre-meeting or post-meeting paragraph has no timestamp. Editing it later does not invent one. Legacy text with no stored anchors is seeded as untimed before an edit is reconciled.

These anchors describe when a thought was first written, not when every word in it was spoken. Long edits, pasted notes, and dictation into the editor can differ substantially from the speech timeline. The UI and synthesis input must preserve that distinction. A closed notes panel leaves notes in the meeting; its visibility is independent of recording ownership.

The panel uses a floating, movable, resizable native window that can join Spaces and appear alongside a full-screen call. This is the intended macOS presentation, not a guarantee against another application's higher window level. Full-screen, multiple-display, focus, and keyboard behavior still require interactive acceptance testing on the target Mac.

### Keep annotations separate from evidence

The summary input presents three distinct sources: recognized speech, the user's notes, and highlighted context. Speaker names come from assigned speaker identities; unidentified speech remains explicitly unknown. A private note is never inserted into the transcript as something somebody said. Timestamped versions of the notes are labeled as anchors for the same notes, so repetition is not presented as independent corroboration.

For a highlight on an aligned recording, the source time is transformed through that recording's offset and clock-drift rate. Daybook gathers speech from the common meeting timeline around the mark. For an unaligned recording, context stays in source-local time and comes from the latest transcript of that source. It must not pull an unrelated simultaneous-looking passage from another recording.

The default context window starts 30 seconds before a mark and ends 60 seconds after it, extended by any known marker duration. These are Daybook's initial retrieval parameters; they are not documented Soundcore semantics. They favor explanation around the marked point, since a user often marks a topic after hearing its key sentence. Missing speech stays missing, with an instruction to avoid inventing details. Highlighted evidence should receive extra explanation in the summary when the recording supports it, without overriding contradictory speech or treating a user's annotation as a quotation.

Clicking a timed note or aligned marker resolves the exact requested meeting time back to an available recording. It does not jump to the nearest transcript segment's start. During review, a new marker stores the selected recording's actual playback position and source ID. With neither active capture nor playback context, there is no meaningful zero-second default.

## Verification and remaining acceptance work

Automated coverage exercises stable paragraph identities, pre-/post-recording unknown times, paragraph edits and splits, persistence and restart, known and unknown speaker provenance, aligned and unaligned highlight context, and exact playback mapping with offset and drift. Library metadata tests cover independent edits, version precedence, and deletion markers so a stale device cannot resurrect a removed template or folder.

The synthetic suite does not open the microphone or record the host's environment. A physical acceptance pass must verify a deliberately recorded consented call, the floating panel in a full-screen meeting, microphone muting and unmuting, loss of recording permission, and recovery of partial audio. For Soundcore, use a known recording with multiple deliberate double taps and compare the phone app, exported audio/metadata, and direct-transfer result. Until that comparison passes, device marker export and direct-connection parity remain unverified.
