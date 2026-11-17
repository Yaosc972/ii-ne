import AppKit
import IineCore

@MainActor
final class RecognitionResultWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    enum Mode: Int, CaseIterable {
        case text, translation, rewrite

        var title: String {
            switch self {
            case .text: return "提取文字"
            case .translation: return "翻译"
            case .rewrite: return "润色"
            }
        }
    }

    enum Phase: Equatable {
        case recognizing, translating, rewriting, ready, cancelled
        case failed(String)

        var isBusy: Bool { self == .recognizing || self == .translating || self == .rewriting }
    }

    private struct TextRequest: Equatable {
        enum Operation: Equatable {
            case translation(TranslationTarget)
            case rewrite(RewriteOptions)

            var mode: Mode {
                switch self {
                case .translation: return .translation
                case .rewrite: return .rewrite
                }
            }
        }
        let text: String
        let operation: Operation
    }

    private struct TextResult {
        let request: TextRequest
        let text: String
    }

    typealias Translator = @MainActor (String, TranslationTarget) async throws -> String
    typealias Rewriter = @MainActor (String, RewriteOptions) async throws -> String
    typealias Recognizer = @Sendable (CGImage) async throws -> TextRecognitionResult

    var onReselect: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var mode: Mode
    private(set) var phase: Phase = .ready { didSet { updateControls() } }
    private(set) var recognitionResult: TextRecognitionResult?
    private(set) var target: TranslationTarget
    let sourceTextView = RecognitionTextView()
    let translatedTextView = RecognitionTextView()

    private let image: CGImage
    private let scale: CGFloat
    private let translator: Translator
    private let rewriter: Rewriter
    private let recognizer: Recognizer
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private var results: [Mode: TextResult] = [:]
    private var isClosed = false
    private var unmergedText: String?
    private weak var sourceWindow: NSWindow?
    private var translationPane: AppSurfaceView!
    private var modeControl: AppModeControl!
    private var rewriteControls: NSStackView!
    private var instructionExpanded = false
    private let instructionField = AppTextField()
    private let tonePopup = AppPopUpButton()
    private let lengthPopup = AppPopUpButton()
    private let instructionToggle = AppActionButton(title: "补充要求", emphasis: .quiet, target: nil, action: nil)
    private let resultTitle = NSTextField(labelWithString: "译文")
    private let resultCount = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLanguageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let targetPopup = AppPopUpButton()
    private let formatPopup = AppPopUpButton()
    private let copySourceButton = AppActionButton(title: "复制文字", emphasis: .quiet, target: nil, action: nil)
    private let copyTranslationButton = AppActionButton(title: "复制译文", emphasis: .quiet, target: nil, action: nil)
    private let translateButton = AppActionButton(title: "翻译", emphasis: .primary, target: nil, action: nil)
    private let useResultButton = AppActionButton(title: "润色译文", emphasis: .quiet, target: nil, action: nil)
    private let retryButton = AppActionButton(title: "重新识别", emphasis: .quiet, target: nil, action: nil)
    private let cancelButton = AppActionButton(title: "取消任务", emphasis: .quiet, target: nil, action: nil)
    private let reselectButton = AppActionButton(title: "重新框选", emphasis: .quiet, target: nil, action: nil)
    private let previewToggle = AppActionButton(title: "截图预览", emphasis: .quiet, target: nil, action: nil)
    private let previewImage = RecognitionPreviewImageView()
    private var previewExpanded = false
    private let settingsButton = AppActionButton(title: "设置", emphasis: .quiet, target: nil, action: nil)

    init(
        image: CGImage,
        scale: CGFloat,
        mode: Mode,
        target: TranslationTarget,
        translator: @escaping Translator,
        rewriter: @escaping Rewriter = { _, _ in throw TranslationError.unavailable("请在设置中配置润色使用的 AI 服务。") },
        recognizer: @escaping Recognizer = { image in try await TextRecognizer.recognizeAsync(in: image) }
    ) {
        self.image = image
        self.scale = max(scale, 1)
        self.mode = mode
        self.target = target
        self.translator = translator
        self.rewriter = rewriter
        self.recognizer = recognizer
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "文字工作台"
        window.contentMinSize = NSSize(width: 680, height: 540)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = AppPalette.color(.background)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        isClosed = false
        sourceWindow = parent
        if let parent {
            window.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
            parent.addChildWindow(window, ordered: .above)
            let screen = parent.screen?.visibleFrame ?? parent.frame
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRecognition()
    }

    override func close() {
        invalidateOperation()
        isClosed = true
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        invalidateOperation()
        isClosed = true
        if let window { sourceWindow?.removeChildWindow(window) }
        sourceWindow?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    func startRecognition() {
        invalidateOperation()
        let id = requestID
        let image = self.image
        let recognize = recognizer
        recognitionResult = nil
        unmergedText = nil
        results.removeAll()
        sourceTextView.string = ""
        sourceTextView.undoManager?.removeAllActions()
        translatedTextView.string = ""
        phase = .recognizing
        operation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await recognize(image)
                try Task.checkCancellation()
                guard let self, self.accepts(id) else { return }
                self.recognitionResult = result
                self.sourceTextView.string = self.formatted(result.text)
                self.updateSourceLanguage()
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.phase = .failed("没有识别到文字。可以输入文字，或重新框选。")
                    return
                }
                self.phase = .ready
                if self.mode == .translation { self.translateText() }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.accepts(id) else { return }
                self.phase = .failed("文字识别失败，请重试。\(error.localizedDescription)")
            }
        }
    }

    func translateText() {
        processText(TextRequest(text: sourceText, operation: .translation(target)))
    }

    private var sourceText: String { sourceTextView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var rewriteOptions: RewriteOptions {
        RewriteOptions(tone: RewriteTone.allCases[max(0, tonePopup.indexOfSelectedItem)],
                       length: RewriteLength.allCases[max(0, lengthPopup.indexOfSelectedItem)],
                       instruction: instructionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var currentRequest: TextRequest? {
        switch mode {
        case .text: return nil
        case .translation: return TextRequest(text: sourceText, operation: .translation(target))
        case .rewrite: return TextRequest(text: sourceText, operation: .rewrite(rewriteOptions))
        }
    }

    private func processText(_ request: TextRequest) {
        guard !request.text.isEmpty else {
            phase = .failed("请先识别或输入文字。")
            return
        }
        invalidateOperation()
        let id = requestID
        let translate = translator
        let rewrite = rewriter
        results.removeValue(forKey: request.operation.mode)
        translatedTextView.string = ""
        phase = request.operation.mode == .translation ? .translating : .rewriting
        operation = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let output: String
                switch request.operation {
                case .translation(let target): output = try await translate(request.text, target)
                case .rewrite(let options): output = try await rewrite(request.text, options)
                }
                try Task.checkCancellation()
                guard let self, self.accepts(id) else { return }
                self.results[request.operation.mode] = TextResult(request: request, text: output)
                self.translatedTextView.string = output
                self.phase = .ready
                self.revealResult()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.accepts(id) else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelOperation() {
        invalidateOperation()
        phase = .cancelled
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === sourceTextView else { return }
        invalidateOperation()
        unmergedText = nil
        results.removeAll()
        translatedTextView.string = ""
        updateSourceLanguage()
        phase = .ready
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === instructionField else { return }
        invalidateRewrite()
    }

    private func accepts(_ id: UUID) -> Bool { !isClosed && requestID == id }

    private func invalidateOperation() {
        requestID = UUID()
        operation?.cancel()
        operation = nil
    }

    private func buildContent() {
        modeControl = AppModeControl(labels: Mode.allCases.map(\.title), target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = mode.rawValue
        configurePopup(targetPopup, titles: TranslationTarget.allCases.map(\.title), label: "目标语言", action: #selector(targetChanged))
        targetPopup.selectItem(at: TranslationTarget.allCases.firstIndex(of: target) ?? 0)
        targetPopup.toolTip = "自动模式将中文译为英文，其他语言译为中文"
        configurePopup(formatPopup, titles: ["保留换行", "合并段落"], label: "文字排版", action: #selector(formatChanged))
        configurePopup(tonePopup, titles: RewriteTone.allCases.map(\.title), label: "润色语气", action: #selector(rewriteOptionsChanged))
        configurePopup(lengthPopup, titles: RewriteLength.allCases.map(\.title), label: "润色篇幅", action: #selector(rewriteOptionsChanged))
        instructionField.placeholderString = "例如：写给同事，表达礼貌一些"
        instructionField.setAccessibilityLabel("润色补充要求")
        instructionField.delegate = self
        instructionField.isHidden = true

        configure(copySourceButton, #selector(copySource), glyph: .copy)
        configure(copyTranslationButton, #selector(copyTranslation), glyph: .copy)
        configure(translateButton, #selector(processTapped))
        translateButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        translateButton.imagePosition = .imageTrailing
        translateButton.keyEquivalent = "\r"
        translateButton.keyEquivalentModifierMask = [.command]
        translateButton.toolTip = "生成结果 · ⌘Enter"
        configure(useResultButton, #selector(useResult))
        configure(retryButton, #selector(retry))
        configure(cancelButton, #selector(cancelTapped))
        configure(settingsButton, #selector(openSettings))
        settingsButton.toolTip = "翻译与润色设置"
        settingsButton.setAccessibilityLabel("翻译与润色设置")
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        configure(reselectButton, #selector(reselect))
        configure(previewToggle, #selector(togglePreview))
        configure(instructionToggle, #selector(toggleInstruction))
        instructionToggle.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let closeButton = AppActionButton(title: "返回编辑", emphasis: .secondary, target: self, action: #selector(closeTapped))
        closeButton.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)

        let header = row([modeControl, NSView(), settingsButton])
        let optionsRow = row([label("语气", secondary: true), tonePopup, label("篇幅", secondary: true), lengthPopup, NSView(), instructionToggle])
        let options = column([optionsRow, instructionField], spacing: 10)
        rewriteControls = options
        optionsRow.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        instructionField.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        let previewHeader = row([previewToggle, NSView(), reselectButton])
        previewImage.image = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        previewImage.imageScaling = .scaleProportionallyDown
        previewImage.imageAlignment = .alignCenter
        previewImage.setAccessibilityLabel("当前识别区域")
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let previewStack = column([previewHeader, previewImage], spacing: 8)
        previewHeader.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
        previewImage.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
        updatePreview()

        for text in [sourceLanguageLabel, resultCount] {
            text.font = .systemFont(ofSize: 11, weight: .medium)
            text.textColor = AppPalette.color(.secondaryText)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        resultTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        resultTitle.textColor = AppPalette.color(.text)
        sourceTextView.delegate = self
        sourceTextView.placeholder = "识别、粘贴或输入文字…"
        let sourceHeader = row([label("原文"), sourceLanguageLabel, NSView(), copySourceButton], spacing: 6)
        let targetHeader = row([resultTitle, NSView(), targetPopup, copyTranslationButton], spacing: 6)
        let sourceFooter = row([formatPopup, NSView(), retryButton])
        let targetFooter = row([useResultButton, NSView(), translateButton])
        let sourcePane = textPane(view: sourceTextView, editable: true, header: sourceHeader, footer: sourceFooter)
        translationPane = textPane(view: translatedTextView, editable: false, header: targetHeader, footer: targetFooter)
        let panes = row([sourcePane, translationPane], spacing: 12)
        panes.distribution = .fillEqually
        panes.alignment = .top
        panes.setContentHuggingPriority(.defaultLow, for: .vertical)
        sourcePane.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true
        translationPane.heightAnchor.constraint(equalTo: panes.heightAnchor).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = AppPalette.color(.secondaryText)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([spinner, statusLabel, cancelButton, NSView(), resultCount, closeButton])
        let content = column([header, previewStack, options, panes, footer], spacing: 14)
        let container = AppSurfaceView(role: .background, cornerRadius: 0, bordered: false)
        container.appearance = NSAppearance(named: .aqua)
        window?.contentView = container
        pin(content, inside: container, inset: 20)
        for section in [header, previewStack, options, panes, footer] {
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    private func configure(_ button: NSButton, _ action: Selector, glyph: ToolbarGlyph? = nil) {
        button.target = self
        button.action = action
        if let glyph { button.image = ToolbarGlyph.image(glyph) }
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], label: String, action: Selector) {
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel(label)
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func pin(_ content: NSView, inside container: NSView, inset: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    private func label(_ title: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: secondary ? 12 : 14, weight: secondary ? .medium : .semibold)
        label.textColor = AppPalette.color(secondary ? .secondaryText : .text)
        return label
    }

    private func textPane(view: NSTextView, editable: Bool, header: NSView, footer: NSView) -> AppSurfaceView {
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = editable
        view.font = .systemFont(ofSize: 15)
        view.textColor = AppPalette.color(.text)
        view.insertionPointColor = AppPalette.color(.accent)
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        view.defaultParagraphStyle = paragraph
        view.setAccessibilityLabel(editable ? "原文，可编辑" : "译文")
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let content = column([header, scroll, footer], spacing: 10)
        let card = AppSurfaceView(cornerRadius: 24)
        pin(content, inside: card, inset: 16)
        for item in [header, scroll, footer] {
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return card
    }

    private func animateLayout(_ changes: () -> Void) {
        changes()
        window?.contentView?.layoutSubtreeIfNeeded()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = window?.contentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "layoutTransition")
    }

    private func revealResult() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = translatedTextView.enclosingScrollView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "resultReveal")
    }

    private func updatePreview() {
        previewImage.isHidden = !previewExpanded
        previewToggle.image = NSImage(systemSymbolName: previewExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        previewToggle.setAccessibilityExpanded(previewExpanded)
        updateMinimumHeight()
        window?.contentView?.needsLayout = true
    }

    private func updateMinimumHeight() {
        guard let window else { return }
        let optionsHeight: CGFloat = mode == .rewrite ? 50 + (instructionExpanded ? 46 : 0) : 0
        let minimumHeight = max(540, 430 + optionsHeight + (previewExpanded ? 88 : 0))
        window.contentMinSize = NSSize(width: 680, height: minimumHeight)
        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        guard contentHeight < minimumHeight else { return }
        let delta = minimumHeight - contentHeight
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true)
    }

    @objc private func togglePreview() {
        animateLayout {
            previewExpanded.toggle()
            updatePreview()
        }
    }

    @objc private func toggleInstruction() {
        animateLayout {
            instructionExpanded.toggle()
            instructionField.isHidden = !instructionExpanded
            instructionToggle.image = NSImage(systemSymbolName: instructionExpanded ? "minus" : "plus", accessibilityDescription: nil)
            instructionToggle.setAccessibilityExpanded(instructionExpanded)
            updateMinimumHeight()
        }
        if instructionExpanded { window?.makeFirstResponder(instructionField) }
    }

    private func updateControls() {
        reselectButton.isHidden = onReselect == nil
        guard translationPane != nil else { return }
        let hasResult = !translatedTextView.string.isEmpty
        let rewriting = mode == .rewrite
        translationPane.isHidden = mode == .text
        rewriteControls.isHidden = !rewriting
        updateMinimumHeight()
        targetPopup.isHidden = mode != .translation
        translateButton.title = rewriting ? "润色" : "翻译"
        copyTranslationButton.title = rewriting ? "复制结果" : "复制译文"
        resultTitle.stringValue = rewriting ? "润色结果" : "译文"
        translatedTextView.setAccessibilityLabel(resultTitle.stringValue)
        useResultButton.title = rewriting ? "用作原文" : "润色译文"
        useResultButton.isHidden = !hasResult
        useResultButton.isEnabled = hasResult && !phase.isBusy
        settingsButton.isHidden = onOpenSettings == nil
        copySourceButton.isEnabled = !sourceText.isEmpty
        copyTranslationButton.isEnabled = hasResult && !phase.isBusy
        translateButton.isEnabled = !sourceText.isEmpty && !phase.isBusy
        sourceTextView.isEditable = phase != .recognizing
        retryButton.isEnabled = !phase.isBusy
        formatPopup.isEnabled = !sourceText.isEmpty && !phase.isBusy
        cancelButton.isHidden = !phase.isBusy
        spinner.isHidden = !phase.isBusy
        resultCount.stringValue = mode == .text || !hasResult ? "" : "\(translatedTextView.string.count) 字"
        if phase.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        sourceTextView.placeholder = phase == .recognizing ? "正在识别截图中的文字…" : "识别、粘贴或输入文字…"
        translatedTextView.placeholder = rewriting ? "选择语气和篇幅，点击润色。\n保留原意，让表达更顺畅。" : "选择目标语言，点击翻译。"
        if phase == .translating { translatedTextView.placeholder = "正在生成译文…" }
        if phase == .rewriting { translatedTextView.placeholder = "正在润色文字…" }
        statusLabel.textColor = AppPalette.color(.secondaryText)
        switch phase {
        case .recognizing: statusLabel.stringValue = "正在识别文字…"
        case .translating: statusLabel.stringValue = "正在翻译…"
        case .rewriting: statusLabel.stringValue = "正在润色…"
        case .ready:
            statusLabel.stringValue = sourceText.isEmpty ? "" : "原文 \(sourceTextView.string.count) 字，可直接编辑"
        case .cancelled: statusLabel.stringValue = "任务已取消，可以重试或返回编辑"
        case .failed(let message):
            statusLabel.stringValue = message
            statusLabel.textColor = AppPalette.color(.error)
        }
    }

    private func updateSourceLanguage() {
        guard let language = TranslationTargetResolver.detectedSourceLanguage(sourceTextView.string) else {
            sourceLanguageLabel.stringValue = ""
            return
        }
        sourceLanguageLabel.stringValue = Locale(identifier: "zh-Hans").localizedString(forLanguageCode: language) ?? language
    }

    private func formatted(_ text: String) -> String {
        guard formatPopup.indexOfSelectedItem == 1 else { return text }
        unmergedText = text
        return TextRecognitionResult.mergingLineBreaks(in: text)
    }

    private func copy(_ text: String, button: NSButton) {
        guard !text.isEmpty, ClipboardService.copyString(text) else {
            statusLabel.stringValue = "复制失败，请重试"
            return
        }
        statusLabel.stringValue = button === copySourceButton ? "文字已复制" : (mode == .rewrite ? "润色结果已复制" : "译文已复制")
    }

    private func selectMode(_ newMode: Mode) {
        invalidateOperation()
        mode = newMode
        modeControl.selectedSegment = newMode.rawValue
        let result = results[newMode]
        translatedTextView.string = result?.request == currentRequest ? result?.text ?? "" : ""
        animateLayout { phase = .ready }
        if sourceText.isEmpty && recognitionResult == nil {
            startRecognition()
        } else if mode == .translation && !sourceText.isEmpty && translatedTextView.string.isEmpty {
            translateText()
        }
    }

    @objc private func modeChanged() {
        guard let selected = Mode(rawValue: modeControl.selectedSegment) else { return }
        selectMode(selected)
    }

    @objc private func targetChanged() {
        guard TranslationTarget.allCases.indices.contains(targetPopup.indexOfSelectedItem) else { return }
        target = TranslationTarget.allCases[targetPopup.indexOfSelectedItem]
        results.removeValue(forKey: .translation)
        if !sourceText.isEmpty { translateText() }
    }

    private func invalidateRewrite() {
        results.removeValue(forKey: .rewrite)
        guard phase != .recognizing else { return }
        invalidateOperation()
        if mode == .rewrite { translatedTextView.string = "" }
        phase = .ready
    }

    @objc private func rewriteOptionsChanged() { invalidateRewrite() }

    @objc private func formatChanged() {
        invalidateOperation()
        if formatPopup.indexOfSelectedItem == 1 {
            sourceTextView.string = formatted(sourceTextView.string)
        } else if let unmergedText {
            sourceTextView.string = unmergedText
            self.unmergedText = nil
        }
        results.removeAll()
        translatedTextView.string = ""
        updateSourceLanguage()
        phase = .ready
    }

    @objc private func useResult() {
        let result = translatedTextView.string
        guard !result.isEmpty, !phase.isBusy else { return }
        let wasTranslation = mode == .translation
        window?.makeFirstResponder(sourceTextView)
        sourceTextView.breakUndoCoalescing()
        sourceTextView.insertText(result, replacementRange: NSRange(location: 0, length: (sourceTextView.string as NSString).length))
        sourceTextView.undoManager?.setActionName(wasTranslation ? "润色译文" : "使用润色结果")
        if wasTranslation { selectMode(.rewrite) }
        statusLabel.stringValue = "已放入原文，可继续编辑或撤销"
    }

    @objc private func retry() { startRecognition() }
    @objc private func processTapped() {
        window?.makeFirstResponder(sourceTextView)
        if let request = currentRequest { processText(request) }
    }
    @objc private func cancelTapped() { cancelOperation() }
    @objc private func copySource() { copy(sourceTextView.string, button: copySourceButton) }
    @objc private func copyTranslation() { copy(translatedTextView.string, button: copyTranslationButton) }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func reselect() {
        let callback = onReselect
        close()
        callback?()
    }
    @objc private func closeTapped() { close() }
}

@MainActor
final class RecognitionTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    override var string: String { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            (placeholder as NSString).draw(in: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y,
                width: max(0, bounds.width - textContainerOrigin.x * 2), height: 80),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15),
                    .foregroundColor: AppPalette.color(.secondaryText)])
        }
    }
}

@MainActor
private final class RecognitionPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
