#if DEBUG
import AppKit
import CoreText
import DaybookCore
import DaybookKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Debug-only: `--photo-demo` adds a conversation with photos to the `--library` folder (never the
/// everyday library): a recording's timeline, a transcript, a summary, and four photos drawn here (a
/// whiteboard, a slide, a sketch, and a blurred shot), so the photo surfaces can be captured without
/// a camera. The photos are read by Apple Vision as they would be after processing. `--open-photo`
/// opens the first one in the viewer.
@MainActor
enum PhotoDemo {
    static let title = "Spring launch review"
    static var isRequested: Bool { CommandLine.arguments.contains("--photo-demo") && LaunchOptions.libraryURL != nil }
    static var opensPhoto: Bool { CommandLine.arguments.contains("--open-photo") }

    static func apply(to state: AppState) {
        guard isRequested else { return }
        if let existing = state.meetings.first(where: { $0.title == title }) { state.selectedID = existing.id; return }
        Task { await seed(state) }
    }

    private static func seed(_ state: AppState) async {
        let start = Date().addingTimeInterval(-3 * 3600)
        let id = state.library.newMeeting(title: title, date: start)
        state.selectedID = id
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Photo Demo \(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("Microphone.wav")
        try? silentWAV(seconds: 600).write(to: audio)
        await state.library.acquireLock()
        defer { state.library.releaseLock() }
        guard let ingested = try? await state.library.ingest(audio, into: id, provenance: RecordingProvenance(
            source: .microphone, offset: 0, duration: 600, startedAt: start, capture: TrackCaptureDetails())),
              let track = ingested.track else { return }
        let lines: [(TimeInterval, String, String)] = [
            (4, "0", "Let's start with the spring launch budget. Marketing is running about ten percent over."),
            (22, "1", "The events line is under, so overall we're close. I put the numbers on the whiteboard."),
            (95, "0", "Good. Then we move four thousand from events to marketing and keep the launch date."),
            (240, "1", "On hiring, we still need two designers and a recruiter before the summer."),
            (262, "0", "I'll post both design roles this week. Priya will talk to the recruiting agency."),
            (410, "1", "Last thing: the packaging sketch. The box opens from the side now."),
            (431, "0", "That works. Let's send it to the printer for a sample by Friday.")
        ]
        state.update(id) { meeting in
            meeting.speakers = [Speaker(id: "0", name: "Alex"), Speaker(id: "1", name: "Priya")]
            meeting.unifiedTranscript = lines.enumerated().map { index, line in
                let end = index + 1 < lines.count ? lines[index + 1].0 - 1 : line.0 + 14
                return TranscriptSegment(trackID: track.id, start: line.0, end: end, text: line.2, speakerID: line.1)
            }
            meeting.notes = "Move budget from events to marketing\nPackaging sample by Friday"
            meeting.timedNotes = [TimedNote(time: 100, text: "Move budget from events to marketing"),
                                  TimedNote(time: 440, text: "Packaging sample by Friday")]
            meeting.status = .ready
        }
        let origin = PhotoOrigin(kind: PhotoOrigin.macKind, name: Host.current().localizedName)
        let shots: [(TimeInterval, String, Data?)] = [
            (30, "IMG_2041.HEIC", jpeg(board(["SPRING LAUNCH", "Marketing  +10%", "Events  −10%", "Launch: May 12"]))),
            (250, "IMG_2042.HEIC", jpeg(board(["HIRING PLAN", "2 designers", "1 recruiter", "before summer"], tint: 0.93))),
            (418, "IMG_2043.HEIC", jpeg(sketch())),
            (419, "IMG_2044.HEIC", jpeg(board(["PACKAGING"], blur: 22)))
        ]
        var ids: [UUID] = []
        for (time, name, data) in shots {
            guard let data else { continue }
            if let photo = try? await state.library.addPhoto(data: data, to: id, fileName: name,
                                                              timing: PhotoTimingInput(capturedAt: start.addingTimeInterval(time), time: time), origin: origin) {
                ids.append(photo.id)
            }
        }
        guard ids.count == 4 else { return }
        state.update(id) { meeting in
            meeting.setSummary(MeetingSummary(kind: .general, title: title,
                overview: "The team rebalanced the spring launch budget, kept the May 12 date, planned two design hires and a recruiter, and approved the side-opening packaging.",
                sections: [
                    SummarySection(heading: "Budget", body: "- Marketing is about 10% over; events are under.\n- Four thousand moves from events to marketing.", photoIDs: [ids[0]]),
                    SummarySection(heading: "Hiring", body: "- Two designers and a recruiter are needed before summer.\n- Alex posts the design roles this week."),
                    SummarySection(heading: "Packaging", body: "- The box now opens from the side.\n- A printer sample is due Friday.", photoIDs: [ids[2], ids[3]])
                ],
                actionItems: [ActionItem(text: "Post both design roles this week", owner: "Alex"),
                              ActionItem(text: "Talk to the recruiting agency", owner: "Priya"),
                              ActionItem(text: "Send the packaging sketch to the printer for a sample by Friday")],
                modelID: "gemma-4/e2b-4bit"))
        }
        // Read by Apple Vision, then placed as processing would: the blurred shot comes out, and the
        // hiring board lands under Hiring by when it was taken.
        state.readPhotosWhenIdle(id)
    }

    // MARK: Drawing

    private static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// A whiteboard photographed at an angle-free distance: off-white, a frame, marker lines.
    static func board(_ lines: [String], tint: CGFloat = 0.97, blur: Int = 1) -> CGImage {
        let width = 1600, height = 1200
        let canvas = context(width, height)
        canvas.setFillColor(CGColor(red: 0.42, green: 0.40, blue: 0.37, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setFillColor(CGColor(red: tint, green: tint, blue: tint - 0.02, alpha: 1))
        canvas.fill(CGRect(x: 70, y: 70, width: width - 140, height: height - 140))
        let colors = [CGColor(red: 0.08, green: 0.25, blue: 0.62, alpha: 1), CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
                      CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.72, green: 0.12, blue: 0.1, alpha: 1)]
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName((index == 0 ? "MarkerFelt-Wide" : "MarkerFelt-Thin") as CFString, index == 0 ? 120 : 96, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors[index % colors.count]]
            canvas.textPosition = CGPoint(x: 170, y: CGFloat(height - 290 - index * 190))
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), canvas)
        }
        let sharp = canvas.makeImage()!
        guard blur > 1 else { return sharp }
        let small = context(width / blur, height / blur)
        small.interpolationQuality = .high
        small.draw(sharp, in: CGRect(x: 0, y: 0, width: width / blur, height: height / blur))
        let large = context(width, height)
        large.interpolationQuality = .high
        large.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height))
        return large.makeImage()!
    }

    /// A packaging sketch on paper: a box and its side flap.
    static func sketch() -> CGImage {
        let width = 1600, height = 1200
        let canvas = context(width, height)
        canvas.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.9, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.setStrokeColor(CGColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1))
        canvas.setLineWidth(9)
        canvas.stroke(CGRect(x: 420, y: 300, width: 620, height: 520))
        canvas.move(to: CGPoint(x: 420, y: 820)); canvas.addLine(to: CGPoint(x: 600, y: 980)); canvas.addLine(to: CGPoint(x: 1220, y: 980))
        canvas.addLine(to: CGPoint(x: 1040, y: 820)); canvas.strokePath()
        canvas.move(to: CGPoint(x: 1040, y: 300)); canvas.addLine(to: CGPoint(x: 1220, y: 460)); canvas.addLine(to: CGPoint(x: 1220, y: 980)); canvas.strokePath()
        canvas.setStrokeColor(CGColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1))
        canvas.move(to: CGPoint(x: 1040, y: 560)); canvas.addCurve(to: CGPoint(x: 1380, y: 620), control1: CGPoint(x: 1200, y: 520), control2: CGPoint(x: 1320, y: 560))
        canvas.strokePath()
        let font = CTFontCreateWithName("MarkerFelt-Thin" as CFString, 80, nil)
        canvas.textPosition = CGPoint(x: 820, y: 170)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "opens from the side", attributes: [.font: font, .foregroundColor: CGColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1)])), canvas)
        return canvas.makeImage()!
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 16 kHz mono PCM silence.
    static func silentWAV(seconds: Int) -> Data {
        let samples = 16_000 * seconds, bytes = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }
}
#endif
