# Design pass of 2026-11-10

A whole-app design pass of Daybook for Mac and iPhone, run nine days after the [audit of 2026-11-01](../2026-11-01/README.md), with the owner's authority to redesign. Eight reviewers (visual UI on the Mac and on the iPhone and Duo, UX flows, code quality, security and privacy, Apple platform adoption against the installed 27.2 SDKs, the audio pipeline and hardware, and networking and multipoint) looked at 237 captured screens (the Mac at 760–2560 pt in light and dark; the iPhone 18 Pro and the Duo closed, open, and in table mode, at default and accessibility text sizes) and the code, and wrote 219 findings and 62 redesign proposals. The owner's eight open decisions from the previous audit were decided here. Twenty-two fix and redesign packages then ran in parallel worktrees, each with its own tests and captures, and were merged on `design-pass-2026-11` (stacked on PR #61). What each changed and how it was verified is in [docs/validation.md](../../validation.md), "Design pass (2026-11-10)".

| Area | Findings | High | Medium | Low | Proposals |
|---|---|---|---|---|---|
| [Visual: Mac](visual-mac.md) | 25 | 0 | 8 | 17 | 8 |
| [Visual: iPhone and Duo](visual-iphone.md) | 23 | 2 | 8 | 13 | 7 |
| [UX flows and the open decisions](ux-flows.md) | 18 | 2 | 8 | 8 | 8 |
| [Code quality and one codebase](code-quality.md) | 25 | 0 | 5 | 20 | 8 |
| [Security and privacy](security.md) | 15 | 1 | 8 | 6 | 7 |
| [Apple platform, 27.2 and 27.3](apple-platform.md) | 19 | 0 | 8 | 11 | 8 |
| [Audio pipeline and hardware](audio-hardware.md) | 48 | 6 | 33 | 9 | 8 |
| [Networking and multipoint](network-multipoint.md) | 46 | 8 | 20 | 18 | 8 |

## What the pass changed

The reviews agreed on a handful of things that mattered more than any list of findings, and the pass built them:

- **A first recording produces a transcript in minutes, on both apps.** The Mac transcribes as soon as the transcription models are here and summarizes when it can (transcript first), and where the chosen model isn't installed, Apple's on-device speech engine stands in with nothing to download, with the existing Upgrade offer redoing the transcript once the chosen model arrives. A fresh Mac starts on its recommended preset, never "Custom".
- **A recording ends only when someone stops it.** On the Mac a busy disk, a timing gap, a microphone restart, or a stalled source no longer ends the recording; a rolling hearing check and a free-space watch say when it can't hear or is running out of room; a closed lid leaves the devices recording along. On the iPhone a stop from the Lock Screen runs in two steps under background time, joins are packet copies (no second-generation AAC), and a paused recording says so. A Soundcore Start goes ahead of a running import, and live audio survives a lost packet or a dropped link. A device recording because another asked follows it on evidence, not thirty minutes of silence.
- **The page reads as a document.** In the Mac's window the summary is typeset at 15/24 on a 560 pt measure with one lane of times in the margin, marks hanging outside the text, and status beside its words; from 1120 pt the summary and the transcript sit side by side as a spread. On touch every next step puts its owner and time on one line under it.
- **The iPhone library is an iOS 26 app.** The standing status sheet became a bottom toolbar (Record, the system's minimized search, a "+" menu) with one status strip that appears only when something is happening or needs the person; the status sheet lists only devices that exist. The open Duo's left page keeps its navigation bar, its spine is a gutter with bookmarks on the scrubber, the recorder rests expanded on the right page, and the handwriting tools live in the control layer.
- **Personal stays on the device and out of sight.** Under "Use the cloud: Always" a Personal conversation counts down to the device instead; the cloud is a tap per conversation and never an Upgrade offer. Personal titles leave the Recorder widget and the Live Activity, captions never reach a locked Lock Screen, Spotlight holds titles and dates only on both apps, an encrypted library's settings files stay out of iPhone backups, and an optional Touch ID / Face ID lock hides Personal until the person unlocks it.
- **One codebase, kept that way.** Dormant copies and dead code are gone, the drift checks fail instead of skip, two more modules build with strict concurrency, CI fails on a first-party warning, the iPhone tests share the package's test support, and each app has one action dispatcher (which fixed Work/Personal's missing Undo from the More menu).
- **Platform work with the SDK as the referee.** Privacy manifests on both apps and the widgets, Writing Tools that leave handwriting alone and time nothing during a recording, Core Audio following a call app's helpers on macOS 26, the system captions biased to the vocabulary, Live Activities with a small family, a microphone choice on both apps that never puts idle headphones into call mode, and far-field AirPods capture on iOS 26.2.
- **Multipoint and captions that keep up.** Live captions from every source merge off the main actor at a flat cost (about 0.07 ms per update at four hours, from up to 200 ms per rebuild), one line per utterance from the source that heard it best, replaced per recording. Awaited audio says where it is and says when it didn't arrive. The courier delivers before it expires a record. One timing model per track bounds clock rates to physics and fusion can't double words at a region cut.

## Decisions

The previous audit left eight decisions to the owner; the owner delegated them to this pass. Each is recorded in [the 2026-11-01 README](../2026-11-01/README.md) too.

| ID | Decision |
|---|---|
| ux-mac-10 | Personal is never sent to the cloud on its own. Under Always it counts down as Offer First does, with Use the Cloud as a tap, and it gets no cloud Upgrade offers. The same rule covers every surface outside the app. |
| ux-mac-14 | A fresh Mac starts on its recommended preset, never "Custom"; the first recordings transcribe with the system's speech model while the preset downloads. |
| ui-iphone-23 | One search entry, the system's minimized bottom-bar search; the custom Search circle is gone. |
| xdev-settings-03 | Each platform keeps its own Settings structure (the Mac's sidebar, the iPhone's list). "Library" means the library's own things on both: the Mac's Library page gained Summary templates, Vocabulary, and Speaker profiles, and Settings search covers what each page holds. |
| xdev-settings-08 | Transcription language is a synced library setting shown on both apps under Settings › Models › Transcription; speaker settings and the Other languages model stay per device, on the Mac. |
| MSCQ-09 | The unreachable SNR weighting and the stored-alignment writer were deleted; stored alignments from v0.2.2 are still read and fused. Per-source quality weighting, if it returns, comes from data that already syncs, behind a fusion version. |
| MSCQ-25 | Closed. The iCloud account token is compared as bytes or a digest and never decoded, so secure coding on archiving is moot. |
| hig-ios-14 | Add the Time Sensitive capability to `local.daybook` (owner action); the app already marks "Recording stopped" and the new "Recording paused" time sensitive and they are delivered as ordinary notices until the capability exists. |

## Needs the owner

| What | Why |
|---|---|
| Hardware acceptance | Every capture, device, link, and multipoint change was verified against fakes, the Soundcore simulator, loopback links, and the iPhone simulators. The lane pages and docs/validation.md list the checks that need real AirPods, a Soundcore Work, two Macs and an iPhone, a lid close, an external disk, and a real iCloud account. |
| `sharingType = .none` on screen shares | Floating Notes and the call prompt stay out of screen shares only if ScreenCaptureKit honours the window's sharing type; public reports say macOS 15+ ignores it. Check a full-screen share in Zoom, Meet, and Teams on 27.2 before relying on it (security F-06, platform AP-18). |
| Time Sensitive notifications | Enable the capability on the App ID and add `com.apple.developer.usernotifications.time-sensitive` to the iPhone's entitlements. |
| The App Sandbox for the Developer ID build | Still the planned release N+1 switch (docs/sandbox.md); the security review ranks it as the fix for any process on the Mac reading the whole library without a prompt. |
| A link courier for the iPhone's audio | The network review's largest proposal sends a recording to the Mac over the encrypted local link at Stop, giving a second copy in seconds and one summary. It reverses docs/link.md's "audio never travels over the link", so it waits for the owner's sign-off. |
| Compact originals, whole-conversation playback, a second recorder brand | The audio review's larger proposals (ALAC/Opus originals instead of 2.3 GB/h of Float32, mixed level-matched playback from one per-track analysis, a device abstraction a second brand can use) change storage commitments and are left as the roadmap. |
| Apple Intelligence summaries and Mac widgets | A provisional on-device summary where no local model is installed reverses a documented model decision and needs the October evaluation rerun on 27.2; Mac widgets need an app group the owner signs. |
| Corrections as word spans | A person's correction can still lose or double words when a higher-priority recording joins after it (network FU-01); the fix changes how corrections are stored and is left for a pass of its own. |

## Still to do

Scheduled after this pass's merges, in the order the code-quality review ranked them: lifting the last small features drawn twice into the shared libraries (the level meter, Version History, the Use Calendar row, the device glyph, Spotlight's plan, the problem words, the countdown words), one token vocabulary across both apps, the shared status overview on the Mac, and the `AppState` split; the synced transcription language (xdev-settings-08); the iPhone's class-B file protection for recordings in progress, now that Stop runs in two steps; and the live-caption levels on the iPhone.
