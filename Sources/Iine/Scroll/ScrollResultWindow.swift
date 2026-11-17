import AppKit
import IineCore

@MainActor
final class ScrollResultWindow: NSWindow {
    var onPin: ((PasteImage) -> Void)?
    var onDocumentChange: ((CGImage, [Annotation]) -> Void)?
    var onClose: (() -> Void)?
    var onRecognize: ((CGImage, CGFloat, Bool, NSWindow) -> Void)?
    private(set) var translationTarget: TranslationTarget = .auto
    private let image: CGImage
    private let scale: CGFloat
    let canvas: AnnotationCanvas
    let annotationToolbar: AnnotateToolbar
    private let scrollView = NSScrollView()
    private let toolbarScroll = NSScrollView()
    private var lastReportedAnnotations: [Annotation]
    private var sharePicker: NSSharingServicePicker?
    private var barcodeTask: Task<Void, Never>?

    var annotations: [Annotation] { canvas.annotations }
    var document: PasteImage { PasteImage(image: image, pointSize: canvas.canvasSize, annotations: annotations) }

    init(image: CGImage, scale: CGFloat, annotations: [Annotation] = []) {
        self.image = image
        self.scale = scale
        lastReportedAnnotations = annotations
        let points = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let style = ShapeCatalog.entry(for: .rect)!.defaultStyle
        canvas = AnnotationCanvas(base: image, cropOriginPx: .zero, scale: scale, initialStyle: style)
        annotationToolbar = AnnotateToolbar(initialKind: .rect, initialStyle: style, context: .imageEditor)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: min(max(points.width, annotationToolbar.frame.width + 16), visible.width * 0.9),
            height: min(max(points.height + 100, 360), visible.height * 0.85))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        title = "滚动截图"
        minSize = NSSize(width: 400, height: 280)
        isReleasedWhenClosed = false
        let container = ScrollResultContainer(frame: NSRect(origin: .zero, size: size))
        container.onLayout = { [weak self] in self?.layoutContent() }
        contentView = container
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 4
        canvas.frame = NSRect(origin: .zero, size: points)
        canvas.logicalSize = points
        canvas.drawsBaseImage = true
        canvas.receivesEvents = true
        canvas.scrollAdjustsPen = false
        canvas.restoreAnnotations(annotations)
        canvas.selectTool(nil)
        scrollView.documentView = canvas
        container.addSubview(scrollView)
        toolbarScroll.drawsBackground = false
        toolbarScroll.hasHorizontalScroller = true
        toolbarScroll.autohidesScrollers = true
        toolbarScroll.documentView = annotationToolbar
        container.addSubview(toolbarScroll)
        connectActions()
        layoutContent()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, points.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        center()
        makeFirstResponder(canvas)
    }

    private func connectActions() {
        canvas.onChange = { [weak self] in self?.editorChanged() }
        canvas.onFinish = { [weak self] in self?.copyImage() }
        canvas.onCancel = { [weak self] in self?.close() }
        annotationToolbar.onSelectTool = { [weak self] in self?.canvas.selectTool($0) }
        annotationToolbar.onSelectMode = { [weak self] in self?.canvas.selectTool(nil) }
        annotationToolbar.onStyleChange = { [weak self] in self?.canvas.applyStyle($0) }
        annotationToolbar.onStylePropertyChange = { [weak self] style, attribute in
            self?.canvas.applyStyle(style, changed: attribute)
        }
        annotationToolbar.onUndo = { [weak self] in self?.canvas.undo() }
        annotationToolbar.onRedo = { [weak self] in self?.canvas.redo() }
        annotationToolbar.onCopy = { [weak self] in self?.copyImage() }
        annotationToolbar.onSave = { [weak self] in self?.saveImage() }
        annotationToolbar.onQuickSave = { [weak self] in self?.quickSave() }
        annotationToolbar.onPin = { [weak self] in
            guard let self else { return }
            self.canvas.finishEditing()
            self.onPin?(self.document)
            self.annotationToolbar.showMessage("已贴到屏幕")
        }
        annotationToolbar.onExtractText = { [weak self] in self?.recognize(translate: false) }
        annotationToolbar.onTranslate = { [weak self] in self?.recognize(translate: true) }
        annotationToolbar.onTranslationTargetChange = { [weak self] in self?.translationTarget = $0 }
        annotationToolbar.onScanBarcode = { [weak self] in self?.scanBarcode() }
        annotationToolbar.onShare = { [weak self] in self?.shareImage() }
        annotationToolbar.onFinish = { [weak self] in self?.canvas.finishEditing(); self?.canvas.selectTool(nil) }
        annotationToolbar.onCancel = { [weak self] in self?.close() }
        annotationToolbar.onSizeChange = { [weak self] in self?.layoutContent() }
        editorChanged()
    }

    private func editorChanged() {
        if !canvas.selectedIDs.isEmpty { annotationToolbar.updateSelection(kind: canvas.styleKind, style: canvas.currentStyle, drawingTool: canvas.tool) }
        else if let kind = canvas.tool { annotationToolbar.select(kind, style: canvas.currentStyle) }
        else { annotationToolbar.selectMode() }
        annotationToolbar.updateUndoState(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
        if lastReportedAnnotations != canvas.annotations {
            lastReportedAnnotations = canvas.annotations
            onDocumentChange?(image, canvas.annotations)
        }
    }

    private func layoutContent() {
        guard let contentView else { return }
        let bounds = contentView.bounds
        let barHeight = annotationToolbar.frame.height + 12
        toolbarScroll.frame = NSRect(x: 0, y: max(0, bounds.height - barHeight), width: bounds.width, height: barHeight)
        annotationToolbar.frame.origin = CGPoint(x: 0, y: 0)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
    }

    func flattenedImage() -> CGImage? {
        canvas.finishEditing()
        return AnnotationExport.flatten(base: image,
            cropRectPx: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            annotations: canvas.annotations, scale: scale)
    }

    private func copyImage() {
        guard let image = flattenedImage() else { annotationToolbar.showMessage("无法合成图像"); return }
        annotationToolbar.showMessage(ClipboardService.copyToPasteboard(image, scale: scale) ? "图像已复制" : "复制失败，请重试")
    }

    private func saveImage() {
        guard let image = flattenedImage(), let data = ImageOutput.pngData(from: image) else {
            annotationToolbar.showMessage("无法合成图像")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImageOutput.defaultFileName()
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.annotationToolbar.showMessage("图像已保存")
            } catch { self?.annotationToolbar.showMessage("保存失败，\(error.localizedDescription)") }
        }
    }

    private func quickSave() {
        guard let image = flattenedImage(), let data = ImageOutput.pngData(from: image) else { return }
        let directory = SettingsStore().load().quickSaveDirectory
        let store = directory.map { QuickSaveStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? QuickSaveStore()
        do { _ = try store.write(data); annotationToolbar.showMessage("图像已保存") }
        catch { annotationToolbar.showMessage("保存失败，\(error.localizedDescription)") }
    }

    private func recognize(translate: Bool) {
        guard let image = flattenedImage() else { annotationToolbar.showMessage("无法合成图像"); return }
        onRecognize?(image, scale, translate, self)
    }

    private func scanBarcode() {
        guard let image = flattenedImage() else { return }
        barcodeTask?.cancel()
        annotationToolbar.showBusy("识别中…")
        barcodeTask = Task { [weak self] in
            let payload = await Task.detached { BarcodeScanner.scanFirstPayload(in: image) }.value
            guard !Task.isCancelled, let self else { return }
            self.annotationToolbar.hideBusy()
            if let payload, ClipboardService.copyString(payload) { self.annotationToolbar.showMessage("识别码已复制") }
            else { self.annotationToolbar.showMessage("未识别到二维码或条形码") }
        }
    }

    private func shareImage() {
        guard let image = flattenedImage() else { return }
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))])
        sharePicker = picker
        picker.show(relativeTo: annotationToolbar.bounds, of: annotationToolbar, preferredEdge: .minY)
    }

    override func keyDown(with event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if event.modifierFlags.contains(.command), key == "s" { saveImage(); return }
        if event.modifierFlags.contains(.command), key == "c" { copyImage(); return }
        super.keyDown(with: event)
    }

    override func close() {
        canvas.finishEditing()
        barcodeTask?.cancel()
        onDocumentChange?(image, canvas.annotations)
        onClose?()
        super.close()
    }
}

@MainActor
private final class ScrollResultContainer: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onLayout?() }
}
