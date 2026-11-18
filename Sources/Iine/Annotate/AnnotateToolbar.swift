import AppKit
import QuartzCore
import UniformTypeIdentifiers
import IineCore

/// 截图、贴图和长图共用的工具与属性面板。
@MainActor
final class AnnotateToolbar: NSView {
    enum Context { case capture, imageEditor, pin }

    var onAspectRatioChange: ((SelectionAspectRatio) -> Void)?
    var onTranslationTargetChange: ((TranslationTarget) -> Void)?
    var onFinish: (() -> Void)?
    var onSizeChange: (() -> Void)?
    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard maximumWidth != oldValue, selectButton != nil else { return }
            layoutButtons()
        }
    }
    private var compactActions: Bool { maximumWidth < 748 }
    var onSelectTool: ((ShapeKind) -> Void)?
    var onSelectMode: (() -> Void)?
    var onStyleChange: ((Style) -> Void)?
    var onStylePropertyChange: ((Style, AnnotationStyleAttribute) -> Void)?
    var onCopy: (() -> Void)?
    var onExtractText: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onCycleTranslationTarget: (() -> Void)?
    var onScanBarcode: (() -> Void)?
    var onSave: (() -> Void)?
    /// ⇧ + 保存按钮：写快捷保存目录。
    var onQuickSave: (() -> Void)?
    var onShare: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 工具条「贴到屏幕」按钮，与中键走同一条路径。
    var onPin: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onScrollingCapture: (() -> Void)?

    private enum Metrics {
        static let buttonSide: CGFloat = 34
        static let spacing: CGFloat = 2
        static let padding: CGFloat = 7
        static let dropdownWidth: CGFloat = 14
        static let height: CGFloat = buttonSide + padding * 2
        static let styleHeight: CGFloat = 38
    }

    private struct ToolGroup {
        let title: String
        let kinds: [ShapeKind]
    }

    private static let groups = [
        ToolGroup(title: "形状", kinds: [.rect, .roundedRect, .ellipse]),
        ToolGroup(title: "线条", kinds: [.arrow, .line, .polyline]),
        ToolGroup(title: "画笔", kinds: [.brush, .marker]),
        ToolGroup(title: "打码", kinds: [.mosaicRect, .mosaic, .blur]),
    ]
    private let context: Context
    private var groupTools: [ShapeKind] = AnnotateToolbar.groups.map { $0.kinds[0] }
    private var groupDropdowns: [HoverButton] = []
    private var layoutViews: [NSView] = []
    private var separators: [NSView] = []
    private var copyButton: HoverButton!
    private var moreButton: HoverButton!
    private var finishButton: HoverButton!
    private var cancelButton: HoverButton!
    private var aspectRatio: SelectionAspectRatio
    private var translationTarget: TranslationTarget = .auto
    private var selectedObjectKind: ShapeKind?
    private var hasObjectSelection: Bool { selectedObjectKind != nil }
    private var styleKind: ShapeKind { selectedObjectKind ?? selectedKind }
    private var stylePanelRect = NSRect.zero
    private let styleName = NSTextField(labelWithString: "")

    private(set) var selectedKind: ShapeKind = .rect
    private(set) var isSelectMode = false
    private(set) var currentStyle: Style
    private let paletteStore: PaletteStore
    private var paletteModel: PaletteModel
    /// 暴露给验收 harness 程序化点击。
    private(set) var selectButton: HoverButton!
    private(set) var toolButtons: [ShapeKind: HoverButton] = [:]
    private(set) var colorButton: HoverButton!
    private(set) var penButton: HoverButton!
    private(set) var lineStyleButton: HoverButton!
    private(set) var backgroundButton: HoverButton!
    private(set) var arrowHeadsButton: HoverButton!
    private(set) var textButton: HoverButton!
    private(set) var translateButton: HoverButton!
    private(set) var translateTargetButton: HoverButton!
    private(set) var barcodeButton: HoverButton!
    private(set) var saveButton: HoverButton!
    private(set) var pinButton: HoverButton!
    private(set) var shareButton: HoverButton!
    private(set) var undoButton: HoverButton!
    private(set) var redoButton: HoverButton!
    private(set) var scrollingButton: HoverButton!
    private(set) var ratioLabel: NSTextField!
    private(set) var colorPopover: NSPopover?
    private(set) var penPopover: NSPopover?
    private(set) var choicePopover: NSPopover?
    /// 识别结果提示，盖在按钮上，1.6 秒后自动隐藏。
    private lazy var messageLabel: PassthroughLabel = {
        let label = PassthroughLabel(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = AppPalette.color(.text)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(srgbRed: 0.91, green: 0.94, blue: 0.96, alpha: 1).cgColor
        label.layer?.cornerRadius = 12
        label.isHidden = true
        return label
    }()
    /// showBusy 的转圈指示，与提示文字同一行。
    private lazy var busySpinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        indicator.appearance = NSAppearance(named: .aqua)
        return indicator
    }()
    private var messageToken = 0

    /// 提示条只是显示层，不吃点击，避免覆盖期间下面的按钮点不动。
    private final class PassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(
        initialKind: ShapeKind,
        initialStyle: Style,
        initialAspectRatio: SelectionAspectRatio = .free,
        paletteStore: PaletteStore = PaletteStore(),
        context: Context = .capture
    ) {
        selectedKind = initialKind
        currentStyle = initialStyle
        aspectRatio = initialAspectRatio
        self.context = context
        self.paletteStore = paletteStore
        paletteModel = paletteStore.load()
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: Metrics.height))
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 16
        buildButtons()
        addSubview(messageLabel)
        refreshStyleButtons()
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 吞掉容器空白区的点击，避免落到覆盖视图上开始新拖拽。
    override func mouseDown(with event: NSEvent) {}

    /// 选中形状按钮并同步该工具的记忆样式。快捷键、Tab 与点击共用，幂等。
    func select(_ kind: ShapeKind, style: Style) {
        selectedKind = kind
        currentStyle = style
        isSelectMode = false
        selectedObjectKind = nil
        if let group = Self.groups.firstIndex(where: { $0.kinds.contains(kind) }) {
            groupTools[group] = kind
        }
        refreshSelection()
        refreshStyleButtons()
    }

    /// 外部（滚轮 / 数字键）改了样式后同步按钮显示，不再回调 onStyleChange 避免回环。
    func updateStyle(_ style: Style) {
        currentStyle = style
        refreshStyleButtons()
    }

    /// 选区比例变了只更新标签；拖拽数学由 OverlayView 持有设置值自行计算。
    func updateAspectRatio(_ ratio: SelectionAspectRatio) {
        aspectRatio = ratio
        ratioLabel.stringValue = ratio.title
    }

    /// 撤销栈变化后同步按钮可用状态，无历史时按钮置灰。
    func updateUndoState(canUndo: Bool, canRedo: Bool) {
        if undoButton.isEnabled != canUndo { undoButton.isEnabled = canUndo }
        if redoButton.isEnabled != canRedo { redoButton.isEnabled = canRedo }
    }

    /// 切到选择工具。形状按钮全部取消高亮。
    func selectMode() {
        guard !isSelectMode || selectedObjectKind != nil else { return }
        isSelectMode = true
        selectedObjectKind = nil
        refreshSelection()
        refreshStyleButtons()
    }

    func updateSelection(kind: ShapeKind, style: Style, drawingTool: ShapeKind? = nil) {
        guard selectedObjectKind != kind || currentStyle != style
                || isSelectMode != (drawingTool == nil)
                || (drawingTool != nil && selectedKind != drawingTool) else { return }
        selectedObjectKind = kind
        if let drawingTool { selectedKind = drawingTool }
        currentStyle = style
        isSelectMode = drawingTool == nil
        refreshSelection()
        refreshStyleButtons()
    }

    // MARK: - 布局

    private func buildButtons() {
        selectButton = makeHoverButton(glyph: .select, title: "选择 · V", action: #selector(selectModeTapped))
        for (index, entry) in ShapeCatalog.p2.enumerated() {
            let button = makeHoverButton(
                glyph: ToolbarGlyph.shape(entry.kind),
                title: "\(entry.title) · \(entry.shortcut)",
                action: #selector(toolTapped(_:))
            )
            button.tag = index
            toolButtons[entry.kind] = button
        }
        for (index, group) in Self.groups.enumerated() {
            let button = makeHoverButton(glyph: .chevronDown, title: "展开\(group.title)", action: #selector(groupTapped(_:)))
            button.tag = index
            groupDropdowns.append(button)
        }
        colorButton = makeHoverButton(glyph: nil, title: "颜色与透明度", action: #selector(colorTapped))
        colorButton.onScroll = { [weak self] delta in self?.stepAlpha(delta) }
        penButton = makeHoverButton(glyph: nil, title: "笔宽 · 1 减小 / 2 增大", action: #selector(penTapped))
        lineStyleButton = makeHoverButton(glyph: nil, title: "线型", action: #selector(lineStyleTapped))
        backgroundButton = makeHoverButton(glyph: nil, title: "文字背景", action: #selector(backgroundTapped))
        arrowHeadsButton = makeHoverButton(glyph: nil, title: "箭头端点", action: #selector(arrowHeadsTapped))
        undoButton = makeHoverButton(glyph: .undo, title: "撤销 · ⌘Z", action: #selector(undoTapped))
        redoButton = makeHoverButton(glyph: .redo, title: "重做 · ⌘⇧Z", action: #selector(redoTapped))
        textButton = makeHoverButton(glyph: .extractText, title: "提取文字", action: #selector(extractTextTapped))
        translateButton = makeHoverButton(glyph: .translate, title: "翻译", action: #selector(translateTapped))
        translateTargetButton = makeHoverButton(glyph: .chevronDown, title: "翻译方向", action: #selector(translateTargetTapped))
        scrollingButton = makeHoverButton(glyph: .scroll, title: "滚动截图", action: #selector(scrollingCaptureTapped))
        barcodeButton = makeHoverButton(glyph: .barcode, title: "识别码", action: #selector(scanBarcodeTapped))
        shareButton = makeHoverButton(glyph: .share, title: "分享", action: #selector(shareTapped))
        moreButton = makeHoverButton(glyph: .more, title: "更多工具与操作", action: #selector(moreTapped))
        pinButton = makeHoverButton(glyph: .pin, title: "贴到屏幕", action: #selector(pinTapped))
        saveButton = makeHoverButton(glyph: .save, title: "保存 · ⌘S / ⇧ 点击快捷保存", action: #selector(saveTapped))
        copyButton = makeHoverButton(glyph: .copy, title: "复制 · Enter", action: #selector(copyTapped))
        finishButton = makeHoverButton(glyph: .check, title: "完成标注 · Enter", action: #selector(finishTapped))
        cancelButton = makeHoverButton(glyph: .close, title: context == .capture ? "取消 · Esc" : "关闭编辑 · Esc", action: #selector(cancelTapped))
        ratioLabel = NSTextField(labelWithString: aspectRatio.title)
        ratioLabel.isHidden = true
        addSubview(ratioLabel)
        styleName.font = .systemFont(ofSize: 11, weight: .medium)
        styleName.textColor = AppPalette.color(.secondaryText)
        addSubview(styleName)
        if let group = Self.groups.firstIndex(where: { $0.kinds.contains(selectedKind) }) {
            groupTools[group] = selectedKind
        }
        updateUndoState(canUndo: false, canRedo: false)
    }

    private func layoutButtons() {
        for view in layoutViews { view.isHidden = true }
        for separator in separators { separator.removeFromSuperview() }
        separators.removeAll()
        let showsStyle = (!isSelectMode || hasObjectSelection) && styleKind != .eraser
        let height = Metrics.height + (showsStyle ? Metrics.styleHeight : 0)
        let y = height - Metrics.padding - Metrics.buttonSide
        var x = Metrics.padding
        func place(_ button: NSButton, width: CGFloat = Metrics.buttonSide) {
            button.frame = NSRect(x: x, y: y, width: width, height: Metrics.buttonSide)
            button.isHidden = false
            x += width + Metrics.spacing
        }
        func separator() {
            let line = NSView(frame: NSRect(x: x + 4, y: y + 9, width: 1, height: 16))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor(white: 0, alpha: 0.10).cgColor
            addSubview(line)
            separators.append(line)
            x += 11
        }
        place(selectButton)
        separator()
        for index in Self.groups.indices {
            if let button = toolButtons[groupTools[index]] { place(button) }
            place(groupDropdowns[index], width: Metrics.dropdownWidth)
        }
        if let text = toolButtons[.text] { place(text) }
        if let serial = toolButtons[.serial] { place(serial) }
        separator()
        place(undoButton)
        place(redoButton)
        separator()
        if !compactActions {
            place(textButton)
            place(translateButton)
            place(translateTargetButton, width: Metrics.dropdownWidth)
            if context == .capture { place(scrollingButton) }
        }
        place(moreButton)
        separator()
        if !compactActions {
            if context != .pin { place(pinButton) }
            place(saveButton)
        }
        place(copyButton)
        if context != .capture { place(finishButton) }
        place(cancelButton)
        let width = x - Metrics.spacing + Metrics.padding
        stylePanelRect = .zero
        styleName.isHidden = !showsStyle
        if showsStyle {
            styleName.stringValue = ShapeCatalog.entry(for: styleKind)?.title ?? "样式"
            styleName.sizeToFit()
            styleName.frame.origin = NSPoint(x: 14, y: 11)
            var styleX = max(62, styleName.frame.maxX + 12)
            var controls: [HoverButton] = []
            if styleKind != .eraser {
                if ![ShapeKind.mosaic, .mosaicRect, .blur].contains(styleKind) {
                    controls.append(colorButton)
                }
                controls.append(penButton)
                if styleKind.supportsLineStyle { controls.append(lineStyleButton) }
                if styleKind == .text { controls.append(backgroundButton) }
                if styleKind == .arrow { controls.append(arrowHeadsButton) }
            }
            for button in controls {
                button.frame = NSRect(x: styleX, y: 3, width: Metrics.buttonSide, height: Metrics.buttonSide)
                button.isHidden = false
                styleX += Metrics.buttonSide + Metrics.spacing
            }
            stylePanelRect = NSRect(x: 0, y: 0, width: styleX + Metrics.padding, height: Metrics.styleHeight - 2)
        }
        needsDisplay = true
        let newSize = NSSize(width: width, height: height)
        guard frame.size != newSize else { return }
        setFrameSize(newSize)
        invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let mainRect = NSRect(x: 0, y: bounds.height - Metrics.height, width: bounds.width, height: Metrics.height)
        let path = NSBezierPath(roundedRect: mainRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        if !stylePanelRect.isEmpty {
            path.append(NSBezierPath(roundedRect: stylePanelRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14))
        }
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let mainRect = NSRect(x: 0, y: bounds.height - Metrics.height, width: bounds.width, height: Metrics.height)
        guard mainRect.contains(local) || stylePanelRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override var intrinsicContentSize: NSSize { frame.size }

    private func makeHoverButton(glyph: ToolbarGlyph?, title: String, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.isBordered = false
        button.title = ""
        button.refusesFirstResponder = true
        button.appearance = NSAppearance(named: .aqua)
        button.contentTintColor = AppPalette.color(.text)
        button.imageScaling = .scaleNone
        if let glyph { button.image = ToolbarGlyph.image(glyph) }
        button.hoverTitle = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        addSubview(button)
        layoutViews.append(button)
        return button
    }

    /// 实心圆点图标，颜色/笔尖按钮与弹层色块共用。画法收在图标库里，贴图底栏也要用。
    static func dotImage(diameter: CGFloat, color: NSColor, ringed: Bool = false) -> NSImage {
        ToolbarGlyph.colorDot(color, diameter: diameter, ringed: ringed)
    }

    /// 颜色按钮上滚轮调透明度。档位从 100% 递减排列，向上滚往更不透明走。
    private func stepAlpha(_ deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        let presets = ColorPaletteView.alphaPresets
        let current = currentStyle.color.a
        let nearest = presets.enumerated().min {
            abs($0.element - current) < abs($1.element - current)
        }?.offset ?? 0
        let next = min(max(nearest + (deltaY > 0 ? -1 : 1), 0), presets.count - 1)
        guard presets[next] != current else { return }
        currentStyle.color.a = presets[next]
        publishStyle(.opacity)
    }

    /// 当前工具的适用属性与画布保持一致。
    private func refreshStyleButtons() {
        colorButton.image = Self.dotImage(
            diameter: 14,
            color: Self.nsColor(currentStyle.color),
            ringed: true
        )
        penButton.image = ToolbarGlyph.penWidth(currentStyle.pen)
        lineStyleButton.image = ToolbarGlyph.lineStyle(currentStyle.lineStyle)
        backgroundButton.image = ToolbarGlyph.background(
            Self.swatch(currentStyle.background),
            tint: Self.nsColor(currentStyle.color)
        )
        arrowHeadsButton.image = ToolbarGlyph.arrowHeads(currentStyle.arrowHeads)
        lineStyleButton.isEnabled = styleKind.supportsLineStyle
        backgroundButton.isEnabled = styleKind == .text
        arrowHeadsButton.isEnabled = styleKind == .arrow
        let penTitle: String
        switch styleKind {
        case .text: penTitle = "字号 \(Int(currentStyle.pen.textFontSize))"
        case .mosaic, .mosaicRect, .blur: penTitle = "强度 \(currentStyle.pen.rawValue)"
        case .serial: penTitle = "序号大小 \(currentStyle.pen.rawValue)"
        default: penTitle = "笔宽 \(Int(currentStyle.pen.lineWidth)) · 1 减小 / 2 增大"
        }
        penButton.hoverTitle = penTitle
        penButton.setAccessibilityLabel(penTitle)
        layoutButtons()
    }

    /// 背景档位 → 图标状态。
    private static func swatch(_ background: RGBAColor?) -> ToolbarGlyph.BackgroundSwatch {
        switch TextBackground.of(background) {
        case .none: return .none
        case .white: return .white
        case .black: return .black
        case .text: return .tint
        }
    }

    /// 背景选项由样式反推，不另外保存选中状态。
    private enum TextBackground: CaseIterable {
        case none, white, black, text

        static let whiteColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.85)
        static let blackColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.70)

        /// 当前样式落在哪一档。非白非黑的自定义背景按文字色档处理。
        static func of(_ background: RGBAColor?) -> TextBackground {
            guard let background else { return .none }
            if background == whiteColor { return .white }
            if background == blackColor { return .black }
            return .text
        }

        func color(textColor: RGBAColor) -> RGBAColor? {
            switch self {
            case .none: return nil
            case .white: return Self.whiteColor
            case .black: return Self.blackColor
            case .text:
                var tint = textColor
                tint.a = 0.40
                return tint
            }
        }
    }

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    private func refreshSelection() {
        for (kind, button) in toolButtons {
            button.isSelected = !isSelectMode && kind == selectedKind
        }
        selectButton.isSelected = isSelectMode
        let overflowSelected = !isSelectMode && [.magnify, .eraser].contains(selectedKind)
        moreButton.isSelected = overflowSelected
        moreButton.image = ToolbarGlyph.image(overflowSelected ? ToolbarGlyph.shape(selectedKind) : .more)
    }

    /// 识别结果在工具条上短暂提示。后一次提示会让前一次的隐藏计时失效。
    func showMessage(_ text: String) {
        guard !text.isEmpty else { return }
        messageLabel.stringValue = text
        let height: CGFloat = 24
        let fitting = messageLabel.attributedStringValue.size().width
        let width = min(bounds.width - Metrics.padding * 2, ceil(fitting) + 24)
        messageLabel.frame = NSRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - Metrics.height + (Metrics.height - height) / 2,
            width: width,
            height: height
        )
        messageLabel.isHidden = false
        messageToken += 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.messageLabel.isHidden = true
        }
    }

    /// 常驻忙碌提示，带转圈指示，直到 hideBusy 才消失。翻译这类网络等待用它。
    func showBusy(_ text: String) {
        messageLabel.stringValue = text
        let height: CGFloat = 24
        let spinnerSide: CGFloat = 14
        let textWidth = ceil(messageLabel.attributedStringValue.size().width)
        let width = min(
            bounds.width - Metrics.padding * 2,
            textWidth + spinnerSide + 40
        )
        let box = NSRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - Metrics.height + (Metrics.height - height) / 2,
            width: width,
            height: height
        )
        busySpinner.frame = NSRect(
            x: box.minX + 12,
            y: box.minY + (height - spinnerSide) / 2,
            width: spinnerSide,
            height: spinnerSide
        )
        messageLabel.frame = NSRect(
            x: busySpinner.frame.maxX + 8,
            y: box.minY,
            width: textWidth + 8,
            height: height
        )
        if busySpinner.superview == nil {
            addSubview(busySpinner)
        }
        busySpinner.isHidden = false
        busySpinner.startAnimation(nil)
        messageLabel.isHidden = false
        // 让 showMessage 的自动隐藏失效，避免等待中提示先消失。
        messageToken += 1
    }

    func hideBusy() {
        busySpinner.stopAnimation(nil)
        busySpinner.isHidden = true
        messageLabel.isHidden = true
        messageToken += 1
    }

    // MARK: - 弹层

    @objc private func colorTapped() {
        // transient 弹层被点外部关闭后引用仍在，按 isShown 判断而不是非 nil
        if colorPopover?.isShown == true {
            colorPopover?.performClose(nil)
            return
        }
        dismissPopovers()
        let palette = ColorPaletteView(model: paletteModel, selected: currentStyle.color)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        palette.onPick = { [weak self, weak popover] color in
            guard let self else { return }
            // 内置色不带 alpha，换色时沿用当前透明度。
            var picked = color
            picked.a = self.currentStyle.color.a
            self.applyPickedColor(picked)
            popover?.performClose(nil)
        }
        palette.onPickCustom = { [weak self, weak popover] color in
            guard let self else { return }
            // 自定义色自带 alpha，选它就把透明度一起带过来。
            self.applyPickedColor(color)
            popover?.performClose(nil)
        }
        palette.onAddCustom = { [weak self] color in
            guard let self else { return }
            // 面板还在开着，继续调色时要一直跟随，不关弹层。
            self.applyPickedColor(color)
        }
        palette.onPickAlpha = { [weak self] alpha in
            guard let self else { return }
            self.currentStyle.color.a = alpha
            self.publishStyle(.opacity)
        }
        palette.onPaletteChange = { [weak self] model in
            guard let self else { return }
            self.paletteModel = model
            self.paletteStore.save(model)
        }
        let controller = NSViewController()
        controller.view = palette
        palette.onSizeChange = { [weak controller] size in
            controller?.preferredContentSize = size
        }
        popover.contentViewController = controller
        colorPopover = popover
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .minY)
    }

    private func applyPickedColor(_ color: RGBAColor) {
        currentStyle.color = color
        publishStyle(.color)
    }

    @objc private func penTapped() {
        if penPopover?.isShown == true {
            penPopover?.performClose(nil)
            return
        }
        dismissPopovers()
        let sizes = PenSizeView(selected: currentStyle.pen, kind: selectedKind)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sizes.onPick = { [weak self, weak popover] pen in
            guard let self else { return }
            self.currentStyle.pen = pen
            self.publishStyle(.pen)
            popover?.performClose(nil)
        }
        let controller = NSViewController()
        controller.view = sizes
        popover.contentViewController = controller
        penPopover = popover
        popover.show(relativeTo: penButton.bounds, of: penButton, preferredEdge: .minY)
    }

    @objc private func groupTapped(_ sender: NSButton) {
        let index = sender.tag
        let items = Self.groups[index].kinds.compactMap { kind -> ToolbarChoiceView.Item? in
            guard let entry = ShapeCatalog.entry(for: kind) else { return nil }
            return ToolbarChoiceView.Item(
                title: entry.title,
                detail: entry.shortcut,
                image: ToolbarGlyph.image(ToolbarGlyph.shape(kind)),
                selected: groupTools[index] == kind
            ) { [weak self] in self?.onSelectTool?(kind) }
        }
        showChoices(items, from: sender)
    }

    @objc private func lineStyleTapped() {
        let titles = ["实线", "虚线", "点线"]
        showChoices(LineStyle.allCases.enumerated().map { index, style in
            ToolbarChoiceView.Item(
                title: titles[index], image: ToolbarGlyph.lineStyle(style), selected: currentStyle.lineStyle == style
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.lineStyle = style
                self.publishStyle(.lineStyle)
            }
        }, from: lineStyleButton)
    }

    @objc private func backgroundTapped() {
        let titles = ["无背景", "白色", "黑色", "与文字同色"]
        showChoices(TextBackground.allCases.enumerated().map { index, background in
            ToolbarChoiceView.Item(
                title: titles[index],
                image: ToolbarGlyph.background(Self.swatch(background.color(textColor: currentStyle.color)), tint: Self.nsColor(currentStyle.color)),
                selected: TextBackground.of(currentStyle.background) == background
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.background = background.color(textColor: self.currentStyle.color)
                self.publishStyle(.background)
            }
        }, from: backgroundButton)
    }

    @objc private func arrowHeadsTapped() {
        let titles = ["单向箭头", "双向箭头", "反向箭头"]
        showChoices(ArrowHeads.allCases.enumerated().map { index, heads in
            ToolbarChoiceView.Item(
                title: titles[index], image: ToolbarGlyph.arrowHeads(heads), selected: currentStyle.arrowHeads == heads
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.arrowHeads = heads
                self.publishStyle(.arrowHeads)
            }
        }, from: arrowHeadsButton)
    }

    @objc private func moreTapped() {
        var items: [ToolbarChoiceView.Item] = [ShapeKind.magnify, .eraser].compactMap { kind in
            guard let entry = ShapeCatalog.entry(for: kind) else { return nil }
            return ToolbarChoiceView.Item(
                title: entry.title, detail: entry.shortcut,
                image: ToolbarGlyph.image(ToolbarGlyph.shape(kind)),
                selected: !isSelectMode && selectedKind == kind
            ) { [weak self] in self?.onSelectTool?(kind) }
        }
        if compactActions {
            items.append(ToolbarChoiceView.Item(title: "提取文字", image: ToolbarGlyph.image(.extractText)) { [weak self] in self?.onExtractText?() })
            items.append(ToolbarChoiceView.Item(title: "翻译", image: ToolbarGlyph.image(.translate)) { [weak self] in self?.onTranslate?() })
            items.append(ToolbarChoiceView.Item(title: "翻译方向", detail: translationTarget.title + " ›") { [weak self] in self?.showTranslationTargets(from: self?.moreButton) })
            if context == .capture {
                items.append(ToolbarChoiceView.Item(title: "滚动截图", image: ToolbarGlyph.image(.scroll)) { [weak self] in self?.onScrollingCapture?() })
            }
            if context != .pin {
                items.append(ToolbarChoiceView.Item(title: "贴到屏幕", image: ToolbarGlyph.image(.pin)) { [weak self] in self?.onPin?() })
            }
            items.append(ToolbarChoiceView.Item(title: "保存", detail: "⌘S", image: ToolbarGlyph.image(.save)) { [weak self] in self?.onSave?() })
        }
        if onScanBarcode != nil {
            items.append(ToolbarChoiceView.Item(title: "识别二维码 / 条形码", image: ToolbarGlyph.image(.barcode)) { [weak self] in
                self?.onScanBarcode?()
            })
        }
        if context == .capture {
            items.append(ToolbarChoiceView.Item(title: "选区比例", detail: aspectRatio.title + " ›", image: ToolbarGlyph.image(.rect)) { [weak self] in
                self?.showAspectRatios()
            })
        }
        if onShare != nil {
            items.append(ToolbarChoiceView.Item(title: "分享", image: ToolbarGlyph.image(.share)) { [weak self] in self?.onShare?() })
        }
        showChoices(items, from: moreButton)
    }

    private func showAspectRatios() {
        showChoices(SelectionAspectRatio.allCases.map { ratio in
            ToolbarChoiceView.Item(title: ratio.title, selected: aspectRatio == ratio) { [weak self] in
                self?.updateAspectRatio(ratio)
                self?.onAspectRatioChange?(ratio)
            }
        }, from: moreButton)
    }

    private func publishStyle(_ attribute: AnnotationStyleAttribute) {
        refreshStyleButtons()
        if let onStylePropertyChange {
            onStylePropertyChange(currentStyle, attribute)
        } else {
            onStyleChange?(currentStyle)
        }
    }

    private func showChoices(_ items: [ToolbarChoiceView.Item], from view: NSView) {
        dismissPopovers()
        let choices = ToolbarChoiceView(items: items)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let controller = NSViewController()
        controller.view = choices
        popover.contentViewController = controller
        choices.onPick = { [weak popover] action in
            popover?.performClose(nil)
            action()
        }
        choices.onCancel = { [weak popover] in popover?.performClose(nil) }
        choicePopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        choices.window?.makeFirstResponder(choices)
    }

    private func dismissPopovers() {
        colorPopover?.performClose(nil)
        penPopover?.performClose(nil)
        choicePopover?.performClose(nil)
    }

    // MARK: - 动作

    @objc private func selectModeTapped() {
        selectMode()
        onSelectMode?()
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let kind = ShapeCatalog.p2[sender.tag].kind
        // 样式回读由 OverlayView 统一做，这里只上抛选中的工具。
        onSelectTool?(kind)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func extractTextTapped() { onExtractText?() }
    @objc private func translateTapped() { onTranslate?() }
    @objc private func translateTargetTapped() { showTranslationTargets(from: translateTargetButton) }

    private func showTranslationTargets(from anchor: NSView?) {
        guard let anchor else { return }
        showChoices(TranslationTarget.allCases.map { target in
            ToolbarChoiceView.Item(title: target == .auto ? "自动 · 中英互译" : target.title, selected: target == translationTarget) { [weak self] in
                guard let self else { return }
                self.updateTranslationTarget(target)
                self.onTranslationTargetChange?(target)
            }
        }, from: anchor)
    }

    /// 菜单选中项与实际目标语言使用同一个值。
    func updateTranslationTarget(_ target: TranslationTarget) {
        translationTarget = target
        translateTargetButton.hoverTitle = "翻译方向 · \(target.title)"
        translateTargetButton.setAccessibilityLabel(translateTargetButton.hoverTitle)
    }
    @objc private func scanBarcodeTapped() { onScanBarcode?() }
    @objc private func saveTapped() {
        if saveButton.currentModifiers().contains(.shift) {
            onQuickSave?()
        } else {
            onSave?()
        }
    }
    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func scrollingCaptureTapped() { onScrollingCapture?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
}

@MainActor
class HoverButton: NSButton {
    var hoverTitle: String? {
        didSet {
            if oldValue != hoverTitle, isHovered { ToolbarHoverTip.shared.hide(for: self) }
        }
    }
    var onScroll: ((CGFloat) -> Void)?
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var isSelected = false { didSet { updateAppearance() } }
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override var isEnabled: Bool { didSet { updateAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private func configureAppearance() {
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 11
        focusRingType = .none
        contentTintColor = AppPalette.color(.text)
        updateAppearance()
    }

    override func scrollWheel(with event: NSEvent) {
        if isHovered { ToolbarHoverTip.shared.hide(for: self) }
        guard let onScroll else {
            super.scrollWheel(with: event)
            return
        }
        onScroll(event.scrollingDeltaY)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
        if hoverTitle != nil, NSEvent.pressedMouseButtons == 0 { ToolbarHoverTip.shared.schedule(for: self) }
    }

    override func mouseExited(with event: NSEvent) {
        endHover()
    }

    override func mouseDown(with event: NSEvent) {
        if isHovered { ToolbarHoverTip.shared.hide(for: self) }
        super.mouseDown(with: event)
    }

    override func viewDidHide() {
        super.viewDidHide()
        endHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func endHover() {
        guard isHovered else { return }
        isHovered = false
        ToolbarHoverTip.shared.hide(for: self)
        updateAppearance()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        let opacity: CGFloat = !isEnabled ? 0 : (isHighlighted ? 0.14 : (isSelected ? 0.09 : (isHovered ? 0.05 : 0)))
        let color = NSColor(srgbRed: 0.12, green: 0.30, blue: 0.43, alpha: opacity).cgColor
        let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        layer.borderColor = NSColor(srgbRed: 0.12, green: 0.30, blue: 0.43, alpha: 0.18).cgColor
        layer.borderWidth = isSelected ? 1 : 0
        CATransaction.commit()
        if window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let previous {
            let transition = CABasicAnimation(keyPath: "backgroundColor")
            transition.fromValue = previous
            transition.toValue = color
            transition.duration = 0.18
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(transition, forKey: "hover")
        } else {
            layer.removeAnimation(forKey: "hover")
        }
        alphaValue = isEnabled ? 1 : 0.38
    }
}

/// AppKit 的普通提示窗可能盖不到全屏截图覆盖层，提示跟随所属窗口的层级。
@MainActor
private final class ToolbarHoverTip: NSObject {
    static let shared = ToolbarHoverTip()

    private weak var anchor: HoverButton?
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    override init() {
        super.init()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = AppPalette.color(.text)
        NotificationCenter.default.addObserver(self, selector: #selector(hostDidClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    func schedule(for button: HoverButton) {
        dismiss()
        anchor = button
        pending = Task { [weak self, weak button] in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard !Task.isCancelled, let button else { return }
            self?.show(for: button)
        }
    }

    func hide(for button: HoverButton) {
        if anchor === button { dismiss() }
    }

    @objc private func hostDidClose(_ notification: Notification) {
        guard let host = notification.object as? NSWindow else { return }
        if anchor?.window === host || panel?.parent === host { dismiss() }
    }

    private func dismiss() {
        pending?.cancel()
        pending = nil
        anchor = nil
        guard let panel, let parent = panel.parent else { return }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(for button: HoverButton) {
        pending = nil
        guard anchor === button, !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty,
              let host = button.window, host.isVisible, !host.ignoresMouseEvents,
              let title = button.hoverTitle, !title.isEmpty else { return }
        let buttonFrame = host.convertToScreen(button.convert(button.visibleRect, to: nil))
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY))
        }) ?? host.screen else { return }

        let panel = self.panel ?? makePanel()
        label.stringValue = title
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 9, y: 5)
        let size = CGSize(width: label.frame.width + 18, height: label.frame.height + 10)
        let available = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let x = min(max(buttonFrame.midX - size.width / 2, available.minX), available.maxX - size.width)
        let above = buttonFrame.maxY + 7
        let y = above + size.height <= available.maxY ? above : max(available.minY, buttonFrame.minY - size.height - 7)
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        host.addChildWindow(panel, ordered: .above)
        panel.level = NSWindow.Level(rawValue: host.level.rawValue + 1)
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        let surface = AppSurfaceView(cornerRadius: 8)
        surface.addSubview(label)
        panel.contentView = surface
        self.panel = panel
        return panel
    }
}

@MainActor
final class ToolbarChoiceView: NSView {
    struct Item {
        let title: String
        var detail: String = ""
        var image: NSImage? = nil
        var selected: Bool = false
        let action: () -> Void
    }

    let items: [Item]
    private(set) var buttons: [HoverButton] = []
    var onPick: ((() -> Void) -> Void)?
    var onCancel: (() -> Void)?
    private var focusedIndex = 0

    init(items: [Item]) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: CGFloat(items.count) * 36 + 12))
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 16
        for (index, item) in items.enumerated() {
            let button = HoverButton(frame: NSRect(x: 6, y: bounds.height - 6 - CGFloat(index + 1) * 36, width: bounds.width - 12, height: 34))
            button.title = ""
            button.image = item.image
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = AppPalette.color(.text)
            button.target = self
            button.action = #selector(pick(_:))
            button.tag = index
            button.hoverTitle = item.title + (item.detail.isEmpty ? "" : " · " + item.detail)
            button.setAccessibilityLabel(item.title + (item.detail.isEmpty ? "" : " " + item.detail))
            button.isSelected = item.selected
            addSubview(button)
            buttons.append(button)
            let title = ChoiceLabel(labelWithString: item.title)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.textColor = AppPalette.color(.text)
            title.frame = NSRect(x: item.image == nil ? 12 : 40, y: 9, width: 165, height: 18)
            button.addSubview(title)
            if item.image != nil {
                button.image = nil
                let icon = ChoiceImageView(frame: NSRect(x: 10, y: 6, width: 22, height: 22))
                icon.image = item.image
                icon.contentTintColor = AppPalette.color(.text)
                icon.imageScaling = .scaleProportionallyDown
                button.addSubview(icon)
            }
            let detail = ChoiceLabel(labelWithString: item.selected ? "✓" : item.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = AppPalette.color(.secondaryText)
            detail.alignment = .right
            detail.frame = NSRect(x: 185, y: 9, width: 43, height: 18)
            button.addSubview(detail)
        }
        focusedIndex = items.firstIndex(where: { $0.selected }) ?? 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        switch event.keyCode {
        case 125: focusedIndex = (focusedIndex + 1) % items.count
        case 126: focusedIndex = (focusedIndex + items.count - 1) % items.count
        case 36, 76: onPick?(items[focusedIndex].action); return
        case 53: onCancel?(); return
        default: super.keyDown(with: event); return
        }
        for (index, button) in buttons.enumerated() { button.isSelected = index == focusedIndex }
    }

    @objc private func pick(_ sender: NSButton) { onPick?(items[sender.tag].action) }

    private final class ChoiceLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class ChoiceImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 调色板弹层：有序色块网格、透明度档位、自定义入口与导入导出。
/// swatches / alphaSwatches / 四个动作按钮暴露给验收 harness 程序化点击。
@MainActor
final class ColorPaletteView: NSView {
    var onPick: ((RGBAColor) -> Void)?
    var onPickCustom: ((RGBAColor) -> Void)?
    /// 颜色面板里选完立即应用，但不关闭调色板弹层。
    var onAddCustom: ((RGBAColor) -> Void)?
    var onPickAlpha: ((CGFloat) -> Void)?
    /// 色块内容或顺序变化后回调，供外部持久化。
    var onPaletteChange: ((PaletteModel) -> Void)?
    var onSizeChange: ((NSSize) -> Void)?

    private(set) var model: PaletteModel
    private(set) var swatches: [HoverButton] = []
    private(set) var alphaSwatches: [HoverButton] = []
    private(set) var customButton: HoverButton!
    private(set) var exportButton: HoverButton!
    private(set) var importButton: HoverButton!
    private(set) var resetButton: HoverButton!

    /// 记号笔会在所选透明度上叠加自身的墨水透明度。
    static let alphaPresets: [CGFloat] = [1, 0.8, 0.6, 0.4, 0.25]

    private enum Metrics {
        static let side: CGFloat = 28
        static let columns = 4
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
        static let alphaGap: CGFloat = 8
        static let actionGap: CGFloat = 8
        static let actionHeight: CGFloat = 28
        static let rowGap: CGFloat = 6
        static let bottomActionWidths: [CGFloat] = [42, 42, 56]
    }

    private var selectedColor: RGBAColor

    init(model: PaletteModel, selected: RGBAColor) {
        self.model = model
        selectedColor = selected
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: model)))
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 16
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func computeWidth() -> CGFloat {
        let gridWidth = CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let alphaWidth = CGFloat(alphaPresets.count) * Metrics.side
            + CGFloat(alphaPresets.count - 1) * Metrics.spacing
        return Metrics.padding * 2 + max(gridWidth, alphaWidth)
    }

    private static func size(for model: PaletteModel) -> NSSize {
        let rows = max(1, (model.colors.count + Metrics.columns - 1) / Metrics.columns)
        let gridHeight = CGFloat(rows) * Metrics.side + CGFloat(rows - 1) * Metrics.spacing
        let height = Metrics.padding * 2 + gridHeight
            + Metrics.alphaGap + Metrics.side
            + Metrics.actionGap + Metrics.actionHeight * 2 + Metrics.rowGap
        return NSSize(width: computeWidth(), height: height)
    }

    /// 色块增删与排序都会重建，数量变化时同步弹层尺寸。
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        swatches.removeAll()
        alphaSwatches.removeAll()
        frame.size = Self.size(for: model)
        onSizeChange?(frame.size)

        let gridWidth = CGFloat(Metrics.columns) * Metrics.side
            + CGFloat(Metrics.columns - 1) * Metrics.spacing
        let gridX = (frame.width - gridWidth) / 2
        let top = frame.height - Metrics.padding
        for (index, color) in model.colors.enumerated() {
            let column = index % Metrics.columns
            let row = index / Metrics.columns
            let swatch = PaletteSwatchButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(color),
                ringed: Self.sameRGB(color, selectedColor)
            )
            swatch.isSelected = Self.sameRGB(color, selectedColor)
            swatch.hoverTitle = model.isCustom(at: index) ? "自定义颜色" : "颜色 \(index + 1)"
            swatch.target = self
            swatch.action = #selector(picked(_:))
            swatch.tag = index
            swatch.swatchIndex = index
            swatch.palette = self
            swatch.frame = NSRect(
                x: gridX + CGFloat(column) * (Metrics.side + Metrics.spacing),
                y: top - Metrics.side - CGFloat(row) * (Metrics.side + Metrics.spacing),
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            swatches.append(swatch)
        }

        let alphaY = Metrics.padding + Metrics.rowGap + Metrics.actionHeight * 2 + Metrics.actionGap
        let alphaWidth = CGFloat(Self.alphaPresets.count) * Metrics.side
            + CGFloat(Self.alphaPresets.count - 1) * Metrics.spacing
        let alphaX = (frame.width - alphaWidth) / 2
        for (index, alpha) in Self.alphaPresets.enumerated() {
            var shade = selectedColor
            shade.a = alpha
            let swatch = HoverButton()
            swatch.isBordered = false
            swatch.refusesFirstResponder = true
            swatch.image = AnnotateToolbar.dotImage(
                diameter: 18,
                color: AnnotateToolbar.nsColor(shade),
                ringed: abs(selectedColor.a - alpha) < 0.001
            )
            swatch.isSelected = abs(selectedColor.a - alpha) < 0.001
            swatch.hoverTitle = "透明度 \(Int((alpha * 100).rounded()))%"
            swatch.target = self
            swatch.action = #selector(pickedAlpha(_:))
            swatch.tag = index
            swatch.frame = NSRect(
                x: alphaX + CGFloat(index) * (Metrics.side + Metrics.spacing),
                y: alphaY,
                width: Metrics.side,
                height: Metrics.side
            )
            addSubview(swatch)
            alphaSwatches.append(swatch)
        }

        let innerWidth = frame.width - Metrics.padding * 2
        let bottomY = Metrics.padding
        let bottomWidth = Metrics.bottomActionWidths.reduce(0, +)
            + CGFloat(Metrics.bottomActionWidths.count - 1) * Metrics.spacing
        var x = (frame.width - bottomWidth) / 2
        var buttons: [HoverButton] = []
        let bottomActions: [(String, String, Selector)] = [
            ("导出", "导出调色板 JSON", #selector(exportTapped)),
            ("导入", "导入调色板 JSON", #selector(importTapped)),
            ("恢复默认", "恢复默认调色板", #selector(resetTapped)),
        ]
        for (index, entry) in bottomActions.enumerated() {
            let button = makeActionButton(entry.0, toolTip: entry.1, action: entry.2)
            button.frame = NSRect(
                x: x,
                y: bottomY,
                width: Metrics.bottomActionWidths[index],
                height: Metrics.actionHeight
            )
            addSubview(button)
            buttons.append(button)
            x += Metrics.bottomActionWidths[index] + Metrics.spacing
        }
        let custom = makeActionButton("自定义颜色…", toolTip: "自定义颜色…", action: #selector(customTapped))
        custom.frame = NSRect(
            x: Metrics.padding,
            y: bottomY + Metrics.actionHeight + Metrics.rowGap,
            width: innerWidth,
            height: Metrics.actionHeight
        )
        addSubview(custom)

        customButton = custom
        exportButton = buttons[0]
        importButton = buttons[1]
        resetButton = buttons[2]
    }

    private func makeActionButton(_ title: String, toolTip: String, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.isBordered = false
        button.refusesFirstResponder = true
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: AppPalette.color(.text),
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ]
        )
        button.hoverTitle = toolTip
        button.target = self
        button.action = action
        return button
    }

    private static func sameRGB(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
    }

    /// 颜色面板选色与验收注入共用：加入自定义色后立即应用。
    func addCustomColor(_ color: RGBAColor) {
        guard PaletteModel.isValid(color) else { return }
        selectedColor = color
        let added = model.addCustom(color)
        rebuild()
        if added { onPaletteChange?(model) }
        onAddCustom?(color)
    }

    fileprivate func dropSwatch(from source: Int, at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        guard let destination = swatches.firstIndex(where: { $0.frame.contains(point) }),
              destination != source else { return }
        model.move(from: source, to: destination)
        rebuild()
        onPaletteChange?(model)
    }

    @objc private func picked(_ sender: NSButton) {
        guard model.colors.indices.contains(sender.tag) else { return }
        let color = model.colors[sender.tag]
        selectedColor = color
        if model.isCustom(at: sender.tag) {
            onPickCustom?(color)
        } else {
            onPick?(color)
        }
    }

    @objc private func pickedAlpha(_ sender: NSButton) {
        onPickAlpha?(ColorPaletteView.alphaPresets[sender.tag])
    }

    @objc private func customTapped() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        // 连续模式会在拖色时灌进几十个中间色，提交时再收一个。
        panel.isContinuous = false
        panel.color = AnnotateToolbar.nsColor(selectedColor)
        ColorPanelRouter.shared.palette = self
        panel.setTarget(ColorPanelRouter.shared)
        panel.setAction(#selector(ColorPanelRouter.colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "iine-palette.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? model.jsonData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    @objc private func importTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let imported = PaletteModel.decode(data) else { return }
        model = imported
        rebuild()
        onPaletteChange?(model)
    }

    @objc private func resetTapped() {
        model.reset()
        rebuild()
        onPaletteChange?(model)
    }
}

/// 色块拖拽：按下记录起点，松开时按落点换位。拖拽期间不重建视图，
/// 避免正在接收鼠标事件的按钮被移出层级。
@MainActor
private final class PaletteSwatchButton: HoverButton {
    weak var palette: ColorPaletteView?
    var swatchIndex = 0
    private var dragOrigin: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - origin.x, point.y - origin.y) > 3 {
            dragged = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            dragged = false
        }
        if dragged {
            palette?.dropSwatch(from: swatchIndex, at: event.locationInWindow)
        } else {
            performClick(nil)
        }
    }
}

/// NSColorPanel 是单例，target 固定在常驻 router 上，
/// 弹层销毁后 weak palette 自动失效，不会留下悬空 target。
@MainActor
private final class ColorPanelRouter: NSObject {
    static let shared = ColorPanelRouter()
    weak var palette: ColorPaletteView?

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let converted = sender.color.usingColorSpace(.sRGB) else { return }
        palette?.addCustomColor(RGBAColor(
            r: converted.redComponent,
            g: converted.greenComponent,
            b: converted.blueComponent,
            a: converted.alphaComponent
        ))
    }
}

/// 笔宽、字号或效果强度的五档选择。
@MainActor
final class PenSizeView: NSView {
    var onPick: ((PenSize) -> Void)?
    private(set) var swatches: [HoverButton] = []

    private enum Metrics {
        static let side: CGFloat = 34
        static let padding: CGFloat = 10
        static let spacing: CGFloat = 6
    }

    init(selected: PenSize, kind: ShapeKind = .rect) {
        let width = Metrics.padding * 2
            + CGFloat(PenSize.allCases.count) * Metrics.side
            + CGFloat(PenSize.allCases.count - 1) * Metrics.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.side + Metrics.padding * 2 + 16))
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 16

        for pen in PenSize.allCases {
            let index = pen.rawValue - 1
            let button = HoverButton()
            button.isBordered = false
            button.refusesFirstResponder = true
            button.image = AnnotateToolbar.dotImage(
                diameter: 4 + CGFloat(index) * 3,
                color: .black,
                ringed: pen == selected
            )
            let value: String
            switch kind {
            case .text: value = "\(Int(pen.textFontSize))"
            case .mosaic, .mosaicRect, .blur, .serial: value = "\(pen.rawValue)"
            default: value = "\(Int(pen.lineWidth))"
            }
            button.imagePosition = .imageAbove
            button.attributedTitle = NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: AppPalette.color(.text),
            ])
            button.hoverTitle = kind == .text ? "字号 \(value)" : "大小 \(value)"
            button.isSelected = pen == selected
            button.target = self
            button.action = #selector(picked(_:))
            button.tag = index
            button.frame = NSRect(
                x: Metrics.padding + CGFloat(index) * (Metrics.side + Metrics.spacing),
                y: Metrics.padding,
                width: Metrics.side,
                height: Metrics.side + 16
            )
            addSubview(button)
            swatches.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSButton) {
        onPick?(PenSize(rawValue: sender.tag + 1) ?? .p3)
    }
}
