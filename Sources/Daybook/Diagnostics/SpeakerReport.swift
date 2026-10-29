#if DEBUG
import DaybookCore
import Foundation

/// Debug only: `Daybook --speaker-report <library> [--threshold <similarity>] [--margin <margin>]
/// [--recognition off]` reconciles a library's speaker profiles as a dry run and prints aggregate
/// numbers (`SpeakerProfileReport`): speakers by kind of recording, labelled, suggested, and unknown,
/// and how alike voices are to the profiles. Point it at a copy of the library. It reads
/// `library.json` and each conversation's `meeting.json` and writes nothing: no store is opened, no
/// recovery copy is made, nothing syncs (docs/validation.md, "Speaker profiles on real recordings").
enum SpeakerReport {
    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--speaker-report") else {
            print("Usage: Daybook --speaker-report <library> [--threshold 0.82] [--margin 0.06] [--recognition off]")
            return 2
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (meetings, metadata, problems) = read(root)
        guard !meetings.isEmpty || metadata != nil else {
            FileHandle.standardError.write(Data("No conversations or library settings found in \(root.path).\n".utf8))
            return 1
        }
        let matching = SpeakerProfileMatching(labelSimilarity: value("--threshold").flatMap(Double.init) ?? 0.82,
                                              margin: value("--margin").flatMap(Double.init) ?? 0.06)
        let options = SpeakerProfileOptions(matching: matching, recognizes: value("--recognition") != "off")
        let report = SpeakerProfileReport.make(meetings: meetings, metadata: metadata ?? LibraryMetadata(), options: options)
        print(report.text, terminator: "")
        if !problems.isEmpty { print("\nSkipped \(problems.count) conversation\(problems.count == 1 ? "" : "s") that couldn’t be read.") }
        return 0
    }

    /// The library's settings and conversations, read without opening the library: a conversation's
    /// recovery copy stands in for a `meeting.json` that doesn't decode. The Trash is left out.
    static func read(_ root: URL) -> (meetings: [Meeting], metadata: LibraryMetadata?, problems: [String]) {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ urls: [URL]) -> T? {
            for url in urls { if let data = try? Data(contentsOf: url), let value = try? decoder.decode(type, from: data) { return value } }
            return nil
        }
        let metadata = decode(LibraryMetadata.self, [root.appendingPathComponent("library.json"), root.appendingPathComponent("library.recovery.json")])
        let folder = root.appendingPathComponent("Meetings", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var meetings: [Meeting] = [], problems: [String] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where UUID(uuidString: child.lastPathComponent) != nil {
            if let meeting = decode(Meeting.self, [child.appendingPathComponent("meeting.json"), child.appendingPathComponent("meeting.recovery.json")]),
               meeting.schemaVersion == 1 {
                meetings.append(meeting)
            } else {
                problems.append(child.lastPathComponent)
            }
        }
        return (meetings, metadata, problems)
    }
}
#endif
