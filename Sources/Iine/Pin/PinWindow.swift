import AppKit
import IineCore

/// 无边框置顶贴图窗口。窗口尺寸、旋转、翻转与透明度都只由 transform 派生。
@MainActor
final class PinWindow: NSWindow {
    private static let dragGrip: CGFloat = 24

    private let pinView = PinContentView(frame: .zero)
    private(set) var pasteImage: PasteImage
    private(set) var contentFingerprint: PasteImage.ContentFingerprint?
    /// 控制器分配的身份，分组与 Solo 只按它记账，不用窗口对象。
    let pinID: Int
    /// 多选与整组拖动由控制器协调，窗口只把交互意图转过去。
    weak var pinController: PinController?
    var onRecognize: ((CGImage, CGFloat, Bool, NSWindow) -> Void)?
    var translationTarget: TranslationTarget = .auto
    private(set) var transform: PinTransform = .identity
    /// 背景只影响绘制，不进入 transform，也不参与任何导出。
    private(set) var background: PinBackground = .transparent
    /// 是否在多选集合里；控制器是唯一写入口。
    private(set) var isMultiSelected = false
    /// Shift+Esc 销毁的贴图不进恢复列表，普通关闭才进。
    private(set) var canRestore = true
    /// 初始适配到屏幕 80% 后的尺寸。transform.scale 从 1 起，首次变换才不会跳回原图尺寸。
    private(set) var basePointSize: CGSize

    /// 每次裁剪前的保留区域，⌘Z 逐级退回。原始的 pasteImage 始终未改动。
    private var cropHistory: [CGRect?] = []
    private var imageCache: (key: ImageKey, image: CGImage, pointSize: CGSize, annotationBase: CGImage)?
    /// 标注底栏放在贴图窗口外的浮动面板里：贴图可以很小（40x30），
    /// 底栏塞进内容视图会把整张图盖住，也接不了 15 个工具。
    private var annotatePanel: NSPanel?

    private struct ImageKey: Equatable {
        let crop: CGRect?
        let grayscale: Bool
        let inverted: Bool
    }

    private var pixelSize: CGSize {
        CGSize(width: pasteImage.image.width, height: pasteImage.image.height)
    }

