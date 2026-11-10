import DaybookDesign
import DaybookKit
import SwiftUI

// Settings › Models' sections that both apps draw: Processing (whether this device transcribes, its quality presets
// where it has them, and the row that downloads what's chosen) and Model Library (what the models take here, and
// what each app adds there).

/// Processing: whether this device transcribes ("Transcribe on This iPhone"), the qualities it offers (the Mac's Quick,
/// Balanced, and Detailed), and the row that downloads what the choices still need.
public struct ModelProcessingSection<Presets: View>: View {
    private let toggleTitle: String
    private let isOn: Binding<Bool>
    private let presets: Presets
    private let download: ModelDownloadSummary?
    private let downloadName: String
    private let space: ModelSpace
    private let downloadAction: () -> Void
    private let cancelAction: () -> Void
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - toggleTitle: What turning it on does here, in sentence case; the iPhone title-cases it.
    ///   - download: What the choices still need, or nil when it's all here.
    ///   - downloadName: What that download is, in sentence case ("Transcription and speakers").
    public init(toggleTitle: String, isOn: Binding<Bool>, download: ModelDownloadSummary?, downloadName: String,
                space: ModelSpace = .unknown, downloadAction: @escaping () -> Void, cancelAction: @escaping () -> Void,
                @ViewBuilder presets: () -> Presets) {
        self.toggleTitle = toggleTitle
        self.isOn = isOn
        self.presets = presets()
        self.download = download
        self.downloadName = downloadName
        self.space = space
        self.downloadAction = downloadAction
        self.cancelAction = cancelAction
    }

    public var body: some View {
        Section {
            // The Mac's Settings draw every switch at the regular size; on the iPhone it's the only size.
            Toggle(ModelSettingsText.label(toggleTitle, density), isOn: isOn)
                .controlSize(.regular)
            presets
            if let download {
                ModelDownloadRow(download, name: downloadName, space: space, download: downloadAction, cancel: cancelAction)
            }
        } header: {
            Text("Processing")
        }
    }
}

extension ModelProcessingSection where Presets == EmptyView {
    /// Without presets: the iPhone's.
    public init(toggleTitle: String, isOn: Binding<Bool>, download: ModelDownloadSummary?, downloadName: String,
                space: ModelSpace = .unknown, downloadAction: @escaping () -> Void, cancelAction: @escaping () -> Void) {
        self.init(toggleTitle: toggleTitle, isOn: isOn, download: download, downloadName: downloadName, space: space,
                  downloadAction: downloadAction, cancelAction: cancelAction) { EmptyView() }
    }
}

/// Model Library: how much the downloaded models take here, then what the app adds (the Mac's Show in Finder beside the
/// size, old revisions, updates; the iPhone's models with Remove).
public struct ModelLibrarySection<Accessory: View, Rows: View>: View {
    private let total: Int64
    private let showsHeader: Bool
    private let accessory: Accessory
    private let rows: Rows
    @Environment(\.daybookDensity) private var density

    /// - Parameters:
    ///   - total: What the downloaded models take on this device.
    ///   - showsHeader: "Model Library" over it; not on the Mac's page of that name.
    ///   - accessory: Beside the size: the Mac's Show in Finder.
    ///   - rows: Under it.
    public init(total: Int64, showsHeader: Bool = true, @ViewBuilder accessory: () -> Accessory, @ViewBuilder rows: () -> Rows) {
        self.total = total
        self.showsHeader = showsHeader
        self.accessory = accessory()
        self.rows = rows()
    }

    public var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: DaybookSpacing.s3) {
                    Text(ByteSize.format(total)).monospacedDigit().foregroundStyle(.secondary)
                    accessory
                }
            } label: {
                Text(ModelSettingsText.label("Downloaded models", density))
            }
            rows
        } header: {
            if showsHeader { Text("Model Library") }
        }
    }
}

extension ModelLibrarySection where Accessory == EmptyView {
    public init(total: Int64, @ViewBuilder rows: () -> Rows) {
        self.init(total: total, accessory: { EmptyView() }, rows: rows)
    }
}
