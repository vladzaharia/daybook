import DaybookDesign
import DaybookKit
import SwiftUI

/// "Recent imports" on a recorder's page: what the library holds from it, newest first, each opening its
/// conversation (with what's happening to it), and every recording that didn't come off it, with why and Try Again.
/// The failure the problem box above already retries isn't offered again. On the iPhone a row also swipes, and on
/// both it has the same actions in its context menu.
public struct RecentImportsSection: View {
    private let session: DeviceSession
    private let limit: Int
    @Environment(\.recorderServices) private var services

    public init(session: DeviceSession, limit: Int = 10) {
        self.session = session
        self.limit = limit
    }

    /// One row: an import, or a recording that didn't import.
    public enum Entry: Identifiable, Equatable {
        case imported(DeviceLibraryLinks.Entry)
        case failed(DeviceImportFailure)

        public var id: String {
            switch self {
            case .imported(let entry): return entry.trackID.uuidString
            case .failed(let failure): return "failed:" + failure.id
            }
        }

        public var date: Date {
            switch self {
            case .imported(let entry): return entry.importedAt
            case .failed(let failure): return failure.date
            }
        }
    }

    /// Imports and failures merged by date, newest first, at most `limit`.
    public static func entries(recent: [DeviceLibraryLinks.Entry], failures: [DeviceImportFailure], limit: Int = 10) -> [Entry] {
        Array((recent.map(Entry.imported) + failures.map(Entry.failed)).sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The failure the problem box's Try Again retries, which its row doesn't offer again.
    public static func retriedAbove(problem: DeviceProblem?, failures: [DeviceImportFailure]) -> String? {
        guard let problem, problem.isTransferProblem, problem.actions.contains(.tryAgain) else { return nil }
        return failures.first?.id
    }

    public var body: some View {
        let entries = Self.entries(recent: session.links.recent, failures: session.failures, limit: limit)
        if !entries.isEmpty {
            let retried = Self.retriedAbove(problem: RecorderProblemBox.shownProblem(session), failures: session.failures)
            Group {
                RecorderPageHeading("Recent imports")
                ForEach(entries) { entry in
                    switch entry {
                    case .imported(let item): imported(item)
                    case .failed(let failure): failed(failure, offersTryAgain: failure.id != retried)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func imported(_ item: DeviceLibraryLinks.Entry) -> some View {
        let meeting = services?.library.meeting(item.meetingID)
        let detail = [Self.label(item, session: session), meeting.flatMap { services?.processingLabel($0.id) }].compactMap { $0 }
        return Button { if meeting != nil { services?.showConversation(item.meetingID) } } label: {
            RecentImportRow(symbol: "checkmark.circle.fill", symbolInk: DaybookPalette.Ink.meta) {
                Text(meeting?.title ?? Self.label(item, session: session))
                    .daybookFont(.body)
                    .foregroundStyle(meeting == nil ? DaybookPalette.Ink.body : DaybookPalette.Ink.link)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if meeting != nil {
                    Text(detail.joined(separator: " · ").keepingSeparators)
                        .daybookFont(.status)
                        .foregroundStyle(DaybookPalette.Ink.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            } trailing: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(meeting == nil ? "" : "Opens the conversation")
        .contextMenu {
            if meeting != nil {
                Button("Show Conversation") { services?.showConversation(item.meetingID) }
            }
            if let reveal = services?.revealAudio, meeting != nil {
                Button("Show Audio File in Finder") { reveal(item.meetingID, item.recordingID) }
            }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if meeting != nil {
                Button("Show") { services?.showConversation(item.meetingID) }.tint(DaybookPalette.prominentFill)
            }
        }
        #endif
    }

    private func failed(_ failure: DeviceImportFailure, offersTryAgain: Bool) -> some View {
        RecentImportRow(symbol: "exclamationmark.triangle.fill", symbolInk: DaybookPalette.Ink.warning) {
            Text(failure.recording.title)
                .daybookFont(.body)
                .foregroundStyle(DaybookPalette.Ink.body)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Text(failure.message)
                .daybookFont(.status)
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            if offersTryAgain {
                Button("Try Again") { session.retry(failure) }
                    .buttonStyle(.daybookLink)
                    .daybookFont(.status)
                    .accessibilityLabel("Try Again: \(failure.recording.title)")
            }
        }
        .contextMenu {
            Button("Try Again") { session.retry(failure) }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Try Again") { session.retry(failure) }.tint(DaybookPalette.prominentFill)
        }
        #endif
    }

    /// "Mon, Oct 19, 4:00 PM" for a recorder's recording (with "(live)" for what Listen Live saved), the file's name
    /// for an export.
    static func label(_ entry: DeviceLibraryLinks.Entry, session: DeviceSession) -> String {
        // Daybook on iPhone's recordings are named by a UUID; when they arrived says more.
        if session.kind.id == DaybookPhoneIntegration.id { return DeviceDateFormat.title(entry.importedAt) }
        let identity = DeviceRecordingIdentity(kind: session.kind.id, serial: session.recorderSerial, recordingID: entry.recordingID)
        if let date = DeviceRecordingStart.date(of: identity) {
            let title = DeviceDateFormat.title(date)
            return entry.recordingID.hasSuffix(DeviceLibraryLinks.partialSuffix) ? "\(title) (live)" : title
        }
        if entry.recordingID.hasPrefix("file:") {
            return String(entry.recordingID.dropFirst(5).split(separator: "|").first ?? Substring(entry.fileName))
        }
        return entry.fileName
    }
}

/// A row of Recent imports: its glyph in a column, its two lines, and an action at its end.
private struct RecentImportRow<Lines: View, Trailing: View>: View {
    let symbol: String
    let symbolInk: Color
    @ViewBuilder var lines: Lines
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s3) {
            Image(systemName: symbol)
                .foregroundStyle(symbolInk)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) { lines }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, DaybookSpacing.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: Trailing.self == EmptyView.self ? .combine : .contain)
    }
}