    /// topLeft 使用主屏左上角为原点的屏幕坐标（y 向下），与 CLI 的 --pos 一致。
    init(
        pasteImage: PasteImage,
        pinID: Int,
        screen: NSScreen,
        cascadeIndex: Int,
        topLeft requestedTopLeft: CGPoint? = nil,
        fingerprint: PasteImage.ContentFingerprint? = nil
    ) {
        let visible = screen.visibleFrame
        let source = pasteImage.pointSize
        let fit = min(
            1,
            visible.width * 0.8 / max(1, source.width),
            visible.height * 0.8 / max(1, source.height)
        )
        let size = CGSize(
            width: max(1, floor(source.width * fit)),
            height: max(1, floor(source.height * fit))
        )
        basePointSize = size
        self.pasteImage = pasteImage
        self.contentFingerprint = fingerprint ?? pasteImage.contentFingerprint
        self.pinID = pinID
        var origin: CGPoint
        if let requestedTopLeft {
            // 窗口 frame 的原点是左下角，而请求给的是左上角。
            origin = CGPoint(x: requestedTopLeft.x, y: requestedTopLeft.y - size.height)
        } else {
            // 后续贴图错开叠放，否则多张完全重合看不出有几张。
            let offset = CGFloat(cascadeIndex % 6) * 24
            origin = CGPoint(
                x: visible.midX - size.width / 2 + offset,
                y: visible.maxY - visible.height * 0.12 - size.height - offset
            )
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        // 非整数原点会让 AppKit 把 frame 向外取整，尺寸凭空多 1 点。
        origin = CGPoint(x: floor(origin.x), y: floor(origin.y))

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()

        pinView.baseSize = size
        refreshImage()
        pinView.restoreAnnotations(pasteImage.annotations)
    }

    /// 从恢复列表重建，保留关闭时的尺寸与变换，并确保仍能拖回。
    init(pasteImage: PasteImage, pinID: Int, restoring entry: PinRestoreEntry) {
        basePointSize = entry.basePointSize
        self.pasteImage = pasteImage
        self.contentFingerprint = entry.fingerprint ?? pasteImage.contentFingerprint
        self.pinID = pinID
        super.init(
            contentRect: Self.reachableFrame(entry.frame),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        transform = entry.transform
        alphaValue = entry.transform.opacity
        refreshImage()
        pinView.transform = entry.transform
        // 标注跟着图像一起恢复，关闭再贴回不用重画。
        pinView.restoreAnnotations(entry.annotations)
        pinView.needsDisplay = true
    }

    private func configureWindow() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = pinView
        makeFirstResponder(pinView)
    }

    /// 当前图上的标注，关闭时随恢复项一起存下来。
    var annotations: [Annotation] { pinView.annotations }

    /// 历史翻页：把窗口内容、变换、位置一次性换成历史里的另一张。
    func applyHistory(_ entry: PinRestoreEntry) {
        pasteImage = entry.image
        contentFingerprint = entry.fingerprint ?? entry.image.contentFingerprint
        basePointSize = entry.basePointSize
        transform = entry.transform
        alphaValue = entry.transform.opacity
        imageCache = nil
        // 标注属于被换下的那张图：翻页换图时换成该历史项自己的标注。
        pinView.restoreAnnotations(entry.annotations)
        refreshImage()
        pinView.transform = entry.transform
        pinView.needsDisplay = true
        setFrame(Self.reachableFrame(entry.frame), display: true)
        invalidateCursorRects(for: pinView)
    }

    /// 逗号看更早关闭的贴图，句号看更新的。
    func stepHistory(by direction: Int) {
        pinController?.stepHistory(by: direction, in: self)
    }

    /// 销毁：关闭且不留下可恢复的副本。
    func destroy() {
        canRestore = false
        close()
    }

    // MARK: - 标注底栏（独立浮窗）

    /// 承载标注底栏的浮窗。点按钮时不让贴图窗口失焦，因此用非激活面板。
    private func makeAnnotatePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.isFloatingPanel = true
        // 只有底栏里的输入控件需要按键，面板本身不抢 key。
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    func attachAnnotateBar(_ bar: PinAnnotateBar) {
        let panel = annotatePanel ?? makeAnnotatePanel()
        annotatePanel = panel
        let size = bar.intrinsicContentSize
        bar.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = bar
        bar.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        if panel.parent == nil {
            addChildWindow(panel, ordered: .above)
        }
        positionAnnotatePanel()
        panel.orderFront(nil)
    }

    func detachAnnotateBar() {
        guard let panel = annotatePanel else { return }
        annotatePanel = nil
        panel.orderOut(nil)
        if panel.parent != nil { removeChildWindow(panel) }
        panel.contentView = NSView(frame: .zero)
    }

    /// 贴在贴图窗口正下方；下方放不下就翻到上方，横向钳进屏幕。
    private func positionAnnotatePanel() {
        guard let panel = annotatePanel else { return }
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let gap: CGFloat = 8
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - gap - size.height)
        if origin.y < bounds.minY {
            let above = frame.maxY + gap
            origin.y = above + size.height <= bounds.maxY ? above : bounds.minY
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        panel.setFrameOrigin(origin)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        positionAnnotatePanel()
    }

    override func close() {
        pinView.finishEditing()
        pinView.cancelPendingTasks()
        detachAnnotateBar()
        super.close()
    }

    /// 当前视觉状态（裁剪、滤镜、旋转、翻转）加标注的位图，供复制与另存为使用。
    func flattenedImage() -> CGImage? {
        pinView.finishEditing()
        guard let cache = imageCache else { return nil }
        let scale = CGFloat(pasteImage.image.width) / max(1, pasteImage.pointSize.width)
        let crop = transform.cropRect ?? CGRect(x: 0, y: 0, width: pasteImage.image.width, height: pasteImage.image.height)
        let cropOrigin = CGPoint(x: crop.minX / scale,
            y: (CGFloat(pasteImage.image.height) - crop.maxY) / scale)
        let items = pinView.annotations.map {
            Annotation(id: $0.id, shape: $0.shape.translated(by: CGPoint(x: -cropOrigin.x, y: -cropOrigin.y)), style: $0.style)
        }
        guard let base = AnnotationExport.flatten(base: cache.annotationBase, cropRectPx: crop,
            annotations: items, scale: scale) else { return nil }
        guard transform.quarterTurns != 0 || transform.flipHorizontal || transform.flipVertical else { return base }
        let rotated = transform.quarterTurns % 2 != 0
        guard let context = CGContext(data: nil,
            width: rotated ? base.height : base.width, height: rotated ? base.width : base.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(context.width) / 2, y: CGFloat(context.height) / 2)
        context.scaleBy(x: transform.flipHorizontal ? -1 : 1, y: transform.flipVertical ? -1 : 1)
        context.rotate(by: -CGFloat(transform.quarterTurns) * .pi / 2)
        context.draw(base, in: CGRect(x: -CGFloat(base.width) / 2, y: -CGFloat(base.height) / 2,
            width: CGFloat(base.width), height: CGFloat(base.height)))
        return context.makeImage()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setScale(_ value: CGFloat) {
        transform.setScale(value)
        applyTransform()
    }

    func adjustScale(by delta: CGFloat) {
        transform.adjustScale(by: delta)
        applyTransform()
    }

    func rotate(byQuarterTurns turns: Int) {
        transform.rotate(byQuarterTurns: turns)
        applyTransform()
    }

    func toggleFlipHorizontal() {
        transform.toggleFlipHorizontal()
        applyTransform()
    }

    func toggleFlipVertical() {
        transform.toggleFlipVertical()
        applyTransform()
    }

    func setOpacity(_ value: CGFloat) {
        transform.setOpacity(value)
        applyTransform()
    }

    func adjustOpacity(by delta: CGFloat) {
        transform.adjustOpacity(by: delta)
        applyTransform()
    }

    func toggleThumbnail() {
        transform.toggleThumbnail()
        applyTransform()
    }

    func toggleGrayscale() {
        transform.toggleGrayscale()
        applyTransform()
    }

    func toggleInverted() {
        transform.toggleInverted()
        applyTransform()
    }

    func setBackground(_ mode: PinBackground) {
        guard background != mode else { return }
        background = mode
        pinView.background = mode
        pinView.needsDisplay = true
    }

    func cycleBackground() {
        setBackground(background.next())
        print("[pin] background=\(background.rawValue) pin=\(pinID)")
    }

    func setMultiSelected(_ selected: Bool) {
        guard isMultiSelected != selected else { return }
        isMultiSelected = selected
        pinView.isSelected = selected
    }

    func resetTransform() {
        transform.reset()
        cropHistory.removeAll()
        applyTransform()
    }

    /// 裁剪只改 transform 里的保留区域，原图不复制也不删。窗口左上角保持不动。
    @discardableResult
    func applyCrop(viewSelection: CGRect) -> Bool {
        guard !transform.isThumbnail,
              let selection = PinCrop.clampedSelection(viewSelection, in: pinView.bounds),
              let rect = PinCrop.pixelRect(
                  fromViewRect: selection,
                  viewSize: pinView.bounds.size,
                  imagePixelSize: pixelSize,
                  transform: transform,
                  basePointSize: basePointSize
              ) else { return false }
        cropHistory.append(transform.cropRect)
        transform.setCrop(rect)
        applyTransform(anchor: .topLeft)
        return true
    }

    @discardableResult
    func undoLastCrop() -> Bool {
        guard let previous = cropHistory.popLast() else { return false }
        transform.setCrop(previous)
        applyTransform(anchor: .topLeft)
        return true
    }

    /// 效果与裁剪都烘进同一张显示图，导出走同一份成品，而不是在视图上叠滤镜。
    private func refreshImage() {
        let key = ImageKey(
            crop: transform.cropRect,
            grayscale: transform.isGrayscale,
            inverted: transform.isInverted
        )
        guard imageCache?.key != key else { return }
        let full = PinImageEffects.render(pasteImage.image, crop: nil,
            grayscale: key.grayscale, inverted: key.inverted)
        let visible = key.crop.flatMap { PinImageEffects.croppedImage(full, to: $0) } ?? full
        imageCache = (key, visible,
            transform.displayedSize(original: pasteImage.pointSize, imagePixelSize: pixelSize), full)
        guard let imageCache else { return }
        pinView.image = NSImage(cgImage: imageCache.image, size: imageCache.pointSize)
        pinView.logicalPointSize = pasteImage.pointSize
        let scale = CGFloat(pasteImage.image.width) / max(1, pasteImage.pointSize.width)
        if let crop = transform.cropRect {
            pinView.visibleImageRect = CGRect(x: crop.minX / scale,
                y: (CGFloat(pasteImage.image.height) - crop.maxY) / scale,
                width: crop.width / scale, height: crop.height / scale)
        } else {
            pinView.visibleImageRect = CGRect(origin: .zero, size: pasteImage.pointSize)
        }
        pinView.baseCGImage = imageCache.annotationBase
        pinView.baseSize = transform.displayedSize(original: basePointSize, imagePixelSize: pixelSize)
        pinView.updateEditorGeometry()
    }

    private enum Anchor {
        case center
        case topLeft
    }

    /// 以当前中心（裁剪时以左上角）为锚重设尺寸，并留出可拖回的区域。
    private func applyTransform(anchor: Anchor = .center) {
        pinView.transform = transform
        refreshImage()
        let size = transform.windowSize(base: pinView.baseSize)
        let oldFrame = frame
        alphaValue = transform.opacity
        let origin: CGPoint
        switch anchor {
        case .center:
            origin = CGPoint(
                x: floor(oldFrame.midX - size.width / 2),
                y: floor(oldFrame.midY - size.height / 2)
            )
        case .topLeft:
            origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height)
        }
        setFrame(
            Self.reachableFrame(CGRect(origin: origin, size: size)),
            display: true
        )
        pinView.needsDisplay = true
        invalidateCursorRects(for: pinView)
    }

    func move(to origin: CGPoint) {
        let target = Self.reachableFrame(CGRect(origin: origin, size: frame.size)).origin
        if target != frame.origin { setFrameOrigin(target) }
    }

    private static func reachableFrame(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let bounds = reachableOrigins(for: frame.size, near: frame.origin, on: screens) else { return frame }
        return CGRect(origin: clamped(frame.origin, to: bounds), size: frame.size)
    }

    /// 每块屏幕允许的窗口原点范围。优先保留目标位置，否则用距离最近的屏幕。
    static func reachableOrigins(for size: CGSize, near origin: CGPoint, on screens: [CGRect]) -> CGRect? {
        let gripWidth = min(dragGrip, size.width)
        let gripHeight = min(dragGrip, size.height)
        var nearest: CGRect?
        var nearestDistance = CGFloat.infinity
        for screen in screens {
            let bounds = CGRect(
                x: screen.minX - size.width + gripWidth,
                y: screen.minY - size.height + gripHeight,
                width: screen.width + size.width - 2 * gripWidth,
                height: screen.height + size.height - 2 * gripHeight
            )
            let reachable = clamped(origin, to: bounds)
            if reachable == origin { return bounds }
            let dx = reachable.x - origin.x
            let dy = reachable.y - origin.y
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearest = bounds
                nearestDistance = distance
            }
        }
        return nearest
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

/// 键盘变换、双击关闭、边缘缩放、滚轮缩放与拖动移动。
/// 标注状态做成 internal 可读，验收 harness 直接驱动坐标变换与撤销。
@MainActor
final class PinContentView: NSView, NSSharingServicePickerDelegate {
    var image: NSImage?
    var baseCGImage: CGImage? { didSet { configureEditor() } }
    var baseSize: CGSize = .zero { didSet { updateEditorGeometry() } }
    var logicalPointSize: CGSize = .zero
    var visibleImageRect: CGRect = .zero
    var transform: PinTransform = .identity { didSet { updateEditorGeometry() } }
    var background: PinBackground = .transparent
    var isSelected = false { didSet { needsDisplay = true } }
    private(set) var annotationCanvas: AnnotationCanvas?
    private var pendingAnnotations: [Annotation] = []
    private(set) var isAnnotating = false
    private var beforeAnnotationMode: AnnotationCanvas.Checkpoint?
    private var sharePicker: NSSharingServicePicker?
    private var barcodeTask: Task<Void, Never>?
    private var feedbackToken = 0
    private lazy var feedbackLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        label.layer?.cornerRadius = 5
        label.isHidden = true
        return label
    }()

    var annotations: [Annotation] { annotationCanvas?.annotations ?? pendingAnnotations }
    var selectedAnnotationIDs: Set<UUID> { annotationCanvas?.selectedIDs ?? [] }
    var annotationTool: ShapeKind? {
        get { isAnnotating ? annotationCanvas?.tool : nil }
        set {
            if let newValue {
                setAnnotateMode(true)
                annotationCanvas?.selectTool(newValue)
            } else { setAnnotateMode(false) }
        }
    }
    var annotationStyle: Style {
        get { annotationCanvas?.currentStyle ?? ShapeCatalog.entry(for: .rect)!.defaultStyle }
        set { annotationCanvas?.applyStyle(newValue) }
    }

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var resizeState: ResizeState?
    private var isCropping = false
    private var cropStart: CGPoint?
    private var cropSelection: CGRect?

    private let hotZone: CGFloat = 8
    private var hoverTracking: NSTrackingArea?
    private lazy var toolbar = makeToolbar()
    private lazy var annotateBar = makeAnnotateBar()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if toolbar.superview == nil {
            addSubview(toolbar)
            toolbar.isHidden = true
        }
        configureEditor()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateEditorGeometry()
        toolbar.maximumWidth = max(0, bounds.width - 4)
        let size = toolbar.intrinsicContentSize
        toolbar.frame = CGRect(
            x: floor((bounds.width - size.width) / 2),
            y: bounds.height - size.height - 2,
            width: size.width,
            height: size.height
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        toolbar.updateStyle(scale: transform.scale)
        toolbar.isHidden = isAnnotating
    }

    override func mouseExited(with event: NSEvent) {
        toolbar.isHidden = true
    }

    private func makeToolbar() -> PinToolbar {
        let bar = PinToolbar()
        bar.onZoomOut = { [weak self] in self?.pinWindow?.adjustScale(by: -0.1) }
        bar.onZoomIn = { [weak self] in self?.pinWindow?.adjustScale(by: 0.1) }
        bar.onRotateLeft = { [weak self] in self?.pinWindow?.rotate(byQuarterTurns: -1) }
        bar.onRotateRight = { [weak self] in self?.pinWindow?.rotate(byQuarterTurns: 1) }
        bar.onFlipHorizontal = { [weak self] in self?.pinWindow?.toggleFlipHorizontal() }
        bar.onFlipVertical = { [weak self] in self?.pinWindow?.toggleFlipVertical() }
        bar.onGrayscale = { [weak self] in self?.pinWindow?.toggleGrayscale() }
        bar.onInverted = { [weak self] in self?.pinWindow?.toggleInverted() }
        bar.onCopy = { [weak self] in self?.copyImageFromMenu() }
        bar.onSave = { [weak self] in self?.saveImageFromMenu() }
        bar.onAnnotate = { [weak self] in
            guard let self else { return }
            self.setAnnotateMode(!self.isAnnotating)
        }
        bar.onClose = { [weak self] in self?.pinWindow?.close() }
        return bar
    }

    private func makeAnnotateBar() -> PinAnnotateBar {
        let panel = PinAnnotateBar()
        let bar = panel.toolbar
        bar.onSelectTool = { [weak self] in self?.annotationCanvas?.selectTool($0) }
        bar.onSelectMode = { [weak self] in self?.annotationCanvas?.selectTool(nil) }
        bar.onStyleChange = { [weak self] in self?.annotationCanvas?.applyStyle($0) }
        bar.onStylePropertyChange = { [weak self] style, attribute in
            self?.annotationCanvas?.applyStyle(style, changed: attribute)
        }
        bar.onUndo = { [weak self] in self?.annotationCanvas?.undo() }
        bar.onRedo = { [weak self] in self?.annotationCanvas?.redo() }
        bar.onFinish = { [weak self] in self?.setAnnotateMode(false) }
        bar.onCancel = { [weak self] in self?.setAnnotateMode(false, discardingAnnotations: true) }
        bar.onCopy = { [weak self] in self?.copyImageFromMenu() }
        bar.onSave = { [weak self] in self?.saveImageFromMenu() }
        bar.onQuickSave = { [weak self] in self?.quickSaveImage() }
        bar.onScanBarcode = { [weak self] in self?.scanBarcode() }
        bar.onShare = { [weak self] in self?.shareImage() }
        bar.onTranslationTargetChange = { [weak self] in self?.pinWindow?.translationTarget = $0 }
        bar.onExtractText = { [weak self] in self?.recognize(translate: false) }
        bar.onTranslate = { [weak self] in self?.recognize(translate: true) }
        panel.onSizeChange = { [weak self, weak panel] in
            guard let self, let panel, self.isAnnotating else { return }
            self.pinWindow?.attachAnnotateBar(panel)
        }
        return panel
    }

    private var pinWindow: PinWindow? { window as? PinWindow }
    private static var checkerTiles: [PinBackground: CGImage] = [:]

    private func configureEditor() {
        guard let baseCGImage, logicalPointSize.width > 0 else { return }
        let scale = CGFloat(baseCGImage.width) / logicalPointSize.width
        if let annotationCanvas {
            annotationCanvas.updateBase(baseCGImage, scale: scale)
        } else {
            let canvas = AnnotationCanvas(base: baseCGImage, cropOriginPx: .zero, scale: scale,
                initialStyle: ShapeCatalog.entry(for: .rect)!.defaultStyle)
            canvas.logicalSize = logicalPointSize
            canvas.restoreAnnotations(pendingAnnotations)
            canvas.onChange = { [weak self] in self?.refreshAnnotateBar() }
            canvas.onFinish = { [weak self] in self?.setAnnotateMode(false) }
            canvas.onCancel = { [weak self] in self?.setAnnotateMode(false) }
            annotationCanvas = canvas
            addSubview(canvas, positioned: .below, relativeTo: toolbar)
        }
        updateEditorGeometry()
    }

    func updateEditorGeometry() {
        guard let canvas = annotationCanvas, visibleImageRect.width > 0, visibleImageRect.height > 0 else { return }
        let displayed = transform.unrotatedSize(base: baseSize)
        canvas.frame = bounds
        canvas.logicalSize = logicalPointSize
        canvas.displayTransform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: transform.flipHorizontal ? -1 : 1, y: transform.flipVertical ? -1 : 1)
            .rotated(by: -CGFloat(transform.quarterTurns) * .pi / 2)
            .scaledBy(x: displayed.width / visibleImageRect.width, y: displayed.height / visibleImageRect.height)
            .translatedBy(x: -visibleImageRect.midX, y: -visibleImageRect.midY)
        canvas.needsDisplay = true
    }

