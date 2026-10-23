import AppKit
import SwiftUI

@main
enum DaybookEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--smoke-test") {
            let code = await SmokeTest.run(arguments: CommandLine.arguments)
            Darwin.exit(code)
        }
        DaybookApp.main()
    }
}

struct DaybookApp: App {
    @NSApplicationDelegateAdaptor(DaybookDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup("Daybook") {
            LibraryView(state: state)
                .frame(minWidth: 1000, minHeight: 650)
                .task {
                    delegate.state = state
                    await state.initialize()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New conversation") { state.newMeeting() }.keyboardShortcut("n")
                Button("Import recording…") { state.chooseImport() }.keyboardShortcut("o")
                Button(state.isRecording ? "Stop recording" : "Start recording") {
                    Task { if state.isRecording { await state.stopRecording() } else { await state.startRecording() } }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { PreferencesView(state: state).frame(width: 720, height: 650) }
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 14) {
                Label("Daybook", systemImage: "waveform").font(.headline)
                if state.isRecording, let start = state.recordingStartedAt {
                    Label { Text(start, style: .timer).monospacedDigit() } icon: { Circle().fill(.red).frame(width: 8, height: 8) }
                    Button("Show meeting notes") { if let id = state.recordingID { state.showNotes(for: id) } }
                    Button("Stop recording", role: .destructive) { Task { await state.stopRecording() } }
                } else {
                    Text(state.monitor.statusText).font(.caption).foregroundStyle(.secondary)
                    Button("Record a conversation") { Task { await state.startRecording() } }.disabled(!state.isReady || state.isStartingRecording)
                }
                Divider()
                Button("Open Daybook") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.title == "Daybook" }?.makeKeyAndOrderFront(nil) }
                Button("Quit Daybook") { NSApp.terminate(nil) }
            }.padding(18).frame(width: 260)
        } label: { Image(systemName: state.isRecording ? "record.circle.fill" : "waveform").symbolRenderingMode(.palette).foregroundStyle(state.isRecording ? .red : .primary) }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class DaybookDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let state else { return .terminateNow }
        terminating = true
        Task {
            state.cancelDownload(); state.cancelProcessing()
            if state.isRecording || state.isStartingRecording { await state.stopRecording() }
            await state.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
