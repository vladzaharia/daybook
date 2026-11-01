#if DEBUG
import DaybookCaptions
import DaybookKit
import Foundation

/// Debug only: `--library-demo` (or `--demo-library`), with `--library <scratch folder>`, fills the library with the
/// conversations the Mac's demo has, in every state the reading screens show (DaybookKit's `ReadingDemo`), so an
/// iPhone screenshot and a Mac snapshot of one conversation show the same content. This iPhone's saved live captions
/// go through its caption store. Nothing is written when the library already has the demo.
@MainActor
enum DemoLibrary {
    static var isRequested: Bool { ReadingDemo.isRequested }

    static func seed(_ library: LibraryController, rootURL: URL, now: Date = Date()) {
        guard isRequested, library.isLoaded else { return }
        let store = LiveCaptionStore(libraryRoot: rootURL)
        let finishing = ReadingDemo.seed(library, as: .iPhone, now: now) { meetingID, trackID, locale, lines in
            try? store.save(LiveCaptions(meetingID: meetingID, trackID: trackID, localeIdentifier: locale, segments: lines.map { line in
                LiveCaptionSegment(start: line.start, end: line.end, text: line.text, isTentative: line.isTentative,
                                   speaker: line.speakerSlot.map { LiveCaptionSpeaker(slot: $0, name: line.speakerName) })
            }))
        }
        // `--speaker-demo`: speakers recognized, suggested, and named, and their profiles.
        if SpeakerProfileDemo.isRequested {
            Task {
                await finishing?.value
                await SpeakerProfileDemo.seed(library, now: now)
            }
        }
    }
}
#endif