    private struct ResizeState {
        let edge: PinEdge
        let anchorFraction: CGPoint
        let anchorGlobal: CGPoint
        let startMouse: CGPoint
        let baseSize: CGSize
        let quarterTurnsOdd: Bool
    }

    private enum PinEdge {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var anchorFraction: CGPoint {
            switch self {
            case .left: return CGPoint(x: 1, y: 0.5)
            case .right: return CGPoint(x: 0, y: 0.5)
            case .top: return CGPoint(x: 0.5, y: 0)
            case .bottom: return CGPoint(x: 0.5, y: 1)
            case .topLeft: return CGPoint(x: 1, y: 0)
            case .topRight: return CGPoint(x: 0, y: 0)
            case .bottomLeft: return CGPoint(x: 1, y: 1)
            case .bottomRight: return CGPoint(x: 0, y: 1)
            }
        }

        var isHorizontal: Bool {
            switch self {
            case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .top, .bottom: return false
            }
        }

        var isVertical: Bool {
            switch self {
            case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .left, .right: return false
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(context)
        guard let image, baseSize.width > 0, baseSize.height > 0 else { return }
        let size = transform.unrotatedSize(base: baseSize)
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        // 先镜像再旋转，翻转才是按屏幕轴生效，而不是跟着图一起转。
        context.scaleBy(
            x: transform.flipHorizontal ? -1 : 1,
            y: transform.flipVertical ? -1 : 1
        )
        // AppKit 的 y 轴向上，负角表示顺时针。
        context.rotate(by: -CGFloat(transform.quarterTurns) * .pi / 2)
        image.draw(in: CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        ))
        context.restoreGState()
        drawSelectionRing(context)
        drawCropOverlay(context)
    }

