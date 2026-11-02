import DaybookCaptions
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookUI
import SwiftUI

// Live captions on the Mac draw with the shared `LiveCaptionStrip` (DaybookUI's `CaptionLines.swift`
// feeds it), as Floating Notes and the iPhone do; saved captions read on the transcript's page with
// DaybookUI's `SavedCaptionsView`, as on the iPhone. Settings is DaybookUI's `LiveCaptionSettingsSection`.

// MARK: - The conversation page

/// Live captions on the conversation page, after your notes, while this Mac records the conversation:
/// the newest lines as they're heard, You and Call before their words. Once it stops, the saved captions
/// read on the transcript's page, as on the iPhone (`AppState.savedCaptions(for:)`, `SavedCaptionsView`).
///
/// It reads the captions itself, so a revised word redraws only this section.
struct LiveCaptionsSection: View {
    let captions: LiveCaptionsController
    let meeting: Meeting
    let isRecording: Bool

    /// While recording, the page keeps the newest lines.
    static let liveLines = 8

    var body: some View {
        if isRecording, captions.isShowing(for: meeting.id) {
            // On the text's edge, as everything on the page is.
            MarginRow {
                LiveCaptionStrip(lines: Self.lines(captions.recent(Self.liveLines), names: captions.sourceNames,
                                                   listening: captions.state == .listening),
                                 status: LiveCaptionStatus.line(captions.state, locale: captions.locale),
                                 style: Self.style)
            }
            .padding(.top, Space.s6)
        }
    }

    /// The page's lines: in its body type, at its reading scale, each whole; the label as any label, with
    /// no row beside it to line its glyph up with.
    static var style: CaptionStripStyle {
        var style = CaptionStripStyle.feed
        style.lines = liveLines
        style.glyphColumn = nil
        return style
    }

    /// The page has no lane for sources: You, Call, the person, or the device goes before the words.
    static func lines(_ segments: [LiveCaptionSegment], names: [String: String], listening: Bool) -> [CaptionLine] {
        guard listening else { return [] }
        return segments.map { segment in
            var line = CaptionLine(segment, names: names)
            line.speaker = line.speaker ?? line.source
            line.source = nil
            return line
        }
    }
}

// MARK: - Listen Live

/// Listen Live's captions on a recorder's page: the shared strip at the page's body type, its label's
/// glyph in the column the Listening line above it uses. When captions are off, or can't run on this
/// Mac, it shows nothing.
struct LiveCaptionFeed: View {
    let segments: [LiveCaptionSegment]
    let state: LiveCaptionState
    let locale: Locale

    /// The label's glyph column, which Listen Live's Listening row shares, so their words start together.
    static let glyphColumn: CGFloat = CaptionStripStyle.feed.glyphColumn ?? 24

    var body: some View {
        if LiveCaptionStrip.shows(segments: segments, state: state, locale: locale) {
            LiveCaptionStrip(segments: segments, state: state, locale: locale, style: .feed)
        }
    }
}

// MARK: - Settings

/// Settings › General › Live captions: DaybookUI's section with this Mac's settings.
typealias LiveCaptionSettingsSection = DaybookUI.LiveCaptionSettingsSection<LiveCaptionSettings>

extension DaybookUI.LiveCaptionSettingsSection where Settings == LiveCaptionSettings {
    /// This Mac's: the languages its downloaded live recognizers cover, whether one covers the chosen
    /// language, and whether this system's Speech framework captions (macOS 26).
    init(settings: LiveCaptionSettings) {
        self.init(settings: settings, liveLanguages: settings.liveLanguages, liveCovers: settings.hasLiveModels,
                  deviceName: "This Mac", systemCaptions: MacCaptioners.systemSupportsCaptions)
    }
}
