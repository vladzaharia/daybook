import DaybookCore
import DaybookKit
import SwiftUI

/// Under a speaker in the inspector: a name Daybook gave by voice (which the person can take back),
/// or a profile the voice resembles (which the person can confirm). Nothing for names the person gave.
struct SpeakerIdentityLine: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let speaker: Speaker

    private var identity: SpeakerIdentity? {
        guard let identity = meeting.speakerIdentity(speaker.id), identity.$source.isKnown else { return nil }
        return identity
    }
    private var profile: SpeakerProfile? { identity?.profileID.flatMap { state.libraryMetadata.speakerProfile($0) } }

    var body: some View {
        if let identity, let profile {
            switch identity.source {
            case .recognized:
                line {
                    Label("Recognized", systemImage: "waveform").labelStyle(.titleAndIcon)
                    Spacer()
                    Button("Not \(profile.name)") { state.rejectSpeakerProfile(speaker.id, in: meeting.id) }
                        .buttonStyle(.daybookLink)
                }
                .help(similarity(identity))
            case .suggested:
                line {
                    Text("Maybe \(profile.name)")
                    Spacer()
                    Button("Yes") { state.confirmSpeakerProfile(speaker.id, in: meeting.id) }
                        .buttonStyle(.daybookLink)
                        .accessibilityLabel("This is \(profile.name)")
                    Button("No") { state.rejectSpeakerProfile(speaker.id, in: meeting.id) }
                        .buttonStyle(.daybookLink)
                        .accessibilityLabel("Not \(profile.name)")
                }
                .help(similarity(identity))
            default:
                EmptyView()
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
    }

    private func similarity(_ identity: SpeakerIdentity) -> String {
        identity.similarity.map { "\(Int(($0 * 100).rounded()))% alike" } ?? ""
    }
}
