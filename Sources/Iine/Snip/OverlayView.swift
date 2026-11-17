import AppKit
import IineCore

/// 单屏覆盖视图：绘制冻结帧与选区遮罩，承载选区与标注交互。
@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot
    /// 取色模式：放大镜常驻，单击取样后结束会话而不是开始框选。
    private let pickColorMode: Bool
    /// 白板模式：Esc 不退出会话，工具条默认隐藏、由空格切换。
    private let whiteboardMode: Bool
    private var actionBarVisible: Bool
    var onPickColor: (() -> Void)?
    var onReplayEditableHistory: ((CaptureHistoryEntry) -> Void)?

    private enum Phase {
        case idle
        case selecting(origin: CGPoint, freeDrag: Bool)
        case ready
        case resizingSelection(edge: SelectionEdge, original: CGRect)
        case scrolling
    }

    private var phase: Phase = .idle
    private(set) var scrollingPreview: CGImage?
    private var scrollingPreviewPixelSize: CGSize?
    private(set) var scrollingFrameCount = 0
    /// 滚动阶段覆盖层上的提示。滚动时工具条隐藏，提示（如"已达上限"）只能画在覆盖层上。
    private var scrollingMessage: String?
    var onScrollFocusLost: (() -> Void)?
    /// 光标下的可吸附窗口（全局坐标）。nil 表示光标不在任何窗口上。
    /// 按下时记下的吸附目标。只有「按下没拖动就松手」才用它，
    /// 一旦真的拖起来就是自由选区，避免一按下就先框好一整块。
    private var pendingSnapRect: CGRect?
    /// 元素级 AX 探测的节流时间戳与间隔（秒）。
    private var lastElementProbe: TimeInterval = 0
    private static let elementProbeInterval: TimeInterval = 0.08
    private var hoverWindow: WindowCandidate?
    /// 光标下 UI 元素的吸附矩形（视图坐标）。nil 表示本帧没有可用的元素候选。
    private var hoverElementRect: CGRect?
    /// 元素检测的父级层数，滚轮调。0 是光标命中元素本身。
    private var hoverElementLevel = 0
    /// 是否开启元素吸附，来自设置。
    var elementDetectionEnabled = false
    /// 当前选区（视图坐标，左下原点）。空矩形表示尚未选中。
    /// 变化后刷新光标区域：边缘与四角的 cursor rect 跟着新边界走。
    private(set) var selectionRect: CGRect = .zero {
        didSet {
            guard selectionRect != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 是否显示十字光标。保存面板等场景由控制器临时关闭。
    var showsCrosshair = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// 新标注创建后是否自动选中，来自设置，默认开启。
    var autoSelectOnCreation = true

    /// 选区宽高比，来自设置。改写后只刷新工具条上的比例标签。
    var selectionAspectRatio: SelectionAspectRatio = .free {
        didSet { toolbar.updateAspectRatio(selectionAspectRatio) }
    }

    private static let maskAlpha: CGFloat = 0.32
    private static let minimumSelectionSide: CGFloat = 1
    /// 元素吸附的最小边长。更小的控件（光标、分隔线）点一下就选中没有意义，回落到窗口。
    private static let minimumElementSide: CGFloat = 4
    /// 按下到拖动的位移小于该值不脱离窗口吸附；双击确认时手抖不应清掉已确定的选区。
    private static let dragThreshold: CGFloat = 3
    /// 选区边缘拖拽的命中容差：贴边几 pt 内即可调整大小，内部深按仍走画标注。
    private static let selectionEdgeHitTolerance: CGFloat = 6
    /// 选区边缘光标热区的边长。
    private static let selectionCursorSize: CGFloat = 6

    /// 尺寸标签的绘制参数。散在绘制代码里会让间距和字号无法对齐调。
    private enum SizeLabel {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        static let textColor = NSColor.white
        static let background = NSColor(white: 0, alpha: 0.7)
        static let padding = NSSize(width: 6, height: 3)
        static let cornerRadius: CGFloat = 4
        /// 标签与选区、屏幕边缘的间距。
        static let gap: CGFloat = 4
    }

    /// 冻结帧的 NSImage 包装。draw 每帧都会调用，重建 NSImage 在大屏拖拽时会掉帧。
    private let frozenImage: NSImage
    /// 当前显示的图像。回放历史时换成历史截图，翻回 index 0 恢复实时冻结帧。
    private var activeImage: NSImage
    /// 当前图像在视图里的显示矩形。实时帧铺满 bounds；历史帧按等比缩放居中。
    private var activeImageRect: CGRect
    private var activeSource: CGImage
    private var activeScaleX: CGFloat
    private var activeScaleY: CGFloat
    /// 最近成功输出的截图。0 表示本次实时冻结帧，1 是最新历史。
    private let history: [CaptureHistoryEntry]
    private(set) var historyIndex = 0
    /// warp 不生效只提示一次，避免每次按键刷日志。
    private var didWarnCursorWarp = false

    /// 本屏可吸附候选。冻结帧存续期间窗口布局视为不变，只取一次。
    private lazy var candidates: [WindowCandidate] = {
        let own = getpid()
        let all = WindowDetector.onScreenWindows(ownPID: own)
        let snap = WindowDetector.snapCandidates(from: all, ownPID: own)
        return snap.filter { shot.bounds.intersects($0.bounds) }
    }()

    /// 选区确定后浮现的标注工具条（形状 / 颜色 / 笔尖 / 复制 / 保存 / 取消）。
    private lazy var toolbar: AnnotateToolbar = {
        let bar = AnnotateToolbar(
            initialKind: .rect,
            initialStyle: ShapeCatalog.entry(for: .rect)!.defaultStyle,
            initialAspectRatio: selectionAspectRatio
        )
        bar.onSelectTool = { [weak self] kind in self?.selectTool(kind) }
        bar.onSelectMode = { [weak self] in self?.enterSelectMode() }
        bar.onStyleChange = { [weak self] style in self?.applyStyle(style) }
        bar.onStylePropertyChange = { [weak self] style, attribute in
            self?.canvas?.applyStyle(style, changed: attribute)
        }
        bar.onCopy = { [weak self] in self?.requestCopy() }
        bar.onExtractText = { [weak self] in self?.requestTextRecognition() }
        bar.onTranslate = { [weak self] in self?.requestTranslate() }
        bar.onCycleTranslationTarget = { [weak self] in
            guard let self else { return }
            self.translationTarget = self.translationTarget.next
            self.toolbar.updateTranslationTarget(self.translationTarget)
            self.needsDisplay = true
        }
        bar.onScanBarcode = { [weak self] in self?.requestBarcodeScan() }
        bar.onSave = { [weak self] in self?.requestSave() }
        bar.onQuickSave = { [weak self] in self?.requestSave(quick: true) }
        bar.onPin = { [weak self] in self?.requestPin() }
        bar.onUndo = { [weak self] in self?.undoLastAnnotation() }
        bar.onRedo = { [weak self] in self?.redoLastAnnotation() }
        bar.onShare = { [weak self] in self?.requestShare() }
        bar.onCancel = { [weak self] in self?.requestCancel() }
        bar.onScrollingCapture = { [weak self] in self?.requestScrollingCapture() }
        bar.onAspectRatioChange = { [weak self] ratio in self?.selectionAspectRatio = ratio }
        bar.onTranslationTargetChange = { [weak self] target in self?.translationTarget = target }
        bar.onSizeChange = { [weak self] in self?.updateActionBar() }
        bar.updateTranslationTarget(translationTarget)
        bar.isHidden = true
        return bar
    }()

    private var isEditingGesture = false

    /// 放大镜可见性由 Option 按住或正在拖选区两种来源决定。
    private(set) var isMagnifierVisible = false
    private var isOptionDown = false
    private var isShiftDown = false
    private var magnifierCursor: CGPoint?
    /// 取色格式。Shift 在 Hex 与 rgb() 之间切换，切换结果保留到本次截图结束。
    private(set) var colorFormat: ColorFormat = .hex
    private var colorFeedback: String?
    private var colorFeedbackToken = 0

    private struct ElementQuery: Equatable {
        let point: CGPoint
        let pid: pid_t?
        let level: Int
    }
    private let elementQueue = DispatchQueue(label: "iine.hover-element", qos: .userInitiated)
    private var latestElementQuery: ElementQuery?
    private var elementQueryRunning = false

    deinit {
        if let scrollKeyObserver { NotificationCenter.default.removeObserver(scrollKeyObserver) }
    }

    private var canvas: AnnotationCanvas?

    /// 待导出标注。控制器在复制 / 保存时按 displayID 来取。
    var annotations: [Annotation] { canvas?.annotations ?? [] }

    init(
        shot: DisplayShot,
        history: [CaptureHistoryEntry] = [],
        pickColorMode: Bool = false,
        initialHistoryIndex: Int = 0,
        whiteboardMode: Bool = false
    ) {
        self.shot = shot
        self.history = history
        self.pickColorMode = pickColorMode
        self.whiteboardMode = whiteboardMode
        actionBarVisible = !whiteboardMode
        let frozen = NSImage(
            cgImage: shot.image,
            size: NSSize(width: shot.bounds.width, height: shot.bounds.height)
        )
        frozenImage = frozen
        activeImage = frozen
        activeImageRect = NSRect(
            x: 0,
            y: 0,
            width: shot.bounds.width,
            height: shot.bounds.height
        )
        activeSource = shot.image
        activeScaleX = shot.scale
        activeScaleY = shot.scale
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: shot.bounds.width,
            height: shot.bounds.height
        ))
        addSubview(toolbar)
        // 从菜单历史进入时直接停在该张；0 仍是本次实时冻结帧。
        historyIndex = min(max(initialHistoryIndex, 0), history.count)
        if historyIndex > 0 { applyHistoryImage() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showsCrosshair {
            addCursorRect(bounds, cursor: .crosshair)
        }
        guard !selectionRect.isEmpty else { return }
        let half = Self.selectionCursorSize / 2
        for edge in SelectionEdge.allCases {
            let center = cursorCenter(for: edge)
            let rect = CGRect(
                x: center.x - half,
                y: center.y - half,
                width: Self.selectionCursorSize,
                height: Self.selectionCursorSize
            ).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: cursor(for: edge))
        }
    }

    /// 边缘光标热区的中心：四条边取中点，四个角取角点。
    private func cursorCenter(for edge: SelectionEdge) -> CGPoint {
        switch edge {
        case .top: return CGPoint(x: selectionRect.midX, y: selectionRect.maxY)
        case .bottom: return CGPoint(x: selectionRect.midX, y: selectionRect.minY)
        case .left: return CGPoint(x: selectionRect.minX, y: selectionRect.midY)
        case .right: return CGPoint(x: selectionRect.maxX, y: selectionRect.midY)
        case .topLeft: return CGPoint(x: selectionRect.minX, y: selectionRect.maxY)
        case .topRight: return CGPoint(x: selectionRect.maxX, y: selectionRect.maxY)
        case .bottomLeft: return CGPoint(x: selectionRect.minX, y: selectionRect.minY)
        case .bottomRight: return CGPoint(x: selectionRect.maxX, y: selectionRect.minY)
        }
    }

    /// 四角没有公开的斜角光标，统一复用左右箭头；边按方向取上下 / 左右。
    private func cursor(for edge: SelectionEdge) -> NSCursor {
        switch edge {
        case .top, .bottom: return .resizeUpDown
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .resizeLeftRight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if case .scrolling = phase {
            drawScrollingOverlay()
            return
        }
        // 用 NSImage 绘制，避免 CGImage 直接进 CGContext 时的上下翻转。
        // 历史帧只占画面中间一块，周围保留本次实时冻结帧作为参照。
        if activeImageRect != bounds {
            frozenImage.draw(in: bounds)
        }
        activeImage.draw(in: activeImageRect)
        // 白板底图就是用户要导出的背景：纯色不应被遮罩压暗，透明要让实时桌面透出。
        if !whiteboardMode {
            drawMask()
        }
        if selectionRect.isEmpty {
            drawHoverHighlight()
        } else {
            drawSelectionBorder()
            drawSizeLabel()
        }
        drawMagnifier()
        drawHistoryLabel()
    }

    private func drawScrollingOverlay() {
        // 穿透模式下不再绘制整屏冻结帧，否则等于把桌面又盖回去，下层应用会重新被判为被遮挡。
        if !scrollingThrough {
            activeImage.draw(in: activeImageRect)
        }
        if !whiteboardMode {
            drawMask()
        }

        // 穿透模式下也不把拼接预览盖在选区里：实时页面本身就能看见，
        // 盖上去既挡住用户看滚动，也有被再次抓进帧里的风险（自我参照）。
        if !scrollingThrough, let preview = scrollingPreview {
            let pointSize = NSSize(
                width: (scrollingPreviewPixelSize?.width ?? CGFloat(preview.width)) / shot.scale,
                height: (scrollingPreviewPixelSize?.height ?? CGFloat(preview.height)) / shot.scale
            )
            let nsImage = NSImage(cgImage: preview, size: pointSize)
            let visibleHeight = min(selectionRect.height, pointSize.height)
            let destination = CGRect(
                x: selectionRect.minX,
                y: selectionRect.minY,
                width: selectionRect.width,
                height: visibleHeight
            )
            nsImage.draw(
                in: destination,
                from: CGRect(x: 0, y: 0, width: pointSize.width, height: visibleHeight),
                operation: .sourceOver,
                fraction: 1
            )
        }

        drawSelectionBorder()

        // 覆盖层提示优先显示显式消息（如已达上限），否则显示常规滚动进度。
        let hint = scrollingMessage ?? (scrollingFrameCount > 0
            ? "已捕获 \(scrollingFrameCount) 帧 · Enter 完成 · Esc 取消"
            : "滚动页面捕获更多内容 · Enter 完成 · Esc 取消")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = hint.size(withAttributes: attributes)
        let padding: CGFloat = 8
        var origin = NSPoint(
            x: selectionRect.minX,
            y: selectionRect.minY - textSize.height - padding * 2
        )
        if origin.y < padding {
            origin.y = selectionRect.minY + padding
        }
        let background = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        hint.draw(
            at: NSPoint(x: origin.x + padding, y: origin.y + padding / 2),
            withAttributes: attributes
        )
    }

    // MARK: - 鼠标交互

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        refreshMagnifier()
        if case .ready = phase { canvas?.mouseMoved(with: event) }
        // 有按压或已有选区时不画 hover，跳过状态更新避免整屏重绘
        guard case .idle = phase, selectionRect.isEmpty else { return }
        let hit = windowUnderMouse(at: point)
        // 窗口级命中用 CGWindowList，便宜；元素级要走跨进程 AX，跟着每次移动查会卡。
        let now = ProcessInfo.processInfo.systemUptime
        let element: CGRect?
        if now - lastElementProbe >= Self.elementProbeInterval {
            lastElementProbe = now
            element = elementUnderMouse(at: point)
        } else if hit == hoverWindow {
            element = hoverElementRect
        } else {
            element = nil
        }
        guard hit != hoverWindow || element != hoverElementRect else { return }
        hoverWindow = hit
        hoverElementRect = element
        needsDisplay = true
    }

    var translationTarget: TranslationTarget = .auto {
        didSet { toolbar.updateTranslationTarget(translationTarget) }
    }

    /// 本视图内的左键按压会话。覆盖层全屏捕获，与 NSEvent.pressedMouseButtons 等价，
    /// 且可被验收 harness 程序化置位。
    var isLeftButtonDown = false

    /// Snipaste 语义：截图状态中键单击 = 贴到屏幕并结束会话。
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, canOutput, !selectionRect.isEmpty else {
            super.otherMouseDown(with: event)
            return
        }
        requestPin()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        isLeftButtonDown = true
        defer { refreshMagnifier() }
        switch phase {
        case .idle:
            if pickColorMode {
                copyMagnifierColor()
                onPickColor?()
            } else {
                beginSelection(at: point)
            }
        case .ready:
            guard let canvas else { return }
            let local = convert(point, to: canvas)
            if canvas.isEditingText || canvas.hasHandle(at: local) {
                isEditingGesture = true
                canvas.mouseDown(with: event)
                if !canvas.isEditingText { window?.makeFirstResponder(self) }
                return
            }
            if let edge = SelectionEdge.hit(point: point, in: selectionRect, tolerance: Self.selectionEdgeHitTolerance) {
                phase = .resizingSelection(edge: edge, original: selectionRect)
                return
            }
            guard selectionRect.contains(point) else {
                removeCanvas()
                beginSelection(at: point)
                return
            }
            if event.clickCount == 2, canvas.tool != .text,
               !canvas.annotations.contains(where: { $0.shape.kind == .text && $0.shape.contains(local, tolerance: 2) }),
               !canvas.isInteracting, !canvas.hasPendingPolyline {
                requestCopy()
                return
            }
            isEditingGesture = true
            canvas.mouseDown(with: event)
            if !canvas.isEditingText { window?.makeFirstResponder(self) }
        case .selecting, .resizingSelection, .scrolling:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        magnifierCursor = point
        defer { refreshMagnifier() }
        if isEditingGesture {
            canvas?.mouseDragged(with: event)
            return
        }
        switch phase {
        case .selecting(let origin, let freeDrag):
            guard freeDrag
                || abs(point.x - origin.x) >= Self.dragThreshold
                || abs(point.y - origin.y) >= Self.dragThreshold else { return }
            phase = .selecting(origin: origin, freeDrag: true)
            // 拖动即脱离窗口锁定：按起点与当前点重算选区，固定比例时按比例扩展。
            // 鼠标可拖出视图范围，两种路径都把结果限制在冻结帧内。
            if let ratio = selectionAspectRatio.value {
                selectionRect = RectMath.aspectRect(
                    from: origin,
                    to: point,
                    ratio: ratio,
                    within: bounds,
                    minimumSide: Self.minimumSelectionSide
                )
            } else {
                selectionRect = RectMath.clamp(
                    RectMath.normalizedRect(from: origin, to: point),
                    to: bounds
                )
            }
            needsDisplay = true
        case .resizingSelection(let edge, let original):
            // 只改命中的边；标注画布在 mouseUp 时统一补偿，拖动中保持原位。
            selectionRect = SelectionEdge.resized(
                original,
                edge: edge,
                to: point,
                minimum: Self.minimumSelectionSide,
                within: bounds
            )
            updateActionBar()
            needsDisplay = true
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        magnifierCursor = convert(event.locationInWindow, from: nil)
        isLeftButtonDown = false
        defer { refreshMagnifier() }
        if isEditingGesture {
            isEditingGesture = false
            canvas?.mouseUp(with: event)
            return
        }
        switch phase {
        case .selecting:
            let dragged = selectionRect.width >= Self.minimumSelectionSide
                && selectionRect.height >= Self.minimumSelectionSide
            // 单击（没拖动）时把按下的吸附目标选上，等于「点哪个窗口选哪个」。
            if !dragged, let snap = pendingSnapRect,
               snap.width >= Self.minimumSelectionSide,
               snap.height >= Self.minimumSelectionSide {
                selectionRect = snap
                pendingSnapRect = nil
                commitSelection()
                return
            }
            pendingSnapRect = nil
            guard dragged else {
                selectionRect = .zero
                phase = .idle
                updateActionBar()
                needsDisplay = true
                return
            }
            commitSelection()
        case .resizingSelection(_, let original):
            // 先按最终边界对齐，再抵消选区左下角位移：已画标注保持屏幕原位。
            selectionRect = selectionRect.integral
            let delta = CGPoint(
                x: original.minX - selectionRect.minX,
                y: original.minY - selectionRect.minY
            )
            if delta != .zero {
                canvas?.translateAnnotations(by: delta)
            }
            // commitSelection 会回到 ready，选中高亮不再有意义，一并清掉。
            canvas?.selectedIDs = []
            commitSelection()
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if canvas?.handleRightMouseDown(event) == true { return }
        requestCancel()
    }

    override func scrollWheel(with event: NSEvent) {
        if case .idle = phase, elementDetectionEnabled, UIElementDetector.isTrusted,
           event.scrollingDeltaY != 0 {
            let step = event.scrollingDeltaY > 0 ? 1 : -1
            let next = UIElementDetector.clampLevel(hoverElementLevel + step)
            guard next != hoverElementLevel else { return }
            hoverElementLevel = next
            refreshHover(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
            return
        }
        if isReadyOrSelected, canvas?.handleScrollWheel(event) == true { return }
        super.scrollWheel(with: event)
    }

    // MARK: - 二次编辑

    override func keyDown(with event: NSEvent) {
        if case .scrolling = phase {
            if event.keyCode == 36 || event.keyCode == 76 {
                NotificationCenter.default.post(name: .snipScrollFinishRequested, object: self)
            } else if event.keyCode == 53 {
                NotificationCenter.default.post(name: .snipScrollCancelRequested, object: self)
            }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 8, isMagnifierVisible, modifiers.intersection([.command, .control]).isEmpty {
            copyMagnifierColor()
            return
        }
        if [123, 124, 125, 126].contains(event.keyCode),
           canvas?.selectedIDs.isEmpty == false, canvas?.handleKeyDown(event) == true { return }
        if handleCursorKey(event) || handleArrowKey(event) { return }
        if canvas?.handleKeyDown(event) == true { return }
        switch event.keyCode {
        case 53:
            if !whiteboardMode { requestCancel() }
        case 49 where whiteboardMode && modifiers.intersection([.command, .control, .option]).isEmpty:
            actionBarVisible.toggle()
            updateActionBar()
        case 36, 76:
            guard canOutput else { return }
            requestCopy()
        case 1 where modifiers == [.command, .shift]:
            if canOutput { requestSave(quick: true) }
        case 1 where modifiers == .command:
            if canOutput { requestSave() }
        case 43 where canStepHistory(event): stepHistory(-1)
        case 47 where canStepHistory(event): stepHistory(1)
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        // Shift 只在按下沿切换一次；长按不会连续翻转格式。
        if shift, !isShiftDown, isMagnifierVisible {
            colorFormat = colorFormat.toggled
        }
        isOptionDown = option
        isShiftDown = shift
        refreshMagnifier()
    }

    /// 拖选区脱离窗口吸附后自动召唤放大镜；松开鼠标后仅剩 Option 一种来源。
    private var isDraggingSelection: Bool {
        if case .selecting(_, let freeDrag) = phase { return freeDrag }
        return false
    }

    /// Option 按下前还没收到过鼠标移动时，退回窗口记录的当前位置。
    private var effectiveMagnifierCursor: CGPoint? {
        if let magnifierCursor { return magnifierCursor }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func refreshMagnifier() {
        let visible = pickColorMode || isOptionDown || isDraggingSelection
        guard visible != isMagnifierVisible else {
            if visible { needsDisplay = true }
            return
        }
        isMagnifierVisible = visible
        if !visible { colorFeedback = nil }
        needsDisplay = true
    }

    private func copyMagnifierColor() {
        guard let cursor = effectiveMagnifierCursor else { return }
        let sampler = MagnifierSampler(
            image: activeSource,
            canvasSize: bounds.size,
            scaleX: activeScaleX,
            scaleY: activeScaleY,
            origin: activeImageRect.origin
        )
        guard let color = sampler.color(at: cursor) else {
            NSSound.beep()
            return
        }
        let text = colorFormat.string(for: color)
        guard ClipboardService.copyString(text) else {
            NSSound.beep()
            return
        }
        showColorFeedback(text)
    }

    private func showColorFeedback(_ text: String) {
        colorFeedback = text
        colorFeedbackToken &+= 1
        let token = colorFeedbackToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.colorFeedbackToken == token else { return }
                self.colorFeedback = nil
                self.needsDisplay = true
            }
        }
    }

    private var scrollKeyObserver: NSObjectProtocol?
    /// 滚动期间覆盖层是否已切成穿透模式（冻结帧不能再画，否则又变成整屏遮挡）。
    private var scrollingThrough = false

    func beginScrollingCapture() {
        guard !selectionRect.isEmpty else { return }
        phase = .scrolling
        // 关键：整屏不透明覆盖层会遮死下层应用，抓帧只能拿到静态缓存。
        // 白板透明模式本来就是穿透的，不重复切换。
        if !whiteboardMode, let overlayWindow = window as? SnipOverlayWindow {
            overlayWindow.setScrollThrough(true)
            scrollingThrough = true
        }
        scrollingPreview = nil
        scrollingPreviewPixelSize = nil
        scrollingFrameCount = 0
        scrollingMessage = nil
        toolbar.isHidden = true
        window?.ignoresMouseEvents = true
        window?.makeKey()
        if let window {
            scrollKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, case .scrolling = self.phase else { return }
                    self.onScrollFocusLost?()
                }
            }
        }
        needsDisplay = true
    }

    func updateScrollingCapture(preview: CGImage, frameCount: Int, pixelSize: CGSize? = nil) {
        scrollingPreviewPixelSize = pixelSize
        scrollingPreview = preview
        scrollingFrameCount = frameCount
        scrollingMessage = nil
        needsDisplay = true
    }

    /// 滚动阶段覆盖层提示（工具条此时隐藏，消息只能画在覆盖层上）。主线程调用。
    func setScrollingMessage(_ text: String) {
        scrollingMessage = text
        needsDisplay = true
    }

    func endScrollingCapture() {
        guard case .scrolling = phase else { return }
        if scrollingThrough, let overlayWindow = window as? SnipOverlayWindow {
            overlayWindow.setScrollThrough(false)
        }
        scrollingThrough = false
        onScrollFocusLost = nil
        if let observer = scrollKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollKeyObserver = nil
        }
        scrollingPreview = nil
        scrollingPreviewPixelSize = nil
        scrollingFrameCount = 0
        scrollingMessage = nil
        window?.ignoresMouseEvents = false
        phase = .ready
        updateActionBar()
        needsDisplay = true
    }

    /// ready 语义的阶段：选区已确定，复制 / 保存 / 切工具都可用。
    private var isCommittedPhase: Bool {
        if case .ready = phase { return true }
        return false
    }

    private var isReadyOrSelected: Bool { isCommittedPhase && !isEditingGesture }
    private var canOutput: Bool { isReadyOrSelected && !selectionRect.isEmpty }

    // MARK: - 方向键与光标

    /// 方向键：裸键平移，Control 扩大，Shift 缩小。其他修饰组合不拦截。
    private func handleArrowKey(_ event: NSEvent) -> Bool {
        guard isReadyOrSelected,
              let direction = Self.arrowDirection(for: event.keyCode) else { return false }
        switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
        case []: applyNudge(direction, mode: .move)
        case .control: applyNudge(direction, mode: .expand)
        case .shift: applyNudge(direction, mode: .shrink)
        default: return false
        }
        return true
    }

    private static func arrowDirection(for keyCode: UInt16) -> NudgeDirection? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default: return nil
        }
    }

    private func applyNudge(_ direction: NudgeDirection, mode: NudgeMode) {
        let updated = RectMath.nudge(
            selectionRect,
            direction: direction,
            mode: mode,
            within: bounds,
            minimumSide: Self.minimumSelectionSide,
            aspectRatio: selectionAspectRatio.value
        )
        guard updated != selectionRect else { return }
        updateSelection(updated, annotationsFollowSelection: mode == .move)
    }

    /// 方向键调整后的统一落点：画布、标注、工具条与控制器里的待输出选区。
    private func updateSelection(_ rect: CGRect, annotationsFollowSelection: Bool) {
        let previousOrigin = selectionRect.origin
        selectionRect = rect
        if let canvas {
            // 平移时框与标注一起走；边界伸缩时补偿标注坐标，让它继续贴住原截图内容。
            if !annotationsFollowSelection {
                let delta = CGPoint(
                    x: previousOrigin.x - rect.minX,
                    y: previousOrigin.y - rect.minY
                )
                if delta != .zero {
                    canvas.translateAnnotations(by: delta)
                }
            }
            canvas.frame = rect
            canvas.updateCropOrigin(cropOriginPx(for: rect))
        }
        updateActionBar()
        needsDisplay = true
        publishSelection()
    }

    /// W A S D：裸键逐像素移动系统光标；按住左键且在 ready 相位时与方向键
    /// 同一套调整语义（Snipaste：Hold left button + W A S D 移动 / 扩大 / 缩小选区）。
    /// 拖拽选区与画标注中不接管，保持原来的光标移动，避免两套输入同时改选区。
    /// 文字编辑时事件由编辑器接收，不会走到这里。
    private func handleCursorKey(_ event: NSEvent) -> Bool {
        if canvas?.isEditingText == true || isEditingGesture { return false }
        if canvas != nil, !isLeftButtonDown { return false }
        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              let direction = Self.cursorDirections[key] else { return false }
        if isLeftButtonDown, isReadyOrSelected {
            switch event.modifierFlags.intersection([.command, .control, .option, .shift]) {
            case []: applyNudge(direction, mode: .move)
            case .control: applyNudge(direction, mode: .expand)
            case .shift: applyNudge(direction, mode: .shrink)
            default: return false
            }
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        moveSystemCursor(direction)
        return true
    }

    private static let cursorDirections: [String: NudgeDirection] = [
        "w": .up, "a": .left, "s": .down, "d": .right,
    ]

    private func moveSystemCursor(_ direction: NudgeDirection) {
        guard let current = effectiveMagnifierCursor else { return }
        var next = current
        switch direction {
        case .up: next.y += 1
        case .down: next.y -= 1
        case .left: next.x -= 1
        case .right: next.x += 1
        }
        next.x = min(max(next.x, bounds.minX), max(bounds.minX, bounds.maxX - 1))
        next.y = min(max(next.y, bounds.minY), max(bounds.minY, bounds.maxY - 1))
        magnifierCursor = next
        refreshMagnifier()
        needsDisplay = true

        let global = RectMath.toGlobalPoint(
            viewPoint: next,
            displayBounds: shot.bounds,
            viewHeight: bounds.height
        )
        let beforeWarp = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(global)
        CGAssociateMouseAndMouseCursorPosition(1)
        // warp 返回 void，读回系统光标判断是否真的移动。系统会把光标贴到整数像素，
        // 所以只看位置是否变化；目标与当前位置相同（贴边）时不做判断。
        if !didWarnCursorWarp, let beforeWarp,
           hypot(beforeWarp.x - global.x, beforeWarp.y - global.y) >= 0.5,
           let actual = CGEvent(source: nil)?.location,
           abs(actual.x - beforeWarp.x) < 0.01, abs(actual.y - beforeWarp.y) < 0.01 {
            didWarnCursorWarp = true
            print("[snip] warning: 光标 warp 未生效，仅更新内部光标状态")
        }
    }

    // MARK: - 历史回放

    private func canStepHistory(_ event: NSEvent) -> Bool {
        !history.isEmpty
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// index 0 是本次实时冻结帧，1... 是历史（1 为最新）。
    /// 切到历史后自动选中回放图，按 Enter 即可复制或继续标注；翻回实时帧则清空选区。
    private func stepHistory(_ delta: Int) {
        let next = min(max(historyIndex + delta, 0), history.count)
        guard next != historyIndex else { return }
        if next > 0, history[next - 1].editingImage != nil, let onReplayEditableHistory {
            onReplayEditableHistory(history[next - 1])
            return
        }
        historyIndex = next
        resetSelection()
        applyHistoryImage()
        if historyIndex > 0 {
            let entry = history[historyIndex - 1]
            applyInitialSelection(historyRegionRect(entry) ?? activeImageRect)
        }
        needsDisplay = true
    }

    /// 历史条目在源屏上的选区矩形，与原屏信息对不上时返回 nil。
    private func historyRegionRect(_ entry: CaptureHistoryEntry) -> CGRect? {
        guard let region = entry.region, region.displayID == shot.displayID else { return nil }
        return RectMath.clamp(
            RectMath.toViewRect(
                globalRect: region.rect,
                displayBounds: shot.bounds,
                viewHeight: bounds.height
            ),
            to: bounds
        )
    }

    private func applyHistoryImage() {
        guard historyIndex > 0 else {
            activeImage = frozenImage
            activeImageRect = bounds
            activeSource = shot.image
            activeScaleX = shot.scale
            activeScaleY = shot.scale
            return
        }
        let entry = history[historyIndex - 1]
        // 有整屏帧时铺满视图，选区单独由 region 决定，与 Snipaste 的回放一致。
        if let frame = entry.fullFrame {
            activeImageRect = bounds
            activeImage = NSImage(cgImage: frame, size: bounds.size)
            activeSource = frame
            activeScaleX = CGFloat(frame.width) / bounds.width
            activeScaleY = CGFloat(frame.height) / bounds.height
            return
        }
        // 旧条目只有选区图，退回按原位置摆放或等比居中。
        let rect = historyRegionRect(entry) ?? Self.fittedImageRect(for: entry, in: bounds)
        activeImageRect = rect
        activeImage = NSImage(cgImage: entry.image, size: rect.size)
        activeSource = entry.image
        activeScaleX = rect.width > 0
            ? CGFloat(entry.image.width) / rect.width
            : 1
        activeScaleY = rect.height > 0
            ? CGFloat(entry.image.height) / rect.height
            : 1
    }

    /// 历史图等比缩放并在屏幕居中。直接用像素宽高定比例，保证 x/y 同一缩放因子，
    /// 即使导出时加了阴影边距也不会被拉伸；displaySize 仍用于剪贴板点尺寸等场景。
    private static func fittedImageRect(
        for entry: CaptureHistoryEntry,
        in bounds: CGRect
    ) -> CGRect {
        let imageSize = CGSize(
            width: entry.image.width,
            height: entry.image.height
        )
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fitted = CGRect(
            x: bounds.midX - imageSize.width * scale / 2,
            y: bounds.midY - imageSize.height * scale / 2,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        ).integral.intersection(bounds)
        return fitted.isEmpty ? bounds : fitted
    }

    /// 控制器在窗口与冻结帧入列后调用：菜单回放进入时直接选中历史图。
    /// 不能在 init 里选中，提交通知需要回查已入列的 shots。
    func selectReplayedHistory() {
        guard historyIndex > 0 else { return }
        let entry = history[historyIndex - 1]
        applyInitialSelection(historyRegionRect(entry) ?? activeImageRect)
        needsDisplay = true
    }

    private func resetSelection() {
        removeCanvas()
        selectionRect = .zero
        phase = .idle
        hoverWindow = nil
        hoverElementRect = nil
        hoverElementLevel = 0
        latestElementQuery = nil
        updateActionBar()
    }

    func reselectRegion() {
        resetSelection()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func undoLastAnnotation() { canvas?.undo() }

    private func redoLastAnnotation() { canvas?.redo() }

    private func refreshUndoButtons() {
        toolbar.updateUndoState(canUndo: canvas?.canUndo ?? false, canRedo: canvas?.canRedo ?? false)
    }

    /// 光标下的窗口：视图坐标 → CG 全局坐标后在本屏候选里取最顶层命中。
    private func windowUnderMouse(at viewPoint: CGPoint) -> WindowCandidate? {
        let globalPoint = globalPoint(from: viewPoint)
        return WindowDetector.window(at: globalPoint, in: candidates)
    }

    private func refreshHover(at viewPoint: CGPoint) {
        let previousWindow = hoverWindow
        let previousElement = hoverElementRect
        defer {
            if hoverWindow != previousWindow || hoverElementRect != previousElement { needsDisplay = true }
        }
        hoverWindow = windowUnderMouse(at: viewPoint)
        guard elementDetectionEnabled, UIElementDetector.isTrusted else {
            latestElementQuery = nil
            hoverElementRect = nil
            return
        }
        if hoverElementRect?.contains(viewPoint) != true { hoverElementRect = nil }
        let query = ElementQuery(point: globalPoint(from: viewPoint), pid: hoverWindow?.ownerPID, level: hoverElementLevel)
        guard query != latestElementQuery else { return }
        latestElementQuery = query
        requestElement()
    }

    private func elementUnderMouse(at point: CGPoint) -> CGRect? {
        refreshHover(at: point)
        return hoverElementRect?.contains(point) == true ? hoverElementRect : nil
    }

    private func requestElement() {
        guard !elementQueryRunning, let query = latestElementQuery else { return }
        elementQueryRunning = true
        elementQueue.async { [weak self] in
            let rect = autoreleasepool {
                query.level == 0
                    ? UIElementDetector.element(at: query.point, inPID: query.pid)
                    : UIElementDetector.parentRect(of: query.point, levels: query.level, inPID: query.pid)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elementQueryRunning = false
                guard case .idle = self.phase, self.window?.isVisible == true else {
                    self.latestElementQuery = nil
                    return
                }
                guard self.latestElementQuery == query else {
                    self.requestElement()
                    return
                }
                if let rect, UIElementDetector.isUsable(rect, minimumSide: Self.minimumElementSide, within: self.shot.bounds) {
                    self.hoverElementRect = RectMath.clamp(UIElementDetector.viewRect(fromAXRect: rect,
                        displayBounds: self.shot.bounds, viewHeight: self.bounds.height), to: self.bounds)
                } else {
                    self.hoverElementRect = nil
                }
                self.needsDisplay = true
            }
        }
    }

    private func globalPoint(from viewPoint: CGPoint) -> CGPoint {
        RectMath.toGlobalPoint(
            viewPoint: viewPoint,
            displayBounds: shot.bounds,
            viewHeight: bounds.height
        )
    }

    /// 开始一次选区拖拽。
    ///
    /// 按下时**不预填选区**：用户要的是「从这一点开始划」。吸附目标只记在
    /// pendingSnapRect 里，按下没拖动就松手（单击）才用它把整个窗口/元素选上。
    /// 之前的写法一按下就把整块窗口填进选区，鼠标一动就跳变，像是替你框好了。
    private func beginSelection(at point: CGPoint) {
        pendingSnapRect = elementUnderMouse(at: point) ?? windowRectUnderMouse(at: point)
        hoverWindow = nil
        hoverElementRect = nil
        selectionRect = .zero
        phase = .selecting(origin: point, freeDrag: false)
        updateActionBar()
        needsDisplay = true
    }

    /// 光标下窗口在本屏视图坐标系下的矩形。
    private func windowRectUnderMouse(at point: CGPoint) -> CGRect? {
        guard let window = windowUnderMouse(at: point) else { return nil }
        let rect = RectMath.clamp(
            RectMath.toViewRect(
                globalRect: window.bounds,
                displayBounds: shot.bounds,
                viewHeight: bounds.height
            ),
            to: bounds
        )
        return rect.isEmpty ? nil : rect
    }

    /// 选区确定：边界取整保证预览与导出位图尺寸一致，然后进入 ready。
    private func commitSelection() {
        selectionRect = selectionRect.integral
        phase = .ready
        if let canvas {
            // 已有画布（边缘调整后重新确定）：保留已画标注，只同步尺寸与截图原点。
            canvas.frame = selectionRect
            canvas.updateCropOrigin(cropOriginPx(for: selectionRect))
        } else {
            setupCanvas()
        }
        publishSelection()
        updateActionBar()
    }

    /// 控制器在窗口入列后调用：活动窗口截屏 / 重复上次区域直接带着选区进会话。
    func applyInitialSelection(_ viewRect: CGRect) {
        guard case .idle = phase, selectionRect.isEmpty, !pickColorMode else { return }
        let clamped = RectMath.clamp(viewRect, to: bounds)
        guard clamped.width >= Self.minimumSelectionSide,
              clamped.height >= Self.minimumSelectionSide else { return }
        selectionRect = clamped
        commitSelection()
        needsDisplay = true
    }

    /// 把当前选区连同实际输出源交给控制器。方向键调整后也会重新发布。
    private func publishSelection() {
        NotificationCenter.default.post(
            name: .snipCommitted,
            object: nil,
            userInfo: [
                SnipNotificationKey.viewRect: selectionRect,
                SnipNotificationKey.viewHeight: bounds.height,
                SnipNotificationKey.scale: shot.scale,
                SnipNotificationKey.displayID: shot.displayID,
                SnipNotificationKey.sourceImage: activeSource,
                SnipNotificationKey.cropRectPx: RectMath.imageRect(
                    fromViewRect: selectionRect,
                    displayedIn: activeImageRect,
                    scaleX: activeScaleX,
                    scaleY: activeScaleY
                ),
            ]
        )
    }

    private func cropOriginPx(for rect: CGRect) -> CGPoint {
        let imageRect = RectMath.imageRect(
            fromViewRect: rect,
            displayedIn: activeImageRect,
            scaleX: activeScaleX,
            scaleY: activeScaleY
        )
        return CGPoint(x: imageRect.minX, y: imageRect.minY)
    }



    private func setupCanvas() {
        let newCanvas = AnnotationCanvas(
            base: activeSource,
            cropOriginPx: cropOriginPx(for: selectionRect),
            scale: activeScaleX,
            initialStyle: ShapeCatalog.entry(for: .rect)!.defaultStyle
        )
        newCanvas.autoSelectOnCreation = autoSelectOnCreation
        newCanvas.receivesEvents = false
        if historyIndex > 0, history.indices.contains(historyIndex - 1) {
            newCanvas.restoreAnnotations(history[historyIndex - 1].annotations)
        }
        addSubview(newCanvas, positioned: .below, relativeTo: toolbar)
        newCanvas.frame = selectionRect
        canvas = newCanvas
        newCanvas.onChange = { [weak self] in self?.syncEditorToolbar() }
        syncEditorToolbar()
    }

    private func syncEditorToolbar() {
        guard let canvas else { return }
        if !canvas.selectedIDs.isEmpty {
            toolbar.updateSelection(kind: canvas.styleKind, style: canvas.currentStyle, drawingTool: canvas.tool)
        } else if let kind = canvas.tool {
            toolbar.select(kind, style: canvas.currentStyle)
        } else {
            toolbar.selectMode()
        }
        refreshUndoButtons()
        updateActionBar()
    }

    private func removeCanvas() {
        canvas?.removeFromSuperview()
        canvas = nil
    }

    private func updateActionBar() {
        toolbar.maximumWidth = max(320, bounds.width - 8)
        guard isCommittedPhase, !selectionRect.isEmpty, actionBarVisible else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        refreshUndoButtons()
        toolbar.frame.origin = ToolbarPlacement.origin(
            toolbarSize: toolbar.frame.size,
            selection: selectionRect,
            within: bounds
        )
    }

    private func selectTool(_ kind: ShapeKind) { canvas?.selectTool(kind) }

    private func enterSelectMode() { canvas?.selectTool(nil) }

    private func applyStyle(_ style: Style) { canvas?.applyStyle(style) }

    private func requestCopy() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipCopyRequested,
            object: nil,
            userInfo: [
                SnipNotificationKey.displayID: shot.displayID,
                // 没有事件上下文时静态属性返回当前按压状态，正是「复制时按住 ⌥」要的值。
                SnipNotificationKey.modifierFlags: NSEvent.modifierFlags,
            ]
        )
    }

    private func requestPin() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipPinRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestShare() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipShareRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestTextRecognition() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipTextRecognizeRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestTranslate() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipTranslateRequested,
            object: nil,
            userInfo: [
                SnipNotificationKey.displayID: shot.displayID,
                SnipNotificationKey.translationTarget: translationTarget.rawValue,
            ]
        )
    }

    private func requestBarcodeScan() {
        canvas?.finishEditing()
        NotificationCenter.default.post(
            name: .snipBarcodeScanRequested,
            object: nil,
            userInfo: [SnipNotificationKey.displayID: shot.displayID]
        )
    }

    private func requestScrollingCapture() {
        guard case .ready = phase, !selectionRect.isEmpty else { return }
        NotificationCenter.default.post(name: .snipScrollRequested, object: self)
    }

    /// 识别结果回显。控制器在后台识别完成后回主线程调用。
    func showToolbarMessage(_ text: String) {
        toolbar.showMessage(text)
    }

    func showBusyMessage(_ text: String) {
        toolbar.showBusy(text)
    }

    func hideBusyMessage() {
        toolbar.hideBusy()
    }

    private func requestSave(quick: Bool = false) {
        canvas?.finishEditing()
        var info: [AnyHashable: Any] = [SnipNotificationKey.displayID: shot.displayID]
        if quick { info[SnipNotificationKey.quickSave] = true }
        NotificationCenter.default.post(
            name: .snipSaveRequested,
            object: nil,
            userInfo: info
        )
    }

    private func requestCancel() {
        // 滚动阶段只取消滚动捕获，不直接取消整个会话。
        if case .scrolling = phase {
            NotificationCenter.default.post(name: .snipScrollCancelRequested, object: self)
            return
        }
        NotificationCenter.default.post(name: .snipEscapePressed, object: nil)
    }

    // MARK: - 绘制

    /// 悬停只是「点一下会选中这块」的预览：虚线细边，不能画得像已经选好的选区。
    private func drawHoverHighlight() {
        guard let rect = hoverRectInView() else { return }
        let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        // 元素比窗口更细，用不同颜色区分当前吸附的是哪一级。
        (hoverElementRect == nil ? NSColor.systemBlue : NSColor.systemOrange)
            .withAlphaComponent(0.85)
            .setStroke()
        border.stroke()
    }

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        // even-odd 挖空选区/悬停窗口。.clear 混合模式会连已绘制的冻结帧一起擦掉，透出窗口黑底。
        if !selectionRect.isEmpty {
            mask.appendRect(selectionRect)
            mask.windingRule = .evenOdd
        } else if let hoverRect = hoverRectInView() {
            // 悬停窗口提亮：挖空后冻结帧原样显示，接近 Snipaste 观感
            mask.appendRect(hoverRect)
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(Self.maskAlpha).setFill()
        mask.fill()
    }

    /// 当前悬停目标在本屏视图坐标系下的矩形；元素优先于窗口，无悬停或完全在本屏外时为 nil。
    private func hoverRectInView() -> CGRect? {
        if let element = hoverElementRect, !element.isEmpty { return element }
        guard let window = hoverWindow else { return nil }
        let rect = RectMath.clamp(
            RectMath.toViewRect(
                globalRect: window.bounds,
                displayBounds: shot.bounds,
                viewHeight: bounds.height
            ),
            to: bounds
        )
        return rect.isEmpty ? nil : rect
    }

    private func drawSelectionBorder() {
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        if isCommittedPhase { drawSelectionHandles() }
    }

    /// 边缘与四角的调整手柄，只画在覆盖层上，不进导出。
    /// 白色方块配深色描边，浅色与深色底图上都能看清可拖的位置。
    private func drawSelectionHandles() {
        let side: CGFloat = 6
        let half = side / 2
        let points = [
            CGPoint(x: selectionRect.midX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.midX, y: selectionRect.minY),
            CGPoint(x: selectionRect.minX, y: selectionRect.midY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.midY),
            CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.minX, y: selectionRect.minY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
        ]
        for point in points {
            let handle = NSBezierPath(
                rect: CGRect(x: point.x - half, y: point.y - half, width: side, height: side)
            )
            NSColor.white.setFill()
            handle.fill()
            NSColor(white: 0, alpha: 0.55).setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    private func drawSizeLabel() {
        let width = Int(selectionRect.width)
        let height = Int(selectionRect.height)
        guard width >= 1, height >= 1 else { return }

        let text = "\(width) × \(height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: SizeLabel.font,
            .foregroundColor: SizeLabel.textColor,
        ]
        let padding = SizeLabel.padding
        let textSize = text.size(withAttributes: attributes)
        let labelSize = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )

        var origin = CGPoint(
            x: selectionRect.maxX - labelSize.width,
            y: selectionRect.maxY + SizeLabel.gap
        )
        if origin.y + labelSize.height > bounds.maxY {
            origin.y = selectionRect.maxY - labelSize.height - SizeLabel.gap
        }
        origin.x = min(
            max(origin.x, bounds.minX + SizeLabel.gap),
            bounds.maxX - labelSize.width - SizeLabel.gap
        )

        let labelRect = NSRect(origin: origin, size: labelSize)
        SizeLabel.background.setFill()
        NSBezierPath(
            roundedRect: labelRect,
            xRadius: SizeLabel.cornerRadius,
            yRadius: SizeLabel.cornerRadius
        ).fill()
        text.draw(
            at: NSPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    /// 底部居中的历史位置标签。只在实际回放时出现。
    private func drawHistoryLabel() {
        guard historyIndex > 0 else { return }
        let text = "历史 \(historyIndex)/\(history.count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: SizeLabel.font,
            .foregroundColor: SizeLabel.textColor,
        ]
        let padding = SizeLabel.padding
        let textSize = text.size(withAttributes: attributes)
        let labelSize = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let labelRect = NSRect(
            x: (bounds.width - labelSize.width) / 2,
            y: bounds.minY + 16,
            width: labelSize.width,
            height: labelSize.height
        )
        SizeLabel.background.setFill()
        NSBezierPath(
            roundedRect: labelRect,
            xRadius: SizeLabel.cornerRadius,
            yRadius: SizeLabel.cornerRadius
        ).fill()
        text.draw(
            at: NSPoint(x: labelRect.minX + padding.width, y: labelRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    private func drawMagnifier() {
        guard isMagnifierVisible, let cursor = effectiveMagnifierCursor else { return }
        let frame = MagnifierGeometry.frame(cursor: cursor, in: bounds)
        let interior = MagnifierGeometry.interiorRect(in: frame)
        let sampler = MagnifierSampler(
            image: activeSource,
            canvasSize: bounds.size,
            scaleX: activeScaleX,
            scaleY: activeScaleY,
            origin: activeImageRect.origin
        )
        guard let sample = sampler.magnified(
            at: cursor,
            sourcePixels: MagnifierGeometry.samplePixelCount(scale: min(activeScaleX, activeScaleY)),
            zoom: MagnifierGeometry.zoom
        ) else { return }

        let outer = NSBezierPath(
            roundedRect: frame,
            xRadius: MagnifierGeometry.cornerRadius,
            yRadius: MagnifierGeometry.cornerRadius
        )
        NSColor(white: 0.1, alpha: 0.92).setFill()
        outer.fill()

        NSGraphicsContext.saveGraphicsState()
        let radius = MagnifierGeometry.cornerRadius - MagnifierGeometry.borderWidth
        NSBezierPath(roundedRect: interior, xRadius: radius, yRadius: radius).addClip()
        NSImage(cgImage: sample.image, size: interior.size).draw(in: interior)
        drawMagnifierCrosshair(in: interior, sample: sample)
        NSGraphicsContext.restoreGraphicsState()

        outer.lineWidth = MagnifierGeometry.borderWidth
        NSColor.white.withAlphaComponent(0.85).setStroke()
        outer.stroke()

        if let colorFeedback {
            drawColorFeedback(colorFeedback, in: frame)
        }
    }

    private func drawMagnifierCrosshair(
        in interior: CGRect,
        sample: MagnifierSampler.Magnified
    ) {
        let outputSide = CGFloat(sample.outputSide)
        let center = CGPoint(
            x: interior.minX + sample.crosshair.x / outputSide * interior.width,
            y: interior.maxY - sample.crosshair.y / outputSide * interior.height
        )
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: interior.minX, y: center.y))
        cross.line(to: CGPoint(x: interior.maxX, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: interior.minY))
        cross.line(to: CGPoint(x: center.x, y: interior.maxY))
        cross.lineWidth = 3
        NSColor.black.withAlphaComponent(0.5).setStroke()
        cross.stroke()
        cross.lineWidth = 1
        NSColor.white.setStroke()
        cross.stroke()

        // 光标像素本身圈出来，只看十字线分不清落在哪一格。
        let cell = interior.width * CGFloat(sample.zoom) / outputSide
        let box = NSBezierPath(rect: CGRect(
            x: center.x - cell / 2,
            y: center.y - cell / 2,
            width: cell,
            height: cell
        ))
        box.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        box.stroke()
        box.lineWidth = 1
        NSColor.white.setStroke()
        box.stroke()
    }

    private func drawColorFeedback(_ text: String, in frame: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let padding = NSSize(width: 5, height: 2)
        let size = NSSize(
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let rect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + MagnifierGeometry.borderWidth + 3,
            width: size.width,
            height: size.height
        )
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        string.draw(
            at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height),
            withAttributes: attributes
        )
    }
}

