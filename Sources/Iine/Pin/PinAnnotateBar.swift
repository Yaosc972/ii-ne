import AppKit
import IineCore

/// The floating pin panel uses the same controls as capture and long-image editing.
@MainActor
final class PinAnnotateBar: NSView {
    let toolbar = AnnotateToolbar(initialKind: .rect,
        initialStyle: ShapeCatalog.entry(for: .rect)!.defaultStyle, context: .pin)
    var onSizeChange: (() -> Void)?
    var exposedTools: [ShapeKind] { Array(toolbar.toolButtons.keys) }

    init() {
        super.init(frame: .zero)
        addSubview(toolbar)
        toolbar.onSizeChange = { [weak self] in
            guard let self else { return }
            self.invalidateIntrinsicContentSize()
            self.frame.size = self.toolbar.frame.size
            self.onSizeChange?()
        }
        frame.size = toolbar.frame.size
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { toolbar.frame.size }

    func updateState(tool: ShapeKind, color: RGBAColor, pen: PenSize, canUndo: Bool) {
        toolbar.select(tool, style: Style(color: color, pen: pen))
        toolbar.updateUndoState(canUndo: canUndo, canRedo: false)
    }
}
