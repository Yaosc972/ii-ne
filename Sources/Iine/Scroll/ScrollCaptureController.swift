import AppKit
import IineCore

struct ScrollCaptureUpdate {
    let image: CGImage
    let pixelSize: CGSize
    let frameCount: Int
}

@MainActor
final class ScrollCaptureController {
    var onUpdate: ((ScrollCaptureUpdate) -> Void)?
    var onFinish: ((CGImage) -> Void)?
    var onLimitReached: (() -> Void)?
    var onStalled: (() -> Void)?
    var onFramesMissed: (() -> Void)?
    var onStateChange: (() -> Void)?

    private enum Phase { case stopped, running, paused, limited, finishing }
    private struct CaptureAttempt {
        let id: UUID
        let worker: Task<Void, Never>
    }

    private let capturer: any ScrollFrameCapturing
    private let globalRect: CGRect
    private let interval: TimeInterval
    private let captureTimeout: TimeInterval
    private var engine = ScrollCaptureEngine()
    private let workQueue = DispatchQueue(label: "iine.scroll.engine", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var phase: Phase = .stopped { didSet { onStateChange?() } }
    private var generation = UUID()
    private var timer: Timer?
    private var captureAttempt: CaptureAttempt?
    private var timeoutTask: Task<Void, Never>?
    private var processingID: UUID?
    private var slowCaptureCount = 0
    private var nilCaptureCount = 0
    private var lastReportedHeight = 0
    nonisolated private static let missedFrameHintThreshold = 8
    nonisolated private static let previewUpdateThresholdPx = 24
    nonisolated private static let previewMaximumDimension = 1024

    var isPaused: Bool { phase == .paused }
    var isFinishing: Bool { phase == .finishing }
    var canTogglePause: Bool { phase == .running || (phase == .paused && captureAttempt == nil) }

    init(capturer: any ScrollFrameCapturing, globalRect: CGRect, interval: TimeInterval = 0.10,
         captureTimeout: TimeInterval = 2) {
        self.capturer = capturer
        self.globalRect = globalRect
        self.interval = max(0.01, interval)
        self.captureTimeout = max(0.01, captureTimeout)
    }

    deinit {
        timer?.invalidate()
        timeoutTask?.cancel()
        captureAttempt?.worker.cancel()
    }

    func start(firstFrame: CGImage) {
        invalidateCapture()
        phase = captureAttempt == nil ? .running : .paused
        lastReportedHeight = 0
        slowCaptureCount = 0
        nilCaptureCount = 0
        let id = generation
        let engine = ScrollCaptureEngine()
        self.engine = engine
        let workID = UUID()
        processingID = workID
        workQueue.async { [weak self] in
            let state = engine.start(first: firstFrame)
            let image = engine.preview(maxDimension: Self.previewMaximumDimension)
            let size = engine.pixelSize
            Task { @MainActor in
                guard let self, self.processingID == workID else { return }
                self.processingID = nil
                guard self.generation == id, self.phase != .stopped else { return }
                self.report(state, preview: image, pixelSize: size)
                if self.phase == .paused { self.onStalled?() }
            }
        }
        if phase == .running { scheduleTimer() }
    }

    func pause() {
        guard phase == .running else { return }
        invalidateCapture()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        guard captureAttempt == nil else {
            onStalled?()
            return
        }
        generation = UUID()
        phase = .running
        nilCaptureCount = 0
        slowCaptureCount = 0
        scheduleTimer()
    }

    func finish() {
        guard phase == .running || phase == .paused || phase == .limited else { return }
        invalidateCapture()
        phase = .finishing
        let id = generation
        let engine = self.engine
        workQueue.async { [weak self] in
            let image = engine.image
            ScrollDebug.log("finish height=\(image?.height ?? 0) frames=\(engine.frameCount)")
            ScrollDebug.save(image, name: "result.png")
            Task { @MainActor in
                guard let self, self.generation == id, self.phase == .finishing else { return }
                self.processingID = nil
                guard let image else {
                    self.phase = .paused
                    self.onStalled?()
                    return
                }
                self.phase = .stopped
                self.engine = ScrollCaptureEngine()
                self.onFinish?(image)
            }
        }
    }

    func cancel() {
        invalidateCapture()
        phase = .stopped
        processingID = nil
        engine = ScrollCaptureEngine()
    }

    private func scheduleTimer() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidateCapture() {
        timer?.invalidate()
        timer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        captureAttempt?.worker.cancel()
        generation = UUID()
    }

    private func tick() {
        guard phase == .running, captureAttempt == nil, processingID == nil else { return }
        let id = UUID()
        let generation = self.generation
        let capturer = self.capturer
        let rect = globalRect
        let started = ProcessInfo.processInfo.systemUptime
        let worker = Task { [weak self] in
            let frame = await capturer.capture(globalRect: rect)
            self?.captured(frame, attemptID: id, generation: generation, started: started,
                           cancelled: Task.isCancelled)
        }
        captureAttempt = CaptureAttempt(id: id, worker: worker)
        let timeout = captureTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            guard let self, self.captureAttempt?.id == id, self.generation == generation,
                  self.phase == .running else { return }
            self.pause()
            self.onStalled?()
        }
    }

