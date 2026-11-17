import AppKit
import IineCore

/// All annotation geometry stays in image points. Hosts supply only the display transform.
@MainActor
final class AnnotationCanvas: NSView {
    private var base: CGImage
    private var cropOriginPx: CGPoint
    private var scale: CGFloat

    var annotations: [Annotation] = [] { didSet { changed() } }
    var nextSerial = 1
    var draft: Annotation? { didSet { needsDisplay = true } }
    var selectedIDs: Set<UUID> = [] { didSet { if selectedIDs != oldValue { changed() } } }
    var handleIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    var currentStyle: Style { didSet { needsDisplay = true } }
    private(set) var tool: ShapeKind? = .rect
    var logicalSize: CGSize?
    var displayTransform: CGAffineTransform = .identity { didSet { needsDisplay = true } }
    var drawsBaseImage = false
    var receivesEvents = false
    var scrollAdjustsPen = true
    var autoSelectOnCreation = true
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    fileprivate struct Snapshot: Equatable {
        var annotations: [Annotation]
        var nextSerial: Int

        var storageCost: Int {
            annotations.reduce(0) { total, annotation in
                let fixed = total + MemoryLayout<Annotation>.stride
                switch annotation.shape {
                case .polyline(let points), .brush(let points), .marker(let points), .mosaic(let points), .blur(let points):
                    return fixed + points.count * MemoryLayout<CGPoint>.stride
                case .text(let text, _, _, _): return fixed + text.utf8.count
                default: return fixed
                }
            }
        }
    }

    struct Checkpoint {
        fileprivate let snapshot: Snapshot
        fileprivate let history: SnapshotHistory<Snapshot>
    }

    func checkpoint() -> Checkpoint { Checkpoint(snapshot: snapshot, history: history) }

    func restoreCheckpoint(_ checkpoint: Checkpoint) {
        cancelEditing()
        history = checkpoint.history
        restore(checkpoint.snapshot)
        setSelection([])
    }

    private enum Interaction {
        case idle
        case drawing(start: CGPoint, points: [CGPoint])
        case polyline(start: CGPoint, wasEditing: Bool)
        case moving(start: CGPoint, originals: [Annotation], clone: Bool)
        case marquee(start: CGPoint, previous: Set<UUID>)
        case resizing(id: UUID, handle: ShapeHandle, original: Shape)
        case resizingText(id: UUID, handle: TextHandle, original: Shape)
        case rotatingText(id: UUID, original: Shape)
        case lineEndpoint(id: UUID, start: Bool, original: Shape)
        case erasing(last: CGPoint)
    }

    private var interaction: Interaction = .idle
    private var gestureBefore: Snapshot?
    private var history = SnapshotHistory<Snapshot>(maximumCost: 16 * 1024 * 1024, estimateCost: { $0.storageCost })
    private var toolStyles = ToolStyleStore()
    private var copiedAnnotations: [Annotation] = []
    private var polylinePoints: [CGPoint]?
    private var marqueeRect: CGRect?
    private var pendingShortcut: (key: String, time: TimeInterval)?
    private var textEditor: CanvasTextView?
    private var textEdit: TextEdit?
    private var tracking: NSTrackingArea?

    private struct TextEdit {
        let id: UUID?
        let origin: CGPoint
        let fontSize: CGFloat
        let rotation: CGFloat
        let style: Style
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var isEditingText: Bool { textEditor != nil }
    var isInteracting: Bool {
        if case .idle = interaction { return false }
        return true
    }
    var hasPendingPolyline: Bool { polylinePoints != nil }
    var styleKind: ShapeKind { selectedKind ?? toolStyles.currentKind }
    var selectedKind: ShapeKind? {
        annotations.first { selectedIDs.contains($0.id) }?.shape.kind ?? tool
    }
    var canvasSize: CGSize { logicalSize ?? bounds.size }
    private var snapshot: Snapshot { Snapshot(annotations: annotations, nextSerial: nextSerial) }
    private var handleRadius: CGFloat {
        let zoom = max(0.05, hypot(displayTransform.a, displayTransform.b))
        return 8 / zoom
    }

