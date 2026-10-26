import AppKit
import DaybookCore
import DaybookKit

extension LibrarySyncController {
    /// Choose Folder…: an open panel that starts in iCloud Drive.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect your Daybook sync folder"
        panel.message = "Choose or create a private Daybook folder in iCloud Drive. Choose the same folder on your other Macs."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Connect Library"
        // The person's iCloud Drive, not the sandbox container's; the panel falls back on its own if it's missing.
        panel.directoryURL = UserHome.iCloudDrive
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectChosenFolder(url)
    }

    /// Choose Folder Again… for the folder this Mac synced through before, when this build can't open it
    /// (`ICloudSyncState.previousFolderAccessLost`): an open panel where it was.
    func choosePreviousFolderAgain(near location: URL?) {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder this Mac synced through"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.directoryURL = location?.deletingLastPathComponent() ?? UserHome.iCloudDrive
        guard panel.runModal() == .OK, let url = panel.url else { return }
        regrantPreviousFolder(url)
    }
}
