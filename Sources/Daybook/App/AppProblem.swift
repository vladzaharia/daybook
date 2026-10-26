import DaybookCore
import DaybookKit
import SwiftUI

/// Something the person asked for that couldn't be done, for the main window's alert: a title that
/// names it ("Couldn’t Import Audio"), one plain sentence with what to do, and the system's own
/// words only behind Details (docs/interface.md, principle 7).
struct AppProblem: Equatable, Identifiable {
    var title: String
    var message: String
    var details: String?
    var id: String { [title, message, details ?? ""].joined(separator: "\u{1F}") }

    init(title: String, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details.flatMap { $0.isEmpty || $0 == message ? nil : $0 }
    }

    /// Daybook's own errors already say what happened and what to do, so they're the message; the
    /// system's aren't, so they get `fallback` and keep their words for Details.
    init(title: String, fallback: String, error: Error?) {
        guard let error else {
            self.init(title: title, message: fallback)
            return
        }
        if Self.speaksPlainly(error) {
            self.init(title: title, message: error.localizedDescription)
        } else if case DaybookError.saveFailed(let reason) = error {
            self.init(title: title, message: fallback, details: reason)
        } else {
            self.init(title: title, message: fallback, details: error.localizedDescription)
        }
    }

    /// Errors written for people: a sentence, often with its fix.
    static func speaksPlainly(_ error: Error) -> Bool {
        switch error {
        case is RecordingError, is PCMTrackWriterError, is PhotoStoreError, is LibraryError: return true
        case let error as DaybookError: if case .saveFailed = error { return false } else { return true }
        default: return false
        }
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
