import AppKit
import CoreGraphics
import Foundation
import IineCore

private final class PausedHistoryFileManager: FileManager, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var isWaiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered && !released
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline) { released = true }
        }
        condition.unlock()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private actor SuspendedCapturer: ScrollFrameCapturing {
    private var pending: [CheckedContinuation<CGImage?, Never>] = []
    private(set) var calls = 0
    private(set) var completions = 0
    private var isFinished = false

    func capture(globalRect: CGRect) async -> CGImage? {
        calls += 1
        guard !isFinished else { completions += 1; return nil }
        let result = await withCheckedContinuation { pending.append($0) }
        completions += 1
        return result
    }

    func release(_ frame: CGImage?) {
        let replies = pending
        pending.removeAll()
        for reply in replies { reply.resume(returning: frame) }
    }

    func finish() {
        isFinished = true
        release(nil)
    }
}

private actor FixedCapturer: ScrollFrameCapturing {
    let frame: CGImage
    init(frame: CGImage) { self.frame = frame }
    func capture(globalRect: CGRect) async -> CGImage? { frame }
}

@MainActor
private final class ResourceHarness {
    private struct Missing: Error { let message: String }
    private struct FileState: Equatable {
        let contents: Data
        let modified: Date?
    }

    private var passes = 0
    private var failures = 0

