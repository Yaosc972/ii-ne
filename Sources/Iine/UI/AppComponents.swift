import AppKit

enum AppColorRole {
    case background, surface, surfaceVariant, text, secondaryText, outline
    case accent, onAccent, accentSurface, error, disabledText
}

enum AppPalette {
    static func color(_ role: AppColorRole) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value: (CGFloat, CGFloat, CGFloat)
            switch (role, dark) {
            case (.background, false): value = (0.953, 0.973, 0.984)
            case (.surface, false): value = (1, 1, 1)
            case (.surfaceVariant, false): value = (0.910, 0.941, 0.961)
            case (.text, false): value = (0.031, 0.051, 0.071)
            case (.secondaryText, false): value = (0.322, 0.369, 0.400)
            case (.outline, false): value = (0.843, 0.882, 0.906)
            case (.accent, false): value = (0.031, 0.051, 0.071)
            case (.onAccent, false): value = (1, 1, 1)
            case (.accentSurface, false): value = (0.820, 0.898, 0.945)
            case (.error, false): value = (0.710, 0.153, 0.188)
            case (.disabledText, false): value = (0.392, 0.427, 0.486)
            case (.background, true): value = (0.071, 0.086, 0.110)
            case (.surface, true): value = (0.114, 0.133, 0.169)
            case (.surfaceVariant, true): value = (0.165, 0.188, 0.235)
            case (.text, true): value = (0.941, 0.953, 0.980)
            case (.secondaryText, true): value = (0.686, 0.725, 0.788)
            case (.outline, true): value = (0.294, 0.329, 0.388)
            case (.accent, true): value = (0.565, 0.718, 1)
            case (.onAccent, true): value = (0.047, 0.102, 0.208)
            case (.accentSurface, true): value = (0.149, 0.224, 0.357)
            case (.error, true): value = (1, 0.565, 0.584)
            case (.disabledText, true): value = (0.580, 0.624, 0.690)
            }
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
}

@MainActor
final class AppSurfaceView: NSView {
    var surfaceRole: AppColorRole { didSet { updateColors() } }
    var borderRole: AppColorRole = .outline { didSet { updateColors() } }
    var bordered: Bool { didSet { updateColors() } }

    init(role: AppColorRole = .surface, cornerRadius: CGFloat = 24, bordered: Bool = true) {
        surfaceRole = role
        self.bordered = bordered
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AppPalette.color(surfaceRole).cgColor
            layer?.borderColor = AppPalette.color(borderRole).cgColor
            layer?.borderWidth = bordered ? 1 : 0
        }
        needsDisplay = true
    }
}

@MainActor
private final class AppControlAnimation: NSAnimation {
    private let update: (CGFloat) -> Void

    init(duration: TimeInterval = 0.2, update: @escaping (CGFloat) -> Void) {
        self.update = update
        super.init(duration: duration, animationCurve: .easeOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var currentProgress: NSAnimation.Progress {
        didSet { update(CGFloat(currentValue)) }
    }
}

@MainActor
final class AppActionButton: NSButton {
    enum Emphasis { case primary, secondary, quiet }
    let emphasis: Emphasis
    private var hovered = false
    private var interactionAmount: CGFloat = 0
    private var interactionAnimation: AppControlAnimation?

    init(title: String, emphasis: Emphasis = .secondary, target: AnyObject?, action: Selector?) {
        self.emphasis = emphasis
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        font = .systemFont(ofSize: 13, weight: .medium)
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageLeading
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var title: String {
        didSet {
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    override var isEnabled: Bool { didSet { updateInteraction() } }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)])
        let width = imagePosition == .imageOnly ? 36 : max(64, ceil(text.width) + 32 + (image == nil ? 0 : 22))
        return NSSize(width: width, height: 36)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateInteraction() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateInteraction() }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateInteraction() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func updateInteraction() {
        interactionAnimation?.stop()
        let target: CGFloat = !isEnabled ? 0 : (isHighlighted ? 1 : (hovered ? 0.55 : 0))
        let start = interactionAmount
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            interactionAmount = target
            needsDisplay = true
            return
        }
        let animation = AppControlAnimation { [weak self] progress in
            self?.interactionAmount = start + (target - start) * progress
            self?.needsDisplay = true
        }
        interactionAnimation = animation
        animation.start()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let inset = isHighlighted && isEnabled ? 2.0 : 1.0
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            let foreground: NSColor
            let fill: NSColor
            if !isEnabled {
                foreground = AppPalette.color(.disabledText)
                fill = emphasis == .quiet ? .clear : AppPalette.color(.surfaceVariant)
            } else if emphasis == .primary {
                foreground = AppPalette.color(.onAccent)
                fill = AppPalette.color(.accent)
            } else {
                foreground = AppPalette.color(.text)
                let base = emphasis == .quiet ? NSColor.clear : AppPalette.color(.surface)
                fill = base.blended(withFraction: interactionAmount, of: AppPalette.color(.surfaceVariant)) ?? base
            }
            fill.setFill()
            path.fill()
            if isEnabled && emphasis == .primary {
                foreground.withAlphaComponent(0.12 * interactionAmount).setFill()
                path.fill()
            }
            if emphasis == .secondary {
                AppPalette.color(.outline).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            drawContent(color: foreground)
            if window?.firstResponder === self {
                AppPalette.color(.accent).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        }
    }

    private func drawContent(color: NSColor) {
        let showsText = imagePosition != .imageOnly
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let textSize = showsText ? (title as NSString).size(withAttributes: attributes) : .zero
        let iconWidth: CGFloat = image == nil ? 0 : 16
        let gap: CGFloat = image == nil || !showsText || title.isEmpty ? 0 : 6
        let contentWidth = textSize.width + iconWidth + gap
        let leading = floor((bounds.width - contentWidth) / 2)
        let imageTrailing = imagePosition == .imageTrailing || imagePosition == .imageRight
        if let image {
            let rect = NSRect(x: imageTrailing ? leading + textSize.width + gap : leading,
                y: (bounds.height - 16) / 2, width: 16, height: 16)
            if image.isTemplate, let mask = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: rect.minX, y: isFlipped ? rect.maxY : rect.minY)
                context.scaleBy(x: 1, y: isFlipped ? -1 : 1)
                let imageBounds = NSRect(origin: .zero, size: rect.size)
                context.clip(to: imageBounds, mask: mask)
                color.setFill()
                context.fill(imageBounds)
                context.restoreGState()
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if showsText {
            let x = imageTrailing ? leading : leading + iconWidth + gap
            (title as NSString).draw(at: NSPoint(x: x, y: floor((bounds.height - textSize.height) / 2)), withAttributes: attributes)
        }
    }
}

@MainActor
final class AppModeControl: NSSegmentedControl {
    private var displayedSegment: CGFloat = 0
    private var selectionAnimation: AppControlAnimation?

