#if os(iOS)
import CryptoKit
import DaybookCore
import Foundation
import Observation
import PencilKit

/// The notebook's state while it's open: which pages show, the canvases (one per page, kept across layout changes so a fold
/// doesn't recreate them), and when a page settles (docs/notebook.md, "Reading"). A page settles, meaning its strokes are
/// committed and then read, when it leaves view, at Stop, eight seconds after the last stroke on it, and when the notebook
/// closes, the layout changes, or the app goes to the background. Nothing is read while a stroke is being written.
@MainActor
@Observable
public final class NotebookSession {
    public enum Reason: String, Sendable { case turn, stop, idle, close, layout, background }

    /// The pen, its colour, and Undo, shared by every canvas.
    public let ink = InkSession()
    /// The slot of the left page of the open pages: a spread's is always even.
    public private(set) var first = 0
    public private(set) var layout: NotebookLayout = .single(scale: 1)
    /// The page the person last wrote on, else the left one.
    public private(set) var current: UUID?
    /// Pages made in the notebook and not written on yet; the model keeps one with its first strokes.
    public private(set) var pending: [NotebookPage] = []
    /// Pages whose strokes are being brought to this device, and pages whose strokes couldn't be. Neither can be written on.
    public private(set) var loading: Set<UUID> = []
    public private(set) var unavailable: Set<UUID> = []
    /// Why the last save or load failed, in plain words; nil when none.
    public private(set) var problem: String?
    /// Where the pen or a finger is on the screen while it writes (window coordinates); floating controls near it step aside.
    public internal(set) var writingPoint: CGPoint?
    /// The floating controls begin collapsed (a debug launch's picture of that state).
    @ObservationIgnored public var startsCollapsed = false
    /// Bumped when what the pages show changed, for views that draw from the model.
    public private(set) var revision = 0

    @ObservationIgnored private(set) var model: NotebookModel?
    @ObservationIgnored private(set) var canvases: [UUID: PageCanvasView] = [:]
    @ObservationIgnored private var committed: [UUID: String] = [:]
    @ObservationIgnored private var baseline: [UUID: [NotebookStroke]] = [:]
    @ObservationIgnored private var erasedAt: [UUID: [String: Date]] = [:]
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var changes: [UUID: Int] = [:]
    @ObservationIgnored private var idleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var draftTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reading: Set<UUID> = []
    @ObservationIgnored private var pencilSeen = false
    @ObservationIgnored private var opened = false
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored var idleSettle: Duration
    @ObservationIgnored var draftDelay: Duration
    /// Reads a page's strokes; replaced in tests.
    @ObservationIgnored var reader: (PKDrawing, String, NotebookPage, @escaping (Date) -> (trackID: UUID?, time: TimeInterval?)) async -> PageReading =
        { drawing, sha, page, anchor in await NotebookReader.read(drawing, sha256: sha, page: page, anchor: anchor) }

    public init(now: @escaping () -> Date = Date.init, idleSettle: Duration = .seconds(8), draftDelay: Duration = .milliseconds(500)) {
        self.now = now
        self.idleSettle = idleSettle
        self.draftDelay = draftDelay
        ink.onChange = { [weak self] in self?.applyTool() }
    }

    // MARK: Pages

    /// Every page in order: the model's, then the ones made here and not written on.
    public var pages: [NotebookPage] { (model?.pages() ?? []) + pending }

    private var realCount: Int { model?.pages().count ?? 0 }