    private func check(_ condition: Bool, _ message: String) {
        if condition { passes += 1; print("PASS \(message)") }
        else { failures += 1; print("FAIL \(message)") }
    }

    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Missing(message: message) }
        return value
    }

    private func test(_ name: String, _ body: () async throws -> Void) async {
        do { try await body() }
        catch { failures += 1; print("FAIL \(name) \(error)") }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func image(width: Int = 320, height: Int = 900, seed: Int = 0) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw Missing(message: "无法创建合成位图")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 11 + y / 3 + seed * 31) & 255)
                pixels[offset + 1] = UInt8((y * 7 + x / 5 + seed * 17) & 255)
                pixels[offset + 2] = UInt8(((x / 4 + y / 4) % 2) * 255)
                pixels[offset + 3] = 255
            }
        }
        return try require(context.makeImage(), "无法完成合成位图")
    }

    private func pixels(_ image: CGImage) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes = context.data else { throw Missing(message: "像素读取失败") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: bytes, count: image.width * image.height * 4)
    }

    private func files(_ directory: URL) throws -> [String: FileState] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        var result: [String: FileState] = [:]
        for url in urls where url.pathExtension == "png" || url.lastPathComponent == CaptureHistoryStore.indexFileName {
            result[url.lastPathComponent] = FileState(contents: try Data(contentsOf: url),
                modified: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        return result
    }

    private func withHistory(seed: CaptureHistoryEntry? = nil, fileManager: FileManager = .default,
                             _ body: (SnipController, CaptureHistoryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iine-resource-e2e-\(UUID().uuidString)", isDirectory: true)
        let suite = "IineTests.Resource.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "无法创建隔离设置")
        let settings = SettingsStore(defaults: defaults)
        settings.save(.standard)
        let store = CaptureHistoryStore(directory: directory, fileManager: fileManager)
        if let seed { try store.append(seed) }
        let controller = SnipController(historyStore: store)
        controller.settingsStore = settings
        var failure: Error?
        do { try await body(controller, store, directory) }
        catch { failure = error }
        for window in NSApp.windows.compactMap({ $0 as? ScrollResultWindow }) where window.isVisible { window.close() }
        controller.cancel()
        await controller.waitForHistoryPersistence()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        if let failure { throw failure }
    }

    private func editableEntry(_ base: CGImage) -> CaptureHistoryEntry {
        CaptureHistoryEntry(image: base, displaySize: CGSize(width: base.width, height: base.height),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), editingImage: base)
    }

    private func openEditor(_ controller: SnipController) throws -> ScrollResultWindow {
        controller.startReplayingHistory(at: 0)
        return try require(NSApp.windows.compactMap { $0 as? ScrollResultWindow }.first { $0.isVisible },
            "历史入口没有打开长图编辑窗口")
    }

    private func drawRect(in window: ScrollResultWindow) {
        window.annotationToolbar.toolButtons[.rect]?.performClick(nil)
        window.canvas.pointerDown(at: CGPoint(x: 24, y: 90))
        window.canvas.pointerDragged(to: CGPoint(x: 140, y: 240))
        window.canvas.pointerUp(at: CGPoint(x: 140, y: 240))
    }

    private func recordAndReleaseHistory() async throws {
        let base = try image(width: 160, height: 120)
        let marks = [Annotation(shape: .rect(CGRect(x: 4, y: 5, width: 16, height: 10)),
            style: Style(color: .red, pen: .p3))]
        let output = try require(AnnotationExport.flatten(base: base,
            cropRectPx: CGRect(x: 20, y: 50, width: 80, height: 60), annotations: marks, scale: 2), "截图导出失败")
        let expected = try pixels(output)
        let expectedFrame = try pixels(base)
        let region = CaptureRegion(displayID: 1, rect: CGRect(x: 10, y: 5, width: 40, height: 30),
            displayBounds: CGRect(x: 0, y: 0, width: 80, height: 60))
        try await withHistory { controller, store, directory in
            controller.remember(output, displaySize: CGSize(width: 40, height: 30), region: region,
                fullFrame: base, annotations: marks)
            check(controller.historyCount == 1, "HISTORY 输出后立即出现在历史中")
            await controller.waitForHistoryPersistence()
            let disk = try require(store.load().first, "历史未写入磁盘")
            let replay = try require(controller.latestCapture, "历史回放缺少图像")
            check(try pixels(disk.image) == expected && pixels(replay.image) == expected,
                  "HISTORY 后台保存和回放保持导出像素")
            check(disk.region == region && disk.annotations == marks && disk.displaySize == CGSize(width: 40, height: 30),
                  "HISTORY 后台保存保留位置、标注与显示尺寸")
            let frame = try require(replay.fullFrame, "回放缺少整屏帧")
            controller.clearHistory()
            await controller.waitForHistoryPersistence()
            let clearedEntries = try store.load()
            let clearedFiles = try files(directory)
            check(controller.historyCount == 0 && clearedEntries.isEmpty && clearedFiles.isEmpty,
                  "HISTORY 清空完成后内存与磁盘为空")
            check(try pixels(replay.image) == expected && pixels(frame) == expectedFrame,
                  "HISTORY 文件删除后已经取得的回放图像仍可读取")
        }
    }

    private func clearWhileWriting() async throws {
        let gate = PausedHistoryFileManager()
        defer { gate.release() }
        let first = try image(width: 640, height: 480)
        try await withHistory(fileManager: gate) { controller, store, directory in
            controller.remember(first, displaySize: CGSize(width: 320, height: 240), region: nil, fullFrame: first)
            guard await waitUntil(timeout: 1, { gate.isWaiting }) else {
                gate.release()
                throw Missing(message: "写入没有在后台进入受控等待")
            }
            for index in 1...5 {
                let next = try image(width: 160 + index, height: 120, seed: index)
                controller.remember(next, displaySize: CGSize(width: next.width, height: next.height), region: nil)
            }
            controller.clearHistory()
            check(controller.historyCount == 0 && gate.isWaiting,
                  "HISTORY 进行中的磁盘写入不会阻塞清空操作")
            gate.release()
            await controller.waitForHistoryPersistence()
            let clearedEntries = try store.load()
            let clearedFiles = try files(directory)
            check(clearedEntries.isEmpty && clearedFiles.isEmpty,
                  "HISTORY 进行中和排队中的旧写入不能在清空后恢复条目")
        }
    }

    private func clearOpenEditor() async throws {
        let base = try image()
        try await withHistory(seed: editableEntry(base)) { controller, store, directory in
            let window = try openEditor(controller)
            drawRect(in: window)
            check(window.annotations.count == 1, "HISTORY 长图通过工具栏和画布产生待保存编辑")
            controller.clearHistory()
            window.close()
            await controller.waitForHistoryPersistence()
            try? await Task.sleep(nanoseconds: 550_000_000)
            await controller.waitForHistoryPersistence()
            let clearedEntries = try store.load()
            let clearedFiles = try files(directory)
            check(controller.historyCount == 0 && clearedEntries.isEmpty && clearedFiles.isEmpty,
                  "HISTORY 清空后的自动保存和窗口关闭都不会复活旧记录")
        }
    }

    private func editAfterClear() async throws {
        let base = try image()
        try await withHistory(seed: editableEntry(base)) { controller, store, _ in
            let window = try openEditor(controller)
            controller.clearHistory()
            await controller.waitForHistoryPersistence()
            drawRect(in: window)
            await controller.waitForHistoryPersistence()
            let entries = try store.load()
            let entry = try require(entries.first, "清空后的新编辑没有保存")
            let expected = try require(window.flattenedImage(), "长图无法导出")
            check(entries.count == 1 && entry.annotations == window.annotations,
                  "HISTORY 清空后的新编辑可以作为新历史保存")
            check(try pixels(entry.image) == pixels(expected), "HISTORY 新编辑的历史像素与当前导出一致")
        }
    }

    private func unchangedEditorDoesNotRewrite() async throws {
        let base = try image()
        try await withHistory(seed: editableEntry(base)) { controller, _, directory in
            let before = try files(directory)
            let window = try openEditor(controller)
            await controller.waitForHistoryPersistence()
            let afterOpen = try files(directory)
            window.close()
            await controller.waitForHistoryPersistence()
            let afterClose = try files(directory)
            check(afterOpen == before && afterClose == before,
                  "HISTORY 未修改的长图打开和关闭都不重写图片或索引")
        }
    }

    private func flushLastEditorChange() async throws {
        let base = try image()
        try await withHistory(seed: editableEntry(base)) { controller, store, directory in
            let window = try openEditor(controller)
            window.annotationToolbar.toolButtons[.text]?.performClick(nil)
            window.canvas.pointerDown(at: CGPoint(x: 36, y: 120))
            let editor = try require(window.canvas.subviews.compactMap { $0 as? NSTextView }.first, "长图文字编辑器缺失")
            editor.insertText("最后一次编辑", replacementRange: NSRange(location: 0, length: 0))
            check(window.annotations.isEmpty, "HISTORY 文字草稿尚未提前变成已提交标注")
            await controller.waitForHistoryPersistence()
            let disk = try require(store.load().first, "最后编辑未写入磁盘")
            let hasText = disk.annotations.contains {
                if case .text(let text, _, _, _) = $0.shape { return text == "最后一次编辑" }
                return false
            }
            check(hasText && disk.annotations == window.annotations,
                  "HISTORY flush会提交文字草稿并持久化最后编辑")
            let saved = try files(directory)
            window.close()
            await controller.waitForHistoryPersistence()
            check(try files(directory) == saved, "HISTORY 已flush的最后编辑在关窗时不重复写入")
        }
    }

    private func scrollAsyncCompletion() async throws {
        let frame = try image(width: 1536, height: 384)
        let controller = ScrollCaptureController(capturer: FixedCapturer(frame: frame),
            globalRect: CGRect(x: 0, y: 0, width: frame.width, height: frame.height), interval: 1)
        defer { controller.cancel() }
        var updates: [ScrollCaptureUpdate] = []
        var result: CGImage?
        var finished = 0
        controller.onUpdate = { updates.append($0) }
        controller.onFinish = { result = $0; finished += 1 }
        controller.start(firstFrame: frame)
        check(updates.isEmpty, "SCROLL start通过后台工作返回首帧预览")
        guard await waitUntil({ !updates.isEmpty }) else { throw Missing(message: "滚动首帧预览未返回") }
        let update = try require(updates.first, "首帧更新缺失")
        check(update.pixelSize == CGSize(width: 1536, height: 384) && update.frameCount == 1
              && max(update.image.width, update.image.height) <= 1024,
              "SCROLL 缩略预览保留真实输出尺寸和帧数")
        controller.finish()
        check(result == nil, "SCROLL finish通过后台工作生成完整长图")
        guard await waitUntil({ result != nil }) else { throw Missing(message: "滚动完成没有返回完整图像") }
        let output = try require(result, "滚动输出缺失")
        let outputPixels = try pixels(output)
        let framePixels = try pixels(frame)
        check(output.width == frame.width && output.height == frame.height && outputPixels == framePixels,
              "SCROLL 完成输出保留完整分辨率与像素")
        controller.finish()
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(finished == 1, "SCROLL 重复完成不会重复交付结果")
    }

    private func scrollTimeoutAndRelease() async throws {
        let frame = try image(width: 320, height: 240)
        let capturer = SuspendedCapturer()
        var controller: ScrollCaptureController? = ScrollCaptureController(capturer: capturer,
            globalRect: CGRect(x: 0, y: 0, width: 320, height: 240), interval: 0.01, captureTimeout: 0.05)
        weak var releasedController = controller
        var updates = 0
        var finishes = 0
        var stalls = 0
        controller?.onUpdate = { _ in updates += 1 }
        controller?.onFinish = { _ in finishes += 1 }
        controller?.onStalled = { stalls += 1 }
        controller?.start(firstFrame: frame)
        var failure: Error?
        do {
            guard await waitUntil({ controller?.isPaused == true && stalls > 0 }) else {
                throw Missing(message: "不响应取消的截图任务没有触发超时暂停")
            }
            let calls = await capturer.calls
            let updatesBeforeResume = updates
            for _ in 0..<3 { controller?.resume() }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let callsAfterResume = await capturer.calls
            check(calls == 1 && callsAfterResume == 1 && controller?.isPaused == true,
                  "SCROLL 超时后重试不会叠加仍挂起的截图任务")
            controller?.cancel()
            controller = nil
            check(await waitUntil { releasedController == nil }, "SCROLL 挂起截图任务不会强持有已取消的控制器")
            await capturer.release(frame)
            try? await Task.sleep(nanoseconds: 80_000_000)
            let completions = await capturer.completions
            check(updates == updatesBeforeResume && finishes == 0 && completions == 1,
                  "SCROLL 控制器释放后迟到截图不会更新预览或交付结果")
        } catch { failure = error }
        controller?.cancel()
        controller = nil
        await capturer.finish()
        if let failure { throw failure }
    }

    private func resumeAfterTimedOutCaptureReturns() async throws {
        let frame = try image(width: 320, height: 240)
        let capturer = SuspendedCapturer()
        let controller = ScrollCaptureController(capturer: capturer,
            globalRect: CGRect(x: 0, y: 0, width: 320, height: 240), interval: 0.01, captureTimeout: 0.15)
        var updates = 0
        var finished: CGImage?
        controller.onUpdate = { _ in updates += 1 }
        controller.onFinish = { finished = $0 }
        controller.start(firstFrame: frame)
        var failure: Error?
        do {
            guard await waitUntil({ controller.isPaused }) else { throw Missing(message: "截图超时没有暂停") }
            check(!controller.canTogglePause, "SCROLL 上一帧挂起时继续操作不可用")
            let initialUpdates = updates
            await capturer.release(frame)
            try? await Task.sleep(nanoseconds: 80_000_000)
            check(updates == initialUpdates && controller.isPaused, "SCROLL 超时帧返回后仍保持暂停且不回写旧预览")
            check(controller.canTogglePause, "SCROLL 上一帧返回后继续操作恢复可用")
            controller.resume()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while await capturer.calls < 2 && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let callsAfterResume = await capturer.calls
            check(callsAfterResume == 2 && !controller.isPaused, "SCROLL 旧抓帧返回后允许继续一个新请求")
            controller.finish()
            guard await waitUntil({ finished != nil }) else { throw Missing(message: "有挂起抓帧时无法完成已有内容") }
            let result = try require(finished, "滚动结果缺失")
            check(try pixels(result) == pixels(frame), "SCROLL 完成保留已经捕获的内容")
        } catch { failure = error }
        controller.cancel()
        await capturer.finish()
        if let failure { throw failure }
    }

    private func scrollCancellationDuringUpdate() async throws {
        let tall = try image(width: 8, height: 9000)
        let controller = ScrollCaptureController(capturer: FixedCapturer(frame: tall), globalRect: .zero)
        var updates = 0
        var limits = 0
        controller.onUpdate = { [weak controller] _ in
            updates += 1
            controller?.cancel()
        }
        controller.onLimitReached = { limits += 1 }
        controller.start(firstFrame: tall)
        guard await waitUntil({ updates == 1 }) else { throw Missing(message: "滚动初始化没有回调") }
        check(limits == 0 && !controller.canTogglePause, "SCROLL 更新回调取消后不再提交旧上限状态")
        controller.cancel()
    }

    private func filePinReadsUpdatedContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iine-pin-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("image.png")
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) { result[type] = data }
            }
        }
        let controller = PinController(restoreCapacity: 4)
        var ownedClipboardRevision: Int?
        defer {
            controller.closeAll()
            controller.setRestoreCapacity(0)
            if pasteboard.changeCount == ownedClipboardRevision {
                pasteboard.clearContents()
                let items = previous.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try image(width: 64, height: 48, seed: 1)
        let second = try image(width: 64, height: 48, seed: 2)
        try require(ImageOutput.pngData(from: first), "文件贴图无法编码").write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let revision = pasteboard.changeCount
        ownedClipboardRevision = revision
        guard controller.pinFromPasteboard() else { throw Missing(message: "文件首张贴图失败") }
        let originalWindow = try require(NSApp.windows.compactMap { $0 as? PinWindow }.first { $0.pinController === controller && $0.isVisible }, "首张贴图窗口缺失")
        originalWindow.close()
        try require(ImageOutput.pngData(from: second), "更新文件无法编码").write(to: file, options: .atomic)
        guard controller.pinFromPasteboard() else { throw Missing(message: "更新文件贴图失败") }
        let current = try require(NSApp.windows.compactMap { $0 as? PinWindow }.first { $0.pinController === controller && $0.isVisible }, "更新贴图窗口缺失")
        let currentPixels = try pixels(current.pasteImage.image)
        let updatedPixels = try pixels(second)
        check(pasteboard.changeCount == revision && currentPixels == updatedPixels,
              "PIN 剪贴板版本不变时重新读取已修改的文件内容")
    }

    private func batchAnnotationUpdates() throws {
        let base = try image(width: 800, height: 800)
        let canvas = AnnotationCanvas(base: base, cropOriginPx: .zero, scale: 1, initialStyle: Style(color: .red, pen: .p3))
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        canvas.selectTool(nil)
        let original = (0..<100).map { index in
            Annotation(shape: .rect(CGRect(x: 20 + index % 10 * 60, y: 20 + index / 10 * 60, width: 30, height: 30)),
                style: Style(color: .red, pen: .p3))
        }
        canvas.annotations = original
        canvas.setSelection(Set(original.map(\.id)))
        var notifications = 0
        canvas.onChange = { notifications += 1 }
        canvas.pointerDown(at: CGPoint(x: 20, y: 35))
        notifications = 0
        let steps = 20
        for step in 1...steps {
            canvas.pointerDragged(to: CGPoint(x: 20 + step, y: 35 + step))
        }
        check(notifications <= steps * 2, "ANNOTATION 多选拖动通知按事件计数，不按100个对象重复刷新")
        canvas.pointerUp(at: CGPoint(x: 40, y: 55))
        let moved = original.map { Annotation(id: $0.id, shape: $0.shape.translated(by: CGPoint(x: 20, y: 20)), style: $0.style) }
        check(canvas.annotations == moved, "ANNOTATION 100个选中对象都按同一位移移动")
        canvas.undo()
        check(canvas.annotations == original, "ANNOTATION 批量移动只占一步撤销")
        canvas.redo()
        check(canvas.annotations == moved, "ANNOTATION 重做恢复全部对象")
        canvas.setSelection(Set(moved.map(\.id)))
        notifications = 0
        let blue = RGBAColor.palette[5]
        canvas.applyStyle(Style(color: blue, pen: .p3), changed: .color)
        check(notifications <= 4 && canvas.annotations.allSatisfy { $0.style.color == blue },
              "ANNOTATION 批量改色只发送有限通知并更新每个对象")
        canvas.undo()
        check(canvas.annotations == moved, "ANNOTATION 批量改色可以一次撤销")
    }

    private func blurUndoAndExport() throws {
        let base = try image(width: 160, height: 160)
        let rect = CGRect(x: 0, y: 0, width: 160, height: 160)
        let canvas = AnnotationCanvas(base: base, cropOriginPx: .zero, scale: 1,
            initialStyle: Style(color: .red, pen: .p3))
        canvas.frame = rect
        canvas.selectTool(.blur)
        canvas.pointerDown(at: CGPoint(x: 20, y: 20))
        for offset in stride(from: 30, through: 130, by: 10) {
            canvas.pointerDragged(to: CGPoint(x: offset, y: offset))
        }
        canvas.pointerUp(at: CGPoint(x: 130, y: 130))
        let blur = canvas.annotations
        let output = try require(AnnotationExport.flatten(base: base, cropRectPx: rect, annotations: blur, scale: 1), "模糊无法导出")
        let original = try require(AnnotationExport.flatten(base: base, cropRectPx: rect, annotations: [], scale: 1), "原图无法导出")
        let outputPixels = try pixels(output)
        let originalPixels = try pixels(original)
        check(blur.count == 1 && blur.first?.shape.kind == .blur && outputPixels != originalPixels,
              "ANNOTATION 模糊画笔实际改变导出像素")
        canvas.undo()
        check(canvas.annotations.isEmpty, "ANNOTATION 模糊笔画可撤销")
        canvas.redo()
        let restored = try require(AnnotationExport.flatten(base: base, cropRectPx: rect, annotations: canvas.annotations, scale: 1), "模糊重做无法导出")
        let restoredPixels = try pixels(restored)
        check(canvas.annotations == blur && restoredPixels == outputPixels, "ANNOTATION 模糊重做保持导出结果")
    }

    func run() async -> Bool {
        await test("recordAndReleaseHistory") { try await recordAndReleaseHistory() }
        await test("clearWhileWriting") { try await clearWhileWriting() }
        await test("clearOpenEditor") { try await clearOpenEditor() }
        await test("editAfterClear") { try await editAfterClear() }
        await test("unchangedEditorDoesNotRewrite") { try await unchangedEditorDoesNotRewrite() }
        await test("flushLastEditorChange") { try await flushLastEditorChange() }
        await test("scrollAsyncCompletion") { try await scrollAsyncCompletion() }
        await test("scrollTimeoutAndRelease") { try await scrollTimeoutAndRelease() }
        await test("resumeAfterTimedOutCaptureReturns") { try await resumeAfterTimedOutCaptureReturns() }
        await test("scrollCancellationDuringUpdate") { try await scrollCancellationDuringUpdate() }
        await test("filePinReadsUpdatedContents") { try filePinReadsUpdatedContents() }
        await test("batchAnnotationUpdates") { try batchAnnotationUpdates() }
        await test("blurUndoAndExport") { try blurUndoAndExport() }
        print("SUMMARY passes=\(passes) failures=\(failures)")
        return failures == 0
    }
}

@main
private struct ResourceE2E {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            let success = await ResourceHarness().run()
            fflush(stdout)
            exit(success ? 0 : 1)
        }
        application.run()
        print("FAIL AppKit event loop exited before resource verification completed")
        exit(1)
    }
}
