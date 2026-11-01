#if DEBUG
import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// Debug only: `Daybook --cloud-check <anthropic|openai> <model> <fixture.json> [--fixture <id>] [--effort low|medium|high]
/// [--output <run.json>]` summarizes one synthetic conversation with a cloud model, exactly as Settings › Cloud's choice
/// would (`CloudSummarizer`), and prints the summary, the tokens in and out, the estimated cost, and the time
/// (docs/cloud.md, "Checking a model"). The key comes from `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or
/// `DAYBOOK_CLOUD_KEY`) and is never printed or stored; nothing touches a library, the keychain, or the app's
/// preferences. `DAYBOOK_CLOUD_BASE_URL` sends every request to another server (a local fake one).
///
/// The fixture is the summary harness's format, `[{id, title, kind, templateID?, speakers: {id: name}, lines: [[speaker,
/// text]], notes: [{after?, text}], bookmarks: [{during, text}]}]` (one object or a list: the first, or `--fixture <id>`),
/// or a conversation's `meeting.json`. `--output` writes the run in the harness's scoring format.
enum CloudCheck {
    struct Fixture: Decodable {
        struct Note: Decodable { var after: String?; var text: String }
        struct Mark: Decodable { var during: String; var text: String }
        var id: String?
        var title: String
        var kind: String?
        var templateID: String?
        var speakers: [String: String]
        var lines: [[String]]
        var notes: [Note]?
        var bookmarks: [Mark]?
    }

    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let index = arguments.firstIndex(of: "--cloud-check"), index + 3 < arguments.count,
              let provider = CloudProvider(rawValue: arguments[index + 1].lowercased()) else {
            print("Usage: Daybook --cloud-check <anthropic|openai> <model> <fixture.json> [--fixture <id>] [--effort low|medium|high] [--output <run.json>]")
            return 2
        }
        let modelID = arguments[index + 2]
        let fixtureURL = URL(fileURLWithPath: (arguments[index + 3] as NSString).expandingTildeInPath)
        let environment = ProcessInfo.processInfo.environment
        let variable = provider == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        guard let key = (environment["DAYBOOK_CLOUD_KEY"] ?? environment[variable]).flatMap(CloudAPIKey.init) else {
            print("Set \(variable) (or DAYBOOK_CLOUD_KEY) to the key to use.")
            return 2
        }
        let effort = value("--effort").flatMap(CloudEffort.init(rawValue:)) ?? .medium
        let meeting: Meeting
        do { meeting = try self.meeting(at: fixtureURL, id: value("--fixture")) }
        catch {
            print("The fixture couldn’t be read: \(error.localizedDescription)")
            return 1
        }

