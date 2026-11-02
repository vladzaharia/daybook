#if DEBUG
import DaybookKit
import Foundation

// Debug-only: `--vocabulary-demo` and `--templates-demo` fill a scratch library's vocabulary or templates, for
// screenshots of Vocabulary and Summary Templates on either app. Only with `--library`, whose library they write
// to, and only into an empty vocabulary, or templates that are all built-in.

@MainActor
enum VocabularyDemo {
    static func apply(to library: LibraryController, arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--library"), arguments.contains("--vocabulary-demo"), library.isLoaded, library.glossary.isEmpty else { return }
        // A term from a conversation (one is made in an empty library), and one from a conversation that's gone.
        let conversation = library.meetings.first(where: { $0.title == "Weekly product sync" })?.id ?? library.meetings.first?.id
            ?? library.newMeeting(title: "Weekly product sync with the design and research teams")
        [GlossaryTerm(term: "Daybook", aliases: ["day book"], definition: "The app", approved: true),
         GlossaryTerm(term: "Soundcore Work", definition: "The recorder clipped to a lapel", approved: true),
         GlossaryTerm(term: "Parakeet", aliases: ["Parakeet Ultra"], definition: "", approved: true),
         GlossaryTerm(term: "Kubernetes", aliases: ["cooper netties"], definition: "Container orchestration; also k8s", approved: false,
                      sourceMeetingIDs: [conversation]),
         GlossaryTerm(term: "Ximena Oyelaran-Castellanos", definition: "", approved: false, sourceMeetingIDs: [UUID()])]
            .forEach(library.saveGlossaryTerm)
    }
}

@MainActor
enum TemplatesDemo {
    static func apply(to library: LibraryController, arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--library"), arguments.contains("--templates-demo"), library.isLoaded,
              library.templates.allSatisfy(\.isBuiltIn) else { return }
        library.saveTemplate(SummaryTemplate(name: "Board update", kind: .general, instructions: "Lead with the numbers, then risks and asks."))
        library.saveTemplate(SummaryTemplate(name: "Quarterly customer advisory council debrief and follow-ups", kind: .interview,
                                             instructions: "Group feedback by theme. Quote customers where they're specific."))
        library.saveTemplate(SummaryTemplate(name: "", kind: .general, instructions: ""))
        // The one the Mac's window opens on, which takes this edit in as the other device's would.
        if var edited = library.templates.first(where: \.isBuiltIn) {
            edited.instructions += " Keep it under a page."
            library.saveTemplate(edited)
        }
    }
}
#endif
