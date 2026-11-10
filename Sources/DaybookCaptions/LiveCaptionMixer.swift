import Foundation

/// One recording's captions from every source that heard it, put together as they arrive, off the main
/// actor: this device's own sources (a Mac's You and Call, an iPhone's microphone) and other devices'
/// (a recorder recording along, a paired iPhone or Mac). Several sources hear the same speech, so lines
/// from different sources that overlap in time and share most of the shorter one's words, or where one's
/// ending is the other's beginning, are one utterance (`LiveCaptionMix.matches`) and read once:
///
/// - The utterance's words come from the source that heard it best: the call for remote speakers, else
///   the one with the highest level (a worn recorder for its wearer, the nearest microphone for the
///   room), else this device's own. A line from another source that runs on past those words shows only
///   its new words; one that adds nothing isn't shown. A line no other source heard shows as it is,
///   labelled with its device.
/// - Verdicts are sticky, so lines don't flicker: until all its lines are final, or `settlesAfter` has
///   passed, an utterance keeps the source it first read from, and a line still being revised never
///   takes the place of a final one. Once settled the best source is chosen again, once.
/// - Only lines near a change are judged again; lines that ended `frozenAfter` before the newest keep
///   their verdicts. Each line's words are folded once, when its text changes.
///
/// This device's microphone and call are one utterance only through the speakers' echo: `echoes(_:from:)`
/// says from when the output can echo (not headphones).
///
/// The main actor gets the newest lines (`Tail`) and a version; the whole list is built only to be saved
/// (`lines()`). Captions are never the transcript, merged or not: tentative, never fused, summarized, or
/// used as evidence.
public actor LiveCaptionMixer {
    /// The newest lines and a version that grows with every change, for the main actor.
    public struct Tail: Equatable, Sendable {
        public var lines: [LiveCaptionSegment]
        public var version: Int

        public init(lines: [LiveCaptionSegment] = [], version: Int = 0) {
            self.lines = lines; self.version = version
        }
    }

    /// Lines that ended this long before the newest keep their verdicts.
    public static let frozenAfter: TimeInterval = 30
    /// An utterance whose lines are still being revised settles this long after it ends anyway.
    public static let settlesAfter: TimeInterval = 4
    /// A source's level must beat the one an utterance reads from by this much (0…1 meter) to take its place.
    public static let levelMargin = 0.1

    /// How many of the newest lines the main actor gets: as many as any surface shows.
    public let tailLength: Int

    private struct Unit {
        /// On this recording's timeline, `source` set.
        var line: LiveCaptionSegment
        let seq: Int
        var words: LiveCaptionMix.Words
        /// Changes with its words, so two lines' match is worked out again only when one's words change.
        var revision: Int
        /// Sent on to other devices (`forwardable`): this device's own and its recorders', not another device's.
        var forwards: Bool
        var cluster: Int?
        var source: LiveCaptionSource { line.source ?? .microphone }
    }

    private struct Cluster {
        var members: [UUID]
        var sources: Set<LiveCaptionSource>
        var best: LiveCaptionSource
        var settled: Bool
        var start: TimeInterval
        var end: TimeInterval
        /// The lines it shows.
        var shown: [UUID]
    }

    private struct Shown {
        var line: LiveCaptionSegment
        var key: Key
    }

    private struct Key: Comparable {
        var start: TimeInterval
        var seq: Int
        static func < (a: Key, b: Key) -> Bool { a.start == b.start ? a.seq < b.seq : a.start < b.start }
    }

    private var units: [UUID: Unit] = [:]
    /// Each source's lines by start.
    private var bySource: [LiveCaptionSource: [UUID]] = [:]
    /// Each source's longest line, so a search by start doesn't miss one that began well before.
    private var longest: [LiveCaptionSource: TimeInterval] = [:]
    private var clusters: [Int: Cluster] = [:]
    private var unsettled: Set<Int> = []
    private var nextCluster = 0
    private var nextSeq = 0
    private var shown: [UUID: Shown] = [:]
    private var order: [(key: Key, id: UUID)] = []
    /// While judging: lines the utterances judged again showed before, until they're shown again.
    private var stale: Set<UUID> = []
    private var own: Set<LiveCaptionSource> = []
    private var routes: [(time: TimeInterval, echoes: Bool)] = []
    private var levels: [LiveCaptionSource: [(time: TimeInterval, value: Double)]] = [:]
    private var newest: TimeInterval = 0
    private var version = 0
    private var revisions = 0
    /// Whether two lines' words are one utterance (by their arrival), as last worked out, with their revisions
    /// then; emptied each minute of the recording, since only lines near the newest are compared again.
    private var matched: [Pair: (a: Int, b: Int, matches: Bool)] = [:]
    private var matchedSince: TimeInterval = 0

    private struct Pair: Hashable {
        let a: Int, b: Int
    }

    public init(tailLength: Int = 8) {
        self.tailLength = tailLength
    }

    // MARK: What changes

    /// This device's sources: their lines carry their source only when there are several (a Mac's You and
    /// Call); one source's lines carry none.
    public func ownSources(_ sources: [LiveCaptionSource]) {
        own = Set(sources)
    }

    /// Everything one of this device's sources has heard, as its captioner last said (in time order). Only
    /// the lines since `frozenAfter` before the newest are compared with what it said before.
    public func heard(_ snapshot: [LiveCaptionSegment], from source: LiveCaptionSource,
                      levels: [LiveCaptionSource: Double] = [:]) -> Tail {
        var change = Change()
        replaceRecent(of: source, with: snapshot, offset: 0, forwards: true, into: &change)
        return apply(change, levels: levels)
    }

    /// Another device's lines. `offset` moves its times onto this recording's; lines from before this
    /// recording began are left out. All it has heard (a recorder's captioner), or with `changesOnly` only
    /// the lines that changed and those it took back (`removed`: a phone's link). `forwards`: its lines go on
    /// to other devices with this one's (a recorder this device manages), or stay here (another device's own).
    public func received(_ lines: [LiveCaptionSegment], removed: [UUID] = [], from source: LiveCaptionSource,
                         offset: TimeInterval, changesOnly: Bool, forwards: Bool = true,
                         levels: [LiveCaptionSource: Double] = [:]) -> Tail {
        var change = Change()
        if changesOnly {
            for line in lines { upsert(line, from: source, offset: offset, forwards: forwards, into: &change) }
            for id in removed { remove(id, into: &change) }
        } else {
            replaceRecent(of: source, with: lines, offset: offset, forwards: forwards, into: &change)
        }
        return apply(change, levels: levels)
    }

    /// From `time` on, whether this device's microphone can hear its call through the speakers (not
    /// headphones). Until said, it can.
    public func echoes(_ canEcho: Bool, from time: TimeInterval) -> Tail {
        guard routes.last?.echoes != canEcho else { return tail() }
        routes.append((time, canEcho))
        var change = Change()
        change.ranges.append(time...max(time, newest))
        return apply(change, levels: [:])
    }

    /// The audio ended: every line is kept as heard.
    public func heardAsSaid() -> Tail {
        var change = Change()
        for (id, unit) in units where unit.line.isTentative {
            units[id]?.line.isTentative = false
            change.touch(id, unit.line.start...unit.line.end)
        }
        return apply(change, levels: [:])
    }

    // MARK: What's read

    /// The newest lines, and the version.
    public func tail() -> Tail {
        Tail(lines: order.suffix(tailLength).compactMap { shown[$0.id]?.line }, version: version)
    }

    /// Every line shown, in time order: what's saved.
    public func lines() -> [LiveCaptionSegment] {
        order.compactMap { shown[$0.id]?.line }
    }

    /// Every line this device's sources and its recorders heard, as heard, in time order: what goes to
    /// another device recording the same conversation, which puts them together with its own.
    public func forwardable() -> [LiveCaptionSegment] {
        units.values.filter(\.forwards).sorted { Key(start: $0.line.start, seq: $0.seq) < Key(start: $1.line.start, seq: $1.seq) }
            .map(\.line)
    }

    // MARK: Taking lines in

    private struct Change {
        var ranges: [ClosedRange<TimeInterval>] = []
        var units: Set<UUID> = []
        var clusters: Set<Int> = []

        mutating func touch(_ id: UUID, _ range: ClosedRange<TimeInterval>) {
            units.insert(id)
            ranges.append(range)
        }
    }

    /// A source's whole list: its lines since the frozen ones are compared with what's here, and older
    /// lines only until one that's already here (a recorder's list when it joins).
    private func replaceRecent(of source: LiveCaptionSource, with lines: [LiveCaptionSegment], offset: TimeInterval,
                               forwards: Bool, into change: inout Change) {
        let horizon = newest - Self.frozenAfter
        var first = lines.count
        while first > 0, lines[first - 1].end + offset >= horizon { first -= 1 }
        while first > 0, units[lines[first - 1].id] == nil { first -= 1 }
        let recent = lines[first...]
        let kept = Set(recent.map(\.id))
        for id in (bySource[source] ?? []).reversed() {
            guard let unit = units[id] else { continue }
            if unit.line.end < horizon { break }
            if !kept.contains(id) { remove(id, into: &change) }
        }
        for line in recent { upsert(line, from: source, offset: offset, forwards: forwards, into: &change) }
    }

    private func upsert(_ line: LiveCaptionSegment, from source: LiveCaptionSource, offset: TimeInterval, forwards: Bool,
                        into change: inout Change) {
        var moved = line
        moved.start += offset
        moved.end += offset
        moved.source = source
        guard moved.end > 0, !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remove(line.id, into: &change)
            return
        }
        moved.start = max(0, moved.start)
        moved.end = max(moved.start, moved.end)
        if var unit = units[line.id] {
            guard unit.line != moved || unit.forwards != forwards else { return }
            let before = unit.line
            let moves = before.start != moved.start || before.source != moved.source
            if moves { detachOrder(line.id, source: unit.source, start: before.start) }
            if unit.line.text != moved.text {
                unit.words = LiveCaptionMix.Words(moved.text)
                revisions += 1
                unit.revision = revisions
            }
            unit.line = moved
            unit.forwards = forwards
            units[line.id] = unit
            if moves { insertOrder(line.id, source: source, start: moved.start) }
            if let cluster = unit.cluster { change.clusters.insert(cluster) }
            change.touch(line.id, min(before.start, moved.start)...max(before.end, moved.end))
        } else {
            nextSeq += 1
            revisions += 1
            units[line.id] = Unit(line: moved, seq: nextSeq, words: LiveCaptionMix.Words(moved.text), revision: revisions,
                                  forwards: forwards)
            insertOrder(line.id, source: source, start: moved.start)
            change.touch(line.id, moved.start...moved.end)
        }
        longest[source] = max(longest[source] ?? 0, moved.end - moved.start)
        newest = max(newest, moved.end)
    }

    private func remove(_ id: UUID, into change: inout Change) {
        guard let unit = units.removeValue(forKey: id) else { return }
        detachOrder(id, source: unit.source, start: unit.line.start)
        if let cluster = unit.cluster { change.clusters.insert(cluster) }
        change.ranges.append(unit.line.start...unit.line.end)
    }

    private func insertOrder(_ id: UUID, source: LiveCaptionSource, start: TimeInterval) {
        var list = bySource[source] ?? []
        let index = firstIndex(in: list, startingAtOrAfter: start, seq: units[id]?.seq ?? 0)
        list.insert(id, at: index)
        bySource[source] = list
    }

    private func detachOrder(_ id: UUID, source: LiveCaptionSource, start: TimeInterval) {
        guard var list = bySource[source] else { return }
        var index = firstIndex(in: list, startingAtOrAfter: start - 0.000_001, seq: 0)
        while index < list.count, list[index] != id { index += 1 }
        if index < list.count { list.remove(at: index) } else { list.removeAll { $0 == id } }
        bySource[source] = list
    }

    /// Where a line starting at `start` goes in a source's list (by start, then arrival).
    private func firstIndex(in list: [UUID], startingAtOrAfter start: TimeInterval, seq: Int) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            let other = units[list[middle]]
            let before = other.map { Key(start: $0.line.start, seq: $0.seq) < Key(start: start, seq: seq) } ?? true
            if before { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Judging

    private func apply(_ change: Change, levels readings: [LiveCaptionSource: Double]) -> Tail {
        note(readings)
        if newest - matchedSince >= 60 {
            matched.removeAll(keepingCapacity: true)
            matchedSince = newest
        }
        var change = change
        let horizon = newest - Self.settlesAfter
        for key in unsettled {
            guard let cluster = clusters[key] else { continue }
            if cluster.end <= horizon || cluster.members.allSatisfy({ units[$0]?.line.isTentative == false }) {
                change.clusters.insert(key)
            }
        }
        if !change.ranges.isEmpty || !change.clusters.isEmpty { judge(change) }
        return tail()
    }

    /// Judges again the lines near a change, and the utterances they were part of.
    private func judge(_ change: Change) {
        let horizon = newest - Self.frozenAfter
        var gathered = Set<UUID>(change.units.filter { units[$0] != nil })
        for range in change.ranges {
            for (source, list) in bySource {
                let from = range.lowerBound - LiveCaptionMix.window - (longest[source] ?? 0)
                var index = firstIndex(in: list, startingAtOrAfter: from, seq: 0)
                while index < list.count, let unit = units[list[index]], unit.line.start <= range.upperBound + LiveCaptionMix.window {
                    if unit.line.end >= range.lowerBound - LiveCaptionMix.window, unit.line.end >= horizon { gathered.insert(list[index]) }
                    index += 1
                }
            }
        }
        // Whole utterances: each one any of these lines was in.
        var old: [Int: Cluster] = [:]
        for key in change.clusters { if let cluster = clusters[key] { old[key] = cluster } }
        for id in gathered { if let key = units[id]?.cluster, old[key] == nil, let cluster = clusters[key] { old[key] = cluster } }
        for cluster in old.values { for id in cluster.members where units[id] != nil { gathered.insert(id) } }
        for (key, cluster) in old {
            clusters[key] = nil
            unsettled.remove(key)
            stale.formUnion(cluster.shown)
        }
        defer {
            for id in stale { hide(id) }
            stale = []
        }
        var previous: [UUID: Int] = [:]
        for id in gathered { previous[id] = units[id]?.cluster; units[id]?.cluster = nil }

        // Lines from different sources that are one utterance.
        let members = gathered.compactMap { id in units[id].map { (id, $0) } }.sorted { $0.1.line.start < $1.1.line.start }
        var parent = Array(members.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        for i in members.indices {
            let a = members[i].1
            var j = i + 1
            while j < members.count, members[j].1.line.start <= a.line.end + LiveCaptionMix.window {
                let b = members[j].1
                defer { j += 1 }
                guard a.source != b.source, pairs(a, b), matches(a, b) else { continue }
                parent[root(j)] = root(i)
            }
        }
        var groups: [Int: [UUID]] = [:]
        for index in members.indices { groups[root(index), default: []].append(members[index].0) }
        for group in groups.values.sorted(by: { (units[$0[0]]?.seq ?? 0) < (units[$1[0]]?.seq ?? 0) }) {
            // The same lines as before, none of them changed, nothing to settle: it stays as it was.
            if let key = previous[group[0]], let before = old[key], !change.clusters.contains(key), before.members.count == group.count,
               Set(before.members) == Set(group), !group.contains(where: change.units.contains) {
                clusters[key] = before
                for id in group { units[id]?.cluster = key }
                stale.subtract(before.shown)
                if !before.settled { unsettled.insert(key) }
                continue
            }
            form(group, previous: previous, old: old)
        }
    }

    /// Whether two lines from different sources may be one utterance: always across devices; this device's
    /// microphone and call only where the output can echo, and within `ownWindow`.
    private func pairs(_ a: Unit, _ b: Unit) -> Bool {
        let window = a.source.isDevice || b.source.isDevice ? LiveCaptionMix.window : LiveCaptionMix.ownWindow
        guard a.line.start <= b.line.end + window, b.line.start <= a.line.end + window else { return false }
        if a.source.isDevice || b.source.isDevice { return true }
        let time = max(a.line.start, b.line.start)
        return routes.last { $0.time <= time }?.echoes ?? true
    }

    /// Whether two lines' words are one utterance (`LiveCaptionMix.matches`), worked out again only when one's
    /// words changed.
    private func matches(_ a: Unit, _ b: Unit) -> Bool {
        let (first, second) = a.seq < b.seq ? (a, b) : (b, a)
        let pair = Pair(a: first.seq, b: second.seq)
        if let known = matched[pair], known.a == first.revision, known.b == second.revision { return known.matches }
        let result = LiveCaptionMix.matches(first.words.words, second.words.words)
        matched[pair] = (first.revision, second.revision, result)
        return result
    }

    /// One utterance: which source it reads from, and the lines it shows.
    private func form(_ ids: [UUID], previous: [UUID: Int], old: [Int: Cluster]) {
        let lines = ids.compactMap { units[$0] }.sorted { Key(start: $0.line.start, seq: $0.seq) < Key(start: $1.line.start, seq: $1.seq) }
        guard !lines.isEmpty else { return }
        let sources = Set(lines.map(\.source))
        let start = lines.map(\.line.start).min() ?? 0, end = lines.map(\.line.end).max() ?? 0
        let settled = lines.allSatisfy { !$0.line.isTentative } || end <= newest - Self.settlesAfter
        // What it read from before, for the earliest line that was in an utterance still reading from a source here.
        let inherited = lines.sorted { $0.seq < $1.seq }.lazy.compactMap { line in previous[line.line.id].flatMap { old[$0] } }
            .first { sources.contains($0.best) }
        let best = choose(lines, sources: sources, start: start, end: end, settled: settled, inherited: inherited)

        nextCluster += 1
        let key = nextCluster
        var cluster = Cluster(members: lines.map(\.line.id), sources: sources, best: best, settled: settled, start: start, end: end, shown: [])
        for line in lines { units[line.line.id]?.cluster = key }

        let heardToo = sources.subtracting([best]).sorted { $0.rawValue < $1.rawValue }
        let reads = lines.filter { $0.source == best }
        var words = reads.flatMap(\.words.words)
        var from = reads.map(\.line.start).min() ?? start, to = reads.map(\.line.end).max() ?? end
        for unit in reads {
            var line = tagged(unit.line)
            line.alsoHeard = heardToo.isEmpty ? nil : heardToo
            show(line, seq: unit.seq, in: &cluster)
        }
        // Each other source, in order, adds only what the utterance doesn't have yet.
        let others = sources.subtracting([best]).sorted { $0.isDevice == $1.isDevice ? $0.rawValue < $1.rawValue : !$0.isDevice }
        for source in others {
            for unit in lines where unit.source == source {
                let all = unit.words.words
                let matched = LiveCaptionMix.align(all, words)
                guard let first = matched.first, let last = matched.last else {
                    show(tagged(unit.line), seq: unit.seq, in: &cluster)
                    if unit.line.start < from { words = all + words } else { words += all }
                    from = min(from, unit.line.start); to = max(to, unit.line.end)
                    continue
                }
                let before = unit.line.start < from - LiveCaptionMix.runsOn ? 0..<first.a : 0..<0
                let after = unit.line.end > to + LiveCaptionMix.runsOn ? (last.a + 1)..<all.count : all.count..<all.count
                guard !before.isEmpty || !after.isEmpty else { continue }
                var line = tagged(unit.line)
                line.text = [unit.words.text(before), unit.words.text(after)].filter { !$0.isEmpty }.joined(separator: " … ")
                if before.isEmpty {
                    // Its new words come after the utterance's: placed there.
                    let share = Double(after.lowerBound) / Double(max(1, all.count))
                    line.start = max(unit.line.start + (unit.line.end - unit.line.start) * share, to - LiveCaptionMix.runsOn)
                }
                show(line, seq: unit.seq, in: &cluster)
                words = Array(all[before]) + words + Array(all[after])
                from = min(from, unit.line.start); to = max(to, unit.line.end)
            }
        }
        clusters[key] = cluster
        if !settled { unsettled.insert(key) }
    }

    /// The source an utterance reads from. The call, for remote speakers, always. Until it settles: the one it
    /// read from before, unless only a line still being revised has it and another source's is final; else a
    /// source with a final line. Once settled (or when another source joins one that was), chosen again: the
    /// highest level (by a margin over the one it read from), else this device's own, else by name.
    private func choose(_ lines: [Unit], sources: Set<LiveCaptionSource>, start: TimeInterval, end: TimeInterval, settled: Bool,
                        inherited: Cluster?) -> LiveCaptionSource {
        if sources.contains(.call) { return .call }
        let final = Set(lines.filter { !$0.line.isTentative }.map(\.source))
        if let inherited {
            let keeps = settled ? inherited.settled && inherited.sources == sources : final.isEmpty || final.contains(inherited.best)
            if keeps { return inherited.best }
        }
        let candidates = settled || final.isEmpty ? sources : final
        let ordered = candidates.sorted { $0.rawValue < $1.rawValue }
        var best = ordered[0]
        for source in ordered.dropFirst() where reads(source, before: best, start: start, end: end) { best = source }
        if settled, let kept = inherited?.best, kept != best, let keptLevel = level(kept, start, end),
           let bestLevel = level(best, start, end), bestLevel - keptLevel < Self.levelMargin {
            return kept
        }
        return best
    }

    /// Whether `a` reads an utterance before `b`: the higher level when both were measured, else this device's
    /// own source.
    private func reads(_ a: LiveCaptionSource, before b: LiveCaptionSource, start: TimeInterval, end: TimeInterval) -> Bool {
        if let x = level(a, start, end), let y = level(b, start, end), abs(x - y) >= Self.levelMargin { return x > y }
        return !a.isDevice && b.isDevice
    }

    /// A line as shown: this device's own carry their source only when it has several.
    private func tagged(_ line: LiveCaptionSegment) -> LiveCaptionSegment {
        guard let source = line.source, !source.isDevice, own.count < 2 else { return line }
        var line = line
        line.source = nil
        return line
    }

    // MARK: Levels

    private func note(_ readings: [LiveCaptionSource: Double]) {
        guard !readings.isEmpty else { return }
        for (source, value) in readings {
            var samples = levels[source] ?? []
            samples.append((newest, value))
            if let stale = samples.firstIndex(where: { $0.time >= newest - 60 }), stale > 0 { samples.removeFirst(stale) }
            levels[source] = samples
        }
    }

    /// A source's mean level while an utterance was heard, when it was measured then.
    private func level(_ source: LiveCaptionSource, _ start: TimeInterval, _ end: TimeInterval) -> Double? {
        guard let samples = levels[source] else { return nil }
        let heard = samples.filter { $0.time >= start - 1 && $0.time <= end + 2 }
        guard !heard.isEmpty else { return nil }
        return heard.map(\.value).reduce(0, +) / Double(heard.count)
    }

    // MARK: What's shown

    private func show(_ line: LiveCaptionSegment, seq: Int, in cluster: inout Cluster) {
        cluster.shown.append(line.id)
        stale.remove(line.id)
        let key = Key(start: line.start, seq: seq)
        if let current = shown[line.id] {
            guard current.line != line else { return }
            if current.key != key {
                removeOrder(current.key, line.id)
                insertOrder(key, line.id)
            }
        } else {
            insertOrder(key, line.id)
        }
        shown[line.id] = Shown(line: line, key: key)
        version += 1
    }

    /// Takes a line off: one the utterances judged again no longer show.
    private func hide(_ id: UUID) {
        guard let current = shown.removeValue(forKey: id) else { return }
        removeOrder(current.key, id)
        version += 1
    }

    private func insertOrder(_ key: Key, _ id: UUID) {
        var low = 0, high = order.count
        while low < high {
            let middle = (low + high) / 2
            if order[middle].key < key { low = middle + 1 } else { high = middle }
        }
        order.insert((key, id), at: low)
    }

    private func removeOrder(_ key: Key, _ id: UUID) {
        var low = 0, high = order.count
        while low < high {
            let middle = (low + high) / 2
            if order[middle].key < key { low = middle + 1 } else { high = middle }
        }
        while low < order.count, order[low].id != id, !(key < order[low].key) { low += 1 }
        if low < order.count, order[low].id == id { order.remove(at: low) } else { order.removeAll { $0.id == id } }
    }
}
