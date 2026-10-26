import DaybookCore
import SwiftUI

/// The recorder while a recording is active, in each posture (docs/iphone.md, "iPhone Duo"):
///
/// - **Pocket** (closed, and every other iPhone held upright): one hand. Status and the clock at the
///   top, the level, the notes, and a large Bookmark and Stop at the thumb.
/// - **Notebook** (open): notes on the left page; the clock, level, live timeline, bookmarks, and
///   multipoint status on the right. Split at the crease, never across it.
/// - **Table** (partly open, standing): glanceable from across a table. A large clock and level on
///   one page, a large Bookmark target on the other; dims between touches. Write Notes swaps the
///   clock's page for the notes (and stops dimming) until Done.
///
/// Folding mid-recording only rearranges the same pieces: nothing about the recording restarts.
/// `RootView` shows it whenever `model.isRecordingActive`.
struct RecordingSurface: View {
    let style: SurfaceStyle

    var body: some View {
        Group {
            switch style {
            case .pocket: PocketRecording()
            case .notebook: NotebookRecording()
            case .table: TableRecording()
            }
        }
        .background(PhoneStyle.paper.ignoresSafeArea())
    }
}

// MARK: Pocket

/// Closed: one column, one hand. The controls sit where the thumb is.
private struct PocketRecording: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                RecordingStatusHeader()
                HStack(alignment: .center) {
                    RecordingClockText(size: RecordingStyle.Clock.pocket, weight: .medium)
                    Spacer(minLength: 8)
                    CameraControl()
                }
                if recorder.isPaused {
                    PausedPanel()
                } else {
                    RollingMeter(height: RecordingStyle.Meter.pocketHeight)
                }
                MultipointStatus(compact: true)
            }
            .padding(.horizontal, PhoneStyle.Space.s5)
            .padding(.top, PhoneStyle.Space.s3)
            .padding(.bottom, PhoneStyle.Space.s2)

            Divider().padding(.horizontal, PhoneStyle.Space.s5).opacity(0.6)

            RecordingNotesEditor()
                .frame(maxHeight: .infinity)

            VStack(spacing: PhoneStyle.Space.s3) {
                LiveCaptionsView(style: .strip)
                    .padding(.horizontal, PhoneStyle.Space.s2)
                RecordingNotice()
                HStack(spacing: PhoneStyle.Space.s3) {
                    BookmarkControl(height: RecordingStyle.Control.pocketHeight)
                    StopControl(height: RecordingStyle.Control.pocketHeight)
                }
            }
            .padding(.horizontal, PhoneStyle.Space.s4)
            .padding(.top, PhoneStyle.Space.s2)
            .padding(.bottom, PhoneStyle.Space.s3)
        }
        .animation(.snappy(duration: 0.3), value: recorder.isPaused)
    }
}

// MARK: Notebook

/// Open: notes on the left page, the recorder on the right.
private struct NotebookRecording: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        CreaseSplit {
            NotesPage()
        } trailing: {
            RecorderPage()
        }
    }
}

private struct NotesPage: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recorder.title.isEmpty ? "New conversation" : recorder.title)
                    .font(PhoneStyle.Typeface.title(.title2))
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .lineLimit(2)
                Text(byline)
                    .font(.subheadline)
                    .foregroundStyle(PhoneStyle.Ink.secondary)
            }
            .padding(.horizontal, PhoneStyle.Space.s6)
            .padding(.top, PhoneStyle.Space.s5)
            .padding(.bottom, PhoneStyle.Space.s2)
            RecordingNotesEditor()
                .padding(.horizontal, PhoneStyle.Space.s3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var byline: String {
        let started = model.recorder.startedAt ?? Date()
        var parts = ["Today", started.formatted(date: .omitted, time: .shortened), "iPhone microphone"]
        if let mac = model.multipoint?.recordingMacs.first?.name ?? (model.multipoint?.isMacLed == true ? model.multipoint?.macs.first?.name : nil) {
            parts[2] = "iPhone and \(mac)"
        }
        return parts.joined(separator: " · ")
    }
}