    func setAnnotateMode(_ active: Bool, discardingAnnotations: Bool = false) {
        guard active != isAnnotating else { return }
        configureEditor()
        guard let canvas = annotationCanvas else { return }
        if active {
            beforeAnnotationMode = canvas.checkpoint()
            isAnnotating = true
            canvas.selectTool(.rect)
            pinWindow?.attachAnnotateBar(annotateBar)
            toolbar.isHidden = true
        } else {
            if discardingAnnotations, let beforeAnnotationMode { canvas.restoreCheckpoint(beforeAnnotationMode) }
            else { canvas.finishEditing() }
            canvas.setSelection([])
            canvas.handleIDs = []
            isAnnotating = false
            self.beforeAnnotationMode = nil
            pinWindow?.detachAnnotateBar()
            window?.makeFirstResponder(self)
        }
        refreshAnnotateBar()
        window?.invalidateCursorRects(for: self)
    }

    func restoreAnnotations(_ items: [Annotation]) {
        pendingAnnotations = items
        annotationCanvas?.restoreAnnotations(items)
        beforeAnnotationMode = annotationCanvas?.checkpoint()
        refreshAnnotateBar()
    }

    func clearAnnotations() { restoreAnnotations([]) }
    func deselectAllAnnotations() { annotationCanvas?.setSelection([]) }
    func finishEditing() { annotationCanvas?.finishEditing() }