    init(labels: [String], target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            setLabel(label, forSegment: index)
            setWidth(96, forSegment: index)
            setToolTip(label, forSegment: index)
        }
        trackingMode = .selectOne
        segmentStyle = .roundRect
        segmentDistribution = .fillEqually
        font = .systemFont(ofSize: 13, weight: .semibold)
        focusRingType = .none
        self.target = target
        self.action = action
        setAccessibilityLabel("工作模式")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var selectedSegment: Int { didSet { updateSelection() } }
    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(segmentCount) * 96 + 4, height: 36) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); updateSelection() }
    override func keyDown(with event: NSEvent) { super.keyDown(with: event); updateSelection() }

    private func updateSelection() {
        selectionAnimation?.stop()
        let target = CGFloat(max(0, selectedSegment))
        let start = displayedSegment
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            displayedSegment = target
            needsDisplay = true
            return
        }
        let animation = AppControlAnimation(duration: 0.24) { [weak self] progress in
            self?.displayedSegment = start + (target - start) * progress
            self?.needsDisplay = true
        }
        selectionAnimation = animation
        animation.start()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard segmentCount > 0 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let outer = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            AppPalette.color(.surfaceVariant).setFill()
            outer.fill()
            let width = (bounds.width - 4) / CGFloat(segmentCount)
            if selectedSegment >= 0 {
                let selectedRect = NSRect(x: 2 + displayedSegment * width, y: 2, width: width, height: bounds.height - 4)
                AppPalette.color(.surface).setFill()
                NSBezierPath(roundedRect: selectedRect, xRadius: selectedRect.height / 2, yRadius: selectedRect.height / 2).fill()
            }
            for index in 0..<segmentCount {
                let rect = NSRect(x: 2 + CGFloat(index) * width, y: 2, width: width, height: bounds.height - 4)
                let color = !isEnabled ? AppPalette.color(.disabledText)
                    : AppPalette.color(index == selectedSegment ? .accent : .secondaryText)
                let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color]
                let title = (label(forSegment: index) ?? "") as NSString
                let size = title.size(withAttributes: attributes)
                title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: floor(rect.midY - size.height / 2)), withAttributes: attributes)
            }
            if window?.firstResponder === self {
                AppPalette.color(.accent).setStroke()
                outer.lineWidth = 2
                outer.stroke()
            }
        }
    }
}

@MainActor
final class AppPopUpButton: NSPopUpButton {
    private var hovered = false
    private var interactionAmount: CGFloat = 0
    private var interactionAnimation: AppControlAnimation?

    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .none
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13)]
        let width = itemTitles.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 48
        return NSSize(width: max(88, ceil(width) + 44), height: 36)
    }
    override var isEnabled: Bool { didSet { updateInteraction() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateInteraction() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateInteraction() }
    override func highlight(_ flag: Bool) { super.highlight(flag); updateInteraction() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func updateInteraction() {
        interactionAnimation?.stop()
        let target: CGFloat = !isEnabled ? 0 : (isHighlighted ? 1 : (hovered ? 0.6 : 0))
        let start = interactionAmount
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            interactionAmount = target
            needsDisplay = true
            return
        }
        let animation = AppControlAnimation { [weak self] progress in
            self?.interactionAmount = start + (target - start) * progress
            self?.needsDisplay = true
        }
        interactionAnimation = animation
        animation.start()
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            let surface = AppPalette.color(.surface)
            let fill = surface.blended(withFraction: interactionAmount, of: AppPalette.color(.surfaceVariant)) ?? surface
            fill.setFill()
            path.fill()
            AppPalette.color(.outline).setStroke()
            path.lineWidth = 1
            path.stroke()
            let color = AppPalette.color(isEnabled ? .text : .disabledText)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            let title = (titleOfSelectedItem ?? "") as NSString
            let height = title.size(withAttributes: attributes).height
            title.draw(in: NSRect(x: 12, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - 38), height: height),
                withAttributes: attributes)
            let arrow = NSBezierPath()
            let down: CGFloat = isFlipped ? 1 : -1
            arrow.move(to: NSPoint(x: bounds.maxX - 23, y: bounds.midY - down * 2))
            arrow.line(to: NSPoint(x: bounds.maxX - 19, y: bounds.midY + down * 2))
            arrow.line(to: NSPoint(x: bounds.maxX - 15, y: bounds.midY - down * 2))
            color.setStroke()
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            if window?.firstResponder === self {
                AppPalette.color(.accent).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        }
    }
}
