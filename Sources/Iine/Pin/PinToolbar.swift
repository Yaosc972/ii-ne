import AppKit

/// 贴图窗口顶部的悬浮工具条。鼠标进入窗口时出现，离开后隐藏。
@MainActor
final class PinToolbar: NSView {
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onFlipHorizontal: (() -> Void)?
    var onFlipVertical: (() -> Void)?
    var onGrayscale: (() -> Void)?
    var onInverted: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onAnnotate: (() -> Void)?

    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard maximumWidth != oldValue else { return }
            updateLayout()
        }
    }

    private enum LayoutMode { case full, compact, menuOnly }

    private struct Action {
        let glyph: ToolbarGlyph
        let title: String
        let selector: Selector
    }

    private static let actionGroups: [[Action]] = [
        [Action(glyph: .zoomOut, title: "缩小", selector: #selector(zoomOutTapped)),
         Action(glyph: .zoomIn, title: "放大", selector: #selector(zoomInTapped))],
        [Action(glyph: .rotateLeft, title: "向左旋转", selector: #selector(rotateLeftTapped)),
         Action(glyph: .rotateRight, title: "向右旋转", selector: #selector(rotateRightTapped)),
         Action(glyph: .flipHorizontal, title: "水平翻转", selector: #selector(flipHorizontalTapped)),
         Action(glyph: .flipVertical, title: "垂直翻转", selector: #selector(flipVerticalTapped))],
        [Action(glyph: .grayscale, title: "灰度", selector: #selector(grayscaleTapped)),
         Action(glyph: .invert, title: "反色", selector: #selector(invertedTapped))],
        [Action(glyph: .brush, title: "标注", selector: #selector(annotateTapped))],
        [Action(glyph: .copy, title: "复制图像", selector: #selector(copyTapped)),
         Action(glyph: .save, title: "另存为", selector: #selector(saveTapped)),
         Action(glyph: .close, title: "关闭", selector: #selector(closeTapped))],
    ]
    private static let compactActions = [#selector(annotateTapped), #selector(copyTapped), #selector(closeTapped)]

    static let buttonSide: CGFloat = 28
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 2

    private let sizeLabel = NSTextField(labelWithString: "大小: 100%")
    private var stack: NSStackView!
    private var fullViews: [NSView] = []
    private var compactViews: [NSView] = []
    private var moreButton: NSButton!
    private var layoutMode: LayoutMode = .full

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor(white: 0, alpha: 0.10).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 18

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = AppPalette.color(.secondaryText)
        sizeLabel.alignment = .right

        var buttons: [Selector: NSButton] = [:]
        for group in Self.actionGroups {
            if !fullViews.isEmpty { fullViews.append(Self.separator()) }
            for action in group {
                let button = Self.glyphButton(action.glyph, action.title, action.selector, target: self)
                fullViews.append(button)
                buttons[action.selector] = button
            }
        }
        fullViews.append(sizeLabel)
        moreButton = Self.glyphButton(.more, "更多贴图操作", #selector(showMore(_:)), target: self)
        compactViews = Self.compactActions.compactMap { buttons[$0] }
        compactViews.insert(moreButton, at: compactViews.count - 1)
        stack = NSStackView()
        stack.setViews(fullViews, in: .center)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
        sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: width(of: stack.views),
            height: Self.buttonSide + Self.padding * 2
        )
    }

    func updateStyle(scale: CGFloat) {
        sizeLabel.stringValue = "大小: \(Int((scale * 100).rounded()))%"
        updateLayout()
    }

    private func width(of views: [NSView]) -> CGFloat {
        let content = views.reduce(CGFloat.zero) { $0 + $1.fittingSize.width }
        return ceil(content + CGFloat(max(0, views.count - 1)) * Self.spacing + Self.padding * 2)
    }

    private func updateLayout() {
        guard stack != nil else { return }
        let mode: LayoutMode
        if width(of: fullViews) <= maximumWidth {
            mode = .full
        } else if width(of: compactViews) <= maximumWidth {
            mode = .compact
        } else {
            mode = .menuOnly
        }
        if mode != layoutMode {
            layoutMode = mode
            let views: [NSView]
            switch mode {
            case .full: views = fullViews
            case .compact: views = compactViews
            case .menuOnly: views = [moreButton]
            }
            stack.setViews(views, in: .center)
            updateOverflowMenu()
        }
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func updateOverflowMenu() {
        let menu = NSMenu(title: "贴图操作")
        for group in Self.actionGroups {
            let actions = group.filter { layoutMode != .compact || !Self.compactActions.contains($0.selector) }
            guard !actions.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for action in actions {
                let item = NSMenuItem(title: action.title, action: action.selector, keyEquivalent: "")
                item.target = self
                item.image = ToolbarGlyph.image(action.glyph)
                menu.addItem(item)
            }
        }
        moreButton.menu = menu
    }

    @objc private func showMore(_ sender: NSButton) {
        let point = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY)
        sender.menu?.popUp(positioning: nil, at: point, in: sender)
    }

    static func glyphButton(
        _ glyph: ToolbarGlyph,
        _ title: String,
        _ action: Selector,
        target: AnyObject
    ) -> NSButton {
        let button = HoverButton()
        button.isBordered = false
        button.image = ToolbarGlyph.image(glyph)
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.contentTintColor = AppPalette.color(.text)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSide),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSide),
        ])
        return button
    }

    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }

    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func rotateLeftTapped() { onRotateLeft?() }
    @objc private func rotateRightTapped() { onRotateRight?() }
    @objc private func flipHorizontalTapped() { onFlipHorizontal?() }
    @objc private func flipVerticalTapped() { onFlipVertical?() }
    @objc private func grayscaleTapped() { onGrayscale?() }
    @objc private func invertedTapped() { onInverted?() }
    @objc private func annotateTapped() { onAnnotate?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func closeTapped() { onClose?() }
}
