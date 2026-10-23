import DaybookCore
import SwiftUI
import UniformTypeIdentifiers

enum DaybookStyle {
    static let accent = Color(red: 0.22, green: 0.43, blue: 0.38)
    static let gold = Color(red: 0.65, green: 0.48, blue: 0.25)
    static let canvas = Color(nsColor: .textBackgroundColor)
}

struct LibraryView: View {
    @ObservedObject var state: AppState
    @State private var showPreferences = false
    @State private var showGlossary = false
    @State private var editingFolder: LibraryFolder?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 11) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(DaybookStyle.accent)
                    Text("daybook").font(.system(size: 25, weight: .semibold, design: .rounded))
                }.padding(.top, 18).padding(.horizontal, 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR LIBRARY").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(1.4).padding(.horizontal, 14).padding(.bottom, 8)
                    ForEach(LibrarySection.allCases) { section in
                        Button { state.section = section; state.folderFilter = nil; state.tagFilter = nil } label: {
                            HStack {
                                Image(systemName: section == .all ? "rectangle.stack" : section == .work ? "briefcase" : "leaf")
                                    .frame(width: 20)
                                Text(section.rawValue)
                                Spacer()
                                if section == .all { Text("\(state.meetings.count)").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.horizontal, 12).padding(.vertical, 11)
                                .background(state.section == section && state.folderFilter == nil && state.tagFilter == nil ? DaybookStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("FOLDERS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                            Spacer()
                            Button { editingFolder = LibraryFolder(name: "") } label: { Image(systemName: "plus") }.help("New folder")
                        }.padding(.bottom, 4)
                        ForEach(state.folders) { folder in
                            Button {
                                state.folderFilter = folder.id; state.tagFilter = nil; state.section = .all
                            } label: {
                                Label(folder.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8).background(state.folderFilter == folder.id ? DaybookStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.contextMenu {
                                Button("Rename folder…") { editingFolder = folder }
                                Button("Remove folder", role: .destructive) { state.removeFolder(folder.id) }
                            }
                        }
                        if !state.allTags.isEmpty {
                            Text("TAGS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary).padding(.top, 14)
                            ForEach(state.allTags, id: \.self) { tag in
                                Button { state.tagFilter = tag; state.folderFilter = nil; state.section = .all } label: {
                                    Label(tag, systemImage: "number").frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(7).background(state.tagFilter == tag ? DaybookStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }.buttonStyle(.plain).padding(.horizontal, 18)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { showGlossary = true } label: { Label("Vocabulary", systemImage: "character.book.closed") }
                    Button { showPreferences = true } label: { Label("Models & settings", systemImage: "slider.horizontal.3") }
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(DaybookStyle.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("At home on your Mac").font(.caption).fontWeight(.medium)
                            Text("Models run on this Mac. Your library can sync with iCloud.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain).padding(18)
            }.navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 250)
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Text(state.folderFilter.flatMap { id in state.folders.first { $0.id == id }?.name } ?? state.tagFilter.map { "#" + $0 } ?? (state.section == .all ? "Conversations" : state.section.rawValue)).font(.title2.weight(.semibold))
                    Spacer()
                    Button { state.newMeeting() } label: { Image(systemName: "square.and.pencil") }.help("New conversation")
                }.buttonStyle(.borderless).padding(18)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your conversations", text: $state.search).textFieldStyle(.plain)
                    if !state.search.isEmpty { Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16).padding(.bottom, 12)
                Divider()
                if state.visibleMeetings.isEmpty {
                    ContentUnavailableView(state.search.isEmpty ? "A little room to remember" : "No matches", systemImage: "text.bubble", description: Text(state.search.isEmpty ? "Your conversations will appear here." : "Try a name, term, or phrase."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(selection: $state.selectedID) {
                        ForEach(state.visibleMeetings) { meeting in
                            ConversationRow(meeting: meeting, queued: state.queuedIDs.contains(meeting.id)).tag(meeting.id)
                        }
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
                Divider()
                Button { state.chooseImport() } label: { Label("Import recording", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.padding(14)
            }.navigationSplitViewColumnWidth(min: 270, ideal: 305, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if state.isRecording { recordingBanner }
                if let notice = state.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle").foregroundStyle(DaybookStyle.accent)
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { state.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(DaybookStyle.accent.opacity(0.08))
                }
                if let meeting = state.selectedMeeting {
                    MeetingDetailView(state: state, meetingID: meeting.id).id(meeting.id)
                } else {
                    WelcomeView(state: state, showModels: { showPreferences = true })
                }
            }.background(DaybookStyle.canvas)
        }
        .tint(DaybookStyle.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording() } }
                } label: {
                    Label(state.isRecording ? "Stop recording" : state.isStartingRecording ? "Starting…" : "Record", systemImage: state.isRecording ? "stop.circle.fill" : "record.circle")
                }.tint(state.isRecording ? .red : DaybookStyle.accent)
                    .disabled(!state.isReady || state.isStartingRecording || state.isStoppingRecording)
            }
        }
        .sheet(isPresented: $showPreferences) { PreferencesView(state: state).frame(width: 760, height: 700) }
        .sheet(item: $editingFolder) { folder in FolderEditor(folder: folder, save: state.saveFolder) }
        .sheet(isPresented: $showGlossary) { GlossaryView(state: state).frame(width: 720, height: 620) }
        .alert("Daybook needs your attention", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        do { try await state.importFiles([url], source: .imported, attachTo: nil) }
                        catch { state.errorMessage = error.localizedDescription }
                    }
                }
            }
            return !providers.isEmpty
        }
    }
    private var recordingBanner: some View {
        HStack {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Recording on this Mac").fontWeight(.medium)
            if let started = state.recordingStartedAt { Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary) }
            Spacer()
            Button("Open notes") { if let id = state.recordingID { state.showNotes(for: id) } }
            Button("Stop") { Task { await state.stopRecording() } }.disabled(state.isStoppingRecording)
        }.font(.callout).padding(12).background(.red.opacity(0.07))
    }
}

private struct ConversationRow: View {
    let meeting: Meeting
    let queued: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(meeting.displayKind == .auto ? "CONVERSATION" : meeting.displayKind.title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if meeting.status == .recording { Circle().fill(.red).frame(width: 7, height: 7) }
                else if [.transcribing, .summarizing].contains(meeting.status) { ProgressView().controlSize(.mini) }
            }
            Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text(meeting.summary?.overview ?? (meeting.notes.isEmpty ? "\(meeting.tracks.count) audio source\(meeting.tracks.count == 1 ? "" : "s") · \(queued ? "Queued" : meeting.status.rawValue.capitalized)" : meeting.notes))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(.vertical, 12)
    }
}

private struct WelcomeView: View {
    @ObservedObject var state: AppState
    let showModels: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(DaybookStyle.accent.opacity(0.09)).frame(width: 88, height: 88)
                    Image(systemName: "waveform").font(.system(size: 34, weight: .light)).foregroundStyle(DaybookStyle.accent)
                }
                Text("Keep the conversation.\nStay in the moment.").font(.system(size: 36, weight: .medium, design: .serif)).lineSpacing(3)
                Text("One quiet place for your meetings, everyday conversations, and the things you want to remember.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                HStack(spacing: 12) {
                    Button { Task { await state.startRecording() } } label: { Label("Record a conversation", systemImage: "record.circle").padding(.vertical, 5) }.buttonStyle(.borderedProminent).disabled(!state.isReady || state.isStartingRecording)
                    Button("Import audio") { state.chooseImport() }.buttonStyle(.bordered)
                }
                Divider().padding(.vertical, 8)
                WelcomeFeature(icon: "waveform.badge.mic", title: "In the room. On the call.", detail: "Bring Soundcore recordings and computer meetings into the same library.")
                WelcomeFeature(icon: "pencil.and.outline", title: "Your notes, with the details filled in.", detail: "Jot down what matters. Daybook brings your notes and transcript together.")
                WelcomeFeature(icon: "cpu", title: "Intelligence that lives here.", detail: "Download a speech model and a summary model once. Then work offline.")
                if !state.canProcess {
                    Button { showModels() } label: { Label("Set up local models", systemImage: "arrow.down.circle").fontWeight(.semibold) }.buttonStyle(.plain).foregroundStyle(DaybookStyle.accent).padding(.top, 8)
                }
            }.padding(54).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
private struct WelcomeFeature: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(DaybookStyle.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.weight(.semibold)); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct FolderEditor: View {
    let folder: LibraryFolder
    let save: (LibraryFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(folder.name.isEmpty ? "New folder" : "Rename folder").font(.title2)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(LibraryFolder(id: folder.id, name: name)); dismiss() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 350).onAppear { name = folder.name }
    }
}