extension Notification.Name {
    static let snipEscapePressed = Notification.Name("snipEscapePressed")
    static let snipCommitted = Notification.Name("snipCommitted")
    static let snipCopyRequested = Notification.Name("snipCopyRequested")
    static let snipShareRequested = Notification.Name("snipShareRequested")
    static let snipTextRecognizeRequested = Notification.Name("snipTextRecognizeRequested")
    static let snipTranslateRequested = Notification.Name("snipTranslateRequested")
    static let snipBarcodeScanRequested = Notification.Name("snipBarcodeScanRequested")
    static let snipSaveRequested = Notification.Name("snipSaveRequested")
    static let snipPinRequested = Notification.Name("snipPinRequested")
    static let snipScrollRequested = Notification.Name("snipScrollRequested")
    static let snipScrollFinishRequested = Notification.Name("snipScrollFinishRequested")
    static let snipScrollCancelRequested = Notification.Name("snipScrollCancelRequested")
}

/// 截图通知 userInfo 的键。收成封闭枚举，避免字符串字面量在两端拼错。
enum SnipNotificationKey: Hashable {
    case viewRect
    case viewHeight
    case scale
    case displayID
    /// 实际输出源与像素裁剪矩形。历史回放时可能是历史截图。
    case sourceImage
    case cropRectPx
    /// ⇧ + 保存按钮 / ⌘⇧S：直接写快捷保存目录，不弹面板。
    case quickSave
    /// 复制请求发出时的修饰键，决定「按住 ⌥ 时」是否落文件。
    case modifierFlags
    /// 本次翻译请求的目标语言代码，工具条方向按钮决定。
    case translationTarget
}

extension Dictionary where Key == AnyHashable, Value == Any {
    subscript(key: SnipNotificationKey) -> Any? {
        self[AnyHashable(key)]
    }
}
