import AppKit
import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// Something the person asked for that couldn't be done, for the main window's alert: a title that
/// names it ("Couldn’t Import Audio"), one plain sentence with what to do, and the system's own
/// words only behind Details (docs/interface.md, principle 7).
struct AppProblem: Equatable, Identifiable {
    var title: String
    var message: String
    var details: String?
    /// The Privacy & Security pane that fixes it (the microphone, screen and system audio recording): the alert offers
    /// Open System Settings.
    var privacyPane: PrivacySettings.Pane?
    var id: String { [title, message, details ?? ""].joined(separator: "\u{1F}") }

    init(_ words: ProblemWords) {
        title = words.title
        message = words.message
        details = words.details
    }

    init(title: String, message: String, details: String? = nil) {
        self.init(ProblemWords(title: title, message: message, details: details))
    }

    /// Daybook's own errors (`PlainSentenceError`) already say what happened and what to do, so they're the message;
    /// the system's aren't, so they get `fallback` and keep their words for Details: the words both apps use
    /// (`ProblemWords`).
    init(title: String, fallback: String, error: Error?) {
        self.init(ProblemWords(title: title, fallback: fallback, error: error))
    }
}

// The Mac's own errors, written for people: a sentence, often with its fix.
extension RecordingError: PlainSentenceError {}
extension PCMTrackWriterError: PlainSentenceError {}
extension SandboxMigration.MoveError: PlainSentenceError {}

/// A full disk, in the words a person needs: how much to free.
enum DiskSpace {
    /// Whether `error`, or an error under it, is the disk running out of space.
    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let error = current else { return false }
            if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// "This Mac is out of space. Free up 1.6 GB and try again."
    static func freeUpSentence(_ bytes: Int64) -> String {
        "This Mac is out of space. Free up \(bytes > 0 ? ByteSize.format(bytes) : "some space") and try again."
    }
}

extension AppState {
    /// Shows a problem in the main window's alert. `fallback` is the plain sentence used when the
    /// error itself isn't one of Daybook's own.
    func report(_ title: String, _ fallback: String, _ error: Error? = nil) {
        problem = AppProblem(title: title, fallback: fallback, error: error)
    }

    /// The problem the window shows: one reported here, else a library save that failed.
    var shownProblem: AppProblem? {
        if let problem { return problem }
        guard let message = library.errorMessage else { return nil }
        return AppProblem(title: "Couldn’t Save Changes", message: message, details: library.errorDetails)
    }

    func dismissProblem() {
        problem = nil
        library.errorMessage = nil
        library.errorDetails = nil
    }
}

/// The library couldn't open (`AppState.libraryProblem`): said on the page, with the system's words behind Details…,
/// Show in Finder for the library folder, and Try Again, rather than in an alert over an empty window. Relaunching
/// rarely helps: what stops a folder opening (its permissions, a damaged or missing folder) is still there.
struct LibraryProblemPage: View {
    let state: AppState
    let problem: AppProblem
    @State private var retrying = false

    var body: some View {
        // Where the empty library's words would be: nothing else is on the page.
        box
            .frame(maxWidth: DaybookStyle.measure)
            .padding(.horizontal, Space.s6)
            .offset(y: -24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DaybookStyle.paper)
    }

    /// A problem box in `AttentionBox`'s inks and wash: the warning glyph in its column, the title and the sentence, and
    /// the actions under them on the words' edge (three, with Details…, never fit beside them at the measure). Drawn
    /// here because the shared box fixes its words' height, which, outside a scroll view, makes the split view taller
    /// than the window and pushes the sidebar under the title bar.
    private var box: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Ink.warning)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(problem.title).font(TypeStyle.statusLead).foregroundStyle(AttentionBoxLayout.title(for: .problem).ink.color)
                    Text(problem.message).font(TypeStyle.status).foregroundStyle(AttentionBoxLayout.message(for: .problem).ink.color)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: Space.s3) { actions }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s3)
        .background(AttentionBoxLayout.wash(for: .problem).color, in: DaybookRadius.shape(DaybookRadius.box))
    }

    @ViewBuilder private var actions: some View {
        if let details = problem.details { DetailsButton(details: details).buttonStyle(.daybookLink) }
        Button("Show in Finder") { state.showLibraryInFinder() }
            .buttonStyle(.daybookLink)
        Button("Try Again") {
            retrying = true
            Task { await state.retryOpeningLibrary(); retrying = false }
        }
        .buttonStyle(.borderedProminent)
        .tint(DaybookStyle.prominentFill)
        .disabled(retrying)
    }
}

extension AppState {
    /// Opening the library again from its problem, as launching does.
    func retryOpeningLibrary() async {
        libraryProblem = nil
        await initialize()
    }

    /// The library folder in Finder, or the folder it should be in when it's missing.
    func showLibraryInFinder() {
        let exists = FileManager.default.fileExists(atPath: storageURL.path)
        NSWorkspace.shared.activateFileViewerSelecting([exists ? storageURL : storageURL.deletingLastPathComponent()])
    }
}

/// Details… from a problem's alert: what happened, then the system's own words, selectable.
struct ProblemDetailsSheet: View {
    let problem: AppProblem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(problem.title).font(.headline)
            Text(problem.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(problem.details ?? "")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s2)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s4)
        .frame(width: 420)
    }
}
