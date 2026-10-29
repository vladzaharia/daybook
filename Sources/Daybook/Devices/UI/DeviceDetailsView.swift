import AppKit
import DaybookKit
import SwiftUI

/// More › Device Details…: a read-only popover with the recorder's status, versions, and serial
/// number, and the honest technical facts under a disclosure. Every row shares one label column, so
/// the values line up from the top of the popover to the foot of Technical Details.
struct DeviceDetailsView: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var browser: DeviceBrowser
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The label column: wide enough for "Recorder firmware" and "Audio key exchange".
    private static let labelWidth: CGFloat = 132

    var body: some View {
        let detailed = session.direct as? any DetailedConnection
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                DeviceGlyph(symbol: session.kind.systemImage, size: 20, linked: session.isLinked)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.device.name).font(.headline)
                    if let vendor = session.kind.vendor {
                        Text(vendor).font(TypeStyle.status).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(detailed?.details ?? []) { detail in
                    if detail.label == "Recorder firmware" { Divider().padding(.vertical, 2) }
                    row(detail.label) {
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
                            Text(detail.value).monospacedDigit()
                                .foregroundStyle(detail.value.hasPrefix("Unknown") ? .secondary : .primary)
                        }
                    }
                }
                Divider().padding(.vertical, 2)
                row("Status updated") {
                    HStack(spacing: Space.s2) {
                        Text(updated(session.status?.updatedAt))
                        Spacer(minLength: Space.s3)
                        // Only while it can: connected, and not busy importing or listing.
                        if session.isLinked, session.queue.current == nil {
                            Button("Refresh") { session.primary?.refresh() }
                                .controlSize(.small)
                                .disabled(session.primary?.isRefreshing == true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.s3) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { browser.showsTechnicalDetails.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(browser.showsTechnicalDetails ? 90 : 0))
                        Text("Technical Details")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Technical Details")
                .accessibilityValue(browser.showsTechnicalDetails ? "Expanded" : "Collapsed")

                if browser.showsTechnicalDetails {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detailed?.technicalDetails ?? []) { detail in
                            row(detail.label) { Text(detail.value) }
                        }
                        if let problem = detailed?.lastTechnicalProblem {
                            row("Last problem") { Text(problem).textSelection(.enabled) }
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ForEach(session.kind.technicalNotes, id: \.self) { note in
                            Text(note).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .padding(Space.s4)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A label in the shared column, then its value.
    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(label).foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func updated(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if Date().timeIntervalSince(date) < 90 { return "Just now" }
        return DeviceDateFormat.title(date)
    }
}
