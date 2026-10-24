import AppKit
import DaybookKit
import SwiftUI

/// More › Device Details…: a read-only popover with the recorder's status, versions, and serial
/// number, and the honest technical facts under a disclosure.
struct DeviceDetailsView: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var browser: DeviceBrowser
    @State private var copied = false

    var body: some View {
        let detailed = session.direct as? any DetailedConnection
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                DeviceGlyph(symbol: session.kind.systemImage, size: 20, linked: session.isLinked)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.device.name).font(.headline)
                    if let vendor = session.kind.vendor {
                        Text(vendor).font(TypeStyle.status).foregroundStyle(.secondary)
                    }
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s4, verticalSpacing: 7) {
                ForEach(detailed?.details ?? []) { detail in
                    if detail.label == "Recorder firmware" { Divider().gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        label(detail.label)
                        if let copy = detail.copyValue {
                            HStack(spacing: Space.s2) {
                                Text(detail.value).monospacedDigit()
                                    .help("Only the last four characters are shown.")
                                Button(copied ? "Copied" : "Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(copy, forType: .string)
                                    copied = true
                                }
                                .buttonStyle(.daybookLink)
                                .accessibilityLabel("Copy \(detail.label.lowercased())")
                            }
                        } else {
                            Text(detail.value).monospacedDigit().fixedSize()
                                .foregroundStyle(detail.value.hasPrefix("Unknown") ? .secondary : .primary)
                        }
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    label("Status updated")
                    HStack(spacing: Space.s2) {
                        Text(updated(session.status?.updatedAt))
                        Spacer(minLength: Space.s3)
                        Button("Refresh") { session.primary?.refresh() }
                            .controlSize(.small)
                            .disabled(!session.isLinked || session.queue.current != nil || session.primary?.isRefreshing == true)
                    }
                }
            }
            .font(.system(size: 12))

            DisclosureGroup("Technical Details", isExpanded: $browser.showsTechnicalDetails) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if let technical = detailed?.technicalDetails, !technical.isEmpty {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s4, verticalSpacing: 6) {
                            ForEach(technical) { detail in
                                GridRow { label(detail.label); Text(detail.value) }
                            }
                        }
                    }
                    ForEach(session.kind.technicalNotes, id: \.self) { note in
                        Text(note)
                    }
                    if let problem = detailed?.lastTechnicalProblem {
                        Text("Last problem: \(problem)").textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s2)
            }
            .font(.system(size: 12))
        }
        .padding(Space.s4)
        .frame(width: 400)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func updated(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if Date().timeIntervalSince(date) < 90 { return "Just now" }
        return DeviceDateFormat.title(date)
    }
}
