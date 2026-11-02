import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// Settings' Storage row on the Mac, as the iPhone's Settings has one: how much audio the library holds ("1.2 GB of
/// audio"), with Show… opening Storage in a sheet: the figures the iPhone shows (DaybookUI's `LibraryStorageSection`:
/// audio, conversations, and downloaded models) and the library folder with Show in Finder. Measured when it appears
/// and as the library changes, off the main actor.
struct StorageSettingsRow: View {
    let state: AppState
    @State private var report: LibraryStorageReport?
    @State private var showing = false

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s3) {
                if let report {
                    Text(StorageWords.audioSummary(bytes: report.audio, here: "this Mac")).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Show…") { showing = true }
            }
        } label: {
            Text("Storage")
        }
        .task(id: state.library.revision) {
            // A burst of edits is measured once, after it.
            if report != nil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            report = await Self.measure(state)
        }
        .sheet(isPresented: $showing) {
            StorageSettingsSheet(state: state, report: report) { showing = false }
        }
        #if DEBUG
        // `--storage-sheet` (with `--open-settings library`) opens Storage, for screenshots.
        .task { if CommandLine.arguments.contains("--storage-sheet") { showing = true } }
        #endif
    }

    /// The library folder and this Mac's downloaded models, measured off the main actor. The Mac keeps every recording,
    /// so none of its audio counts as downloaded. Its models are in the library folder, and count once, as models.
    static func measure(_ state: AppState) async -> LibraryStorageReport {
        let root = state.storageURL
        let modelsFolder = await state.runtime.modelsDirectory
        let models = await state.runtime.diskUsage().total
        return await Task.detached(priority: .utility) {
            LibraryStorageReport.measure(libraryRoot: root, downloaded: nil, models: models, excluding: [modelsFolder])
        }.value
    }
}

/// Storage in a sheet: the figures, then where the library is.
private struct StorageSettingsSheet: View {
    let state: AppState
    let report: LibraryStorageReport?
    let done: () -> Void

    var body: some View {
        SettingsFormSheet(title: "Storage", cancel: nil, confirm: .init("Done", perform: done)) {
            LibraryStorageSection(report: report)
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.storageURL]) }
                } label: {
                    Text("Library folder")
                    Text(SettingsPath.display(state.storageURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(state.storageURL.path)
                }
            }
        }
    }
}