    init(base: CGImage, cropOriginPx: CGPoint, scale: CGFloat, initialStyle: Style) {
        self.base = base
        self.cropOriginPx = cropOriginPx
        self.scale = scale
        self.currentStyle = initialStyle
        super.init(frame: .zero)
        toolStyles.updateAlpha(initialStyle.color.a)
        toolStyles.update(initialStyle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if receivesEvents { return hit }
        return hit === self ? nil : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func updateBase(_ image: CGImage, cropOriginPx: CGPoint = .zero, scale: CGFloat) {
        base = image
        self.cropOriginPx = cropOriginPx
        self.scale = scale
        needsDisplay = true
    }

    func updateCropOrigin(_ origin: CGPoint) {
        guard origin != cropOriginPx else { return }
        cropOriginPx = origin
        needsDisplay = true
    }

    func translateAnnotations(by delta: CGPoint) {
        annotations = annotations.map {
            Annotation(id: $0.id, shape: $0.shape.translated(by: delta), style: $0.style)
        }
    }

    func restoreAnnotations(_ items: [Annotation], clearHistory: Bool = true) {
        cancelEditing()
        annotations = items
        selectedIDs = []
        handleIDs = []
        nextSerial = (items.compactMap { item -> Int? in
            if case .serial(let value, _, _) = item.shape { return value }
            return nil
        }.max() ?? 0) + 1
        if clearHistory { history.removeAll() }
        changed()
    }

    func selectTool(_ kind: ShapeKind?) {
        finishEditing()
        cancelGesture()
        polylinePoints = nil
        draft = nil
        selectedIDs = []
        handleIDs = []
        tool = kind
        if let kind { currentStyle = toolStyles.select(kind) }
        changed()
    }

    func applyStyle(_ style: Style, changed attribute: AnnotationStyleAttribute? = nil) {
        finishEditing()
        let old = currentStyle
        guard old != style || attribute != nil else { return }
        currentStyle = style
        if let kind = tool {
            toolStyles.select(kind)
            toolStyles.updateAlpha(style.color.a)
            toolStyles.update(style)
        }
        if !selectedIDs.isEmpty {
            let before = snapshot
            var updated = annotations
            for index in updated.indices where selectedIDs.contains(updated[index].id) {
                if attribute == .color || (attribute == nil && old.color != style.color) { updated[index].style.color = style.color }
                if attribute == .opacity { updated[index].style.color.a = style.color.a }
                if attribute == .pen || (attribute == nil && old.pen != style.pen) {
                    updated[index].style.pen = style.pen
                    switch updated[index].shape {
                    case .text(let text, let origin, _, let rotation):
                        updated[index].shape = .text(text, origin: origin, fontSize: style.pen.textFontSize, rotation: rotation)
                    case .serial(let value, let center, _):
                        updated[index].shape = .serial(value: value, center: center, radius: style.pen.serialRadius)
                    default: break
                    }
                }
                if attribute == .lineStyle || (attribute == nil && old.lineStyle != style.lineStyle) { updated[index].style.lineStyle = style.lineStyle }
                if attribute == .background || (attribute == nil && old.background != style.background) { updated[index].style.background = style.background }
                if attribute == .arrowHeads || (attribute == nil && old.arrowHeads != style.arrowHeads) { updated[index].style.arrowHeads = style.arrowHeads }
            }
            annotations = updated
            record(before)
        }
        changed()
    }

    func setSelection(_ ids: Set<UUID>) {
        selectedIDs = ids.intersection(Set(annotations.map(\.id)))
        handleIDs = []
        if let selected = annotations.first(where: { selectedIDs.contains($0.id) }) {
            currentStyle = selected.style
        }
        changed()
    }

    func undo() {
        finishEditing()
        cancelGesture()
        guard let previous = history.undo(current: snapshot) else { return }
        restore(previous)
    }

    func redo() {
        finishEditing()
        cancelGesture()
        guard let next = history.redo(current: snapshot) else { return }
        restore(next)
    }

    func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        let before = snapshot
        annotations.removeAll { selectedIDs.contains($0.id) }
        selectedIDs = []
        handleIDs = []
        record(before)
    }

    func finishEditing() {
        commitText()
        commitPolyline()
    }

    func cancelEditing() {
        cancelText()
        cancelGesture()
        polylinePoints = nil
        draft = nil
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    private func record(_ before: Snapshot) {
        guard before != snapshot else { return }
        history.record(before)
        changed()
    }

    private func restore(_ state: Snapshot) {
        annotations = state.annotations
        nextSerial = state.nextSerial
        selectedIDs.formIntersection(Set(annotations.map(\.id)))
        handleIDs.formIntersection(Set(annotations.map(\.id)))
        if let selected = annotations.first(where: { selectedIDs.contains($0.id) }) {
            currentStyle = selected.style
        }
        changed()
    }

    private func cancelGesture() {
        if let before = gestureBefore { restore(before) }
        gestureBefore = nil
        interaction = .idle
        marqueeRect = nil
        draft = nil
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).applying(displayTransform.inverted())
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), canvasSize.width), y: min(max(point.y, 0), canvasSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        pointerDown(at: imagePoint(event), modifiers: event.modifierFlags, clickCount: event.clickCount)
    }

