import DaybookDesign
import DaybookKit
import SwiftUI

/// Settings › Storage's figures, the same on both apps: how much room Daybook takes on this device, then its audio
/// (what was recorded here and what was downloaded, where that's told apart), everything else its conversations keep,
/// and downloaded models. Measured from the library's files (`LibraryStorageReport`), so they're right with sync off.
/// Each app adds its own sections after it: the iPhone's Keep Up To, Clear Downloaded Audio, and backups; the Mac's
/// library folder.
public struct LibraryStorageSection: View {
    private let report: LibraryStorageReport?
    @Environment(\.daybookDensity) private var density

    /// - Parameter report: Nil while it's measured.
    public init(report: LibraryStorageReport?) { self.report = report }

    private var here: String { "this \(ICloudSyncShown.device)" }

    public var body: some View {
        Section {
            if let report {
                Text(ByteSize.format(report.total))
                    .font(density == .touch ? .title2.weight(.semibold) : .system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .padding(.vertical, density == .touch ? 4 : 2)
                    .accessibilityLabel("\(ByteSize.format(report.total)) on \(here)")
                figure("Audio", report.audio, detail: StorageWords.audioBreakdown(report, here: here))
                figure("Conversations", report.conversations)
                figure("Models", report.models)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(StorageWords.section(device: ICloudSyncShown.device))
        }
    }

    private func figure(_ title: String, _ bytes: Int64, detail: String? = nil) -> some View {
        LabeledContent {
            Text(ByteSize.format(bytes)).monospacedDigit()
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

/// A meter of the audio this device keeps against how much it may keep (the iPhone's Keep Up To while it syncs):
/// neutral ink, because it's neither an action nor work in progress.
public struct StorageBudgetMeter: View {
    private let bytes: Int64
    private let budget: Int64
    @Environment(\.daybookDensity) private var density

    public init(bytes: Int64, budget: Int64) {
        self.bytes = bytes
        self.budget = budget
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
            Text("\(ByteSize.format(bytes)) of \(ByteSize.format(budget))")
                .font(density == .touch ? .subheadline : .system(size: 12))
                .monospacedDigit()
                .foregroundStyle(DaybookPalette.Ink.secondary)
            ProgressView(value: min(1, Double(max(0, bytes)) / Double(max(1, budget))))
                .tint(DaybookPalette.Ink.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
