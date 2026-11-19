import DaybookCore
import DaybookKit
import DaybookUI
import Foundation
import PencilKit
import UIKit

/// Strokes written in a saved conversation's notebook between commits (a crash safety, never synced): a file per page in the
/// library's drafts folder, rewritten as the canvas changes and gone once its strokes are committed.
struct PageDrafts {
    let folder: URL

    init(root: URL, meeting: UUID) {
        folder = root.appendingPathComponent("Drafts/Pages/\(meeting.uuidString)", isDirectory: true)
    }

    func url(_ page: UUID) -> URL { folder.appendingPathComponent("\(page.uuidString).\(PageDrawing.fileExtension)") }

    func write(_ data: Data, page: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url(page), options: [.atomic, .completeFileProtectionUnlessOpen])
            return true
        } catch { return false }
    }

    func remove(page: UUID) { try? FileManager.default.removeItem(at: url(page)) }

    /// A draft whose strokes differ from the committed drawing and are newer than it is the work a crash cut off: it's committed, then
    /// goes. One that's older, or the same, just goes.
    @MainActor
    func recover(in id: UUID, library: LibraryController) async {
        for page in library.meeting(id)?.visiblePages ?? [] {
            let file = url(page.id)
            guard let data = try? Data(contentsOf: file) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let sha = AudioDigest.sha256(data: data)
            if page.drawing?.sha256 != sha, modified > (page.drawing?.editedAt ?? .distantPast),
               let strokes = try? PKDrawing(data: data) {
                _ = try? await library.commitPageDrawing(data, page: page.id, in: id, strokeCount: strokes.strokes.count,
                                                         contentVersion: strokes.requiredContentVersion.rawValue,
                                                         device: UIDevice.current.name)
            }
            remove(page: page.id)
        }
    }
}

/// The player's position, as the notebook samples it when a stroke begins, so strokes written while a saved conversation plays are
/// timed by the player on the recording it has loaded (trackID and seconds) rather than by the wall clock.
@MainActor
final class PlayerClock {
    private struct Entry { var at: Date; var position: TimeInterval; var playing: Bool; var track: UUID? }
    private var entries: [Entry] = []
    /// How long a sample speaks for the moments after it (the player may have been moved since).
    static let reach: TimeInterval = 120

    func sample(playing: Bool, position: TimeInterval, track: UUID?, at now: Date) {
        entries.append(Entry(at: now, position: position, playing: playing && track != nil, track: track))
        if entries.count > 500 { entries.removeFirst(100) }
    }

    /// Seconds into the loaded recording at `moment`, while it was playing; nil when it wasn't (wall clock only).
    func anchor(_ moment: Date) -> (trackID: UUID?, time: TimeInterval?) {
        guard let before = entries.last(where: { $0.at <= moment }), before.playing, moment.timeIntervalSince(before.at) <= Self.reach else { return (nil, nil) }
        return (before.track, max(0, before.position + moment.timeIntervalSince(before.at)))
    }
}

extension NotebookModel {
    /// A saved conversation's pages: strokes in the library's files (brought from iCloud when they aren't on this iPhone), each change
    /// a thin edit of the conversation.
    @MainActor
    static func conversation(_ id: UUID, model: PhoneAppModel, player: PlaybackController, provider: any AudioProviding,
                             drafts: PageDrafts) -> NotebookModel {
        let library = model.library.controller
        let clock = PlayerClock()
        let fetched = FetchedDrawings()
        func local(_ drawing: PageDrawing) -> Data? {
            if let url = fetched.urls[drawing.sha256], let data = try? Data(contentsOf: url) { return data }
            guard library.hasLocalPageDrawing(drawing, in: id) else { return nil }
            return try? Data(contentsOf: library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)/\(drawing.relativePath)"))
        }
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
            saveDraft: { drafts.write($1, page: $0) },
            commit: { pageID, data, count, version in
                let stored = try await library.commitPageDrawing(data, page: pageID, in: id, strokeCount: count, contentVersion: version,
                                                                 device: UIDevice.current.name)
                drafts.remove(page: pageID)
                return stored.sha256
            },
            applyReading: { library.applyPageReading($1, to: $0, in: id) },
            correct: { library.correctPassage(pageID: $0, passageID: $1, text: $2, in: id) },
            remove: { library.removePage($0, in: id) },
            recordErasures: { pageID, erased in library.update(id) { $0.recordErasures(erased, on: pageID) } },
            // Turns of a saved conversation's notebook are logged only against a recording clock: while it plays.
            logTurn: { turn in if turn.time != nil { library.update(id) { $0.logPageTurn(turn) } } },
            sampleClock: {
                clock.sample(playing: player.isActive(for: id) && player.isPlaying, position: player.position, track: player.trackID, at: Date())
            },
            anchor: { clock.anchor($0) },
            play: { passage, page in
                guard let meeting = library.meeting(id), let target = meeting.playbackTarget(of: passage, on: page) else { return }
                player.play(target, in: meeting, provider: provider)
            },
            origin: .thisIPhone(installation: model.library.installationID))
    }
}

/// Drawings fetched to this iPhone, by SHA-256.
@MainActor
private final class FetchedDrawings {
    var urls: [String: URL] = [:]
}