    func cancelPendingTasks() {
        barcodeTask?.cancel()
        barcodeTask = nil
        sharePicker?.delegate = nil
        sharePicker = nil
    }

    private func refreshAnnotateBar() {
        guard isAnnotating, let canvas = annotationCanvas else { return }
        let bar = annotateBar.toolbar
        if !canvas.selectedIDs.isEmpty { bar.updateSelection(kind: canvas.styleKind, style: canvas.currentStyle, drawingTool: canvas.tool) }
        else if let tool = canvas.tool { bar.select(tool, style: canvas.currentStyle) }
        else { bar.selectMode() }
        bar.updateUndoState(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
    }

    func cycleAnnotationColor() {
        guard let canvas = annotationCanvas else { return }
        var style = canvas.currentStyle
        let index = RGBAColor.palette.firstIndex(of: style.color) ?? -1
        style.color = RGBAColor.palette[(index + 1) % RGBAColor.palette.count]
        canvas.applyStyle(style)
    }

    private func recognize(translate: Bool) {
        guard let pinWindow, let image = pinWindow.flattenedImage() else { return }
        let scale = CGFloat(pinWindow.pasteImage.image.width) / max(1, pinWindow.pasteImage.pointSize.width)
        pinWindow.onRecognize?(image, scale, translate, pinWindow)
    }

    /// 背景铺在图像之下；图像自身的透明区域会露出它。
    private func drawBackground(_ context: CGContext) {
        guard let fill = background.fill else { return }
        context.setFillColor(fill.cgColor)
        context.fill(bounds)
        guard let tile = Self.checkerTile(for: background) else { return }
        context.saveGState()
        // 瓦片是 16px 的整数倍图，最近邻放大才不会把 8pt 格子糊成灰边。
        context.interpolationQuality = .none
        context.draw(tile, in: bounds, byTiling: true)
        context.restoreGState()
    }

    private static func checkerTile(for mode: PinBackground) -> CGImage? {
        if let cached = checkerTiles[mode] { return cached }
        guard let base = mode.fill, let alternate = mode.checkerAlternate else { return nil }
        let cell = Int(PinBackground.checkerCellSize)
        let side = cell * 2
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(alternate.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
        context.fill(CGRect(x: cell, y: cell, width: cell, height: cell))
        guard let image = context.makeImage() else { return nil }
        checkerTiles[mode] = image
        return image
    }

    private func drawSelectionRing(_ context: CGContext) {
        guard isSelected else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 1, dy: 1))
    }

