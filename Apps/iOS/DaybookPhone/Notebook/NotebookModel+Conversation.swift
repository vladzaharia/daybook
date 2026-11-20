import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import PencilKit
import UIKit

/// Strokes written in a saved conversation's notebook between commits (a crash safety, never synced): a file per page in the
/// library's drafts folder, rewritten as the canvas changes and gone once its strokes are committed and the conversation is on
/// disk. Beside each is the SHA-256 of the drawing the canvas was loaded or last committed from, so recovery can tell what changed
/// elsewhere meanwhile (the staging journal keeps a page's base the same way).
struct PageDrafts {
    let folder: URL

    init(root: URL, meeting: UUID) {
        folder = root.appendingPathComponent("Drafts/Pages/\(meeting.uuidString)", isDirectory: true)
    }

    func url(_ page: UUID) -> URL { folder.appendingPathComponent("\(page.uuidString).\(PageDrawing.fileExtension)") }
    func baseURL(_ page: UUID) -> URL { folder.appendingPathComponent("\(page.uuidString).base") }

    func write(_ data: Data, page: UUID, base: String? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data((base ?? "").utf8).write(to: baseURL(page), options: [.atomic, .completeFileProtectionUnlessOpen])
            try data.write(to: url(page), options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch { return false }
    }

    func base(of page: UUID) -> String? {
        let text = (try? String(contentsOf: baseURL(page), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    func remove(page: UUID) {
        try? FileManager.default.removeItem(at: url(page))
        try? FileManager.default.removeItem(at: baseURL(page))
    }

    /// Commits what a crash (or a commit that never reached the disk) cut off. A draft whose page is deleted just goes; one whose
    /// page is missing from the conversation brings the page back first. A page changed elsewhere since the draft began (or whose
    /// base isn't known) has its strokes and the draft's merged by stroke, as the notebook does at a commit; when that drawing isn't
    /// on this iPhone yet, or the commit or the save fails, the draft stays for the next time. A draft goes only once the conversation
    /// holding its strokes is on disk.
    @MainActor
    func recover(in id: UUID, library: LibraryController, device: String = UIDevice.current.name) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let drafts = files.filter { $0.pathExtension == PageDrawing.fileExtension }
        guard !drafts.isEmpty, library.meeting(id) != nil, (try? await library.flushDurably([id])) != nil else { return }
        for file in drafts {
            guard let pageID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file) else { continue }
            await recover(pageID, data: data, in: id, library: library, device: device)
        }
    }

    @MainActor
    private func recover(_ pageID: UUID, data: Data, in id: UUID, library: LibraryController, device: String) async {
        if library.meeting(id)?.page(pageID) == nil {
            let order = (library.meeting(id)?.pages ?? []).map(\.order).max() ?? 0
            library.addPage(NotebookPage(id: pageID, order: order + 1), to: id)
        }
        guard let page = library.meeting(id)?.page(pageID) else { return }
        guard page.removedAt == nil, let canvas = try? PKDrawing(data: data) else { return remove(page: pageID) }
        var strokes = canvas
        if let stored = page.drawing, stored.sha256 != base(of: pageID) {
            guard let storedData = localPageData(stored, in: id, library: library), let theirs = try? PKDrawing(data: storedData) else { return }
            var erased: Set<String> = []
            if let base = base(of: pageID), let before = localPageData(PageDrawing(relativePath: PageDrawing.relativePath(page: pageID, sha256: base), sha256: base,
                                                                                    byteCount: 0, strokeCount: 0, editedAt: .distantPast), in: id, library: library),
               let earlier = try? PKDrawing(data: before) {
                erased = Set(NotebookReader.strokes(of: earlier).map(\.key)).subtracting(NotebookReader.strokes(of: canvas).map(\.key))
            }
            strokes = NotebookReader.merging(canvas, with: theirs, erasedHere: erased)
        }
        let bytes = strokes.strokes.count == canvas.strokes.count ? data : strokes.dataRepresentation()
        if page.drawing?.sha256 != AudioDigest.sha256(data: bytes) {
            guard (try? await library.commitPageDrawing(bytes, page: pageID, in: id, strokeCount: strokes.strokes.count,
                                                        contentVersion: strokes.requiredContentVersion.rawValue, device: device)) != nil else { return }
        }
        guard (try? await library.flushDurably([id])) != nil else { return }
        remove(page: pageID)
    }
}

/// A page's drawing from the conversation's folder, nil when it isn't on this iPhone.
@MainActor
private func localPageData(_ drawing: PageDrawing, in id: UUID, library: LibraryController) -> Data? {
    guard library.hasLocalPageDrawing(drawing, in: id) else { return nil }
    return try? Data(contentsOf: library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)"))
}

/// The player's position, as the notebook samples it, so strokes written while a saved conversation plays are timed by the player
/// on the recording it has loaded (trackID and seconds) rather than by the wall clock. Samples are taken when a stroke begins (which
/// trails the stroke's own creation date) and whenever the player plays, pauses, seeks, or changes track, and speak for moments the
/// way the recorder's do (`RecordingClockMap.elapsed`): the latest at or before a moment, else the earliest just after it.
@MainActor
final class PlayerClock {
    private struct Entry { var at: Date; var position: TimeInterval; var playing: Bool; var track: UUID?; var rate: Double }
    private var entries: [Entry] = []
    /// How long a sample speaks for the moments after it (the player may have been moved since).
    static let reach: TimeInterval = RecordingClockMap.reach

    func sample(playing: Bool, position: TimeInterval, track: UUID?, rate: Double = 1, at now: Date) {
        entries.append(Entry(at: now, position: position, playing: playing && track != nil, track: track, rate: rate))
        if entries.count > 500 { entries.removeFirst(100) }
    }

    /// Seconds into the loaded recording at `moment`, while it was playing; nil when it wasn't (wall clock only).
    func anchor(_ moment: Date) -> (trackID: UUID?, time: TimeInterval?) {
        let chosen: Entry?
        if let before = entries.last(where: { $0.at <= moment }), moment.timeIntervalSince(before.at) <= Self.reach || entries.contains(where: { $0.at > moment }) {
            chosen = before
        } else {
            chosen = entries.first { $0.at > moment && $0.at.timeIntervalSince(moment) <= RecordingClockMap.trailing }
        }
        guard let sample = chosen, sample.playing else { return (nil, nil) }
        let time = sample.position + moment.timeIntervalSince(sample.at) * sample.rate
        return time.isFinite ? (sample.track, max(0, time)) : (nil, nil)
    }
}

extension NotebookModel {
    /// A saved conversation's pages: strokes in the library's files (brought from iCloud when they aren't on this iPhone), each change
    /// a thin edit of the conversation. `durably` waits for the conversation to be on disk (the library flushes by default).
    @MainActor
    static func conversation(_ id: UUID, model: PhoneAppModel, player: PlaybackController, provider: any AudioProviding,
                             drafts: PageDrafts, durably: ((UUID) async throws -> Void)? = nil) -> NotebookModel {
        let library = model.library.controller
        let clock = PlayerClock()
        let fetched = FetchedDrawings()
        let durably = durably ?? { try await library.flushDurably([$0]) }
        func local(_ drawing: PageDrawing) -> Data? {
            if let url = fetched.urls[drawing.sha256], let data = try? Data(contentsOf: url) { return data }
            return localPageData(drawing, in: id, library: library)
        }
        func sample() {
            clock.sample(playing: player.isActive(for: id) && player.isPlaying, position: player.position, track: player.trackID,
                         rate: Double(player.rate), at: Date())
        }
        player.moved = { sample() }
        return NotebookModel(
            pages: { library.meeting(id)?.visiblePages ?? [] },
            content: { pageID in
                guard let drawing = library.meeting(id)?.page(pageID)?.drawing else { return .blank }
                return local(drawing).map(NotebookPageContent.strokes) ?? .notLoaded
            },
            fetch: { pageID in
                guard let drawing = library.meeting(id)?.page(pageID)?.drawing else { return false }
                do {
                    fetched.urls[drawing.sha256] = try await provider.localPageDrawing(for: drawing, in: id)
                    return true
                } catch { return false }
            },
            add: { library.addPage($0, to: id) },
            saveDraft: { drafts.write($1, page: $0, base: $2) },
            commit: { pageID, data, count, version in
                let stored = try await library.commitPageDrawing(data, page: pageID, in: id, strokeCount: count, contentVersion: version,
                                                                 device: UIDevice.current.name)
                // The conversation is saved a moment after the change: the draft stays until it has reached the disk (or `recover` finds it).
                if (try? await durably(id)) != nil { drafts.remove(page: pageID) }
                return stored.sha256
            },
            applyReading: { library.applyPageReading($1, to: $0, in: id) },
            correct: { library.correctPassage(pageID: $0, passageID: $1, text: $2, in: id) },
            remove: { library.removePage($0, in: id) },
            recordErasures: { pageID, erased in library.update(id) { $0.recordErasures(erased, on: pageID) } },
            // Turns of a saved conversation's notebook are logged only against a recording clock: while it plays.
            logTurn: { turn in if turn.time != nil { library.update(id) { $0.logPageTurn(turn) } } },
            sampleClock: { sample() },
            // What a recording filed with its clock knows is exact; otherwise the player's position when it was playing.
            anchor: { moment in library.meeting(id)?.recordingPlacement(at: moment) ?? clock.anchor(moment) },
            play: { passage, page in
                guard let meeting = library.meeting(id), let target = meeting.playbackTarget(of: passage, on: page) else { return }
                player.play(target, in: meeting, provider: provider)
            },
            origin: .thisIPhone(installation: model.library.installationID),
            setHiddenFromSummary: { library.setPageHiddenFromSummary($0, hidden: $1, in: id) })
    }
}

/// Drawings fetched to this iPhone, by SHA-256.
@MainActor
private final class FetchedDrawings {
    var urls: [String: URL] = [:]
}