    private func captured(_ frame: CGImage?, attemptID: UUID, generation: UUID,
                          started: TimeInterval, cancelled: Bool) {
        guard captureAttempt?.id == attemptID else { return }
        captureAttempt = nil
        onStateChange?()
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !cancelled, self.generation == generation, phase == .running else { return }
        guard let frame else {
            nilCaptureCount += 1
            if nilCaptureCount >= 3 { pause(); onStalled?() }
            return
        }
        nilCaptureCount = 0
        slowCaptureCount = ProcessInfo.processInfo.systemUptime - started > 1 ? slowCaptureCount + 1 : 0
        if slowCaptureCount >= 3 { pause(); onStalled?(); return }
        let engine = self.engine
        let workID = UUID()
        let reportedHeight = lastReportedHeight
        processingID = workID
        workQueue.async { [weak self] in
            let state = engine.consume(frame: frame)
            let size = engine.pixelSize
            let misses = engine.consecutiveMisses
            let changedHeight = Int(size.height) - reportedHeight
            let shouldReport = reportedHeight == 0 || changedHeight < 0 || changedHeight >= Self.previewUpdateThresholdPx
            let preview = state != nil && shouldReport ? engine.preview(maxDimension: Self.previewMaximumDimension) : nil
            if ScrollDebug.isEnabled {
                let offset = engine.lastEstimate.map { String(format: "%.0f", $0.offsetPx) } ?? "nil"
                ScrollDebug.log("frame \(frame.width)x\(frame.height) offset=\(offset) frames=\(engine.frameCount) height=\(Int(size.height))")
                ScrollFrameDump.save(frame)
            }
            Task { @MainActor in
                guard let self, self.processingID == workID else { return }
                self.processingID = nil
                guard self.generation == generation, self.phase == .running else { return }
                if misses >= Self.missedFrameHintThreshold, misses % Self.missedFrameHintThreshold == 0 {
                    self.onFramesMissed?()
                }
                if let state { self.report(state, preview: preview, pixelSize: size) }
            }
        }
    }

    private func report(_ state: ScrollStitchState, preview: CGImage?, pixelSize: CGSize) {
        let reportedGeneration = generation
        if let preview {
            lastReportedHeight = Int(pixelSize.height)
            onUpdate?(ScrollCaptureUpdate(image: preview, pixelSize: pixelSize, frameCount: state.frameCount))
        }
        guard generation == reportedGeneration else { return }
        if state.reachedLimit {
            invalidateCapture()
            phase = .limited
            onLimitReached?()
        }
    }

}

private enum ScrollFrameDump {
    private static let lock = NSLock()
    private static var count = 0

    static func save(_ image: CGImage) {
        lock.lock()
        guard count < 24 else { lock.unlock(); return }
        count += 1
        let index = count
        lock.unlock()
        ScrollDebug.save(image, name: String(format: "frame-%02d.png", index))
    }
}

@MainActor
final class ScrollCapturePreview: NSPanel {
    var onTogglePause: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "滚动页面以捕获更多内容")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)

    init(selection: CGRect, screen: NSScreen, level: NSWindow.Level) {
        let size = NSSize(width: 220, height: 320)
        let visible = screen.visibleFrame
        var x = selection.maxX + 12
        if x + size.width > visible.maxX { x = selection.minX - size.width - 12 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(selection.maxY - size.height, visible.minY + 8), visible.maxY - size.height - 8)
        super.init(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = NSWindow.Level(rawValue: level.rawValue + 1)
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.97).cgColor
        content.layer?.cornerRadius = 10
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 12, y: 104, width: 196, height: 202)
        sizeLabel.frame = NSRect(x: 12, y: 81, width: 196, height: 20)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.frame = NSRect(x: 12, y: 45, width: 196, height: 34)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let finish = NSButton(title: "完成", target: self, action: #selector(finishCapture))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelCapture))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        for (index, button) in [pauseButton, finish, cancel].enumerated() {
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 10 + index * 67, y: 10, width: 66, height: 28)
            content.addSubview(button)
        }
        content.addSubview(imageView)
        content.addSubview(sizeLabel)
        content.addSubview(statusLabel)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(image: CGImage, frames: Int, pixelSize: CGSize) {
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        sizeLabel.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px · \(frames) 帧"
        statusLabel.stringValue = "继续滚动，或点击完成保留长图"
    }

    func showMessage(_ text: String) { statusLabel.stringValue = text }
    func setPaused(_ paused: Bool, enabled: Bool = true) {
        pauseButton.isEnabled = enabled
        pauseButton.title = paused ? "继续" : "暂停"
        statusLabel.stringValue = paused ? "已暂停，当前长图已保留" : "继续滚动，或点击完成保留长图"
    }

    @objc private func togglePause() { onTogglePause?() }
    @objc private func finishCapture() { onFinish?() }
    @objc private func cancelCapture() { onCancel?() }
}
