import AppKit
import CoreGraphics
import Foundation
import IineCore

private actor ScrollFixtureCapturer: ScrollFrameCapturing {
    private var frame: CGImage
    private(set) var captureCount = 0

    init(frame: CGImage) { self.frame = frame }
    func setFrame(_ frame: CGImage) { self.frame = frame }
    func capture(globalRect: CGRect) async -> CGImage? {
        captureCount += 1
        return frame
    }
}

private actor WorkbenchRecognitionGate {
    private let result: TextRecognitionResult
    private var isOpen = false
    private var pending: [CheckedContinuation<TextRecognitionResult, Never>] = []

    init(result: TextRecognitionResult) { self.result = result }

    func recognize() async -> TextRecognitionResult {
        if isOpen { return result }
        return await withCheckedContinuation { pending.append($0) }
    }

    func allowRecognition() {
        isOpen = true
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: result) }
    }
}

@MainActor
private final class RewriteServiceFixture {
    struct Call {
        let text: String
        let options: RewriteOptions
    }

    var calls: [Call] = []
    var replies: [CheckedContinuation<String, Never>] = []
    var failure: TranslationError?
    var completed = 0

    func rewrite(_ text: String, options: RewriteOptions) async throws -> String {
        calls.append(Call(text: text, options: options))
        if let failure { throw failure }
        let result = await withCheckedContinuation { replies.append($0) }
        completed += 1
        return result
    }

    func finishPending() {
        let pending = replies
        replies.removeAll()
        for reply in pending { reply.resume(returning: "测试结束后的迟到结果") }
    }
}

@MainActor
private final class UXHarness {
    private var passes = 0
    private var failures = 0
    private let evidence = URL(fileURLWithPath: "/tmp/iine-verify/evidence/ux", isDirectory: true)

    private struct Missing: Error { let description: String }

    private func check(_ condition: Bool, _ name: String) {
        if condition {
            passes += 1
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    private func require<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw Missing(description: description) }
        return value
    }

    private func test(_ name: String, _ body: () throws -> Void) {
        do { try body() }
        catch {
            failures += 1
            print("FAIL \(name) \(error)")
        }
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        var result: [T] = []
        if let matchingView = view as? T { result.append(matchingView) }
        for child in view.subviews { result.append(contentsOf: descendants(child, as: type)) }
        return result
    }

    private func button(_ view: NSView, title: String) throws -> NSButton {
        try require(descendants(view, as: NSButton.self).first { $0.title == title || $0.toolTip == title }, "找不到按钮 \(title)")
    }

