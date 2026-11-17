import AppKit

@MainActor
final class AppSwitch: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.switch)
        isBordered = false
        focusRingType = .none
        toolTip = title
        setAccessibilityLabel(title)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 26) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let track = NSRect(x: bounds.midX - 22, y: bounds.midY - 12, width: 44, height: 24)
            let path = NSBezierPath(roundedRect: track, xRadius: 12, yRadius: 12)
            let selected = state == .on
            AppPalette.color(selected && isEnabled ? .accent : .surfaceVariant).setFill()
            path.fill()
            AppPalette.color(selected && isEnabled ? .accent : .outline).setStroke()
            path.lineWidth = 1
            path.stroke()
            let thumb = NSRect(x: selected ? track.maxX - 21 : track.minX + 3,
                y: track.midY - 9, width: 18, height: 18)
            AppPalette.color(!isEnabled ? .disabledText : (selected ? .onAccent : .secondaryText)).setFill()
            NSBezierPath(ovalIn: thumb).fill()
            if isHighlighted {
                AppPalette.color(.text).withAlphaComponent(0.08).setFill()
                path.fill()
            }
            if window?.firstResponder === self {
                AppPalette.color(selected ? .onAccent : .accent).setStroke()
                let focus = NSBezierPath(roundedRect: track.insetBy(dx: 1.5, dy: 1.5), xRadius: 10.5, yRadius: 10.5)
                focus.lineWidth = 1.5
                focus.stroke()
            }
        }
    }
}

@MainActor
final class AppToggleButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.pushOnPushOff)
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(title)
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 40) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let selected = state == .on
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            AppPalette.color(selected ? .accentSurface : .surface).setFill()
            path.fill()
            AppPalette.color(selected && isEnabled ? .accent : .outline).setStroke()
            path.lineWidth = window?.firstResponder === self ? 2 : 1
            path.stroke()
            let color = AppPalette.color(!isEnabled ? .disabledText : (selected ? .accent : .text))
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            if isHighlighted {
                color.withAlphaComponent(0.08).setFill()
                path.fill()
            }
        }
    }
}

private enum FieldTextLayout {
    static func rect(_ bounds: NSRect, font: NSFont?) -> NSRect {
        let font = font ?? .systemFont(ofSize: 13)
        let height = ceil(font.ascender - font.descender + font.leading + 2)
        return NSRect(x: bounds.minX + 10, y: floor(bounds.midY - height / 2),
            width: max(0, bounds.width - 20), height: min(bounds.height, height))
    }
}

private final class AppTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { FieldTextLayout.rect(rect, font: font) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}

private final class AppSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { FieldTextLayout.rect(rect, font: font) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}

@MainActor
private enum FieldAppearance {
    static func configure(_ field: NSTextField) {
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.alignment = .left
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 10
        field.layer?.borderWidth = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
    }

    static func refresh(_ field: NSTextField, focused: Bool) {
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            field.layer?.backgroundColor = AppPalette.color(field.isEnabled ? .surface : .surfaceVariant).cgColor
            field.layer?.borderColor = AppPalette.color(focused && field.isEnabled ? .accent : .outline).cgColor
            field.layer?.borderWidth = focused && field.isEnabled ? 2 : 1
        }
        field.textColor = AppPalette.color(field.isEnabled ? .text : .disabledText)
        if let editor = field.currentEditor() as? NSTextView {
            editor.textColor = field.textColor
            editor.insertionPointColor = AppPalette.color(.accent)
            editor.drawsBackground = false
        }
        field.needsDisplay = true
    }
}

@MainActor
final class AppTextField: NSTextField {
    private var editing = false

    init() {
        super.init(frame: .zero)
        cell = AppTextFieldCell(textCell: "")
        FieldAppearance.configure(self)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: NSControl.textDidBeginEditingNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: NSControl.textDidEndEditingNotification, object: self)
        FieldAppearance.refresh(self, focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
    override var isEnabled: Bool { didSet { FieldAppearance.refresh(self, focused: editing) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); FieldAppearance.refresh(self, focused: editing) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); FieldAppearance.refresh(self, focused: editing) }
    @objc private func editingChanged(_ note: Notification) {
        editing = note.name == NSControl.textDidBeginEditingNotification
        FieldAppearance.refresh(self, focused: editing)
    }
}

@MainActor
class AppSecureTextField: NSSecureTextField {
    private var editing = false

    init() {
        super.init(frame: .zero)
        cell = AppSecureTextFieldCell(textCell: "")
        FieldAppearance.configure(self)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: NSControl.textDidBeginEditingNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: NSControl.textDidEndEditingNotification, object: self)
        FieldAppearance.refresh(self, focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
    override var isEnabled: Bool { didSet { FieldAppearance.refresh(self, focused: editing) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); FieldAppearance.refresh(self, focused: editing) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); FieldAppearance.refresh(self, focused: editing) }
    @objc private func editingChanged(_ note: Notification) {
        editing = note.name == NSControl.textDidBeginEditingNotification
        FieldAppearance.refresh(self, focused: editing)
    }
}

@MainActor
final class AppColorWell: NSColorWell {
    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel("背景颜色")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 36) }
    override var color: NSColor { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            AppPalette.color(.surface).setFill()
            outer.fill()
            AppPalette.color(isActive || window?.firstResponder === self ? .accent : .outline).setStroke()
            outer.lineWidth = isActive ? 2 : 1
            outer.stroke()
            let swatch = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 5, yRadius: 5)
            (isEnabled ? color : color.withAlphaComponent(0.35)).setFill()
            swatch.fill()
            AppPalette.color(.outline).setStroke()
            swatch.lineWidth = 0.5
            swatch.stroke()
        }
    }
}

@MainActor
final class AppNumberInput: NSView {
    let field: NSTextField
    let minusButton = AppActionButton(title: "−", emphasis: .secondary, target: nil, action: nil)
    let plusButton = AppActionButton(title: "+", emphasis: .secondary, target: nil, action: nil)
    private let range: ClosedRange<Int>
    private let step: Int
    var isEnabled = true { didSet { refresh() } }

    init(field: NSTextField, range: ClosedRange<Int>, step: Int = 1, label: String) {
        self.field = field
        self.range = range
        self.step = max(1, step)
        super.init(frame: .zero)
        field.alignment = .center
        field.setAccessibilityLabel(label)
        minusButton.setAccessibilityLabel("减少" + label)
        plusButton.setAccessibilityLabel("增加" + label)
        minusButton.target = self
        minusButton.action = #selector(decrease)
        plusButton.target = self
        plusButton.action = #selector(increase)
        let stack = NSStackView(views: [minusButton, field, plusButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 64),
            minusButton.widthAnchor.constraint(equalToConstant: 36),
            plusButton.widthAnchor.constraint(equalToConstant: 36),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: 144, height: 36) }

    func refresh() {
        field.isEnabled = isEnabled
        minusButton.isEnabled = isEnabled && field.integerValue > range.lowerBound
        plusButton.isEnabled = isEnabled && field.integerValue < range.upperBound
    }

    private func change(by delta: Int) {
        let value = min(max(field.integerValue, range.lowerBound), range.upperBound)
        field.integerValue = min(max(value + delta, range.lowerBound), range.upperBound)
        if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
        refresh()
    }

    @objc private func decrease() { change(by: -step) }
    @objc private func increase() { change(by: step) }
}
