import AppKit
import DaybookKit

extension LibrarySyncController {
    /// Choose Folder…: an open panel that starts in iCloud Drive.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect your Daybook sync folder"
        panel.message = "Choose or create a private Daybook folder in iCloud Drive. Choose the same folder on your other Macs."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Connect library"
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: drive.path) { panel.directoryURL = drive }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectChosenFolder(url)
    }
}