    /// The pages open now, left to right: one in a single layout, two in a spread. Always as many as the layout shows.
    public var visible: [NotebookPage] {
        let all = pages
        return (first..<(first + layout.pageCount)).compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    public var visibleIDs: [UUID] { visible.map(\.id) }

    public func number(of id: UUID) -> Int? { pages.firstIndex { $0.id == id }.map { $0 + 1 } }

    func canvas(for id: UUID) -> PageCanvasView? { canvases[id] }

    /// "3–4 of 7", or "3 of 7" in a single layout. The count is the pages written, or the open ones when they're further on.
    public var pagesLabel: String {
        let numbers = visibleIDs.compactMap(number(of:))
        guard let low = numbers.min(), let high = numbers.max() else { return "" }
        let total = max(realCount, high)
        return low == high ? "\(low) of \(total)" : "\(low)–\(high) of \(total)"
    }

    public var pagesAccessibilityLabel: String {
        let numbers = visibleIDs.compactMap(number(of:))
        guard let low = numbers.min(), let high = numbers.max() else { return "" }
        let total = max(realCount, high)
        return low == high ? "Page \(low) of \(total)" : "Pages \(low) and \(high) of \(total)"
    }

    public var canGoBack: Bool { first > 0 }
    /// Forward goes on to the pages after these while the last of these has been made; a blank page is written on, not passed.
    public var canGoForward: Bool { first + layout.pageCount <= realCount }
    /// New Page turns to the blank pages after the last one, unless they're already open.
    public var canAddPage: Bool { first + layout.pageCount <= realCount }

    // MARK: Binding

    /// Connects the notebook to whoever keeps the pages, and shows the pages open now.
    public func bind(_ model: NotebookModel) {
        self.model = model
        // The first time, it opens at the pages written last; after that, where it was (a fold, table mode, and back).
        if !opened { opened = true; showLastPage() } else { reconcile() }
    }

    /// The person's own words for a passage.
    public func correct(page: UUID, passage: UUID, text: String) {
        model?.correct(page, passage, text)
    }

    /// Takes a new layout (the display's size, or a fold). When the number of pages shown changes, what was open settles
    /// first and the canvases stay where they are.
    public func resolve(_ new: NotebookLayout) {
        guard new != layout else { return }
        guard new.pageCount != layout.pageCount else { layout = new; return }
        let leaving = visibleIDs
        let keep = leaving.contains { $0 == current } ? current.flatMap { id in pages.firstIndex { $0.id == id } } : nil
        layout = new
        // A spread starts on an even slot; a single page shows the page last written on, else the left one.
        if new.isSpread { first -= first % 2 } else if let keep { first = keep }
        reconcile()
        Task { await settle(.layout, pages: leaving) }
        logTurn()
    }

    /// Makes sure the open pages exist and have canvases: a blank page after the last is made here, and a page written on
    /// later is kept by the model with its first strokes. Called whenever what's open might have changed.
    public func reconcile() {
        guard model != nil else { return }
        let count = realCount
        let needed = first + layout.pageCount
        // Blank pages up to the open ones; blank pages no longer open and never written on go.
        let openIDs = Set(visibleIDs)
        pending.removeAll { page in !openIDs.contains(page.id) && canvases[page.id]?.drawing.strokes.isEmpty != false }
        while count + pending.count < needed {
            let order = ((model?.pages().map(\.order).max() ?? 0) + Double(pending.count) + 1)
            pending.append(NotebookPage(order: order, origin: model?.origin, now: now()))
        }
        if current == nil || !visibleIDs.contains(current ?? UUID()) { current = visible.first?.id }
        for page in visible { open(page) }
        ink.undoManager = current.flatMap { canvases[$0] }?.undoManager
        ink.refreshUndo()
        revision += 1
    }

    private func open(_ page: NotebookPage) {
        guard canvases[page.id] == nil, let model else { return }
        let view = PageCanvasView(pageID: page.id, size: CGSize(width: page.width, height: page.height), paper: page.paper)
        view.began = { [weak self] view in self?.began(view) }
        view.changed = { [weak self] view in self?.changed(view) }
        view.sawPencil = { [weak self] in self?.pencilTouched() }
        view.touching = { [weak self] point in self?.writingPoint = point }
        view.longPressed = { [weak self] point in self?.play(at: point, on: page.id) }
        view.longPressEnabled = canPlay && pencilSeen
        canvases[page.id] = view
        view.apply(tool: ink.tool.pencilTool(color: ink.color), pencilOnly: pencilSeen)
        load(page.id, into: view, content: model.content(page.id))
    }

    private func load(_ id: UUID, into view: PageCanvasView, content: NotebookPageContent) {
        switch content {
        case .strokes(let data):
            guard let drawing = try? PKDrawing(data: data) else {
                markUnavailable(id, "This page’s writing couldn’t be opened.")
                return
            }
            view.load(drawing)
            committed[id] = Self.sha256(data)
            baseline[id] = NotebookReader.strokes(of: drawing)
            view.isWritable = model?.isEditable ?? false
            loading.remove(id)
            unavailable.remove(id)
        case .blank:
            view.load(PKDrawing())
            baseline[id] = []
            view.isWritable = model?.isEditable ?? false
        case .notLoaded:
            // Never open over strokes that exist: the page stays closed until they arrive.
            view.isWritable = false
            guard let fetch = model?.fetch else {
                markUnavailable(id, "This page’s writing isn’t available.")
                return
            }
            loading.insert(id)
            Task { [weak self] in
                let arrived = await fetch(id)
                guard let self else { return }
                self.loading.remove(id)
                if arrived, let model = self.model, case .strokes = model.content(id), let view = self.canvases[id] {
                    self.load(id, into: view, content: model.content(id))
                } else {
                    self.markUnavailable(id, "This page’s writing isn’t available.")
                }
            }
        }
    }

    private func markUnavailable(_ id: UUID, _ message: String) {
        unavailable.insert(id)
        loading.remove(id)
        canvases[id]?.isWritable = false
        problem = message
    }

    public func isWritable(_ id: UUID) -> Bool { (model?.isEditable ?? false) && !loading.contains(id) && !unavailable.contains(id) }

    // MARK: Playing

    /// Whether a passage can be played from (a saved conversation's notebook).
    public var canPlay: Bool { model?.play != nil }

    /// Plays the conversation from when a passage was written.
    public func play(_ passage: NotebookPassage, on page: NotebookPage) { model?.play?(passage, page) }

    /// A long press on the handwriting: plays from the passage whose strokes are there (page points), the nearest when several are.
    func play(at point: CGPoint, on id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        let hits = page.passages.filter { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).insetBy(dx: -12, dy: -12).contains(point) }
        let nearest = hits.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
        if let nearest { play(nearest, on: page) }
    }