private struct RecorderPage: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s4) {
            HStack(alignment: .top) {
                RecordingStatusHeader(showsTitle: false)
                Spacer(minLength: 0)
                CameraControl()
            }
            RecordingClockText(size: RecordingStyle.Clock.notebook, weight: .medium)
            if recorder.isPaused {
                PausedPanel()
            } else {
                RollingMeter(height: RecordingStyle.Meter.notebookHeight)
            }
            LiveTimelineBar()
            MultipointStatus()
            // Captions take the space when they're on: they're the live sign that the audio is being
            // heard, while bookmarks already show twice (the notes' margin lane and the timeline's
            // amber ticks). Without captions, the bookmark log returns.
            if model.captions.isShowing {
                LiveCaptionsView(style: .page)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .clipped()
            } else {
                ScrollView {
                    BookmarkLog()
                        .padding(.top, PhoneStyle.Space.s1)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
            }
            RecordingNotice()
            HStack(spacing: PhoneStyle.Space.s3) {
                BookmarkControl(height: RecordingStyle.Control.notebookHeight)
                StopControl(height: RecordingStyle.Control.notebookHeight)
            }
        }
        .padding(.horizontal, PhoneStyle.Space.s5)
        .padding(.top, PhoneStyle.Space.s5)
        .padding(.bottom, PhoneStyle.Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.3), value: recorder.isPaused)
    }
}

// MARK: Table

/// Partly open, standing on a table: readable from across it. A touch anywhere wakes it; the
/// Bookmark target always works, dimmed or not.
private struct TableRecording: View {
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var dimmed = false
    @State private var lastTouch = Date()
    @State private var writing = false

    var body: some View {
        GeometryReader { proxy in
            // Turned a quarter turn like a laptop (flex mode), the hinge runs across: the standing half
            // is on top. Standing like a book, the hinge runs down the middle.
            if proxy.size.height > proxy.size.width {
                FlexTable(writing: $writing, wake: wake)
            } else if model.options.interfaceOrientation == "preview-portrait" {
                // Debug: the simulator can't turn the device, so draw flex mode turned within the
                // landscape window, as the turned display would show it.
                let full = CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                                  height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
                FlexTable(writing: $writing, wake: wake)
                    .frame(width: full.height, height: full.width)
                    .rotationEffect(.degrees(-90))
                    .frame(width: full.width, height: full.height)
                    .offset(x: -proxy.safeAreaInsets.leading, y: -proxy.safeAreaInsets.top)
            } else {
                BookTable(writing: $writing, wake: wake)
            }
        }
        // Dimmed, it goes dark: black ground (cheap on OLED), the clock and target in their dark
        // inks at low brightness, still readable from across the table.
        .environment(\.colorScheme, dimmed ? .dark : colorScheme)
        .opacity(dimmed ? RecordingStyle.dimmedOpacity : 1)
        .background((dimmed ? Color.black : PhoneStyle.paper).ignoresSafeArea())
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { wake() })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: dimmed)
        .task(id: lastTouch) {
            try? await Task.sleep(for: RecordingStyle.dimAfter)
            guard !Task.isCancelled, !model.recorder.isPaused, !writing else { return }
            dimmed = true
        }
        .onChange(of: model.recorder.isPaused) { _, paused in if paused { wake() } }
        .onChange(of: writing) { wake() }
        .persistentSystemOverlays(.hidden)
        .onAppear { InterfaceOrientation.apply(model.options.interfaceOrientation) }
    }

    private func wake() {
        dimmed = false
        lastTouch = Date()
    }
}

/// Flex mode: the top half stands facing the room (captions, the clock, the level), the bottom half
/// lies flat under the hand (Bookmark and Stop). Writing, the notes take the standing half and the
/// keyboard the flat one, like a laptop.
private struct FlexTable: View {
    @Environment(PhoneAppModel.self) private var model
    @Binding var writing: Bool
    var wake: () -> Void

    var body: some View {
        let recorder = model.recorder
        HorizontalCreaseSplit {
            VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                HStack(alignment: .center) {
                    RecordingStatusHeader(showsTitle: false)
                    MultipointStatus(compact: true)
                    if writing {
                        Spacer(minLength: 0)
                        RecordingClockText(size: 34, weight: .medium)
                    }
                }
                if writing {
                    RecordingNotesEditor()
                        .padding(.horizontal, -PhoneStyle.Space.s4)
                        .frame(maxHeight: .infinity)
                } else {
                    HStack(alignment: .center, spacing: PhoneStyle.Space.s5) {
                        RecordingClockText(size: 92, weight: .light)
                            .fixedSize()
                        RollingMeter(height: RecordingStyle.Meter.tableHeight)
                    }
                    LiveCaptionsView(style: .stage)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .padding(.horizontal, PhoneStyle.Space.s6)
            .padding(.top, PhoneStyle.Space.s5)
            .padding(.bottom, PhoneStyle.Space.s4)
        } bottom: {
            HStack(spacing: PhoneStyle.Space.s4) {
                if recorder.isPaused {
                    PausedPanel(large: true)
                } else {
                    FlexBookmarkTarget(touched: wake)
                }
                VStack(spacing: PhoneStyle.Space.s3) {
                    StopControl(height: 84)
                    TableTools(writing: $writing, size: 48)
                }
                .frame(maxWidth: 170)
            }
            .padding(.horizontal, PhoneStyle.Space.s6)
            .padding(.vertical, PhoneStyle.Space.s5)
            .frame(maxHeight: .infinity)
        }
        // The keyboard covers the flat half instead of squeezing both.
        .ignoresSafeArea(.keyboard)
    }
}

/// Standing like a book: the clock and level on one page, the Bookmark target on the other.
/// Writing, the notes take the clock's page.
private struct BookTable: View {
    @Environment(PhoneAppModel.self) private var model
    @Binding var writing: Bool
    var wake: () -> Void