    func pointerDown(at rawPoint: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        let point = clamped(rawPoint)
        if clickCount >= 2, let hit = hitAnnotation(at: point), case .text = hit.shape {
            beginText(at: point, editing: hit)
            return
        }
        if tool == .polyline {
            let wasEditing = polylinePoints != nil
            if polylinePoints == nil { polylinePoints = [] }
            if polylinePoints?.last != point { polylinePoints?.append(point) }
            draft = Annotation(shape: .polyline(polylinePoints ?? []), style: currentStyle)
            interaction = .polyline(start: point, wasEditing: wasEditing)
            if clickCount >= 2 { commitPolyline() }
            return
        }
        gestureBefore = snapshot
        if let handle = handleInteraction(at: rawPoint) {
            if let id = selectedIDs.union(handleIDs).first { setSelection([id]) }
            interaction = handle
            return
        }
        if tool == .eraser {
            interaction = .erasing(last: point)
            erase(from: point, to: point)
            return
        }
        if tool == .text {
            gestureBefore = nil
            beginText(at: point, editing: nil)
            return
        }
        if tool == .serial {
            let annotation = Annotation(shape: .serial(value: nextSerial, center: point, radius: currentStyle.pen.serialRadius), style: currentStyle)
            annotations.append(annotation)
            nextSerial += 1
            if let before = gestureBefore { record(before) }
            gestureBefore = nil
            selectedIDs = autoSelectOnCreation ? [annotation.id] : []
            interaction = .idle
            changed()
            return
        }
        if let hit = hitAnnotation(at: point), tool == nil || selectedIDs.contains(hit.id) {
            var ids = selectedIDs
            if modifiers.contains(.shift) {
                if ids.contains(hit.id) { ids.remove(hit.id) } else { ids.insert(hit.id) }
            } else if !ids.contains(hit.id) {
                ids = [hit.id]
            }
            setSelection(ids)
            let originals = annotations.filter { ids.contains($0.id) }
            interaction = .moving(start: point, originals: originals, clone: modifiers.contains(.control))
            return
        }
        if tool == nil {
            let previous = modifiers.contains(.shift) ? selectedIDs : []
            setSelection(previous)
            interaction = .marquee(start: point, previous: previous)
            marqueeRect = CGRect(origin: point, size: .zero)
            return
        }
        selectedIDs = []
        handleIDs = []
        interaction = .drawing(start: point, points: [point])
        draft = makeDraft(start: point, current: point, points: [point])
    }

    override func mouseDragged(with event: NSEvent) {
        pointerDragged(to: imagePoint(event), modifiers: event.modifierFlags)
        autoscroll(with: event)
    }