    private func distance(from point: CGPoint, to passage: NotebookPassage) -> CGFloat {
        hypot(point.x - (passage.x + passage.width / 2), point.y - (passage.y + passage.height / 2))
    }

    // MARK: Writing

    private func began(_ view: PageCanvasView) {
        model?.sampleClock?()
        current = view.pageID
        ink.undoManager = view.undoManager
    }

    func changed(_ view: PageCanvasView) {
        let id = view.pageID
        guard isWritable(id) else { return }
        current = id
        dirty.insert(id)
        changes[id, default: 0] += 1
        keepWithModel(id)
        noteErasures(id, view.drawing)
        ink.refreshUndo()
        scheduleDraft(id)
        scheduleIdle(id)
    }

    /// A page written on is the model's from its first stroke, together with any blank page before it in the open pages (so
    /// that pages never swap places under the pen).
    private func keepWithModel(_ id: UUID) {
        guard let model, let index = pending.firstIndex(where: { $0.id == id }) else { return }
        for page in pending[...index] { model.add(page) }
        pending.removeFirst(index + 1)
        revision += 1
    }

    private func pencilTouched() {
        guard !pencilSeen else { return }
        pencilSeen = true
        // A finger no longer writes, so holding one on handwriting plays it.
        for view in canvases.values { view.longPressEnabled = canPlay }
        applyTool()
    }

    private func applyTool() {
        let tool = ink.tool.pencilTool(color: ink.color)
        for view in canvases.values { view.apply(tool: tool, pencilOnly: pencilSeen) }
    }

    /// What was in the last committed strokes and isn't in the canvas now, with the moment each went.
    private func noteErasures(_ id: UUID, _ drawing: PKDrawing) {
        guard let before = baseline[id], !before.isEmpty else { return }
        let keys = Set(NotebookReader.strokes(of: drawing).map(\.key))
        var gone = erasedAt[id] ?? [:]
        for stroke in before {
            if keys.contains(stroke.key) { gone[stroke.key] = nil } else if gone[stroke.key] == nil { gone[stroke.key] = now() }
        }
        erasedAt[id] = gone
    }