    /// 裁剪模式下压暗保留区之外，并画出选择框与操作提示。
    private func drawCropOverlay(_ context: CGContext) {
        guard isCropping else { return }
        let dim = NSColor.black.withAlphaComponent(0.45).cgColor
        context.setFillColor(dim)
        if let selection = cropSelection, selection.width > 0, selection.height > 0 {
            let outside = [
                CGRect(x: 0, y: 0, width: bounds.width, height: selection.minY),
                CGRect(x: 0, y: selection.maxY, width: bounds.width, height: bounds.height - selection.maxY),
                CGRect(x: 0, y: selection.minY, width: selection.minX, height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: bounds.width - selection.maxX, height: selection.height)
            ]
            for rect in outside where rect.width > 0 && rect.height > 0 {
                context.fill(rect)
            }
            // 白线外再压一圈深色，浅色贴图上也能看清边界。
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.stroke(selection.insetBy(dx: 1.5, dy: 1.5))
        } else {
            context.fill(bounds)
        }
        let hint = (isCropping && cropSelection == nil)
            ? "拖动选择保留区域，Esc 取消"
            : "松开确认，Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: (bounds.width - textSize.width) / 2, y: bounds.height - textSize.height - 12),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if isCropping {
            cropStart = point
            cropSelection = nil
            needsDisplay = true
            return
        }
        if isAnnotating {
            annotationCanvas?.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.shift) {
                pinWindow.toggleThumbnail()
            } else {
                pinWindow.close()
            }
            return
        }
        // Shift 单击只改多选集合，不进入拖动或缩放。
        if event.modifierFlags.contains(.shift) {
            pinWindow.pinController?.toggleSelection(pinID: pinWindow.pinID)
            return
        }
        if let edge = edge(at: point) {
            beginResize(edge, in: pinWindow)
            return
        }
        resizeState = nil
        dragStart = pinWindow.convertPoint(toScreen: event.locationInWindow)
        windowStart = pinWindow.frame.origin
        pinWindow.pinController?.beginDrag(of: pinWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else { return }
        if isCropping {
            guard let cropStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            cropSelection = CGRect(
                x: min(cropStart.x, current.x),
                y: min(cropStart.y, current.y),
                width: abs(current.x - cropStart.x),
                height: abs(current.y - cropStart.y)
            ).intersection(bounds)
            needsDisplay = true
            return
        }
        if isAnnotating {
            annotationCanvas?.mouseDragged(with: event)
            return
        }
        if let resizeState {
            updateResize(resizeState, in: pinWindow, mouse: NSEvent.mouseLocation)
            return
        }
        guard let dragStart, let windowStart else { return }
        let current = pinWindow.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        if pinWindow.pinController?.dragSelection(by: delta) == true { return }
        pinWindow.move(to: CGPoint(
            x: windowStart.x + delta.x,
            y: windowStart.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if isAnnotating {
            annotationCanvas?.mouseUp(with: event)
            return
        }
        if isCropping {
            let selection = cropSelection
            endCropMode()
            guard let selection, selection.width >= 1, selection.height >= 1,
                  let pinWindow = window as? PinWindow else { return }
            pinWindow.applyCrop(viewSelection: selection)
            return
        }
        dragStart = nil
        windowStart = nil
        resizeState = nil
        (window as? PinWindow)?.pinController?.endDrag()
    }

    private func beginCrop() {
        guard !transform.isThumbnail, let pinWindow = window as? PinWindow else { return }
        pinWindow.makeKey()
        isCropping = true
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

    private func endCropMode() {
        isCropping = false
        cropStart = nil
        cropSelection = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isAnnotating {
            if annotationCanvas?.handleRightMouseDown(event) != true { setAnnotateMode(false) }
        } else { super.rightMouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isAnnotating else { return nil }
        guard let pinWindow = window as? PinWindow else { return nil }
        let menu = NSMenu()

        let annotate = actionItem("标注…", #selector(annotateFromMenu))
        annotate.keyEquivalent = "e"
        annotate.keyEquivalentModifierMask = .command
        menu.addItem(annotate)
        menu.addItem(.separator())

        menu.addItem(actionItem("复制图像", #selector(copyImageFromMenu)))
        menu.addItem(actionItem("图像另存为…", #selector(saveImageFromMenu)))
        menu.addItem(.separator())

        let shadow = actionItem("窗口阴影", #selector(toggleShadowFromMenu))
        shadow.state = pinWindow.hasShadow ? .on : .off
        menu.addItem(shadow)
        menu.addItem(.separator())

        let scaleItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        scaleItem.submenu = makeScaleMenu(current: pinWindow.transform.scale)
        menu.addItem(scaleItem)

        let effectsItem = NSMenuItem(title: "图像处理", action: nil, keyEquivalent: "")
        effectsItem.submenu = makeEffectsMenu(pinWindow: pinWindow)
        menu.addItem(effectsItem)

        let crop = actionItem("裁剪", #selector(beginCropFromMenu))
        crop.isEnabled = !pinWindow.transform.isThumbnail
        menu.addItem(crop)
        menu.addItem(.separator())

        menu.addItem(actionItem("粘贴", #selector(pasteFromMenu)))

        if let controller = pinWindow.pinController {
            let move = NSMenuItem(title: "移动到分组", action: nil, keyEquivalent: "")
            move.submenu = makeGroupMenu(controller: controller, pinID: pinWindow.pinID)
            menu.addItem(move)
            if controller.selectedPinCount > 0 {
                menu.addItem(actionItem("选中的贴图加入当前分组", #selector(joinSelectionFromMenu)))
            }
        }
        menu.addItem(.separator())

        menu.addItem(actionItem("关闭", #selector(closeFromMenu)))
        menu.addItem(actionItem("销毁", #selector(destroyFromMenu)))
        menu.addItem(.separator())

        let size = NSMenuItem(
            title: "\(Int(pinWindow.frame.width)) × \(Int(pinWindow.frame.height))",
            action: nil,
            keyEquivalent: ""
        )
        size.isEnabled = false
        menu.addItem(size)
        return menu
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeScaleMenu(current: CGFloat) -> NSMenu {
        let menu = NSMenu()
        for percent in [50, 100, 200] {
            let value = CGFloat(percent) / 100
            let item = actionItem("\(percent)%", #selector(scaleSelected(_:)))
            item.representedObject = value
            item.state = abs(current - value) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("适应屏幕", #selector(fitToScreenFromMenu)))
        return menu
    }

    private func makeEffectsMenu(pinWindow: PinWindow) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem("向左旋转", #selector(rotateLeftFromMenu)))
        menu.addItem(actionItem("向右旋转", #selector(rotateRightFromMenu)))
        menu.addItem(actionItem("水平翻转", #selector(flipHorizontalFromMenu)))
        menu.addItem(actionItem("垂直翻转", #selector(flipVerticalFromMenu)))
        menu.addItem(.separator())
        menu.addItem(effectItem(
            title: "灰度",
            isOn: pinWindow.transform.isGrayscale,
            action: #selector(toggleGrayscaleFromMenu)
        ))
        menu.addItem(effectItem(
            title: "反色",
            isOn: pinWindow.transform.isInverted,
            action: #selector(toggleInvertedFromMenu)
        ))
        menu.addItem(.separator())
        let backgroundItem = NSMenuItem(title: "背景", action: nil, keyEquivalent: "")
        backgroundItem.submenu = makeBackgroundMenu(current: pinWindow.background)
        menu.addItem(backgroundItem)
        return menu
    }

    private func makeGroupMenu(controller: PinController, pinID: Int) -> NSMenu {
        let menu = NSMenu()
        for group in controller.pinGroups {
            let item = actionItem(group.name, #selector(groupSelected(_:)))
            item.representedObject = group.id
            item.state = group.id == controller.activePinGroupID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func makeBackgroundMenu(current: PinBackground) -> NSMenu {
        let menu = NSMenu()
        for mode in PinBackground.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(backgroundSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func backgroundSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PinBackground(rawValue: raw) else { return }
        (window as? PinWindow)?.setBackground(mode)
    }

    @objc private func joinSelectionFromMenu() {
        (window as? PinWindow)?.pinController?.joinSelectionToActiveGroup()
    }

    private func effectItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    @objc private func toggleGrayscaleFromMenu() {
        (window as? PinWindow)?.toggleGrayscale()
    }

    @objc private func toggleInvertedFromMenu() {
        (window as? PinWindow)?.toggleInverted()
    }

    @objc private func beginCropFromMenu() {
        beginCrop()
    }

    @objc private func copyImageFromMenu() {
        guard let pinWindow, let image = pinWindow.flattenedImage() else {
            showOutputMessage("无法合成图像")
            return
        }
        let scale = CGFloat(pinWindow.pasteImage.image.width) / max(1, pinWindow.pasteImage.pointSize.width)
        showOutputMessage(ClipboardService.copyToPasteboard(image, scale: scale) ? "图像已复制" : "复制失败，请重试")
    }

    @objc private func annotateFromMenu() { setAnnotateMode(true) }

    @objc private func saveImageFromMenu() {
        guard let pinWindow, let image = pinWindow.flattenedImage(), let data = ImageOutput.pngData(from: image) else {
            showOutputMessage("无法合成图像")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImageOutput.defaultFileName()
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.showOutputMessage("图像已保存")
            } catch { self?.showOutputMessage("保存失败，\(error.localizedDescription)") }
        }
    }

    private func showOutputMessage(_ message: String) {
        if isAnnotating { annotateBar.toolbar.showMessage(message); return }
        feedbackToken += 1
        let token = feedbackToken
        feedbackLabel.stringValue = message
        let width = min(max(80, feedbackLabel.intrinsicContentSize.width + 18), bounds.width)
        feedbackLabel.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - 26) / 2), width: width, height: 26)
        if feedbackLabel.superview == nil { addSubview(feedbackLabel) }
        feedbackLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.feedbackToken == token else { return }
            self.feedbackLabel.isHidden = true
        }
    }

    private func quickSaveImage() {
        guard let image = pinWindow?.flattenedImage(), let data = ImageOutput.pngData(from: image) else { return }
        let directory = SettingsStore().load().quickSaveDirectory
        let store = directory.map { QuickSaveStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? QuickSaveStore()
        do { _ = try store.write(data); showOutputMessage("图像已保存") }
        catch { showOutputMessage("保存失败，\(error.localizedDescription)") }
    }

    private func scanBarcode() {
        guard let image = pinWindow?.flattenedImage() else { return }
        barcodeTask?.cancel()
        annotateBar.toolbar.showBusy("识别中…")
        barcodeTask = Task { [weak self] in
            let payload = await BarcodeScanner.scanFirstPayloadAsync(in: image)
            guard !Task.isCancelled, let self else { return }
            self.annotateBar.toolbar.hideBusy()
            if let payload, ClipboardService.copyString(payload) { self.showOutputMessage("识别码已复制") }
            else { self.showOutputMessage("未识别到二维码或条形码") }
        }
    }

    private func shareImage() {
        guard let pinWindow, let image = pinWindow.flattenedImage() else { return }
        let scale = CGFloat(pinWindow.pasteImage.image.width) / max(1, pinWindow.pasteImage.pointSize.width)
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: image,
            size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))])
        picker.delegate = self
        sharePicker = picker
        picker.show(relativeTo: annotateBar.toolbar.bounds, of: annotateBar.toolbar, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        DispatchQueue.main.async { [weak self] in
            if self?.sharePicker === sharingServicePicker { self?.sharePicker = nil }
        }
    }

    @objc private func toggleShadowFromMenu() {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.hasShadow.toggle()
    }

    @objc private func scaleSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        (window as? PinWindow)?.setScale(value)
    }

    @objc private func fitToScreenFromMenu() {
        guard let pinWindow = window as? PinWindow else { return }
        pinWindow.setScale(1)
    }

    @objc private func rotateLeftFromMenu() {
        (window as? PinWindow)?.rotate(byQuarterTurns: -1)
    }

    @objc private func rotateRightFromMenu() {
        (window as? PinWindow)?.rotate(byQuarterTurns: 1)
    }

    @objc private func flipHorizontalFromMenu() {
        (window as? PinWindow)?.toggleFlipHorizontal()
    }

    @objc private func flipVerticalFromMenu() {
        (window as? PinWindow)?.toggleFlipVertical()
    }

    @objc private func pasteFromMenu() {
        (window as? PinWindow)?.pinController?.pinFromPasteboard()
    }

    @objc private func groupSelected(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? Int,
              let pinWindow = window as? PinWindow else { return }
        pinWindow.pinController?.assign(pinID: pinWindow.pinID, toGroup: groupID)
    }

    @objc private func closeFromMenu() {
        (window as? PinWindow)?.close()
    }

    @objc private func destroyFromMenu() {
        (window as? PinWindow)?.destroy()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow, event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        pinWindow.resetTransform()
    }

    override func scrollWheel(with event: NSEvent) {
        if isAnnotating, annotationCanvas?.handleScrollWheel(event) == true { return }
        guard let pinWindow = window as? PinWindow else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.control) {
            pinWindow.adjustOpacity(by: delta * 0.01)
        } else {
            pinWindow.setScale(pinWindow.transform.scale * exp(delta * 0.01))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let pinWindow = window as? PinWindow else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if flags == .command, key == "e" {
            setAnnotateMode(!isAnnotating)
            return
        }
        if isAnnotating {
            if annotationCanvas?.handleKeyDown(event) == true { return }
            if flags.contains(.command), key == "c" { copyImageFromMenu(); return }
            if flags.contains(.command), key == "s" { saveImageFromMenu(); return }
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            if isCropping { endCropMode() }
            else if flags.contains(.shift) { pinWindow.destroy() }
            else if pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) != true { pinWindow.close() }
            return
        }
        if flags.contains(.command) {
            if key == "z", !flags.contains(.shift), pinWindow.undoLastCrop() { return }
            if key == "c" { copyImageFromMenu(); return }
            if key == "s" { saveImageFromMenu(); return }
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control) {
            // Ctrl+W 的 characters 可能是控制字符，keyCode 更可靠。
            if event.keyCode == 13 || key == "w" {
                pinWindow.close()
                return
            }
            switch key {
            case "+", "=":
                pinWindow.adjustOpacity(by: 0.1)
            case "-", "_":
                pinWindow.adjustOpacity(by: -0.1)
            default:
                break
            }
            return
        }
        switch key {
        case "1":
            pinWindow.rotate(byQuarterTurns: -1)
        case "2":
            pinWindow.rotate(byQuarterTurns: 1)
        case "3":
            pinWindow.toggleFlipHorizontal()
        case "4":
            pinWindow.toggleFlipVertical()
        case "+", "=":
            pinWindow.adjustScale(by: 0.1)
        case "-", "_":
            pinWindow.adjustScale(by: -0.1)
        case "g":
            pinWindow.toggleGrayscale()
        case "i":
            pinWindow.toggleInverted()
        case "b":
            pinWindow.cycleBackground()
        case "c":
            if annotationTool == nil { beginCrop() }
        case ",":
            pinWindow.stepHistory(by: -1)
        case ".":
            pinWindow.stepHistory(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isAnnotating {
            if annotationCanvas?.hasPendingPolyline == true { annotationCanvas?.cancelEditing() }
            else if !selectedAnnotationIDs.isEmpty { deselectAllAnnotations() }
            else { setAnnotateMode(false) }
            return
        }
        if isCropping {
            endCropMode()
            return
        }
        if let pinWindow = window as? PinWindow,
           pinWindow.pinController?.closeSelection(triggeredBy: pinWindow) == true {
            return
        }
        window?.close()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isCropping || isAnnotating {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        guard !transform.isThumbnail else { return }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: hot), cursor: .resizeUpDown)
        addCursorRect(
            NSRect(x: 0, y: bounds.height - hot, width: bounds.width, height: hot),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: 0, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: bounds.width - hot, y: hot, width: hot, height: max(0, bounds.height - hot * 2)),
            cursor: .resizeLeftRight
        )
        // AppKit 没有公开的对角缩放光标，四角用十字。
        addCursorRect(NSRect(x: 0, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: bounds.width - hot, y: 0, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: bounds.height - hot, width: hot, height: hot), cursor: .crosshair)
        addCursorRect(
            NSRect(x: bounds.width - hot, y: bounds.height - hot, width: hot, height: hot),
            cursor: .crosshair
        )
    }

    private func edge(at point: CGPoint) -> PinEdge? {
        guard !transform.isThumbnail else { return nil }
        let bounds = self.bounds
        let hot = min(hotZone, min(bounds.width, bounds.height) / 2)
        guard hot > 0 else { return nil }
        let nearLeft = point.x <= hot
        let nearRight = point.x >= bounds.maxX - hot
        let nearBottom = point.y <= hot
        let nearTop = point.y >= bounds.maxY - hot
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        return nil
    }

    private func beginResize(_ edge: PinEdge, in pinWindow: PinWindow) {
        let frame = pinWindow.frame
        let fraction = edge.anchorFraction
        resizeState = ResizeState(
            edge: edge,
            anchorFraction: fraction,
            anchorGlobal: CGPoint(
                x: frame.minX + fraction.x * frame.width,
                y: frame.minY + fraction.y * frame.height
            ),
            startMouse: NSEvent.mouseLocation,
            baseSize: pinWindow.basePointSize,
            quarterTurnsOdd: pinWindow.transform.quarterTurns % 2 == 1
        )
        dragStart = nil
        windowStart = nil
    }

    private func updateResize(_ state: ResizeState, in pinWindow: PinWindow, mouse: CGPoint) {
        let dx = abs(mouse.x - state.anchorGlobal.x)
        let dy = abs(mouse.y - state.anchorGlobal.y)
        // 窗口宽高相对未旋转基准轴的对应关系随四分之一圈互换。
        let widthBase = state.quarterTurnsOdd ? state.baseSize.height : state.baseSize.width
        let heightBase = state.quarterTurnsOdd ? state.baseSize.width : state.baseSize.height
        guard widthBase > 0, heightBase > 0 else { return }
        // 角上两个轴都参与，用位移更大的轴定尺度，否则纯纵向拖动会被没动过的横向距离锁死。
        let useHorizontal: Bool
        if state.edge.isHorizontal && state.edge.isVertical {
            let moveX = abs(mouse.x - state.startMouse.x)
            let moveY = abs(mouse.y - state.startMouse.y)
            useHorizontal = moveX >= moveY
        } else {
            useHorizontal = state.edge.isHorizontal
        }
        let rawScale = useHorizontal ? dx / widthBase : dy / heightBase
        pinWindow.setScale(rawScale)
        let frame = pinWindow.frame
        pinWindow.move(to: CGPoint(
            x: state.anchorGlobal.x - state.anchorFraction.x * frame.width,
            y: state.anchorGlobal.y - state.anchorFraction.y * frame.height
        ))
    }
}
