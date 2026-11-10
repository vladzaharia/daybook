# Audit of 2026-11-01

A whole-app audit of Daybook for Mac and iPhone, run as a workflow of agents against main at `57ed5eb`: two captures of every screen, 17 auditors, an adversarial verifier per area, a plan of 23 fix packages in two waves, a fixer and up to two review-and-repair rounds per package, integration with every suite, and a final code, design, and security review whose 14 issues were fixed too.

**340 findings confirmed and fixed**, one deliberately left (HIG-22 below), 8 that need the owner (below), and 28 rejected by the verifiers. What changed in each area, and how it was verified, is in docs/validation.md, "Audit and fixes (2026-11-01)".

| Area | Findings | High | Medium | Low |
|---|---|---|---|---|
| [Consistency: reading](consistency-reading.md) | 23 | 1 | 12 | 10 |
| [Consistency: recording and devices](consistency-recording.md) | 19 | 0 | 4 | 15 |
| [Consistency: Settings](consistency-settings.md) | 16 | 0 | 6 | 10 |
| [Consistency: design system](consistency-system.md) | 22 | 1 | 6 | 15 |
| [HIG: macOS](hig-mac.md) | 26 | 3 | 9 | 14 |
| [HIG: iOS](hig-phone.md) | 20 | 3 | 8 | 9 |
| [iCloud and sync](icloud.md) | 15 | 3 | 7 | 5 |
| [Motion and delight](motion.md) | 15 | 0 | 2 | 13 |
| [Security](security.md) | 8 | 0 | 2 | 6 |
| [Swift: core and kit](swift-core.md) | 22 | 0 | 6 | 16 |
| [Swift: Mac app](swift-mac.md) | 25 | 2 | 4 | 19 |
| [Swift: iPhone app](swift-phone.md) | 19 | 1 | 5 | 13 |
| [Swift: platform modules and scripts](swift-platform.md) | 20 | 0 | 2 | 18 |
| [UI: Mac](ui-mac.md) | 17 | 0 | 3 | 14 |
| [UI: iPhone](ui-phone.md) | 23 | 2 | 6 | 15 |
| [UX: Mac](ux-mac.md) | 23 | 3 | 11 | 9 |
| [UX: iPhone and cross-device](ux-phone.md) | 27 | 2 | 12 | 13 |

## Needs the owner

| ID | Area | Finding | Why |
|---|---|---|---|
| MSCQ-09 | swift-core | SNR weighting and the stored audio-alignment pipeline are dead in production, though the docs describe them | Wiring SNR in or deleting it is a product call. Wiring it in changes the fused wording of existing conversations, and the iPhone runs fusion too (LibraryController.realign, LibraryController.swift:449) without local audio. Its result would match the Mac's only if per-track profiles were stored in meeting.json and synced, which is a schema and sync-size decision. Deleting it removes a feature the owner documented. Until there's a decision, the safe interim fix is to correct docs/architecture.md:117, docs/alignment.md:25,127 and the FusionSummary.swift:141-143 comments to describe what ships. Decided 2026-11-10: deleted; stored alignments still read. |
| MSCQ-25 | swift-core | The iCloud account token is unarchived with secure coding off | The proposed fix assumes the ubiquity identity token's class supports NSSecureCoding. I couldn't confirm that here: the token exists only in an iCloud-entitled, team-signed build, which agents can't produce. If the assumption is wrong, a secure decode returns nil, sameAccount returns false whenever the archived bytes differ, and sync pauses with 'the iCloud account changed'. The owner needs to check the token's class (and that it round-trips with requiringSecureCoding: true) on a signed build before the change ships. Closed 2026-11-10: the token is compared as bytes or a digest, never decoded (`LibrarySyncController+Container.swift`). |
| ui-iphone-23 | ui-phone | Two search entry points on screen at once in the pocket library | The owner needs to decide which search entry stays. docs/iphone.md and the code comment at LibraryPage.swift:35 both prescribe a thumb Search button that opens the field under the title. navigationBarDrawer(displayMode: .automatic) has no mode that hides the field at rest. Keeping only the thumb button means changing search placement (for example, attaching searchable only while presented, or using iOS 26 toolbar placement). Removing the thumb button contradicts the doc. |
| ux-mac-10 | ux-mac | Personal conversations follow the cloud policy like any other: 'Always' sends a therapy session to the cloud, and upgrades nudge toward it | Product policy: should 'Use the cloud: Always' apply to conversations placed in Personal? Suggested default: Personal counts down (as Offer First) and gets no cloud upgrade offers. Automatic Personal filing can't be honored before the first summary, because the kind comes from the summary. |
| ux-mac-14 | ux-mac | A fresh install starts on 'Custom' models, not the recommended preset | Should a fresh install start on the recommended preset (reversing models.md's lean initialSelection, which avoids a second speaker-model download), or keep the lean selection and present it as the recommendation instead of 'Custom'? |
| hig-ios-14 | hig-phone | The "recorder is recording, this iPhone isn't" notification can be held by Focus and offers no action | Time Sensitive interruption needs the com.apple.developer.usernotifications.time-sensitive capability on local.daybook, which is a capability and signing change only the account owner can make. |
| xdev-settings-03 | consistency-settings | Settings is organized differently on each app: Mac has a TabView of 5 panes plus 3 separate windows, iPhone has a root list; 'Library' means different things | This reverses a documented design decision. SettingsView.swift:12 ('Direction A §5.14: five grouped panes') and interface.md:78 ('Settings has five panes') fix the Mac's tabbed Settings, and moving to a NavigationSplitView sidebar plus regrouping panes changes both apps' information architecture. The owner should choose between that restructure and the minimal alternative: rename or regroup so 'Library' means the same thing on both apps. |
| xdev-settings-08 | consistency-settings | Speaker and language processing settings exist only on the Mac; the iPhone processes its own recordings with fixed defaults | Two product decisions are open. First, ProcessingPreferences is per-device today (Mac UserDefaults), so even another Mac doesn't follow one Mac's choice: should speaker and language preferences become synced library settings or stay per device? Second, docs/iphone.md states the iPhone 'transcribes with speakers and voice profiles, as the Mac does, or not at all', which rules out a 'Tell speakers apart' switch there. A transcription-language choice on the iPhone is the least contentious part. |

## Status column in the area pages

Each area page gives the fixer's own report per finding: **fixed**; **partial**, which means the package fixed its own files and the rest fell to another package or to the integrator, who wired the halves together (docs/validation.md says how); **not fixed**, only HIG-22, a customizable Mac toolbar, built and then reverted because it broke the layout in 760 pt windows; or **—** where the fixer reported the package as a whole. Reviews and repairs after the fixer's report aren't reflected per finding.