    var body: some View {
        let recorder = model.recorder
        CreaseSplit {
            if writing {
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                    HStack(alignment: .center) {
                        RecordingStatusHeader(showsTitle: false)
                        Spacer(minLength: 0)
                        RecordingClockText(size: 34, weight: .medium)
                    }
                    .padding(.horizontal, PhoneStyle.Space.s6)
                    RecordingNotesEditor()
                        .padding(.horizontal, PhoneStyle.Space.s2)
                        .frame(maxHeight: .infinity)
                }
                .padding(.top, PhoneStyle.Space.s4)
            } else {
                VStack(spacing: PhoneStyle.Space.s4) {
                    Spacer(minLength: 0)
                    RecordingStatusHeader(showsTitle: false, alignment: .center)
                    RecordingClockText(size: RecordingStyle.Clock.table, weight: .light)
                    RollingMeter(height: RecordingStyle.Meter.tableHeight)
                        .frame(maxWidth: 360)
                    MultipointStatus(compact: true)
                    LiveCaptionsView(style: .strip)
                        .frame(maxWidth: 380)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PhoneStyle.Space.s6)
            }
        } trailing: {
            VStack(spacing: PhoneStyle.Space.s5) {
                Spacer(minLength: 0)
                if recorder.isPaused {
                    PausedPanel(large: true).frame(maxWidth: 340)
                } else {
                    TableBookmarkTarget(touched: wake)
                }
                Spacer(minLength: 0)
                HStack(spacing: PhoneStyle.Space.s3) {
                    TableTools(writing: $writing, size: 52)
                    StopControl(height: 52).frame(maxWidth: 220)
                }
            }
            .padding(.horizontal, PhoneStyle.Space.s5)
            .padding(.vertical, PhoneStyle.Space.s4)
        }
    }
}

/// Write Notes (Done while writing) and Take Photo, beside Stop.
private struct TableTools: View {
    @Binding var writing: Bool
    var size: CGFloat

    var body: some View {
        HStack(spacing: PhoneStyle.Space.s3) {
            Button { writing.toggle() } label: {
                Image(systemName: writing ? "keyboard.chevron.compact.down" : "square.and.pencil")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(PhoneStyle.Ink.title)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(writing ? "Done Writing" : "Write Notes")
            CameraControl(size: size)
        }
    }
}

/// Flex mode's Bookmark: a wide amber target on the flat half, where the hand rests.
private struct FlexBookmarkTarget: View {
    @Environment(PhoneAppModel.self) private var model
    var touched: () -> Void

    var body: some View {
        let count = model.recorder.bookmarkCount
        Button {
            touched()
            Task { try? await model.addBookmark() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .symbolEffect(.bounce, value: count)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bookmark").font(.title2.weight(.semibold))
                    Text(count == 0 ? "Tap to mark this moment" : count == 1 ? "1 so far" : "\(count) so far")
                        .font(.subheadline.monospacedDigit())
                        .opacity(0.8)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(PhoneStyle.bookmark)
            .frame(maxWidth: .infinity, minHeight: 140)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .sensoryFeedback(.impact(weight: .heavy), trigger: count)
        .accessibilityLabel(count > 0 ? "Bookmark, \(count) so far" : "Bookmark")
    }
}

/// The table's Bookmark: a large amber target meant to be hit without looking.
private struct TableBookmarkTarget: View {
    @Environment(PhoneAppModel.self) private var model
    var touched: () -> Void

    var body: some View {
        let count = model.recorder.bookmarkCount
        Button {
            touched()
            Task { try? await model.addBookmark() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .symbolEffect(.bounce, value: count)
                Text("Bookmark")
                    .font(.title2.weight(.semibold))
                Text(count == 0 ? "Tap to mark this moment" : count == 1 ? "1 so far" : "\(count) so far")
                    .font(.subheadline.monospacedDigit())
                    .opacity(0.8)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(PhoneStyle.bookmark)
            .frame(width: RecordingStyle.Control.tableTarget, height: RecordingStyle.Control.tableTarget)
            .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .sensoryFeedback(.impact(weight: .heavy), trigger: count)
        .accessibilityLabel(count > 0 ? "Bookmark, \(count) so far" : "Bookmark")
    }
}
