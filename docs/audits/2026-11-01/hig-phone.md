# HIG: iOS

Audit of 2026-11-01 against main at 57ed5eb. 20 confirmed findings, each fixed in the package named here; see [the summary](README.md) and docs/validation.md, "Audit and fixes (2026-11-01)".

| ID | Severity | Finding | Where | Package | Fixer's report |
|---|---|---|---|---|---|
| hig-ios-01 | high | In landscape the status sheet fills the screen and hides the whole library on every iPhone except the open Duo | `Apps/iOS/DaybookPhone/Status/StatusSheet.swift:91` | w2-status-sheet | fixed |
| hig-ios-02 | high | Table mode doesn't keep the screen on, so the Duo auto-locks partway through a meeting | `Apps/iOS/DaybookPhone/Recording/UI/RecordingSurface.swift:179` | w2-recorder-surface | — |
| hig-ios-03 | high | Tap targets far below 44 pt, including the side-by-side text links Use the Cloud and Start Now | `Apps/iOS/DaybookPhone/Reading/Components/PageComponents.swift:189` | w2-summary-page | partial |
| hig-ios-04 | medium | At accessibility text sizes the recording screen truncates Bookmark and Stop and squeezes the notes into one word per line | `Apps/iOS/DaybookPhone/Recording/UI/RecordingComponents.swift:157` | w2-recorder-surface | — |
| hig-ios-05 | medium | At accessibility sizes the status sheet's glyphs overlap their labels, its lines truncate, and the compact detent hides the list | `Apps/iOS/DaybookPhone/Status/StatusSheet.swift:452` | w2-status-sheet | fixed |
| hig-ios-06 | medium | VoiceOver isn't told when a recording starts, pauses, or saves | `Apps/iOS/DaybookPhone/UI/RootView.swift:24` | w2-recorder-surface | — |
| hig-ios-07 | medium | Correct Passage, a new template, and Add Term can be swiped away, losing what was typed | `Apps/iOS/DaybookPhone/Reading/Sheets/ReadingSheets.swift:174` | w2-transcript-page | fixed |
| hig-ios-08 | medium | Speaker profiles, voiceprints, and templates are deleted immediately, with no confirmation or undo | `Apps/iOS/DaybookPhone/Settings/SpeakerProfilesSettings.swift:139` | w2-inspector-people | fixed |
| hig-ios-09 | medium | Conversation titles show on the locked Lock Screen through the processing Live Activity and Now Playing | `Apps/iOS/DaybookPhone/Processing/PhoneProcessor.swift:226` | w2-models-processing | partial |
| hig-ios-10 | medium | Starting from Control Center, the Action button, Siri, or a widget fails when microphone access was never asked | `Apps/iOS/Shared/RecordingIntents.swift:48` | w2-phone-recording | fixed |
| hig-ios-11 | medium | The recording's Lock Screen Live Activity can exceed the 160 pt height limit | `Apps/iOS/DaybookPhoneWidgets/RecordingLiveActivity.swift:165` | w2-phone-recording | fixed |
| hig-ios-12 | low | The recording's compact and minimal presentations are a generic red dot, and level updates go out every 2 s | `Apps/iOS/DaybookPhoneWidgets/RecordingLiveActivity.swift:41` | w2-phone-recording | fixed |
| hig-ios-13 | low | Siri and Shortcuts get no spoken confirmation, and conversations aren't available as app entities | `Apps/iOS/Shared/RecordingIntents.swift:48` | w2-phone-recording | fixed |
| hig-ios-15 | low | At accessibility sizes the byline date is clipped and row titles truncate instead of wrapping | `Apps/iOS/DaybookPhone/Reading/Components/PageComponents.swift:285` | w2-library-list | fixed |
| hig-ios-16 | low | The library has two search entry points: a field at the top and a Search button at the bottom | `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift:37` | w2-library-list | fixed |
| hig-ios-17 | low | On the open Duo, the right-page cards and the large status panel can't be dismissed with the VoiceOver escape gesture or a swipe | `Apps/iOS/DaybookPhone/Reading/LibraryBrowser.swift:274` | w2-conversation-chrome | fixed |
| hig-ios-18 | low | The next-step haptic also fires on changes synced from the Mac, and starting a recording has no haptic | `Apps/iOS/DaybookPhone/Reading/Conversation/SummaryPage.swift:357` | w2-summary-page | fixed |
| hig-ios-19 | low | Liquid Glass buttons aren't grouped in a container, and the conversation's player has no scroll edge effect | `Apps/iOS/DaybookPhone/Reading/Conversation/ConversationScreen.swift:28` | w2-conversation-chrome | fixed |
| hig-ios-20 | low | On the open Duo, the library's buttons sit closer to the crease than allowed, and Open is an icon-only button | `Apps/iOS/DaybookPhone/Reading/Library/LibraryPage.swift:304` | w2-library-list | fixed |
| hig-ios-21 | low | Continued background processing is requested for automatic work as well as work the person started | `Apps/iOS/DaybookPhone/Processing/PhoneProcessor.swift:226` | w2-models-processing | fixed |

## Notes on partial fixes

- **hig-ios-03:** Fixed in this package's files: status text links get 44 pt targets through .daybookLink and are 24 pt apart under touch, and they wrap under the words instead of overflowing. Try Again uses the prominent style at regular size. The next-step circle and the bookmark chevron have 44 pt targets. TimeButton in PageComponents now uses daybookHitTarget. The colophon's Template and Summarize Again, and the next-step and margin times, use daybookHitTarget. Still open in other packages' files: Heard In in the iPhone TranscriptPage (w2-transcript-page), the player scrubber in PlayerViews (w2-conversation-chrome), and the status sheet's queue links (w2-status-sheet).
- **hig-ios-09:** Fixed in my files: the continued-processing task never shows a conversation's title. Its subtitle is '1 conversation' or 'N conversations' (PhoneProcessor.subtitle), and a test checks this with a Personal conversation. Left to others: Now Playing is w2-conversation-chrome's. The widgets' Data Protection (Complete) capability is an owner signing step and needs a device check; nothing changed.
