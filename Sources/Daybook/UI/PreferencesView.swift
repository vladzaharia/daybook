import AppKit
import CoreGraphics
import DaybookCore
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var showTemplates = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Make yourself at home").font(.system(size: 25, weight: .medium, design: .serif))
                    Text("Local models, recording, and your library.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(26)
            Picker("Settings", selection: $tab) {
                Text("Models & quality").tag(0); Text("Recording & imports").tag(1); Text("Storage & sync").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 26).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == 0 { modelSettings }
                    else if tab == 1 { recordingSettings }
                    else { storageSettings }
                }.padding(26)
            }
        }.tint(DaybookStyle.accent)
            .sheet(isPresented: $showTemplates) { TemplatesView(state: state).frame(width: 900, height: 680) }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Models download from Hugging Face. Transcription, speaker analysis, and summaries always run on your Mac. Library sync is optional.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("Starting points").font(.headline)
                HStack {
                    Button("Quick") { applyPreset(transcription: "whisper-base", summary: "qwen-1.5b", quality: .fast) }
                    Button("Balanced") { applyPreset(transcription: "whisper-small", summary: "qwen-3b", quality: .balanced) }
                    Button("Detailed") { applyPreset(transcription: "whisper-large-turbo", summary: "qwen-7b", quality: .accurate) }
                }.controlSize(.small)
                Text("Each stage can be adjusted below. These buttons select models; use Download to install any missing ones. Larger models and detailed analysis take more time and memory, and results still depend on the recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let downloading = state.downloadingID {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Downloading \(DaybookModelCatalog.models.first { $0.id == downloading }?.name ?? downloading)").font(.headline); Spacer(); Button("Cancel") { state.cancelDownload() } }
                    ProgressView(value: state.downloadProgress.fraction)
                    Text(state.downloadProgress.message).font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(DaybookStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            modelSection("Transcription", role: .transcription)
            Text("Selections apply to new processing requests. To apply a different speech model to an existing conversation, choose Re-transcribe audio. Earlier runs and correction history remain available.").font(.caption).foregroundStyle(.secondary)
            modelSection("Notes & summaries", role: .summarization)
            Button { showTemplates = true } label: { Label("Manage summary templates…", systemImage: "doc.text") }
            modelSection("Speaker detection", role: .diarization)
            SpeakerQualitySettingsView(state: state)
        }
    }

    private func modelSection(_ title: String, role: LocalModelRole) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(DaybookModelCatalog.models.filter { $0.role == role }) { model in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: role == .transcription ? "waveform" : role == .summarization ? "sparkles" : "person.2.wave.2")
                        .foregroundStyle(DaybookStyle.accent).frame(width: 22).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(model.name).font(.callout.weight(.semibold)); if isSelected(model) { Text("SELECTED").font(.system(size: 8, weight: .bold)).foregroundStyle(DaybookStyle.accent).padding(.horizontal, 5).padding(.vertical, 3).background(DaybookStyle.accent.opacity(0.09), in: Capsule()) } }
                        Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("About \(ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)) · \(model.recommendedMemoryGB) GB memory recommended")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if state.installedModels.contains(model.id) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if !isSelected(model) { Button("Use model") { select(model) }.controlSize(.small) }
                            else { Label("On this Mac", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(DaybookStyle.accent) }
                            Button("Remove") { state.removeModel(model.id) }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary).disabled(state.processingID != nil || state.downloadingID != nil)
                        }
                    } else {
                        Button("Download") { state.download(model.id) }.controlSize(.small).disabled(state.downloadingID != nil || state.processingID != nil)
                    }
                }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func isSelected(_ model: LocalModelDescriptor) -> Bool {
        switch model.role {
        case .transcription: return model.id == state.transcriptionModel
        case .summarization: return model.id == state.summaryModel
        case .diarization: return model.id == state.processingPreferences.speakerModelID
        }
    }
    private func select(_ model: LocalModelDescriptor) {
        switch model.role {
        case .transcription: state.transcriptionModel = model.id
        case .summarization: state.summaryModel = model.id
        case .diarization: state.processingPreferences.speakerModelID = model.id
        }
    }
    private func applyPreset(transcription: String, summary: String, quality: SpeakerQuality) {
        state.transcriptionModel = transcription
        state.summaryModel = summary
        state.processingPreferences.speakerModelID = DaybookModelCatalog.diarization
        state.processingPreferences.speakerOptions.quality = quality
    }

    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Capture").font(.headline)
                Toggle("Include computer audio", isOn: $state.includeComputerAudio)
                Text("Records separate microphone and computer tracks. macOS will request microphone and Screen & System Audio Recording access when you first record. No screen video is saved.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically record detected meetings", isOn: Binding(get: { state.automaticRecording }, set: { enabled in
                    if enabled && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                    state.automaticRecording = enabled
                }))
                Text("Starts after 6 seconds of meeting-window and audio activity. Stops after 45 seconds without meeting activity. Use the menu bar or notes window to stop at any time. Make sure the people involved know you are recording.").font(.caption).foregroundStyle(.secondary)
                Label(state.monitor.statusText, systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(DaybookStyle.accent)
                Text("Supported detection: Zoom, Teams, Slack Huddles, and meeting pages in Chrome, Safari, Firefox, Edge, and Arc. Window titles and app audio are heuristics; manual recording is always available.").font(.caption).foregroundStyle(.secondary)
                Text("Browser meetings must use the microphone device to start automatically. A muted browser call may need manual start. Playback from another tab alone does not start a recording.").font(.caption).foregroundStyle(.secondary)
                Button("Open recording permissions") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
            }
            Divider()
            SoundcoreView(controller: state.soundcore)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Soundcore & folder imports").font(.headline)
                Text("Export an audio file from the Soundcore phone app and AirDrop or copy it to this Mac. Daybook processes the imported audio with its own local models.").font(.callout).foregroundStyle(.secondary)
                Text("Device connection is experimental. Exported audio is the supported import path; Soundcore's documented USB connection does not export recordings.").font(.caption).foregroundStyle(.secondary)
                if let folder = state.folderWatcher.folder {
                    Label(folder.path, systemImage: "folder").font(.caption).textSelection(.enabled)
                    HStack { Button("Choose another folder…") { state.chooseImportFolder() }; Button("Turn off") { state.folderWatcher.stop(forget: true) }; Button("Retry imports") { state.folderWatcher.retry() } }
                } else { Button("Watch an export folder…") { state.chooseImportFolder() } }
                Text(state.folderWatcher.status).font(.caption).foregroundStyle(.secondary)
                Text("Files must remain unchanged across two scans before import. To combine a Soundcore recording with a computer call, open that conversation and choose Add audio.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("A local library you control", systemImage: "externaldrive").font(.title3.weight(.semibold))
            Text("Recordings, editable transcripts, notes, vocabulary, and revision history are saved in your Mac's Application Support folder. Models are stored alongside them.").foregroundStyle(.secondary)
            Text(AppState.libraryURL.path).font(.callout.monospaced()).textSelection(.enabled)
            Button("Open library in Finder") { NSWorkspace.shared.open(AppState.libraryURL) }
            Divider()
            SyncSettingsView(state: state)
            Divider()
            Text("Use each conversation's menu to export Markdown or JSON. JSON includes all original transcript runs, highlights, and revision history. Audio remains in the meeting's folder.").font(.callout).foregroundStyle(.secondary)
            Text("Daybook restricts local library files to your macOS user. It does not add its own encryption; protection depends on your Mac, backups, and any sync service you enable. Inference stays local, and Daybook does not send analytics.").font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Daybook 0.1 · Local preview").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SpeakerQualitySettingsView: View {
    @ObservedObject var state: AppState
    @State private var advanced = false
    private var supportsMatching: Bool { DaybookModelCatalog.supportsVoiceMatching(state.processingPreferences.speakerModelID) }
    private var supportsCount: Bool { DaybookModelCatalog.supportsExpectedSpeakerCount(state.processingPreferences.speakerModelID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Label speakers during processing", isOn: $state.detectSpeakers)
            if state.detectSpeakers && !state.installedModels.contains(state.processingPreferences.speakerModelID) {
                Text("Download the selected speaker model before processing with speaker labels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Analysis effort", selection: $state.processingPreferences.speakerOptions.quality) {
                ForEach(SpeakerQuality.allCases, id: \.self) { quality in Text(quality.title).tag(quality) }
            }.pickerStyle(.segmented)
            Text(state.processingPreferences.speakerOptions.quality.detail).font(.caption).foregroundStyle(.secondary)
            Picker("Expected speakers", selection: Binding(get: { state.processingPreferences.speakerOptions.expectedSpeakerCount ?? 0 }, set: { value in
                state.processingPreferences.speakerOptions.expectedSpeakerCount = value == 0 ? nil : value
            })) {
                Text("Automatic").tag(0)
                ForEach(1...12, id: \.self) { count in Text("\(count)").tag(count) }
            }.frame(maxWidth: 300).disabled(!supportsCount)
            Text(supportsCount ? "An expected count guides clustering; it does not guarantee a particular number of speakers." : "Sortformer detects up to four speakers automatically and does not use a count override.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Match voices across recordings of this conversation", isOn: $state.processingPreferences.matchSpeakersAcrossSources)
                .disabled(!supportsMatching)
            Text(supportsMatching ? "Uses local voice embeddings to connect speakers across sources and preserve names on re-analysis. Ambiguous voices remain separate. Matches stay within the conversation." : "This model does not provide compatible voice embeddings. Choose Community-1 to match voices across recordings.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Voice matching thresholds", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Minimum similarity")
                        Spacer()
                        Text(state.processingPreferences.speakerMatchThreshold, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }.font(.caption)
                    Slider(value: $state.processingPreferences.speakerMatchThreshold, in: 0.65...0.95, step: 0.01)
                    HStack {
                        Text("Separation from next candidate")
                        Spacer()
                        Text(state.processingPreferences.speakerMatchMargin, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }.font(.caption)
                    Slider(value: $state.processingPreferences.speakerMatchMargin, in: 0...0.2, step: 0.01)
                    Text("These are similarity thresholds, not probabilities of identity. Higher values make fewer, more conservative matches. Start with 0.82 similarity and 0.06 separation, then review the speakers.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore matching defaults") {
                        state.processingPreferences.speakerMatchThreshold = 0.82
                        state.processingPreferences.speakerMatchMargin = 0.06
                    }.controlSize(.small)
                }.padding(.top, 10)
            }.disabled(!supportsMatching || !state.processingPreferences.matchSpeakersAcrossSources)
            Text("Changing these settings does not overwrite a finished transcript. Use Re-label speakers or Re-transcribe audio on a conversation to run another analysis.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(DaybookStyle.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct GlossaryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newTerm = ""
    @State private var newDefinition = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("A vocabulary of your own").font(.system(size: 25, weight: .medium, design: .serif)); Spacer(); Button("Done") { dismiss() } }
            Text("Daybook suggests names and terms from your conversations. Approve a term to use it in other meetings. Unapproved suggestions remain scoped to their source meeting.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Name or term", text: $newTerm).textFieldStyle(.roundedBorder)
                TextField("Meaning or preferred spelling", text: $newDefinition).textFieldStyle(.roundedBorder)
                Button("Add") {
                    state.saveGlossaryTerm(GlossaryTerm(term: newTerm.trimmingCharacters(in: .whitespacesAndNewlines), definition: newDefinition, approved: true))
                    newTerm = ""; newDefinition = ""
                }.disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            if state.glossary.isEmpty { ContentUnavailableView("The words that matter", systemImage: "character.book.closed", description: Text("Add a name, project, or specialized term, or process a conversation to discover suggestions.")) }
            else {
                List {
                    ForEach(state.glossary.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }) { term in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(term.term).font(.headline)
                                if !term.definition.isEmpty { Text(term.definition).font(.caption).foregroundStyle(.secondary) }
                                Text(term.approved ? "Available across conversations" : "Suggested · only used in its source conversation").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Approved", isOn: Binding(get: { state.glossary.first { $0.id == term.id }?.approved ?? false }, set: { approved in var copy = term; copy.approved = approved; state.saveGlossaryTerm(copy) })).toggleStyle(.checkbox)
                            Button { state.removeGlossaryTerm(term.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }.listStyle(.plain)
            }
        }.padding(26).tint(DaybookStyle.accent)
    }
}