    private func scheduleDraft(_ id: UUID) {
        draftTasks[id]?.cancel()
        draftTasks[id] = Task { [weak self, delay = draftDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let view = self.canvases[id], !self.pending.contains(where: { $0.id == id }) else { return }
            _ = self.model?.saveDraft(id, view.drawing.dataRepresentation())
        }
    }

    private func scheduleIdle(_ id: UUID) {
        idleTasks[id]?.cancel()
        idleTasks[id] = Task { [weak self, delay = idleSettle] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.settle(.idle, pages: [id])
        }
    }

    // MARK: Settling

    /// Commits and reads the pages written on since they last settled (all open pages' canvases when `ids` is nil).
    public func settle(_ reason: Reason, pages ids: [UUID]? = nil) async {
        for id in ids ?? Array(dirty) { await commit(id) }
    }

    /// Stop: settles every page, waiting at most two seconds; the recording is never held for more.
    public func settleForStop() async {
        let work = Task { await settle(.stop) }
        let limit = Task { try? await Task.sleep(for: .seconds(2)); work.cancel() }
        await work.value
        limit.cancel()
    }

    private func commit(_ id: UUID) async {
        guard let model, let view = canvases[id], isWritable(id) else { return }
        idleTasks[id]?.cancel()
        draftTasks[id]?.cancel()
        let drawing = view.drawing
        let marker = changes[id, default: 0]
        // A page with nothing on it that never had anything isn't kept.
        guard !drawing.strokes.isEmpty || committed[id] != nil else { dirty.remove(id); return }
        let data = drawing.dataRepresentation()
        let sha = Self.sha256(data)
        if sha == committed[id] { if changes[id] == marker { dirty.remove(id) }; return }
        keepWithModel(id)
        do {
            let confirmed = try await model.commit(id, data, drawing.strokes.count, drawing.requiredContentVersion.rawValue)
            committed[id] = confirmed
            problem = nil
            let strokes = NotebookReader.strokes(of: drawing)
            captureErasures(id, now: strokes)
            if changes[id, default: 0] == marker { dirty.remove(id) }
            read(id, drawing, sha: confirmed)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func captureErasures(_ id: UUID, now strokes: [NotebookStroke]) {
        guard let model else { return }
        let keys = Set(strokes.map(\.key))
        let gone = erasedAt[id] ?? [:]
        let erased = (baseline[id] ?? []).compactMap { stroke -> ErasedStroke? in
            guard !keys.contains(stroke.key), let when = gone[stroke.key] else { return nil }
            let placed = model.anchor(when)
            return ErasedStroke(key: stroke.key, madeAt: stroke.start, erasedAt: when, trackID: placed.trackID, time: placed.time)
        }
        if !erased.isEmpty { model.recordErasures(id, erased) }
        baseline[id] = strokes
        erasedAt[id] = [:]
    }

    private func read(_ id: UUID, _ drawing: PKDrawing, sha: String) {
        guard let model, let page = pages.first(where: { $0.id == id }), !reading.contains(id) else { return }
        if page.reading?.drawingSHA256 == sha, (page.reading?.groupingVersion ?? 0) >= PassageGrouping.version { return }
        reading.insert(id)
        let anchor = model.anchor
        Task { [weak self, reader] in
            let result = await reader(drawing, sha, page, anchor)
            guard let self else { return }
            self.reading.remove(id)
            // Strokes written since mean this reading is of old ones: a settle of the new strokes reads them.
            guard self.committed[id] == sha else {
                if let view = self.canvases[id], let current = self.committed[id] { self.read(id, view.drawing, sha: current) }
                return
            }
            self.model?.applyReading(id, result)
            self.revision += 1
        }
    }

    // MARK: Turning

    /// A page turn, or a step through the open pages.
    public func turn(_ direction: Int) {
        let target = direction > 0 ? first + layout.pageCount : max(0, first - layout.pageCount)
        guard direction > 0 ? canGoForward : canGoBack else { return }
        go(to: target)
    }

    /// Turns to the blank pages after the last written.
    public func newPage() {
        guard canAddPage else { return }
        let count = realCount
        go(to: layout.isSpread ? count + count % 2 : count)
    }

    private func go(to target: Int) {
        let leaving = visibleIDs
        first = target
        reconcile()
        Task { await settle(.turn, pages: leaving) }
        logTurn()
    }

    /// Opens the pages at a slot (0 is the first page), kept to where pages are.
    public func show(slot: Int) {
        let target = min(max(0, slot), realCount)
        first = layout.isSpread ? target - target % 2 : target
        reconcile()
    }

    /// Opens at the page last written on, else the first blank spread after the pages made.
    public func showLastPage() {
        let count = realCount
        let last = max(0, count - 1)
        first = layout.isSpread ? last - last % 2 : last
        reconcile()
    }

    /// Notes the open pages (to the recording clock) so playback can show the page that was open.
    private func logTurn() {
        guard let model else { return }
        let real = Set(model.pages().map(\.id))
        let open = visibleIDs.filter(real.contains)
        guard !open.isEmpty else { return }
        model.sampleClock?()
        let moment = now()
        let placed = model.anchor(moment)
        model.logTurn(PageTurn(at: moment, pages: open, trackID: placed.trackID, time: placed.time))
    }

    /// Settles everything and notes that no page is open.
    public func close() async {
        await settle(.close)
        guard let model, !model.pages().isEmpty else { return }
        model.sampleClock?()
        let moment = now()
        let placed = model.anchor(moment)
        model.logTurn(PageTurn(at: moment, pages: [], trackID: placed.trackID, time: placed.time))
    }

    /// Deletes a page; what undoes it, nil when it wasn't the model's.
    public func remove(_ id: UUID) -> (() -> Void)? {
        let undo = model?.remove(id)
        reconcile()
        return undo.map { undo in { [weak self] in undo(); self?.reconcile() } }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