    private func image(width: Int = 1000, height: Int = 740) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in stride(from: 0, to: height, by: 32) {
            context.setFillColor(CGColor(gray: row % 64 == 0 ? 0.82 : 0.90, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 14))
        }
        return context.makeImage()!
    }

    private func host(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 120, y: 100), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func mouse(_ view: NSView, type: NSEvent.EventType, point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    private func click(_ view: NSView, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        view.mouseDown(with: mouse(view, type: .leftMouseDown, point: point, modifiers: modifiers, clicks: clicks))
        view.mouseUp(with: mouse(view, type: .leftMouseUp, point: point, modifiers: modifiers, clicks: clicks))
    }

    private func drag(_ view: NSView, from start: CGPoint, to end: CGPoint,
                      modifiers: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(view, type: .leftMouseDown, point: start, modifiers: modifiers))
        for index in 1...6 {
            let amount = CGFloat(index) / 6
            let point = CGPoint(x: start.x + (end.x - start.x) * amount, y: start.y + (end.y - start.y) * amount)
            view.mouseDragged(with: mouse(view, type: .leftMouseDragged, point: point, modifiers: modifiers))
        }
        view.mouseUp(with: mouse(view, type: .leftMouseUp, point: end, modifiers: modifiers))
    }

    private func key(_ view: NSView, code: UInt16, text: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    @discardableResult
    private func render(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        var rendered: NSBitmapImageRep?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.displayIfNeeded()
            rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            if let rendered { view.cacheDisplay(in: view.bounds, to: rendered) }
        }
        let representation = try require(rendered, "无法创建渲染缓冲")
        let png = try require(representation.representation(using: .png, properties: [:]), "无法导出PNG")
        try png.write(to: evidence.appendingPathComponent(name + ".png"))
        return representation
    }

    private func chooseTool(_ toolbar: AnnotateToolbar, _ kind: ShapeKind) throws {
        let toolButton = try require(toolbar.toolButtons[kind], "工具缺失 \(kind)")
        if !toolButton.isHidden {
            toolButton.performClick(nil)
            return
        }
        let menuTitle: String
        switch kind {
        case .rect, .roundedRect, .ellipse: menuTitle = "展开形状"
        case .line, .arrow, .polyline: menuTitle = "展开线条"
        case .brush, .marker: menuTitle = "展开画笔"
        case .mosaicRect, .mosaic, .blur: menuTitle = "展开打码"
        default: menuTitle = "更多工具与操作"
        }
        try button(toolbar, title: menuTitle).performClick(nil)
        let choices = try require(toolbar.choicePopover?.contentViewController?.view as? ToolbarChoiceView, "工具菜单未打开")
        let title = try require(ShapeCatalog.entry(for: kind)?.title, "工具名称缺失")
        let index = try require(choices.items.firstIndex { $0.title == title }, "菜单中缺少 \(title)")
        choices.buttons[index].performClick(nil)
    }

    private func chooseColor(_ toolbar: AnnotateToolbar) throws -> RGBAColor {
        toolbar.colorButton.performClick(nil)
        let palette = try require(toolbar.colorPopover?.contentViewController?.view as? ColorPaletteView, "颜色面板未打开")
        let index = try require(palette.model.colors.indices.first {
            palette.model.colors[$0] != toolbar.currentStyle.color
        }, "调色板没有替代颜色")
        let expected = palette.model.colors[index]
        palette.swatches[index].performClick(nil)
        return expected
    }

    private func captureEditing() throws {
        let shot = DisplayShot(displayID: 9999, image: image(), bounds: CGRect(x: 0, y: 0, width: 1000, height: 740), scale: 1)
        let view = OverlayView(shot: shot)
        let window = host(view, size: shot.bounds.size)
        defer { window.close() }
        drag(view, from: CGPoint(x: 80, y: 170), to: CGPoint(x: 900, y: 650))
        let toolbar = try require(descendants(view, as: AnnotateToolbar.self).first, "截图工具条未显示")
        try chooseTool(toolbar, .rect)
        drag(view, from: CGPoint(x: 160, y: 260), to: CGPoint(x: 360, y: 400))
        let before = try require(view.annotations.first, "矩形未创建")
        let activeCanvas = try require(descendants(view, as: AnnotationCanvas.self).first, "标注画布缺失")
        check(activeCanvas.tool == .rect && toolbar.toolButtons[.rect]?.isSelected == true
              && !toolbar.selectButton.isSelected,
              "TOOLBAR 创建后选中对象时仍准确显示当前绘图工具")
        toolbar.selectButton.performClick(nil)
        click(view, at: CGPoint(x: 160, y: 320))
        let expected = try chooseColor(toolbar)
        check(view.annotations.first?.style.color == expected, "CAPTURE 选中已有矩形后改色")
        toolbar.undoButton.performClick(nil)
        check(view.annotations.first == before, "CAPTURE 撤销改色保留矩形")
        toolbar.redoButton.performClick(nil)
        check(view.annotations.first?.style.color == expected, "CAPTURE 重做恢复颜色")

        try chooseTool(toolbar, .arrow)
        let arrow = try require(toolbar.toolButtons[.arrow], "箭头按钮缺失")
        arrow.mouseEntered(with: mouse(arrow, type: .mouseMoved, point: CGPoint(x: 10, y: 10)))
        arrow.mouseExited(with: mouse(arrow, type: .mouseMoved, point: CGPoint(x: -1, y: -1)))
        check(arrow.isSelected && (arrow.layer?.backgroundColor?.alpha ?? 0) > 0, "TOOLBAR 鼠标离开后保留工具选中态")
        let stateIconColors = try [toolbar.penButton, toolbar.lineStyleButton].map {
            try resolvedColor($0.contentTintColor ?? .labelColor, for: $0)
        }
        check(stateIconColors.allSatisfy { luminance($0) < 0.2 },
              "TOOLBAR 状态图标在浅色工具栏上使用深色")
        check(toolbar.frame.width < 900, "TOOLBAR 收纳后适合常见窗口宽度")
        check(arrow.frame.width >= 34 && (arrow.image?.size.width ?? 0) >= 20, "TOOLBAR 图标及点击区域放大")
        try render(toolbar, name: "capture-toolbar")

        let dropdown = try button(toolbar, title: "展开形状")
        dropdown.performClick(nil)
        let choices = try require(toolbar.choicePopover?.contentViewController?.view as? ToolbarChoiceView, "工具族菜单未打开")
        let ellipseIndex = try require(choices.items.firstIndex { $0.title == "椭圆" }, "工具族中缺少椭圆")
        choices.buttons[ellipseIndex].performClick(nil)
        check(toolbar.selectedKind == .ellipse && toolbar.toolButtons[.ellipse]?.isHidden == false,
              "TOOLBAR 从工具族直接选择椭圆")
        drag(view, from: CGPoint(x: 480, y: 260), to: CGPoint(x: 680, y: 400))
        check(view.annotations.last?.shape.kind == .ellipse, "CAPTURE 分组菜单选择作用于实际画布")
        try render(view, name: "capture-editing")
    }

    private func makeEditor() -> (NSWindow, AnnotationCanvas, AnnotateToolbar) {
        let canvas = AnnotationCanvas(base: image(width: 700, height: 500), cropOriginPx: .zero,
            scale: 1, initialStyle: ShapeCatalog.entry(for: .rect)!.defaultStyle)
        canvas.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        canvas.drawsBaseImage = true
        canvas.receivesEvents = true
        let toolbar = AnnotateToolbar(initialKind: .rect, initialStyle: canvas.currentStyle, context: .imageEditor)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 610))
        container.addSubview(canvas)
        container.addSubview(toolbar)
        toolbar.frame.origin = CGPoint(x: 5, y: 515)
        toolbar.onSelectTool = { [weak canvas] in canvas?.selectTool($0) }
        toolbar.onSelectMode = { [weak canvas] in canvas?.selectTool(nil) }
        toolbar.onStyleChange = { [weak canvas] in canvas?.applyStyle($0) }
        toolbar.onStylePropertyChange = { [weak canvas] style, attribute in
            canvas?.applyStyle(style, changed: attribute)
        }
        toolbar.onUndo = { [weak canvas] in canvas?.undo() }
        toolbar.onRedo = { [weak canvas] in canvas?.redo() }
        canvas.onChange = { [weak canvas, weak toolbar] in
            guard let canvas, let toolbar else { return }
            if canvas.selectedIDs.isEmpty {
                toolbar.select(canvas.styleKind, style: canvas.currentStyle)
                if canvas.tool == nil { toolbar.selectMode() }
            } else {
                toolbar.updateSelection(kind: canvas.styleKind, style: canvas.currentStyle, drawingTool: canvas.tool)
            }
            toolbar.updateUndoState(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
        }
        return (host(container, size: container.frame.size), canvas, toolbar)
    }

    private func mixedSelectionStyle() throws {
        let shot = DisplayShot(displayID: 9998, image: image(), bounds: CGRect(x: 0, y: 0, width: 1000, height: 740), scale: 1)
        let view = OverlayView(shot: shot)
        let window = host(view, size: shot.bounds.size)
        defer { window.close() }
        drag(view, from: CGPoint(x: 80, y: 170), to: CGPoint(x: 900, y: 650))
        let toolbar = try require(descendants(view, as: AnnotateToolbar.self).first, "截图工具条缺失")
        try chooseTool(toolbar, .rect)
        drag(view, from: CGPoint(x: 160, y: 260), to: CGPoint(x: 330, y: 400))
        let firstColor = try require(view.annotations.first?.style.color, "首个矩形缺失")
        try chooseTool(toolbar, .rect)
        let secondColor = try chooseColor(toolbar)
        toolbar.colorButton.performClick(nil)
        let palette = try require(toolbar.colorPopover?.contentViewController?.view as? ColorPaletteView, "透明度面板未打开")
        palette.alphaSwatches[1].performClick(nil)
        toolbar.colorPopover?.close()
        drag(view, from: CGPoint(x: 490, y: 260), to: CGPoint(x: 660, y: 400))
        check(view.annotations.count == 2 && view.annotations[0].style.color != view.annotations[1].style.color,
              "MULTI 建立不同颜色与透明度的两个对象")
        toolbar.selectButton.performClick(nil)
        click(view, at: CGPoint(x: 160, y: 320))
        click(view, at: CGPoint(x: 490, y: 320), modifiers: .shift)
        toolbar.colorButton.performClick(nil)
        let colors = try require(toolbar.colorPopover?.contentViewController?.view as? ColorPaletteView, "多选调色板未打开")
        let firstIndex = try require(colors.model.colors.firstIndex { $0.r == firstColor.r && $0.g == firstColor.g && $0.b == firstColor.b }, "调色板缺少原颜色")
        colors.swatches[firstIndex].performClick(nil)
        check(view.annotations.allSatisfy { $0.style.color.r == firstColor.r && $0.style.color.g == firstColor.g && $0.style.color.b == firstColor.b },
              "MULTI 点击首对象已有颜色仍统一所有选中对象")
        toolbar.undoButton.performClick(nil)
        check(view.annotations[0].style.color == firstColor && view.annotations[1].style.color.r == secondColor.r,
              "MULTI 撤销改色恢复各对象原有颜色")
        toolbar.colorButton.performClick(nil)
        let opacity = try require(toolbar.colorPopover?.contentViewController?.view as? ColorPaletteView, "多选透明度面板未打开")
        opacity.alphaSwatches[0].performClick(nil)
        toolbar.colorPopover?.close()
        check(view.annotations.allSatisfy { $0.style.color.a == 1 }, "MULTI 点击首对象已有透明度仍统一所有选中对象")
        check(view.annotations[0].style.color.r == firstColor.r && view.annotations[1].style.color.r == secondColor.r,
              "MULTI 改透明度保留各对象不同颜色")
    }

    private func textAndSelection() throws {
        let (window, canvas, toolbar) = makeEditor()
        defer { window.close() }
        try chooseTool(toolbar, .text)
        click(canvas, at: CGPoint(x: 160, y: 220))
        let editor = try require(descendants(canvas, as: NSTextView.self).first, "文字工具未打开输入框")
        editor.insertText("中文标注", replacementRange: NSRange(location: 0, length: 0))
        key(editor, code: 36, text: "\r", modifiers: .command)
        let original = try require(canvas.annotations.first, "文字没有提交")
        guard case .text(let value, _, _, _) = original.shape else { throw Missing(description: "输出不是文字标注") }
        check(value == "中文标注", "TEXT 中文文字通过输入框创建")
        let geometry = try require(original.shape.textGeometry, "文字几何缺失")
        let rotate = geometry.point(for: .rotate)
        let target = CGPoint(x: geometry.center.x + 60, y: geometry.center.y + 20)
        drag(canvas, from: rotate, to: target)
        let rotated = try require(canvas.annotations.first, "旋转后文字丢失")
        check(rotated.shape != original.shape, "TEXT 拖动旋转控制点改变文字方向")
        toolbar.undoButton.performClick(nil)
        check(canvas.annotations.first == original, "TEXT 撤销旋转恢复原角度")
        toolbar.redoButton.performClick(nil)
        check(canvas.annotations.first == rotated, "TEXT 重做恢复旋转")
        key(canvas, code: 51, text: "\u{7f}")
        check(canvas.annotations.isEmpty, "SELECTION 删除选中文字")
        toolbar.undoButton.performClick(nil)
        check(canvas.annotations.first == rotated, "SELECTION 撤销删除恢复文字")
        try render(canvas, name: "text-rotation")
    }

    private func textAtSelectionEdge() throws {
        let shot = DisplayShot(displayID: 9997, image: image(), bounds: CGRect(x: 0, y: 0, width: 1000, height: 740), scale: 1)
        let view = OverlayView(shot: shot)
        let window = host(view, size: shot.bounds.size)
        defer { window.close() }
        drag(view, from: CGPoint(x: 80, y: 170), to: CGPoint(x: 900, y: 650))
        let toolbar = try require(descendants(view, as: AnnotateToolbar.self).first, "截图工具条缺失")
        let canvas = try require(descendants(view, as: AnnotationCanvas.self).first, "截图标注画布缺失")
        try chooseTool(toolbar, .text)
        click(view, at: CGPoint(x: 250, y: view.selectionRect.maxY - 12))
        let editor = try require(descendants(canvas, as: NSTextView.self).first, "贴边文字输入框未出现")
        editor.insertText("贴边旋转", replacementRange: NSRange(location: 0, length: 0))
        key(editor, code: 36, text: "\r", modifiers: .command)
        let original = try require(view.annotations.first, "贴边文字未提交")
        let geometry = try require(original.shape.textGeometry, "贴边文字几何缺失")
        let handle = geometry.point(for: .rotate)
        check(handle.y > canvas.canvasSize.height, "TEXT-EDGE 旋转手柄位于截图选区之外")
        let target = CGPoint(x: geometry.center.x + 70, y: geometry.center.y + 12)
        drag(view, from: canvas.convert(handle, to: view), to: canvas.convert(target, to: view))
        check(view.annotations.count == 1 && view.annotations.first?.id == original.id
              && view.annotations.first?.shape != original.shape,
              "TEXT-EDGE 选区外手柄旋转原文字且不创建新对象")
        toolbar.undoButton.performClick(nil)
        check(view.annotations == [original], "TEXT-EDGE 撤销贴边文字旋转")
    }

    private func recognitionReturnToEditing() throws {
        let shot = DisplayShot(displayID: 9996, image: image(), bounds: CGRect(x: 0, y: 0, width: 1000, height: 740), scale: 1)
        let view = OverlayView(shot: shot)
        let window = host(view, size: shot.bounds.size)
        defer { window.close() }
        drag(view, from: CGPoint(x: 80, y: 170), to: CGPoint(x: 900, y: 650))
        let toolbar = try require(descendants(view, as: AnnotateToolbar.self).first, "截图工具条缺失")
        try chooseTool(toolbar, .arrow)
        drag(view, from: CGPoint(x: 180, y: 280), to: CGPoint(x: 390, y: 430))
        let annotations = view.annotations
        guard !annotations.isEmpty else { throw Missing(description: "返回编辑测试未创建标注") }
        let selection = view.selectionRect
        let result = TextRecognitionResult(blocks: [RecognizedTextBlock(text: "识别文字",
            bounds: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3), confidence: 0.99)])
        var reselectCount = 0
        let panel = RecognitionResultWindow(image: image(width: 600, height: 200), scale: 1, mode: .text,
            target: .auto, translator: { _, _ in "unused" }, recognizer: { _ in result })
        panel.onReselect = {
            reselectCount += 1
            view.reselectRegion()
        }
        defer { panel.close() }
        panel.show(relativeTo: window)
        let content = try require(panel.window?.contentView, "识别面板内容缺失")
        try button(content, title: "返回编辑").performClick(nil)
        check(view.selectionRect == selection && view.annotations == annotations,
              "RECOGNITION 返回编辑保留截图选区及标注")
        check(reselectCount == 0 && panel.window?.isVisible == false,
              "RECOGNITION 返回编辑只关闭结果面板")

        let reselectPanel = RecognitionResultWindow(image: image(width: 600, height: 200), scale: 1, mode: .text,
            target: .auto, translator: { _, _ in "unused" }, recognizer: { _ in result })
        reselectPanel.onReselect = {
            reselectCount += 1
            view.reselectRegion()
        }
        defer { reselectPanel.close() }
        reselectPanel.show(relativeTo: window)
        let reselectContent = try require(reselectPanel.window?.contentView, "重新框选面板内容缺失")
        try button(reselectContent, title: "重新框选").performClick(nil)
        check(view.selectionRect.isEmpty && view.annotations.isEmpty,
              "RECOGNITION 显式重新框选才清空原选区")
        check(reselectCount == 1 && reselectPanel.window?.isVisible == false,
              "RECOGNITION 重新框选关闭面板并执行一次回调")
    }

    private func editableHistoryReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iine-ux-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory)
        let source = image(width: 800, height: 1600)
        let item = Annotation(shape: .arrow(from: CGPoint(x: 150, y: 1300), to: CGPoint(x: 350, y: 1450)),
            style: Style(color: RGBAColor.palette[0], pen: .p3))
        let flattened = try require(AnnotationExport.flatten(base: source,
            cropRectPx: CGRect(x: 0, y: 0, width: source.width, height: source.height),
            annotations: [item], scale: 1), "长图历史合成失败")
        try store.append(CaptureHistoryEntry(image: flattened, displaySize: CGSize(width: 800, height: 1600),
            editingImage: source, annotations: [item]))
        let controller = SnipController(historyStore: store)
        let suite = "iine-ux-history-settings-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "无法建立独立设置")
        controller.settingsStore = SettingsStore(defaults: defaults)
        let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        defer {
            controller.cancel()
            let owned = NSApp.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) }
            for window in owned { window.close() }
            defaults.removePersistentDomain(forName: suite)
        }
        controller.startReplayingHistory(at: 0)
        let result = try require(NSApp.windows.compactMap { $0 as? ScrollResultWindow }.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        }, "长图历史没有打开结果窗口")
        check(result.annotations == [item], "HISTORY 回放保留单份可编辑标注")
        controller.startReplayingHistory(at: 0)
        let visibleResults = NSApp.windows.compactMap { $0 as? ScrollResultWindow }.filter {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        }
        check(visibleResults.count == 1 && visibleResults.first === result,
              "HISTORY 重复打开同一记录复用已有窗口")

        guard ScreenCaptureService.hasPermission() else {
            throw Missing(description: "历史翻页回归需要当前测试进程具有屏幕录制权限")
        }
        controller.startWhiteboard(background: .solid(.white), activeScreen: true)
        let overlays = NSApp.windows.compactMap { $0 as? SnipOverlayWindow }.filter { $0.isVisible }
        let overlay = try require(overlays.first?.contentView as? OverlayView, "白板截图覆盖层未创建")
        check(controller.isActive && !overlays.isEmpty, "HISTORY 建立截图覆盖层后回放已开长图")
        key(overlay, code: 47, text: ".")
        check(!controller.isActive && overlays.allSatisfy { !$0.isVisible } && result.isVisible,
              "HISTORY 历史快捷键回放先关闭覆盖层再激活原长图")

        try chooseTool(result.annotationToolbar, .rect)
        drag(result.canvas, from: CGPoint(x: 450, y: 1280), to: CGPoint(x: 650, y: 1410))
        let updated = result.annotations
        check(updated.count == 2, "HISTORY 回放后继续编辑长图")
        result.close()
        await controller.waitForHistoryPersistence()
        let persisted = try store.load()
        check(persisted.count == 1 && persisted.first?.annotations == updated
              && persisted.first?.editingImage?.height == source.height,
              "HISTORY 关闭后只保存一份最新标注和原图，记录数 \(persisted.count)，标注数 \(persisted.map { $0.annotations.count })，原图高度 \(persisted.first?.editingImage?.height ?? 0)，内容一致 \(persisted.first?.annotations == updated)")
        controller.startReplayingHistory(at: 0)
        let reopened = try require(NSApp.windows.compactMap { $0 as? ScrollResultWindow }.first {
            !previousWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        }, "关闭后的长图历史未能重新打开")
        check(reopened !== result && reopened.annotations == updated,
              "HISTORY 重新打开恢复最新可编辑内容")
    }

    private func drawingAndTransform() throws {
        let (window, canvas, toolbar) = makeEditor()
        defer { window.close() }
        for (index, kind) in [ShapeKind.arrow, .brush, .mosaicRect, .blur].enumerated() {
            try chooseTool(toolbar, kind)
            let x = CGFloat(60 + index * 140)
            drag(canvas, from: CGPoint(x: x, y: 100), to: CGPoint(x: x + 90, y: 180))
            check(canvas.annotations.last?.shape.kind == kind, "DRAW \(kind) 由工具条进入并绘制")
        }
        toolbar.selectButton.performClick(nil)
        click(canvas, at: CGPoint(x: 105, y: 140))
        let before = try require(canvas.annotations.first, "箭头缺失")
        drag(canvas, from: CGPoint(x: 105, y: 140), to: CGPoint(x: 135, y: 170))
        check(canvas.annotations.first?.shape == before.shape.translated(by: CGPoint(x: 30, y: 30)), "SELECTION 移动已有箭头")
        toolbar.undoButton.performClick(nil)
        check(canvas.annotations.first == before, "SELECTION 撤销移动")

        let originalCount = canvas.annotations.count
        try chooseTool(toolbar, .rect)
        canvas.logicalSize = CGSize(width: 700, height: 500)
        canvas.displayTransform = CGAffineTransform(a: 0, b: 0.5, c: -0.5, d: 0, tx: 350, ty: 30)
        let start = CGPoint(x: 340, y: 260)
        let end = CGPoint(x: 500, y: 380)
        drag(canvas, from: start.applying(canvas.displayTransform), to: end.applying(canvas.displayTransform))
        check(canvas.annotations.count == originalCount + 1 && canvas.annotations.last?.shape == .rect(CGRect(x: 340, y: 260, width: 160, height: 120)),
              "TRANSFORM 缩放旋转显示下仍使用原图坐标")
        try render(canvas, name: "transformed-editor")
    }

    private func pinEditing() throws {
        guard let screen = NSScreen.main else { throw Missing(description: "没有屏幕") }
        let source = image(width: 2400, height: 1200)
        let item = Annotation(shape: .arrow(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 1200, y: 700)),
            style: Style(color: RGBAColor.palette[0], pen: .p4))
        let window = PinWindow(pasteImage: PasteImage(image: source, pointSize: CGSize(width: 2400, height: 1200), annotations: [item]),
            pinID: 9001, screen: screen, cascadeIndex: 0)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let content = try require(window.contentView, "贴图没有内容")
        content.layoutSubtreeIfNeeded()
        check(window.annotations == [item], "PIN 导入大图保留可编辑箭头及原始坐标")
        let pinToolbar = try require(descendants(content, as: PinToolbar.self).first, "贴图工具条缺失")
        try button(pinToolbar, title: "标注").performClick(nil)
        let canvas = try require(descendants(content, as: AnnotationCanvas.self).first, "贴图未使用共享编辑画布")
        let bars = (window.childWindows ?? []).flatMap { child -> [AnnotateToolbar] in
            guard let view = child.contentView else { return [] }
            return descendants(view, as: AnnotateToolbar.self)
        }
        let toolbar = try require(bars.first ?? descendants(content, as: AnnotateToolbar.self).first, "贴图未显示共享工具条")
        toolbar.selectButton.performClick(nil)
        click(canvas, at: CGPoint(x: 900, y: 550).applying(canvas.displayTransform))
        let color = try chooseColor(toolbar)
        check(window.annotations.first?.style.color == color, "PIN 大图适配后选中并修改原有箭头")
        let after = window.annotations
        key(canvas, code: 6, text: "z", modifiers: .command)
        check(window.annotations.first?.style == item.style, "PIN ⌘Z 撤销已有对象样式")
        key(canvas, code: 6, text: "z", modifiers: [.command, .shift])
        check(window.annotations == after, "PIN ⌘⇧Z 重做已有对象样式")
        let rendered = try require(window.flattenedImage(), "贴图导出失败")
        check(rendered.width == source.width && rendered.height == source.height, "PIN 大图导出保持原始分辨率")
        window.rotate(byQuarterTurns: 1)
        let rotated = try require(window.flattenedImage(), "旋转贴图导出失败")
        check(rotated.width == source.height && rotated.height == source.width && window.annotations == after,
              "PIN 整图旋转保持标注坐标并正确导出尺寸")
        try render(content, name: "pin-editing")
    }

    private func scrollEditing() throws {
        let window = ScrollResultWindow(image: image(width: 800, height: 1600), scale: 1)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let content = try require(window.contentView, "长图没有内容")
        let toolbar = try require(descendants(content, as: AnnotateToolbar.self).first, "长图未使用共享工具条")
        let canvas = try require(descendants(content, as: AnnotationCanvas.self).first, "长图未使用共享编辑画布")
        try chooseTool(toolbar, .mosaicRect)
        drag(canvas, from: CGPoint(x: 150, y: 1380), to: CGPoint(x: 450, y: 1480))
        check(canvas.annotations.last?.shape.kind == .mosaicRect, "SCROLL 长图可使用区域马赛克")
        check(toolbar.undoButton.isEnabled, "SCROLL 绘制后撤销立即可用")
        let items = canvas.annotations
        toolbar.undoButton.performClick(nil)
        check(canvas.annotations.isEmpty && toolbar.redoButton.isEnabled, "SCROLL 撤销后重做可用")
        toolbar.redoButton.performClick(nil)
        check(canvas.annotations == items, "SCROLL 重做恢复标注")
        try chooseTool(toolbar, .text)
        click(canvas, at: CGPoint(x: 200, y: 1270))
        let editor = try require(descendants(canvas, as: NSTextView.self).first, "长图文字输入框未出现")
        editor.insertText("长图文字", replacementRange: NSRange(location: 0, length: 0))
        key(editor, code: 36, text: "\r", modifiers: .command)
        check(canvas.annotations.last?.shape.kind == .text, "SCROLL 长图可创建文字标注")
        try render(content, name: "scroll-editing")
    }

    private func scrollCaptureRecovery() async throws {
        let width = 320
        let height = 900
        var seed: UInt32 = 7
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let base = Int((seed >> 16) % 180)
            for x in 0..<width {
                let value = UInt8(clamping: base + ((x / 3) % 7) * 5)
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try require(CGDataProvider(data: Data(pixels) as CFData), "无法创建滚动样本")
        let page = try require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), "无法生成滚动样本")
        let first = try require(page.cropping(to: CGRect(x: 0, y: 0, width: width, height: 400)), "首帧缺失")
        let second = try require(page.cropping(to: CGRect(x: 0, y: 60, width: width, height: 400)), "第二帧缺失")
        let third = try require(page.cropping(to: CGRect(x: 0, y: 120, width: width, height: 400)), "第三帧缺失")
        let capturer = ScrollFixtureCapturer(frame: second)
        let controller = ScrollCaptureController(capturer: capturer,
            globalRect: CGRect(x: 0, y: 0, width: width, height: 400), interval: 0.03)
        let screen = try require(NSScreen.main, "滚动预览需要显示器")
        let preview = ScrollCapturePreview(selection: CGRect(x: 100, y: 100, width: 320, height: 400),
            screen: screen, level: .normal)
        defer { controller.cancel(); preview.close() }
        let content = try require(preview.contentView, "滚动预览缺失")
        var latest = first
        var finished: CGImage?
        var finishCount = 0
        var cancelCount = 0
        controller.onUpdate = { update in
            latest = update.image
            preview.update(image: update.image, frames: update.frameCount, pixelSize: update.pixelSize)
        }
        controller.onFinish = { finished = $0 }
        preview.onTogglePause = {
            if controller.isPaused { controller.resume() } else { controller.pause() }
            preview.setPaused(controller.isPaused)
        }
        preview.onFinish = { finishCount += 1; controller.finish() }
        preview.onCancel = { cancelCount += 1; controller.cancel() }
        preview.orderFrontRegardless()
        controller.start(firstFrame: first)
        check(await waitUntil { latest.height == 460 }, "SCROLL-CAPTURE 定时抓帧拼接新增内容，实际高度 \(latest.height)")
        try button(content, title: "暂停").performClick(nil)
        check(controller.isPaused, "SCROLL-CAPTURE 预览暂停按钮暂停捕获")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let pausedCount = await capturer.captureCount
        await capturer.setFrame(third)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(await capturer.captureCount == pausedCount, "SCROLL-CAPTURE 暂停期间停止抓帧")
        check(latest.height == 460, "SCROLL-CAPTURE 暂停保留已经拼接的长图，实际高度 \(latest.height)")
        try render(content, name: "scroll-preview-paused")
        try button(content, title: "继续").performClick(nil)
        check(!controller.isPaused, "SCROLL-CAPTURE 继续按钮恢复捕获")
        check(await waitUntil { latest.height == 520 }, "SCROLL-CAPTURE 恢复后从已有长图继续拼接，实际高度 \(latest.height)")
        try button(content, title: "完成").performClick(nil)
        check(await waitUntil { finishCount == 1 && finished?.height == 520 }, "SCROLL-CAPTURE 完成按钮返回完整长图")
        let result = try require(finished, "滚动完成没有返回图像")
        let expected = try require(page.cropping(to: CGRect(x: 0, y: 0, width: width, height: 520)), "预期长图缺失")
        let actualPixels = rgbaPixels(result)
        let expectedPixels = rgbaPixels(expected)
        let mismatchedBytes = zip(actualPixels, expectedPixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        check(actualPixels == expectedPixels,
              "SCROLL-CAPTURE 暂停恢复前后图像连续且内容完整，不同字节 \(mismatchedBytes)")
        try button(content, title: "取消").performClick(nil)
        check(await waitUntil { cancelCount == 1 }, "SCROLL-CAPTURE 取消按钮发出取消操作")
    }

    private func rgbaPixels(_ image: CGImage) -> Data {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(pixels)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func recognition() async throws {
        let image = image(width: 600, height: 120)
        let recognized = TextRecognitionResult(blocks: [RecognizedTextBlock(text: "Hello world",
            bounds: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.4), confidence: 0.98)])
        var requests: [String] = []
        var replies: [CheckedContinuation<String, Never>] = []
        var completedResponses = 0
        let panel = RecognitionResultWindow(image: image, scale: 1, mode: .translation, target: .zh,
            translator: { text, _ in
                requests.append(text)
                let response = await withCheckedContinuation { replies.append($0) }
                completedResponses += 1
                return response
            }, recognizer: { _ in recognized })
        defer {
            panel.close()
            for reply in replies { reply.resume(returning: "late response") }
        }
        panel.show(relativeTo: nil)
        check(await waitUntil { panel.phase == .translating && requests.count == 1 },
              "RECOGNITION 识别后进入翻译等待")
        panel.window?.makeFirstResponder(panel.sourceTextView)
        panel.sourceTextView.setSelectedRange(NSRange(location: 0, length: (panel.sourceTextView.string as NSString).length))
        panel.sourceTextView.insertText("Edited text", replacementRange: panel.sourceTextView.selectedRange())
        let staleReply = try require(replies.first, "原文编辑前翻译请求未启动")
        replies.removeFirst()
        staleReply.resume(returning: "stale translation")
        guard await waitUntil({ completedResponses == 1 }) else { throw Missing(description: "旧翻译未返回") }
        check(panel.sourceTextView.string == "Edited text" && panel.translatedTextView.string.isEmpty,
              "RECOGNITION 修改原文后丢弃迟到译文，原文 \(panel.sourceTextView.string.debugDescription)，译文 \(panel.translatedTextView.string.debugDescription)")
        let content = try require(panel.window?.contentView, "识别结果窗缺失")
        try button(content, title: "翻译").performClick(nil)
        guard await waitUntil({ requests.count == 2 && !replies.isEmpty }) else {
            throw Missing(description: "重译按钮没有启动请求")
        }
        replies.removeFirst().resume(returning: "译文 Edited text")
        check(await waitUntil { panel.phase == .ready && panel.translatedTextView.string == "译文 Edited text" },
              "RECOGNITION 通过按钮重译编辑后的原文")
        check(requests.last == "Edited text", "RECOGNITION 服务收到用户修正后的原文")
        try render(content, name: "recognition")
        try button(content, title: "翻译").performClick(nil)
        guard await waitUntil({ requests.count == 3 && !replies.isEmpty }) else {
            throw Missing(description: "关闭测试的翻译请求未启动")
        }
        panel.close()
        replies.removeFirst().resume(returning: "late response after close")
        guard await waitUntil({ completedResponses == 3 }) else { throw Missing(description: "关闭后的请求未返回") }
        check(panel.translatedTextView.string.isEmpty, "RECOGNITION 关闭后忽略迟到结果")

        let previous = requests.count
        let cancelled = RecognitionResultWindow(image: image, scale: 1, mode: .translation, target: .auto,
            translator: { text, _ in requests.append(text); return "unexpected" },
            recognizer: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return recognized
            })
        defer { cancelled.close() }
        cancelled.show(relativeTo: nil)
        let cancelledContent = try require(cancelled.window?.contentView, "取消测试窗口缺失")
        try button(cancelledContent, title: "取消任务").performClick(nil)
        try? await Task.sleep(nanoseconds: 160_000_000)
        check(cancelled.phase == .cancelled && cancelled.sourceTextView.string.isEmpty && requests.count == previous,
              "RECOGNITION 取消OCR后不更新原文也不发起翻译")
    }

    private func resolvedColor(_ color: NSColor, for view: NSView) throws -> NSColor {
        var resolved: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try require(resolved, "无法解析控件实际颜色")
    }

    private func backgroundBehind(_ view: NSView) throws -> NSColor {
        if let text = view as? NSTextView, text.drawsBackground {
            return try resolvedColor(text.backgroundColor, for: text)
        }
        var ancestor: NSView? = view
        while let current = ancestor {
            if let color = current.layer?.backgroundColor, color.alpha >= 0.99,
               let background = NSColor(cgColor: color) {
                return try resolvedColor(background, for: current)
            }
            ancestor = current.superview
        }
        return try resolvedColor(view.window?.backgroundColor ?? .windowBackgroundColor, for: view)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let linear = channels.map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }

    private func contrast(_ foreground: NSColor, in view: NSView) throws -> CGFloat {
        let foreground = try resolvedColor(foreground, for: view)
        let background = try backgroundBehind(view)
        let alpha = foreground.alphaComponent
        let composed = NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        let first = luminance(composed)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func verifyWorkbenchAppearance(_ panel: RecognitionResultWindow, name: String) throws {
        let content = try require(panel.window?.contentView, "主题测试缺少工作台内容")
        let representation = try render(content, name: name)
        let pixel = try require(representation.colorAt(x: representation.pixelsWide / 2, y: 4), "无法读取工作台背景像素")
        let brightness = luminance(try resolvedColor(pixel, for: content))
        check(brightness > 0.7,
              "APPEARANCE \(name) 工作台保持浅色背景，亮度 \(String(format: "%.3f", Double(brightness)))")
        let labels = descendants(content, as: NSTextField.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty && $0.bounds.width > 0
        }
        let labelRatios = try labels.map { try contrast($0.textColor ?? .labelColor, in: $0) }
        let lowest = labelRatios.min() ?? 0
        check(!labels.isEmpty && lowest >= 4.5,
              "APPEARANCE \(name) 正文与辅助标签对比度至少4.5，最低 \(String(format: "%.2f", Double(lowest)))")
        let textViews = [panel.sourceTextView, panel.translatedTextView].filter { !$0.isHiddenOrHasHiddenAncestor }
        let textRatios = try textViews.map { try contrast($0.textColor ?? .textColor, in: $0) }
        check(textRatios.allSatisfy { $0 >= 4.5 },
              "APPEARANCE \(name) 编辑区文字保持可读")
    }

    private func recognitionWorkbenchAppearance() async throws {
        let original = "Thoughtful details make everyday work easier."
        let result = TextRecognitionResult(blocks: [RecognizedTextBlock(text: original,
            bounds: CGRect(x: 0.06, y: 0.3, width: 0.88, height: 0.35), confidence: 0.99)])
        let recognitionGate = WorkbenchRecognitionGate(result: result)
        var targets: [TranslationTarget] = []
        var responses: [CheckedContinuation<String, Never>] = []
        var failTranslation = false
        let panel = RecognitionResultWindow(image: image(width: 2400, height: 150), scale: 1,
            mode: .translation, target: .zh,
            translator: { _, target in
                targets.append(target)
                if failTranslation { throw TranslationError.network("连接已中断，请重试") }
                return await withCheckedContinuation { responses.append($0) }
            }, recognizer: { _ in await recognitionGate.recognize() })
        defer {
            panel.close()
            Task { await recognitionGate.allowRecognition() }
            for response in responses { response.resume(returning: "迟到响应") }
        }
        let window = try require(panel.window, "工作台窗口缺失")
        window.appearance = NSAppearance(named: .aqua)
        panel.show(relativeTo: nil)
        let content = try require(window.contentView, "工作台内容缺失")
        let copySource = try button(content, title: "复制文字")
        let copyTranslation = try button(content, title: "复制译文")
        let translate = try button(content, title: "翻译")
        let retry = try button(content, title: "重新识别")
        let cancel = try button(content, title: "取消任务")
        check(panel.phase == .recognizing && !panel.sourceTextView.isEditable
              && !copySource.isEnabled && !copyTranslation.isEnabled && !translate.isEnabled,
              "WORKBENCH 识别期间明确禁用无效操作")
        try render(content, name: "recognition-loading")
        cancel.performClick(nil)
        check(panel.phase == .cancelled && retry.isEnabled && targets.isEmpty,
              "WORKBENCH 取消识别后可重试且没有启动翻译")
        await recognitionGate.allowRecognition()
        retry.performClick(nil)
        guard await waitUntil({ panel.phase == .translating && !responses.isEmpty }) else {
            throw Missing(description: "重新识别后未进入翻译等待")
        }
        check(panel.sourceTextView.isEditable && !translate.isEnabled && !cancel.isHidden,
              "WORKBENCH 翻译等待可取消且原文仍能修改")
        window.appearance = NSAppearance(named: .darkAqua)
        try render(content, name: "recognition-translating-dark")
        responses.removeFirst().resume(returning: "用心的细节，让日常工作更轻松。")
        guard await waitUntil({ panel.phase == .ready && !panel.translatedTextView.string.isEmpty }) else {
            throw Missing(description: "工作台翻译结果未显示")
        }
        check(copySource.isEnabled && copyTranslation.isEnabled && translate.isEnabled,
              "WORKBENCH 成功结果可复制和重译")

        for (appearance, name) in [(NSAppearance.Name.aqua, "recognition-light"),
            (.darkAqua, "recognition-system-dark"), (.aqua, "recognition-light-again")] {
            window.appearance = NSAppearance(named: appearance)
            try verifyWorkbenchAppearance(panel, name: name)
        }

        window.appearance = NSAppearance(named: .darkAqua)
        window.makeFirstResponder(panel.sourceTextView)
        panel.sourceTextView.setSelectedRange(NSRange(location: (panel.sourceTextView.string as NSString).length, length: 0))
        panel.sourceTextView.insertText(" Updated.", replacementRange: panel.sourceTextView.selectedRange())
        check(panel.sourceTextView.string == original + " Updated." && panel.translatedTextView.string.isEmpty,
              "WORKBENCH 切换主题后仍可编辑原文并清除旧译文")

        let target = try require(descendants(content, as: NSPopUpButton.self).first {
            $0.accessibilityLabel() == "目标语言"
        }, "工作台目标语言菜单缺失")
        let englishIndex = try require(TranslationTarget.allCases.firstIndex(of: .en), "英文选项缺失")
        target.selectItem(at: englishIndex)
        target.sendAction(target.action, to: target.target)
        guard await waitUntil({ targets.last == .en && !responses.isEmpty }) else {
            throw Missing(description: "语言菜单未触发对应语言的翻译")
        }
        responses.removeFirst().resume(returning: "Thoughtful details improve everyday work.")
        check(await waitUntil { panel.target == .en && panel.phase == .ready
            && panel.translatedTextView.string == "Thoughtful details improve everyday work." },
              "WORKBENCH 语言菜单直接选择并更新译文")

        let previewToggle = try button(content, title: "截图预览")
        let textScroll = try require(panel.sourceTextView.enclosingScrollView, "原文滚动区缺失")
        content.layoutSubtreeIfNeeded()
        let originalHeight = textScroll.frame.height
        let sourceBefore = panel.sourceTextView.string
        let translationBefore = panel.translatedTextView.string
        previewToggle.performClick(nil)
        content.layoutSubtreeIfNeeded()
        check(abs(textScroll.frame.height - originalHeight) > 20
              && panel.sourceTextView.string == sourceBefore && panel.translatedTextView.string == translationBefore,
              "WORKBENCH 收展截图预览重新分配空间并保留文字")
        previewToggle.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let frameMinimum = NSSize(width: max(window.minSize.width, contentMinimum.width),
            height: max(window.minSize.height, contentMinimum.height))
        window.setFrame(NSRect(origin: window.frame.origin, size: frameMinimum), display: true)
        content.layoutSubtreeIfNeeded()
        check(content.bounds.width <= 681, "WORKBENCH 宽截图不会撑大工作台的最小宽度")
        let visibleControls = descendants(content, as: NSControl.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        let clipped = visibleControls.filter {
            !content.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: content))
        }
        check(clipped.isEmpty, "WORKBENCH 最小窗口下操作控件未被裁切，异常控件 \(clipped.map { String(describing: type(of: $0)) })")
        let textFrames = [panel.sourceTextView, panel.translatedTextView].compactMap { $0.enclosingScrollView?.frame }
        check(textFrames.count == 2 && textFrames.allSatisfy { $0.width >= 160 && $0.height >= 100 },
              "WORKBENCH 最小窗口下原文和译文仍可阅读")
        try render(content, name: "recognition-compact")

        failTranslation = true
        translate.performClick(nil)
        guard await waitUntil({ if case .failed = panel.phase { return true }; return false }) else {
            throw Missing(description: "失败状态没有显示")
        }
        check(panel.sourceTextView.string == sourceBefore && translate.isEnabled && retry.isEnabled,
              "WORKBENCH 翻译错误保留原文并可恢复")
        let error = try require(descendants(content, as: NSTextField.self).first { $0.stringValue.contains("连接已中断") },
            "错误状态缺少可见原因")
        let errorContrast = try contrast(error.textColor ?? .labelColor, in: error)
        check(!error.isHiddenOrHasHiddenAncestor && errorContrast >= 4.5,
              "WORKBENCH 深色外观错误提示可见")
        try render(content, name: "recognition-error")
        window.appearance = NSAppearance(named: .aqua)
        content.layoutSubtreeIfNeeded()
        let lightErrorContrast = try contrast(error.textColor ?? .labelColor, in: error)
        check(lightErrorContrast >= 4.5, "WORKBENCH 浅色外观错误提示可见")
        try render(content, name: "recognition-error-light")

        let darkStart = RecognitionResultWindow(image: image(width: 720, height: 150), scale: 1,
            mode: .text, target: .auto, translator: { _, _ in "unused" }, recognizer: { _ in result })
        defer { darkStart.close() }
        darkStart.window?.appearance = NSAppearance(named: .darkAqua)
        darkStart.show(relativeTo: nil)
        guard await waitUntil({ darkStart.phase == .ready }) else { throw Missing(description: "深色启动识别未完成") }
        try verifyWorkbenchAppearance(darkStart, name: "recognition-system-dark-start")
        check(darkStart.sourceTextView.string == original, "WORKBENCH 深色启动保留识别内容")
    }

    private func rewritingWorkflow() async throws {
        let original = "请在周五前整理项目进展。重点说明已经完成的工作，以及还需要协调的问题。"
        let translated = "Please share the project update by Friday, including completed work and issues that need coordination."
        let rewritten = "请于周五前提交项目进展，说明已完成事项及待协调问题。"
        let recognized = TextRecognitionResult(blocks: [RecognizedTextBlock(text: original,
            bounds: CGRect(x: 0.06, y: 0.2, width: 0.88, height: 0.5), confidence: 0.99)])
        let service = RewriteServiceFixture()
        var translations = 0
        var settingsOpened = 0
        let panel = RecognitionResultWindow(image: image(width: 900, height: 180), scale: 1,
            mode: .text, target: .en,
            translator: { _, _ in translations += 1; return translated },
            rewriter: { text, options in try await service.rewrite(text, options: options) },
            recognizer: { _ in recognized })
        defer { panel.close(); service.finishPending() }
        panel.onOpenSettings = { settingsOpened += 1 }
        panel.show(relativeTo: nil)
        guard await waitUntil({ panel.phase == .ready && panel.sourceTextView.string == original }) else {
            throw Missing(description: "润色测试未取得识别原文")
        }
        let window = try require(panel.window, "润色窗口缺失")
        let content = try require(window.contentView, "润色内容缺失")
        let modes = try require(descendants(content, as: AppModeControl.self).first, "润色模式入口缺失")
        func selectMode(_ mode: RecognitionResultWindow.Mode) {
            modes.selectedSegment = mode.rawValue
            modes.sendAction(modes.action, to: modes.target)
        }
        selectMode(.rewrite)
        let generate = try button(content, title: "润色")
        let copy = try button(content, title: "复制结果")
        let tone = try require(descendants(content, as: NSPopUpButton.self).first {
            $0.accessibilityLabel() == "润色语气"
        }, "润色语气菜单缺失")
        let length = try require(descendants(content, as: NSPopUpButton.self).first {
            $0.accessibilityLabel() == "润色篇幅"
        }, "润色篇幅菜单缺失")
        check(panel.mode == .rewrite && service.calls.isEmpty && generate.isEnabled
              && panel.sourceTextView.string == original && !copy.isEnabled,
              "REWRITE 提取文字可切换润色，先选择要求再生成")
        tone.selectItem(withTitle: "专业")
        tone.sendAction(tone.action, to: tone.target)
        length.selectItem(withTitle: "更简短")
        length.sendAction(length.action, to: length.target)
        try button(content, title: "补充要求").performClick(nil)
        let instruction = try require(descendants(content, as: NSTextField.self).first {
            $0.accessibilityLabel() == "润色补充要求"
        }, "补充要求输入框缺失")
        window.makeFirstResponder(instruction)
        let instructionEditor = try require(instruction.currentEditor() as? NSTextView, "补充要求不能编辑")
        instructionEditor.insertText("写给项目组，保留周五这个时间", replacementRange: NSRange(location: 0, length: 0))
        generate.performClick(nil)
        guard await waitUntil({ !service.replies.isEmpty }) else {
            throw Missing(description: "润色按钮没有发起请求")
        }
        let request = try require(service.calls.first, "润色请求缺失")
        check(request.text == original && request.options == RewriteOptions(tone: .professional, length: .shorter,
              instruction: "写给项目组，保留周五这个时间"),
              "REWRITE 语气、篇幅和真实输入的补充要求提交到服务")
        let cancel = try button(content, title: "取消任务")
        check(panel.phase == .rewriting && panel.sourceTextView.isEditable && !generate.isEnabled
              && !copy.isEnabled && !cancel.isHidden,
              "REWRITE 生成中可编辑原文和取消，禁止重复提交")
        service.replies.removeFirst().resume(returning: rewritten)
        guard await waitUntil({ panel.phase == .ready && panel.translatedTextView.string == rewritten }) else {
            throw Missing(description: "润色结果没有显示")
        }
        check(panel.sourceTextView.string == original && copy.isEnabled,
              "REWRITE 结果与原文并排显示，保留原文")
        let pasteboard = NSPasteboard.general
        let clipboardItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { saved, type in
                if let data = item.data(forType: type) { saved[type] = data }
            }
        }
        defer {
            let items = clipboardItems.map { saved in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        copy.performClick(nil)
        check(pasteboard.string(forType: .string) == rewritten
              && descendants(content, as: NSTextField.self).contains { $0.stringValue == "润色结果已复制" },
              "REWRITE 复制结果写入剪贴板并显示反馈")
        try? await Task.sleep(nanoseconds: 250_000_000)
        try verifyWorkbenchAppearance(panel, name: "rewrite-ready")

        selectMode(.translation)
        guard await waitUntil({ panel.translatedTextView.string == translated && panel.phase == .ready }) else {
            throw Missing(description: "切回翻译未生成译文")
        }
        selectMode(.rewrite)
        check(panel.translatedTextView.string == rewritten && service.calls.count == 1,
              "REWRITE 切回润色保留对应结果，无重复请求")
        selectMode(.translation)
        check(panel.translatedTextView.string == translated && translations == 1,
              "REWRITE 翻译和润色分别保留结果")
        try button(content, title: "润色译文").performClick(nil)
        check(panel.mode == .rewrite && panel.sourceTextView.string == translated
              && panel.translatedTextView.string.isEmpty && service.calls.count == 1,
              "REWRITE 润色译文把译文送入编辑区并等待生成")
        window.makeFirstResponder(panel.sourceTextView)
        panel.sourceTextView.undoManager?.undo()
        check(panel.sourceTextView.string == original && panel.translatedTextView.string.isEmpty,
              "REWRITE 润色译文可用原生撤销恢复原文")

        service.failure = .missingCredential
        generate.performClick(nil)
        guard await waitUntil({ if case .failed = panel.phase { return true }; return false }) else {
            throw Missing(description: "缺少密钥没有显示错误")
        }
        check(panel.sourceTextView.string == original && generate.isEnabled
              && !instruction.isHiddenOrHasHiddenAncestor,
              "REWRITE 配置错误保留原文和要求，允许重试")
        try button(content, title: "设置").performClick(nil)
        check(settingsOpened == 1, "REWRITE 配置错误可打开设置")
        try render(content, name: "rewrite-error")
        service.failure = nil
        generate.performClick(nil)
        guard await waitUntil({ !service.replies.isEmpty }) else {
            throw Missing(description: "配置修复后无法重试润色")
        }
        service.replies.removeFirst().resume(returning: rewritten)
        check(await waitUntil { panel.phase == .ready && panel.translatedTextView.string == rewritten },
              "REWRITE 修复配置后重试成功")

        window.appearance = NSAppearance(named: .darkAqua)
        try button(content, title: "截图预览").performClick(nil)
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        window.setFrame(NSRect(origin: window.frame.origin, size: minimum), display: true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        content.layoutSubtreeIfNeeded()
        let controls = descendants(content, as: NSControl.self).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        let clipped = controls.filter { !content.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: content)) }
        check(clipped.isEmpty && content.bounds.width <= 681,
              "REWRITE 最小窗口同时展开预览和要求，所有控件可见")
        let editors = [panel.sourceTextView, panel.translatedTextView].compactMap { $0.enclosingScrollView?.frame }
        check(editors.count == 2 && editors.allSatisfy { $0.width >= 160 && $0.height >= 100 },
              "REWRITE 展开选项后原文和结果仍有可读空间")
        let preview = try require(descendants(content, as: NSImageView.self).first {
            $0.accessibilityLabel() == "当前识别区域"
        }, "截图预览缺失")
        check(preview.bounds.height >= 80, "REWRITE 最小窗口预览保持可读高度")
        try verifyWorkbenchAppearance(panel, name: "rewrite-options")
        try button(content, title: "截图预览").performClick(nil)
        try button(content, title: "用作原文").performClick(nil)
        check(panel.sourceTextView.string == rewritten && panel.translatedTextView.string.isEmpty,
              "REWRITE 润色结果可继续作为原文编辑")
        window.makeFirstResponder(panel.sourceTextView)
        panel.sourceTextView.insertText(" \n ", replacementRange: NSRange(location: 0, length: (panel.sourceTextView.string as NSString).length))
        check(!generate.isEnabled && !copy.isEnabled,
              "REWRITE 空白原文禁用生成与结果复制")
        selectMode(.translation)
        check(panel.phase == .ready && panel.sourceTextView.string == " \n " && !generate.isEnabled,
              "REWRITE 手动清空后切到翻译保持空白，不重新识别")
        selectMode(.rewrite)
        check(panel.phase == .ready && panel.sourceTextView.string == " \n " && !generate.isEnabled,
              "REWRITE 手动清空后切回润色仍等待输入")
    }

    private func rewritingCancellation() async throws {
        let service = RewriteServiceFixture()
        let recognized = TextRecognitionResult(blocks: [RecognizedTextBlock(text: "请整理本周的工作进展。",
            bounds: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5), confidence: 0.99)])
        let recognitionGate = WorkbenchRecognitionGate(result: recognized)
        let panel = RecognitionResultWindow(image: image(width: 720, height: 160), scale: 1,
            mode: .rewrite, target: .auto, translator: { _, _ in "unused" },
            rewriter: { text, options in try await service.rewrite(text, options: options) },
            recognizer: { _ in await recognitionGate.recognize() })
        defer {
            panel.close()
            service.finishPending()
            Task { await recognitionGate.allowRecognition() }
        }
        panel.show(relativeTo: nil)
        let window = try require(panel.window, "取消测试窗口缺失")
        let content = try require(window.contentView, "取消测试内容缺失")
        let generate = try button(content, title: "润色")
        let modes = try require(descendants(content, as: AppModeControl.self).first, "模式控制缺失")
        let tone = try require(descendants(content, as: NSPopUpButton.self).first {
            $0.accessibilityLabel() == "润色语气"
        }, "语气控制缺失")
        let length = try require(descendants(content, as: NSPopUpButton.self).first {
            $0.accessibilityLabel() == "润色篇幅"
        }, "篇幅控制缺失")
        tone.selectItem(withTitle: "专业")
        tone.sendAction(tone.action, to: tone.target)
        length.selectItem(withTitle: "更详细")
        length.sendAction(length.action, to: length.target)
        check(panel.phase == .recognizing && !generate.isEnabled,
              "REWRITE 识别等待时可以预选语气篇幅，识别任务继续")
        await recognitionGate.allowRecognition()
        guard await waitUntil({ panel.phase == .ready && !panel.sourceTextView.string.isEmpty }) else {
            throw Missing(description: "预选润色要求后识别没有完成")
        }
        check(tone.titleOfSelectedItem == "专业" && length.titleOfSelectedItem == "更详细" && service.calls.isEmpty,
              "REWRITE 识别完成保留预选要求，等待用户提交")
        func beginRequest() async throws {
            let previous = service.calls.count
            generate.performClick(nil)
            guard await waitUntil({ service.calls.count == previous + 1 && !service.replies.isEmpty }) else {
                throw Missing(description: "延迟润色请求未开始")
            }
        }
        try await beginRequest()
        window.makeFirstResponder(panel.sourceTextView)
        panel.sourceTextView.insertText("请整理本周进展，并列出下周计划。",
            replacementRange: NSRange(location: 0, length: (panel.sourceTextView.string as NSString).length))
        try await beginRequest()
        service.replies.remove(at: 1).resume(returning: "新版原文的润色结果")
        guard await waitUntil({ panel.translatedTextView.string == "新版原文的润色结果" }) else {
            throw Missing(description: "新版原文没有生成结果")
        }
        service.replies.removeFirst().resume(returning: "旧原文的迟到结果")
        guard await waitUntil({ service.completed == 2 }) else { throw Missing(description: "旧请求未释放") }
        check(panel.translatedTextView.string == "新版原文的润色结果"
              && service.calls.last?.text == "请整理本周进展，并列出下周计划。",
              "REWRITE 修改原文后迟到回复无法覆盖新结果")

        try await beginRequest()
        tone.selectItem(withTitle: "友善")
        tone.sendAction(tone.action, to: tone.target)
        let completedBeforeTone = service.completed
        service.replies.removeFirst().resume(returning: "旧语气的结果")
        guard await waitUntil({ service.completed == completedBeforeTone + 1 }) else { throw Missing(description: "旧语气请求未释放") }
        check(panel.phase == .ready && panel.translatedTextView.string.isEmpty,
              "REWRITE 修改语气立即使旧请求与旧结果失效")

        try await beginRequest()
        try button(content, title: "补充要求").performClick(nil)
        let instruction = try require(descendants(content, as: NSTextField.self).first {
            $0.accessibilityLabel() == "润色补充要求"
        }, "要求输入框缺失")
        window.makeFirstResponder(instruction)
        let editor = try require(instruction.currentEditor() as? NSTextView, "要求输入框无法获得焦点")
        editor.insertText("面向新同事", replacementRange: NSRange(location: 0, length: 0))
        let completedBeforeInstruction = service.completed
        service.replies.removeFirst().resume(returning: "旧要求的结果")
        guard await waitUntil({ service.completed == completedBeforeInstruction + 1 }) else { throw Missing(description: "旧要求请求未释放") }
        check(panel.phase == .ready && panel.translatedTextView.string.isEmpty,
              "REWRITE 编辑补充要求使处理中结果失效")

        try await beginRequest()
        try button(content, title: "取消任务").performClick(nil)
        let completedBeforeCancel = service.completed
        service.replies.removeFirst().resume(returning: "取消后的结果")
        guard await waitUntil({ service.completed == completedBeforeCancel + 1 }) else { throw Missing(description: "取消请求未释放") }
        check(panel.phase == .cancelled && panel.translatedTextView.string.isEmpty && generate.isEnabled,
              "REWRITE 取消后忽略迟到回复并允许重试")

        try await beginRequest()
        modes.selectedSegment = RecognitionResultWindow.Mode.text.rawValue
        modes.sendAction(modes.action, to: modes.target)
        let completedBeforeMode = service.completed
        service.replies.removeFirst().resume(returning: "切换后的结果")
        guard await waitUntil({ service.completed == completedBeforeMode + 1 }) else { throw Missing(description: "切换请求未释放") }
        check(panel.mode == .text && panel.phase == .ready && panel.translatedTextView.string.isEmpty,
              "REWRITE 切换到提取文字后旧结果不会回写")
        modes.selectedSegment = RecognitionResultWindow.Mode.rewrite.rawValue
        modes.sendAction(modes.action, to: modes.target)
        check(panel.translatedTextView.string.isEmpty,
              "REWRITE 取消的旧结果不会被切换模式重新显示")

        try await beginRequest()
        panel.close()
        let completedBeforeClose = service.completed
        service.replies.removeFirst().resume(returning: "关闭后的结果")
        guard await waitUntil({ service.completed == completedBeforeClose + 1 }) else { throw Missing(description: "关闭请求未释放") }
        check(panel.translatedTextView.string.isEmpty && window.isVisible == false,
              "REWRITE 关闭工作台后迟到回复不更新窗口")
    }

    private func lightToolbarAppearance() throws {
        for (context, name) in [(AnnotateToolbar.Context.capture, "capture"), (.imageEditor, "scroll"), (.pin, "pin")] {
            let toolbar = AnnotateToolbar(initialKind: .arrow,
                initialStyle: Style(color: RGBAColor.palette[0], pen: .p3), context: context)
            let window = host(toolbar, size: toolbar.intrinsicContentSize)
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            let representation = try render(toolbar, name: "toolbar-light-" + name)
            let background = try require(representation.colorAt(x: representation.pixelsWide / 2, y: 4), "工具栏背景读取失败")
            check(luminance(try resolvedColor(background, for: toolbar)) > 0.7,
                  "TOOLBAR \(name) 在深色系统外观中保持浅色背景")
            let iconButtons = descendants(toolbar, as: NSButton.self).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled && $0.image?.isTemplate == true
            }
            let ratios = try iconButtons.map { button in
                1.05 / (luminance(try resolvedColor(button.contentTintColor ?? .labelColor, for: button)) + 0.05)
            }
            check(!ratios.isEmpty && ratios.allSatisfy { $0 >= 4.5 },
                  "TOOLBAR \(name) 可用工具的图标在白底上保持清晰")
        }
        let toolbar = PinToolbar()
        let window = host(toolbar, size: toolbar.intrinsicContentSize)
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        let representation = try render(toolbar, name: "toolbar-light-pin-actions")
        let background = try require(representation.colorAt(x: representation.pixelsWide / 2, y: 4), "贴图操作栏背景读取失败")
        check(luminance(try resolvedColor(background, for: toolbar)) > 0.7,
              "TOOLBAR 贴图顶部操作栏保持浅色")
        let copy = try button(toolbar, title: "复制图像")
        var copied = false
        toolbar.onCopy = { copied = true }
        copy.performClick(nil)
        check(copied && copy.bounds.width >= 28 && copy.bounds.height >= 28,
              "TOOLBAR 浅色贴图操作栏保留点击行为与可用尺寸")
        let actions = ["缩小", "放大", "向左旋转", "向右旋转", "水平翻转", "垂直翻转", "灰度", "反色", "标注", "复制图像", "另存为", "关闭"]
        for width: CGFloat in [180, 64] {
            toolbar.maximumWidth = width
            window.setContentSize(NSSize(width: width, height: toolbar.intrinsicContentSize.height))
            toolbar.layoutSubtreeIfNeeded()
            let buttons = descendants(toolbar, as: NSButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            check(buttons.allSatisfy { toolbar.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: toolbar)) },
                  "TOOLBAR 宽度\(Int(width))的贴图操作按钮完整可见")
            let more = try require(buttons.first { $0.menu != nil }, "窄贴图缺少更多菜单")
            let menu = try require(more.menu, "贴图更多菜单缺失")
            let available = Set(buttons.compactMap(\.toolTip) + menu.items.map(\.title))
            check(actions.allSatisfy { available.contains($0) }, "TOOLBAR 窄贴图的所有操作均可通过按钮或菜单访问")
            var rotated = false
            toolbar.onRotateLeft = { rotated = true }
            let rotationIndex = try require(menu.items.firstIndex { $0.title == "向左旋转" }, "贴图菜单缺少旋转操作")
            menu.performActionForItem(at: rotationIndex)
            check(rotated, "TOOLBAR 窄贴图菜单保留旋转操作回调")
            try render(toolbar, name: "toolbar-light-pin-compact-\(Int(width))")
        }
    }

    func run() async -> Bool {
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        test("captureEditing", captureEditing)
        test("mixedSelectionStyle", mixedSelectionStyle)
        test("textAndSelection", textAndSelection)
        test("textAtSelectionEdge", textAtSelectionEdge)
        test("recognitionReturnToEditing", recognitionReturnToEditing)
        test("drawingAndTransform", drawingAndTransform)
        test("pinEditing", pinEditing)
        test("scrollEditing", scrollEditing)
        do { try await editableHistoryReplay() }
        catch { failures += 1; print("FAIL editableHistoryReplay \(error)") }
        test("lightToolbarAppearance", lightToolbarAppearance)
        do { try await scrollCaptureRecovery() }
        catch {
            failures += 1
            print("FAIL scrollCaptureRecovery \(error)")
        }
        do { try await recognition() }
        catch {
            failures += 1
            print("FAIL recognition \(error)")
        }
        do { try await recognitionWorkbenchAppearance() }
        catch {
            failures += 1
            print("FAIL recognitionWorkbenchAppearance \(error)")
        }
        do { try await rewritingWorkflow() }
        catch {
            failures += 1
            print("FAIL rewritingWorkflow \(error)")
        }
        do { try await rewritingCancellation() }
        catch {
            failures += 1
            print("FAIL rewritingCancellation \(error)")
        }
        print("SUMMARY passes=\(passes) failures=\(failures)")
        return failures == 0
    }
}

@main
private struct UXE2E {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            let passed = await UXHarness().run()
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
        application.run()
        print("FAIL AppKit event loop exited before UX verification completed")
        exit(1)
    }
}