    func pointerDragged(to rawPoint: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let point = clamped(rawPoint)
        switch interaction {
        case .idle: break
        case .drawing(let start, var points):
            if tool == .brush || tool == .marker || tool == .mosaic || tool == .blur {
                if points.last != point { points.append(point) }
            }
            interaction = .drawing(start: start, points: points)
            draft = makeDraft(start: start, current: point, points: points)
        case .polyline:
            draft = Annotation(shape: .polyline((polylinePoints ?? []) + [point]), style: currentStyle)
        case .moving(let start, let originals, let clone):
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            guard hypot(delta.x, delta.y) >= 1 else { return }
            if clone {
                let copies = originals.map { Annotation(shape: $0.shape, style: $0.style) }
                annotations.append(contentsOf: copies)
                setSelection(Set(copies.map(\.id)))
                interaction = .moving(start: start, originals: copies, clone: false)
                move(copies, by: delta)
            } else {
                move(originals, by: delta)
            }
        case .marquee(let start, let previous):
            let rect = RectMath.normalizedRect(from: start, to: point)
            marqueeRect = rect
            selectedIDs = previous.union(AnnotationSelection.ids(in: annotations, intersecting: rect))
        case .resizing(let id, let handle, let original):
            let rect = ShapeResize.resizedBox(original.bounds, corner: handle, to: rawPoint, minimum: 2)
            updateShape(id, to: original.resized(to: rect))
        case .resizingText(let id, let handle, let original):
            guard case .text(let text, _, let size, let rotation) = original,
                  let geometry = original.textGeometry else { return }
            let center = geometry.center
            let anchor = geometry.point(for: handle)
            let fontSize = TextGeometry.scaledFontSize(size, from: hypot(anchor.x - center.x, anchor.y - center.y),
                to: hypot(rawPoint.x - center.x, rawPoint.y - center.y))
            updateShape(id, to: .text(text, origin: TextMetrics.origin(text: text, fontSize: fontSize, centeredAt: center),
                fontSize: fontSize, rotation: modifiers.contains(.shift) ? 0 : rotation))
        case .rotatingText(let id, let original):
            guard case .text(let text, let origin, let fontSize, _) = original,
                  let geometry = original.textGeometry else { return }
            var angle = atan2(rawPoint.y - geometry.center.y, rawPoint.x - geometry.center.x) - .pi / 2
            if modifiers.contains(.shift) { angle = (angle / (.pi / 4)).rounded() * (.pi / 4) }
            updateShape(id, to: .text(text, origin: origin, fontSize: fontSize, rotation: angle))
        case .lineEndpoint(let id, let isStart, let original):
            switch original {
            case .line(let from, let to): updateShape(id, to: .line(from: isStart ? point : from, to: isStart ? to : point))
            case .arrow(let from, let to): updateShape(id, to: .arrow(from: isStart ? point : from, to: isStart ? to : point))
            default: break
            }
        case .erasing(let last):
            erase(from: last, to: point)
            interaction = .erasing(last: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pointerUp(at: imagePoint(event), modifiers: event.modifierFlags)
    }

    func pointerUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        switch interaction {
        case .drawing:
            pointerDragged(to: point, modifiers: modifiers)
            if let draft, valid(draft.shape) {
                annotations.append(draft)
                selectedIDs = autoSelectOnCreation ? [draft.id] : []
                handleIDs = autoSelectOnCreation ? [] : [draft.id]
            }
            draft = nil
        case .polyline(let start, let wasEditing):
            if !wasEditing, hypot(point.x - start.x, point.y - start.y) >= 2 {
                polylinePoints?.append(clamped(point))
                commitPolyline()
            }
        case .moving, .resizing, .resizingText, .rotatingText, .lineEndpoint, .erasing:
            pointerDragged(to: point, modifiers: modifiers)
        case .marquee:
            marqueeRect = nil
            if let selected = annotations.first(where: { selectedIDs.contains($0.id) }) { currentStyle = selected.style }
        case .idle: break
        }
        if let before = gestureBefore { record(before) }
        gestureBefore = nil
        interaction = .idle
        changed()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let points = polylinePoints else { return }
        draft = Annotation(shape: .polyline(points + [clamped(imagePoint(event))]), style: currentStyle)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !handleRightMouseDown(event) { onCancel?() }
    }

    @discardableResult
    func handleRightMouseDown(_ event: NSEvent) -> Bool {
        if textEditor != nil { return true }
        if polylinePoints != nil { commitPolyline(); return true }
        if isInteracting { pointerUp(at: imagePoint(event), modifiers: event.modifierFlags); return true }
        return false
    }

    func hasHandle(at point: CGPoint) -> Bool { handleInteraction(at: point) != nil }

    private func move(_ originals: [Annotation], by delta: CGPoint) {
        let shapes = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.shape) })
        var updated = annotations
        for index in updated.indices {
            if let shape = shapes[updated[index].id] { updated[index].shape = shape.translated(by: delta) }
        }
        annotations = updated
    }

    private func updateShape(_ id: UUID, to shape: Shape) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].shape = shape
    }

    private func hitAnnotation(at point: CGPoint) -> Annotation? {
        annotations.reversed().first {
            let tolerance = max(handleRadius * 0.375, $0.style.pen.lineWidth / 2)
            return tool == nil
                ? $0.shape.contains(point, tolerance: tolerance)
                : $0.shape.strokeHit(point, tolerance: tolerance)
        }
    }

    private func handleInteraction(at point: CGPoint) -> Interaction? {
        let ids = selectedIDs.union(handleIDs)
        guard ids.count == 1, let item = annotations.first(where: { ids.contains($0.id) }) else { return nil }
        if let geometry = item.shape.textGeometry {
            for handle in [TextHandle.rotate] + TextHandle.allCases.filter(\.isCorner) {
                let anchor = geometry.point(for: handle)
                if hypot(point.x - anchor.x, point.y - anchor.y) <= handleRadius {
                    return handle == .rotate ? .rotatingText(id: item.id, original: item.shape)
                        : .resizingText(id: item.id, handle: handle, original: item.shape)
                }
            }
        }
        if item.shape.supportsResizeHandles {
            let bounds = item.shape.bounds
            let radius = min(handleRadius, max(0.5, min(bounds.width, bounds.height) / 4))
            for handle in ShapeHandle.allCases {
                let anchor = handle.point(in: bounds)
                if hypot(point.x - anchor.x, point.y - anchor.y) <= radius {
                    return .resizing(id: item.id, handle: handle, original: item.shape)
                }
            }
        }
        switch item.shape {
        case .line(let from, let to), .arrow(let from, let to):
            if hypot(point.x - from.x, point.y - from.y) <= handleRadius {
                return .lineEndpoint(id: item.id, start: true, original: item.shape)
            }
            if hypot(point.x - to.x, point.y - to.y) <= handleRadius {
                return .lineEndpoint(id: item.id, start: false, original: item.shape)
            }
        default: break
        }
        return nil
    }

    private func erase(from start: CGPoint, to end: CGPoint) {
        let ids = Set(annotations.filter { $0.shape.intersects(path: [start, end], tolerance: currentStyle.pen.lineWidth) }.map(\.id))
        annotations.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        handleIDs.subtract(ids)
    }

    private func makeDraft(start: CGPoint, current: CGPoint, points: [CGPoint]) -> Annotation? {
        let rect = RectMath.normalizedRect(from: start, to: current)
        let shape: Shape
        switch tool {
        case .rect: shape = .rect(rect)
        case .roundedRect: shape = .roundedRect(rect, radius: min(rect.width, rect.height) * 0.25)
        case .ellipse: shape = .ellipse(rect)
        case .line: shape = .line(from: start, to: current)
        case .arrow: shape = .arrow(from: start, to: current)
        case .polyline: shape = .polyline(points)
        case .brush: shape = .brush(points)
        case .marker: shape = .marker(points)
        case .mosaic: shape = .mosaic(points)
        case .mosaicRect: shape = .mosaicRect(rect)
        case .blur: shape = .blur(points)
        case .magnify: shape = .magnify(rect, zoom: 2)
        case .text, .serial, .eraser, .none: return nil
        }
        return Annotation(id: draft?.id ?? UUID(), shape: shape, style: currentStyle)
    }

    private func valid(_ shape: Shape) -> Bool {
        switch shape {
        case .rect(let rect), .roundedRect(let rect, _), .ellipse(let rect), .magnify(let rect, _), .mosaicRect(let rect):
            return rect.width >= 2 && rect.height >= 2
        case .line(let from, let to), .arrow(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .polyline(let points):
            return zip(points, points.dropFirst()).contains { hypot($1.x - $0.x, $1.y - $0.y) >= 2 }
        case .text: return false
        default: return true
        }
    }

    func commitPolyline() {
        guard let points = polylinePoints else { return }
        let before = snapshot
        let item = Annotation(id: draft?.id ?? UUID(), shape: .polyline(points), style: draft?.style ?? currentStyle)
        polylinePoints = nil
        draft = nil
        interaction = .idle
        if valid(item.shape) {
            annotations.append(item)
            selectedIDs = autoSelectOnCreation ? [item.id] : []
            record(before)
        }
        changed()
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard textEditor == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if flags.contains(.command) {
            switch key {
            case "z": flags.contains(.shift) ? redo() : undo()
            case "a": setSelection(Set(annotations.map(\.id)))
            case "c", "x":
                guard !selectedIDs.isEmpty else { return false }
                copiedAnnotations = annotations.filter { selectedIDs.contains($0.id) }
                if key == "x" { deleteSelection() }
            case "v":
                guard !copiedAnnotations.isEmpty else { return false }
                let before = snapshot
                let items = copiedAnnotations.map { Annotation(shape: $0.shape.translated(by: CGPoint(x: 12, y: 12)), style: $0.style) }
                annotations.append(contentsOf: items)
                setSelection(Set(items.map(\.id)))
                record(before)
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53:
            if polylinePoints != nil || isInteracting { cancelEditing() }
            else if !selectedIDs.isEmpty { setSelection([]) }
            else if let onCancel { onCancel() }
            else { return false }
            return true
        case 36, 76:
            if polylinePoints != nil { commitPolyline() }
            else if let onFinish { onFinish() }
            else { return false }
            return true
        case 51, 117: deleteSelection(); return true
        case 48:
            if tool == .line { selectTool(.arrow); return true }
            if tool == .arrow { selectTool(.line); return true }
        case 123, 124, 125, 126:
            guard !selectedIDs.isEmpty else { return false }
            let distance: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta = CGPoint(x: event.keyCode == 123 ? -distance : (event.keyCode == 124 ? distance : 0),
                y: event.keyCode == 125 ? -distance : (event.keyCode == 126 ? distance : 0))
            let before = snapshot
            annotations = AnnotationSelection.translating(annotations, ids: selectedIDs, by: delta)
            record(before)
            return true
        default: break
        }
        guard flags.intersection([.control, .option, .shift]).isEmpty else { return false }
        if let digit = Int(key), (1...5).contains(digit) {
            var style = currentStyle
            let raw = digit <= 2 ? style.pen.rawValue + (digit == 1 ? -1 : 1) : digit
            if let pen = PenSize(rawValue: raw) { style.pen = pen; applyStyle(style) }
            return true
        }
        if key == "v" { selectTool(nil); return true }
        let now = ProcessInfo.processInfo.systemUptime
        let upper = key.uppercased()
        if let pendingShortcut, now - pendingShortcut.time < 0.5,
           let entry = ShapeCatalog.p2.first(where: { $0.shortcut == pendingShortcut.key + upper }) {
            self.pendingShortcut = nil
            selectTool(entry.kind)
            return true
        }
        guard let entry = ShapeCatalog.p2.first(where: { $0.shortcut == upper }) else { return false }
        pendingShortcut = (upper, now)
        selectTool(entry.kind)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        if !handleScrollWheel(event) { super.scrollWheel(with: event) }
    }

    @discardableResult
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard scrollAdjustsPen, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              event.scrollingDeltaY != 0, tool != nil else { return false }
        var style = currentStyle
        let raw = style.pen.rawValue + (event.scrollingDeltaY > 0 ? 1 : -1)
        if let pen = PenSize(rawValue: raw) { style.pen = pen; applyStyle(style) }
        return true
    }

    private func beginText(at point: CGPoint, editing annotation: Annotation?) {
        let edit: TextEdit
        let text: String
        if let annotation, case .text(let original, let origin, let fontSize, let rotation) = annotation.shape {
            edit = TextEdit(id: annotation.id, origin: origin, fontSize: fontSize, rotation: rotation, style: annotation.style)
            text = original
            currentStyle = annotation.style
        } else {
            edit = TextEdit(id: nil, origin: point, fontSize: currentStyle.pen.textFontSize, rotation: 0, style: currentStyle)
            text = ""
        }
        let metrics = TextMetrics.lineHeight(fontSize: edit.fontSize)
        let editorHeight = (metrics.ascent + metrics.descent) * 3
        let logicalRect = CGRect(x: edit.origin.x, y: edit.origin.y + metrics.ascent - editorHeight,
            width: max(120, canvasSize.width - edit.origin.x), height: editorHeight)
        let viewRect = logicalRect.applying(displayTransform)
        let editor = CanvasTextView(frame: viewRect)
        editor.drawsBackground = true
        editor.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        editor.isRichText = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.font = .systemFont(ofSize: edit.fontSize * max(0.1, hypot(displayTransform.a, displayTransform.b)))
        editor.textColor = NSColor(cgColor: edit.style.color.cgColor)
        editor.insertionPointColor = .labelColor
        editor.string = text
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.commitText() }
        editor.onCancel = { [weak self] in self?.cancelText() }
        textEdit = edit
        textEditor = editor
        addSubview(editor)
        setSelection(annotation.map { [$0.id] } ?? [])
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        gestureBefore = nil
        interaction = .idle
    }

    func commitText() {
        guard let editor = textEditor, let edit = textEdit else { return }
        let text = editor.string
        endTextEditing()
        let before = snapshot
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let id = edit.id, let index = annotations.firstIndex(where: { $0.id == id }) {
            if isEmpty { annotations.remove(at: index); selectedIDs = [] }
            else { annotations[index].shape = .text(text, origin: edit.origin, fontSize: edit.fontSize, rotation: edit.rotation) }
        } else if !isEmpty {
            let item = Annotation(shape: .text(text, origin: edit.origin, fontSize: edit.fontSize, rotation: edit.rotation), style: edit.style)
            annotations.append(item)
            selectedIDs = autoSelectOnCreation ? [item.id] : []
        }
        record(before)
        changed()
    }

    private func cancelText() {
        guard textEditor != nil else { return }
        endTextEditing()
        changed()
    }

    private func endTextEditing() {
        let editor = textEditor
        textEditor = nil
        textEdit = nil
        editor?.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.concatenate(displayTransform)
        let size = canvasSize
        if drawsBaseImage {
            let rect = CGRect(origin: cropOriginPx, size: CGSize(width: size.width * scale, height: size.height * scale))
            if let image = base.cropping(to: rect) { ctx.draw(image, in: CGRect(origin: .zero, size: size)) }
        }
        let input = RenderInput(base: base, cropOriginPx: cropOriginPx, canvasSize: size, scale: scale)
        let visible = annotations.filter { $0.id != textEdit?.id }
        AnnotationRenderer.draw(visible, draft: draft, input: input, into: ctx)
        drawSelectionHighlight(in: ctx)
        if let marqueeRect {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
            ctx.fill(marqueeRect)
            ctx.stroke(marqueeRect)
        }
        ctx.restoreGState()
    }
    private func drawSelectionHighlight(in ctx: CGContext) {
        let selected = annotations.filter { selectedIDs.contains($0.id) }
        let handlesOnly = annotations.filter {
            handleIDs.contains($0.id) && !selectedIDs.contains($0.id)
        }
        if selected.isEmpty, handlesOnly.count == 1, handlesOnly[0].shape.supportsResizeHandles {
            let shape = handlesOnly[0].shape
            ctx.saveGState()
            ctx.setStrokeColor(RGBAColor.palette[5].cgColor)
            ctx.setLineWidth(1.5)
            drawHandleSquares(ShapeHandle.allCases.map { $0.point(in: shape.bounds) }, in: ctx)
            ctx.restoreGState()
            return
        }
        guard !selected.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(RGBAColor.palette[5].cgColor)
        ctx.setLineWidth(1.5)
        if selected.count == 1 {
            let shape = selected[0].shape
            if let geometry = shape.textGeometry {
                drawTextHandles(geometry, in: ctx)
            } else {
                // 画布 frame 与选区重合，画布坐标即视图坐标，直接描在包围盒外扩 3pt 处。
                let box = shape.bounds.insetBy(dx: -3, dy: -3)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.stroke(box)
                ctx.setLineDash(phase: 0, lengths: [])
                if shape.supportsResizeHandles {
                    drawHandleSquares(ShapeHandle.allCases.map { $0.point(in: shape.bounds) }, in: ctx)
                } else if case .line(let start, let end) = shape {
                    drawHandleSquares([start, end], in: ctx)
                } else if case .arrow(let start, let end) = shape {
                    drawHandleSquares([start, end], in: ctx)
                }
            }
        } else {
            // 多选不显示缩放控制点，逐个描框后再补一个整体包围盒。
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            for annotation in selected {
                ctx.stroke(annotation.shape.bounds.insetBy(dx: -3, dy: -3))
            }
            ctx.setLineDash(phase: 0, lengths: [])
            if let union = AnnotationSelection.bounds(of: selected, ids: selectedIDs) {
                ctx.stroke(union.insetBy(dx: -6, dy: -6))
            }
        }
        ctx.restoreGState()
    }

    /// 文字选中框随旋转一起转：四角白底小方块，顶部白底小圆点。
    private func drawTextHandles(_ geometry: TextGeometry, in ctx: CGContext) {
        let corners = geometry.corners
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.beginPath()
        ctx.move(to: corners[0])
        for point in corners.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.closePath()
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawHandleSquares(corners, in: ctx)

        let dot = geometry.point(for: .rotate)
        let radius: CGFloat = 4
        let circle = CGRect(
            x: dot.x - radius,
            y: dot.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        ctx.fillEllipse(in: circle)
        ctx.strokeEllipse(in: circle)
    }

    /// 白底蓝边方块。文字四角与面状形状的缩放控制点共用。
    private func drawHandleSquares(_ corners: [CGPoint], in ctx: CGContext) {
        let side: CGFloat = 6
        ctx.setFillColor(NSColor.white.cgColor)
        for corner in corners {
            let box = CGRect(
                x: corner.x - side / 2,
                y: corner.y - side / 2,
                width: side,
                height: side
            )
            ctx.fill(box)
            ctx.stroke(box)
        }
    }}

@MainActor
private final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() { onCancel?(); return }
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

extension AnnotationCanvas: NSTextViewDelegate {
    func textDidEndEditing(_ notification: Notification) { commitText() }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, let edit = textEdit else { return }
        let line = editor.string.components(separatedBy: "\n").first ?? ""
        let metrics = TextMetrics.multiline(line.isEmpty ? "国" : line, fontSize: edit.fontSize, origin: .zero)
        let top = CGPoint(x: edit.origin.x, y: edit.origin.y + metrics.rect.maxY).applying(displayTransform)
        if displayTransform.b == 0, displayTransform.c == 0 {
            editor.setFrameOrigin(CGPoint(x: editor.frame.minX, y: top.y - editor.frame.height))
        }
    }
}
