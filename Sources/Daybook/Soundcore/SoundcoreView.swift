import AppKit
import SwiftUI

struct SoundcoreView: View {
    @ObservedObject var controller: SoundcoreController

    var body: some View {
        Form {
            Section("Soundcore Work · Experimental") {
                Text("Connect directly over Bluetooth to check battery, control recording, and import audio locally. Compatibility depends on your device firmware; the official export folder remains available.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Label(controller.status, systemImage: controller.isConnected ? "checkmark.circle" : "wave.3.right")
                    Spacer()
                    if controller.isConnected || controller.isConnecting {
                        Button("Disconnect", action: controller.disconnect)
                    } else if controller.isScanning {
                        Button("Stop Scan", action: controller.stopScan)
                    } else { Button("Scan", action: controller.scan) }
                }
                if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(controller.devices) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text("\(device.signal) dBm").foregroundStyle(.secondary)
                        Button("Connect") { controller.connect(device) }
                            .disabled(controller.isConnecting || controller.isConnected)
                    }
                }
            }
            if controller.isConnected {
                Section("Device") {
                    if let info = controller.deviceInfo {
                        HStack {
                            battery("Microphone", value: info.microphoneBattery, charging: info.microphoneCharging)
                            Spacer()
                            battery("Case", value: info.caseBattery, charging: info.caseCharging)
                        }
                        LabeledContent("Firmware", value: info.firmware.isEmpty ? "Unknown" : info.firmware)
                        LabeledContent("Recording", value: info.isRecording ? "Recording" : "Paused or idle")
                        if info.totalBytes > 0 {
                            LabeledContent("Storage", value: "\(ByteCountFormatter.string(fromByteCount: Int64(min(info.freeBytes, info.totalBytes)), countStyle: .file)) available of \(ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file))")
                        }
                    }
                    HStack {
                        Button("Refresh Status", action: controller.refreshStatus)
                        Spacer()
                        Button("Start Device Recording", action: controller.startRecording)
                        Button("Pause Device Recording", action: controller.pauseRecording)
                    }.disabled(controller.transferProgress != nil)
                    Text("Recording starts only when you press Start or use the device button. Daybook does not bind, reset, or delete recordings on the device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Live audio") {
                    HStack {
                        if controller.isReceivingLive {
                            Button("Stop Reception and Save", action: controller.stopLiveCapture)
                        } else {
                            Button("Receive Live Audio", action: controller.startLiveCapture)
                                .disabled(controller.deviceInfo?.isRecording != true || controller.transferProgress != nil)
                        }
                        Spacer()
                        Text(controller.livePreviewStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Start a recording on the device, then receive its audio here. A local transcript preview updates about every 15 seconds when a speech model is installed. Stopping reception saves the captured portion and leaves device recording unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !controller.liveTranscript.isEmpty {
                        ScrollView { Text(controller.liveTranscript).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 180)
                    }
                }
                Section("Recordings on the device") {
                    HStack {
                        Button("Refresh Recordings", action: controller.listFiles).disabled(controller.transferProgress != nil)
                        Spacer()
                        if controller.encryptionReady { Label("Local transfer ready", systemImage: "lock") }
                    }
                    if let progress = controller.transferProgress {
                        HStack {
                            ProgressView(value: progress)
                            if !controller.isReceivingLive { Button("Cancel Transfer", action: controller.cancelDownload) }
                        }
                    }
                    ForEach(controller.files) { recording in
                        HStack {
                            VStack(alignment: .leading) {
                                if let date = recording.date { Text(date, format: .dateTime.month().day().hour().minute()) }
                                else { Text("Recording \(recording.id)") }
                                Text(ByteCountFormatter.string(fromByteCount: Int64(recording.size), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import") { controller.downloadRecording(recording) }
                                .disabled(controller.transferProgress != nil)
                        }
                    }
                    if controller.files.isEmpty { Text("Refresh to list recordings stored on your Soundcore.").foregroundStyle(.secondary) }
                    if let url = controller.lastRecordingURL {
                        Button("Show Last Imported Audio") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Text("Imports are accepted only after encryption, packet order, audio decoding, and complete byte count checks pass. Transfers have not yet been verified with your physical device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private func battery(_ title: String, value: Int?, charging: Bool) -> some View {
        Label("\(title): \(value.map { "\($0)%" } ?? "Unknown")\(charging ? " · Charging" : "")",
              systemImage: charging ? "battery.100percent.bolt" : "battery.75percent")
    }
}