        // Caches go to a throwaway suite, never the app's preferences.
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-cloud-check-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: suite + ".plist") }
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        var client = CloudClient()
        if let base = environment["DAYBOOK_CLOUD_BASE_URL"].flatMap(URL.init(string:)) { client.endpoints = CloudEndpoints(base: base) }
        let directory = CloudDirectory(keys: MemoryCloudKeyStore([provider: key]), client: client, defaults: defaults)
        print("Key: \(key.masked)")
        do {
            let listed = try await directory.check(key, for: provider)
            print("This key works: \(listed.count) models listed.")
        } catch let error as CloudError {
            print("\(error.message)\n\(error.details)")
            return 1
        } catch {
            print(error.localizedDescription)
            return 1
        }
        let offers = await directory.offers(refresh: true)
        guard let offer = offers.offer(modelID, provider: provider) else {
            let offered = offers.filter { $0.model.provider == provider }.map(\.id).joined(separator: ", ")
            print("\(modelID) isn’t offered for this key. Offered: \(offered.isEmpty ? "none" : offered)")
            return 1
        }
        let model = offer.model
        print("Model: \(model.name) (\(model.id)), \(model.tier.rawValue) tier, effort \(offer.effort(effort).rawValue)")
        if let price = offer.price {
            print(String(format: "Price: $%.2f in, $%.2f out per million tokens%@", price.input, price.output, model.priceIsEstimated ? " (estimated)" : ""))
        }
        let minutes = (meeting.unifiedTranscript.map(\.end).max() ?? 0) / 60
        if let estimate = offer.estimatedCost(minutes: minutes, effort: effort) {
            print(String(format: "Conversation: %.0f minutes; estimated cost $%.4f", minutes, estimate))
        }

        let started = Date()
        let summarizer = CloudSummarizer(directory: directory, deviceName: "cloud-check")
        let result: CloudSummarizer.Result
        do {
            result = try await summarizer.summary(meeting, template: nil, vocabulary: [], model: model, effort: effort) { fraction in
                FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", fraction * 100).utf8))
            }
        } catch let error as CloudError {
            print("\n\(error.message)\n\(error.details)")
            return 1
        } catch {
            print("\n\(error.localizedDescription)")
            return 1
        }
        let seconds = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data("\r".utf8))
        let provenance = result.provenance
        print(String(format: "Done in %.1f s: %d tokens in, %d out; estimated cost $%.4f", seconds, provenance.inputTokens, provenance.outputTokens,
                     provenance.estimatedCost ?? 0))
        print("Written by: \(provenance.name) (\(provenance.modelID))")
        print(text(result.summary))
        if !result.warnings.isEmpty { print("Warnings:\n" + result.warnings.map { "- \($0)" }.joined(separator: "\n")) }
        if let output = value("--output") {
            let run: [String: Any] = [
                "fixture": value("--fixture") ?? fixtureURL.deletingPathExtension().lastPathComponent, "model": provenance.modelID,
                "seconds": seconds, "cost": provenance.estimatedCost ?? 0, "effort": provenance.effort.rawValue,
                "passes": [["in": provenance.inputTokens, "out": provenance.outputTokens, "seconds": seconds]],
                "title": result.summary.title, "overview": result.summary.overview,
                "sections": result.summary.sections.map { ["heading": $0.heading, "body": $0.body] },
                "actions": result.summary.actionItems.map { ["text": $0.text, "owner": $0.owner as Any? ?? NSNull()] },
                "warnings": result.warnings
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
                print("Run written to \(output)")
            } catch {
                print("The run couldn’t be written: \(error.localizedDescription)")
                return 1
            }
        }
        return 0
    }

    /// The summary as plain text: title, overview, sections, and next steps with their owners.
    static func text(_ summary: MeetingSummary) -> String {
        var lines = ["", "# \(summary.title)", "", summary.overview]
        for section in summary.sections { lines += ["", "## \(section.heading)", section.body] }
        if !summary.actionItems.isEmpty {
            lines += ["", "## Next steps"] + summary.actionItems.map { "- \($0.text)\($0.owner.map { " (\($0))" } ?? "")" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The fixture as a conversation: passages at 2.5 words a second, notes and bookmarks at the passages they name;
    /// or a `meeting.json` as it is.
    static func meeting(at url: URL, id: String?) throws -> Meeting {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let meeting = try? decoder.decode(Meeting.self, from: data) { return meeting }
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let meeting = try? iso.decode(Meeting.self, from: data) { return meeting }
        let fixtures: [Fixture]
        if let list = try? decoder.decode([Fixture].self, from: data) { fixtures = list } else { fixtures = [try decoder.decode(Fixture.self, from: data)] }
        guard let fixture = id.map({ id in fixtures.first { $0.id == id } }) ?? fixtures.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No fixture \(id ?? "") in the file."])
        }
        let track = UUID()
        var segments: [TranscriptSegment] = []
        var time = 0.0
        for line in fixture.lines where line.count >= 2 {
            let end = time + Double(line[1].split(separator: " ").count) / 2.5
            segments.append(TranscriptSegment(trackID: track, start: time, end: end, text: line[1], speakerID: line[0]))
            time = end + 0.6
        }
        func segment(_ snippet: String) -> TranscriptSegment? { segments.first { $0.text.hasPrefix(snippet) } }
        var meeting = Meeting(title: fixture.title, kind: fixture.kind.flatMap(MeetingKind.init(rawValue:)) ?? .auto,
                              speakers: fixture.speakers.map { Speaker(id: $0.key, name: $0.value) })
        meeting.templateID = fixture.templateID
        meeting.unifiedTranscript = segments
        let notes = fixture.notes ?? []
        meeting.notes = notes.map(\.text).joined(separator: "\n")
        meeting.timedNotes = notes.map { note in TimedNote(time: note.after.flatMap(segment).map { $0.end + 4 }, text: note.text) }
        meeting.highlights = (fixture.bookmarks ?? []).compactMap { mark in
            segment(mark.during).map { Highlight(time: $0.start + 1, text: mark.text.isEmpty ? "Marked moment" : mark.text) }
        }
        return meeting
    }
}
#endif
