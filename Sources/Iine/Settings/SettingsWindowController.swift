import AppKit
import Carbon.HIToolbox
import IineCore

/// 热键录制控件：点击进入录制，按下组合键写入，Esc 取消。
@MainActor
final class HotkeyRecorderView: NSView {
    var hotkey: Hotkey {
        didSet { refreshAppearance() }
    }
    var onChange: ((Hotkey) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            refreshAppearance()
            onRecordingChange?(isRecording)
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let surface = AppSurfaceView(cornerRadius: 10)
    var hasConflict = false { didSet { refreshAppearance() } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 36) }

    init(hotkey: Hotkey, label title: String = "快捷键") {
        self.hotkey = hotkey
        super.init(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        label.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = "点击录制快捷键，Esc 取消"
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 180),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.keyCode == 36 || event.keyCode == 49 {
                beginRecording()
            } else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        // 字母数字单键做全局热键会抢走正常输入，只接受带修饰键的组合；功能键保持可单按。
        guard modifiers != 0 || Self.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        let recorded = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        isRecording = false
        hotkey = recorded
        refreshAppearance()
        onChange?(recorded)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            cancelRecording()
            surface.borderRole = hasConflict ? .error : .outline
        }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        refreshAppearance()
        return accepted
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        beginRecording()
        return true
    }

    private func refreshAppearance() {
        label.stringValue = isRecording ? "按下快捷键…" : hotkey.displayName
        label.textColor = AppPalette.color(isRecording ? .accent : .text)
        surface.surfaceRole = isRecording ? .accentSurface : .surface
        surface.borderRole = isRecording || window?.firstResponder === self ? .accent : (hasConflict ? .error : .outline)
        setAccessibilityValue(label.stringValue)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        (96...122).contains(keyCode)
    }
}

enum SettingsSection: Int, CaseIterable {
    case general, shortcuts, output, translation, hotCorners

    var title: String {
        switch self {
        case .general: return "常规"
        case .shortcuts: return "快捷键"
        case .output: return "保存与复制"
        case .translation: return "翻译与润色"
        case .hotCorners: return "触发角"
        }
    }
}

/// 设置的编辑与展示，持久化仍由 SettingsStore 负责。
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    struct CredentialAccess {
        let status: () -> TranslationCredentialStore.Status
        let save: (String) -> Bool
        let clear: () -> Bool

        static var keychain: CredentialAccess {
            let store = TranslationCredentialStore()
            return CredentialAccess(status: store.status, save: store.save, clear: store.delete)
        }
    }

    private let credentials: CredentialAccess
    private let store: SettingsStore
    private var settings: Settings
    private let onChange: (Settings) -> Void
    /// 录制期间需要暂停全局热键，否则按下的旧组合会直接触发对应功能。
    var onRecordingStateChange: ((Bool) -> Void)?

    private(set) var hotkeyRecorders: [HotkeyAction: HotkeyRecorderView] = [:]
    private(set) var statusLabels: [HotkeyAction: NSTextField] = [:]
    let directoryLabel = NSTextField(labelWithString: "")
    let chooseDirectoryButton = AppActionButton(title: "选择文件夹", emphasis: .secondary, target: nil, action: nil)
    private let restoreCapacityTitle = "贴图恢复上限"
    let restoreCapacityField = AppTextField()
    private(set) var restoreCapacityInput: AppNumberInput!
    private(set) var dwellInput: AppNumberInput!
    let autoSelectCheckbox = AppSwitch(title: "自动选中标注", target: nil, action: nil)
    let detectElementsCheckbox = AppSwitch(title: "检测界面元素", target: nil, action: nil)
    let aspectRatioPopup = AppPopUpButton()
    let shadowCheckbox = AppSwitch(title: "导出阴影", target: nil, action: nil)
    let copyAsFilePopup = AppPopUpButton()
    let hotCornerCheckbox = AppSwitch(title: "启用触发角", target: nil, action: nil)
    private(set) var hotCornerBoxes: [ScreenCorner: NSButton] = [:]
    let dwellField = AppTextField()
    let whiteboardCheckbox = AppSwitch(title: "白板模式", target: nil, action: nil)
    let whiteboardColorWell = AppColorWell()
    let whiteboardColorHexField = AppTextField()
    let whiteboardTransparentCheckbox = AppSwitch(title: "透明背景", target: nil, action: nil)
    let translationBackendPopup = AppPopUpButton()
    let translationTargetPopup = AppPopUpButton()
    let translationEndpointField = AppTextField()
    let deepSeekModelField = AppTextField()
    let deepSeekKeyField = PasteableSecureTextField()
    let saveKeyButton = AppActionButton(title: "保存密钥", emphasis: .primary, target: nil, action: nil)
    let clearKeyButton = AppActionButton(title: "移除密钥", emphasis: .secondary, target: nil, action: nil)
    let translationKeyStatus = NSTextField(labelWithString: "")
    /// 透明模式下背景枚举不保留颜色，用这个值让取消勾选时恢复用户上次选的纯色。
    private var lastWhiteboardSolidColor: RGBAColor = .white
    private(set) var sectionControl: AppModeControl!
    private(set) var selectedSection: SettingsSection = .general
    private(set) var cloudConfigStack: NSStackView!
    private var pages: [SettingsSection: SettingsPageView] = [:]
    private let scrollView = SettingsScrollView()
    private let footerHint = NSTextField(labelWithString: "设置会即时生效")
    private let translationHint = NSTextField(wrappingLabelWithString: "")
    let resetButton = AppActionButton(title: "恢复默认", emphasis: .secondary, target: nil, action: nil)

    init(store: SettingsStore, settings: Settings, credentialAccess: CredentialAccess? = nil, onChange: @escaping (Settings) -> Void) {
        self.store = store
        self.credentials = credentialAccess ?? .keychain
        self.settings = settings
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppPalette.color(.background)
        // 程序创建的窗口默认关闭即释放，菜单再次打开会变成野指针。
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未使用")
    }

    func show() {
        if selectedSection == .translation { refreshCredentialStatus() }
        window?.level = .normal
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 注册失败的组合在对应行标红，成功时清空提示。
    func showRegistrationFailures(_ failures: Set<HotkeyAction>) {
        for (action, label) in statusLabels {
            label.stringValue = failures.contains(action) ? "被其他程序占用" : ""
            label.isHidden = !failures.contains(action)
            hotkeyRecorders[action]?.hasConflict = failures.contains(action)
        }
        scrollView.needsLayout = true
    }

    private func buildContent() {
        configureControls()
        sectionControl = AppModeControl(labels: SettingsSection.allCases.map(\.title), target: self, action: #selector(sectionChanged))
        sectionControl.selectedSegment = SettingsSection.general.rawValue
        sectionControl.setAccessibilityLabel("设置分类")
        pages[.general] = SettingsPageView(content: generalPage())
        pages[.shortcuts] = SettingsPageView(content: shortcutsPage())
        pages[.output] = SettingsPageView(content: outputPage())
        pages[.translation] = SettingsPageView(content: translationPage())
        pages[.hotCorners] = SettingsPageView(content: hotCornersPage())

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let surface = AppSurfaceView()
        pin(scrollView, inside: surface, inset: 0)
        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = AppPalette.color(.secondaryText)
        let footer = row([resetButton, NSView(), footerHint])
        let header = row([sectionControl, NSView()])
        let content = column([header, surface, footer], spacing: 16)
        let container = AppSurfaceView(role: .background, cornerRadius: 0, bordered: false)
        window?.contentView = container
        pin(content, inside: container, inset: 20)
        window?.initialFirstResponder = sectionControl
        for item in [header, surface, footer] {
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        selectSection(.general)
    }

    private func configureControls() {
        chooseDirectoryButton.target = self
        chooseDirectoryButton.action = #selector(chooseDirectory)
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults)
        configure(restoreCapacityField, action: #selector(restoreCapacityCommitted), label: restoreCapacityTitle)
        configure(dwellField, action: #selector(dwellCommitted), label: "触发角停留时间")
        for (field, range) in [(restoreCapacityField, Settings.restoreCapacityRange), (dwellField, HotCornerSettings.dwellRange)] {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: range.lowerBound)
            formatter.maximum = NSNumber(value: range.upperBound)
            field.formatter = formatter
        }
        restoreCapacityInput = AppNumberInput(field: restoreCapacityField, range: Settings.restoreCapacityRange, label: restoreCapacityTitle)
        dwellInput = AppNumberInput(field: dwellField, range: HotCornerSettings.dwellRange, step: 100, label: "触发角停留时间")
        for (button, action) in [(autoSelectCheckbox, #selector(autoSelectToggled)),
            (detectElementsCheckbox, #selector(detectElementsToggled)), (shadowCheckbox, #selector(shadowToggled)),
            (hotCornerCheckbox, #selector(hotCornersToggled)), (whiteboardCheckbox, #selector(whiteboardToggled)),
            (whiteboardTransparentCheckbox, #selector(whiteboardTransparentToggled))] {
            button.target = self
            button.action = action
        }
        for (popup, labels, action) in [
            (aspectRatioPopup, SelectionAspectRatio.allCases.map(\.title), #selector(aspectRatioChanged)),
            (copyAsFilePopup, CopyAsFileTrigger.allCases.map(\.title), #selector(copyAsFileChanged)),
            (translationBackendPopup, TranslationBackend.allCases.map(\.title), #selector(translationBackendChanged)),
            (translationTargetPopup, TranslationTarget.allCases.map(\.title), #selector(translationTargetChanged))] {
            popup.addItems(withTitles: labels)
            popup.target = self
            popup.action = action
        }
        aspectRatioPopup.setAccessibilityLabel("默认选区比例")
        copyAsFilePopup.setAccessibilityLabel("复制为文件")
        translationBackendPopup.setAccessibilityLabel("翻译服务")
        translationTargetPopup.setAccessibilityLabel("默认翻译方向")
        configure(translationEndpointField, action: #selector(translationEndpointCommitted), label: "接口地址")
        configure(deepSeekModelField, action: #selector(deepSeekModelCommitted), label: "模型 ID")
        configure(whiteboardColorHexField, action: #selector(whiteboardHexCommitted), label: "白板颜色十六进制")
        translationEndpointField.placeholderString = DeepSeekTranslationProvider.defaultEndpoint
        translationEndpointField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        deepSeekModelField.placeholderString = "deepseek-chat"
        deepSeekKeyField.placeholderString = "输入 API Key"
        deepSeekKeyField.setAccessibilityLabel("API Key")
        deepSeekKeyField.delegate = self
        whiteboardColorHexField.placeholderString = "#RRGGBB"
        whiteboardColorHexField.widthAnchor.constraint(equalToConstant: 112).isActive = true
        whiteboardColorWell.target = self
        whiteboardColorWell.action = #selector(whiteboardColorChanged)
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveDeepSeekKey)
        clearKeyButton.target = self
        clearKeyButton.action = #selector(clearDeepSeekKey)
        translationKeyStatus.font = .systemFont(ofSize: 11)
        translationKeyStatus.textColor = AppPalette.color(.secondaryText)
        translationHint.font = .systemFont(ofSize: 12)
        translationHint.textColor = AppPalette.color(.secondaryText)
    }

    private func generalPage() -> NSStackView {
        let background = row([whiteboardColorWell, whiteboardColorHexField])
        return page([
            heading("截图与标注"),
            settingRow("自动选中标注", detail: "截图时，绘制完成后选中刚创建的对象", control: autoSelectCheckbox),
            settingRow("检测界面元素", detail: "辅助定位按钮、输入框等界面区域", control: detectElementsCheckbox),
            settingRow("默认选区比例", control: aspectRatioPopup),
            heading("贴图"),
            settingRow(restoreCapacityTitle,
                detail: "应用运行期间保留最近关闭的贴图。剪贴板仍是上次贴图的内容时，再按贴图快捷键恢复。",
                control: row([restoreCapacityInput, label("张", secondary: true)])),
            heading("白板"),
            settingRow("白板模式", detail: "用纯色或透明背景开始截图", control: whiteboardCheckbox),
            settingRow("透明背景", control: whiteboardTransparentCheckbox),
            settingRow("背景颜色", control: background),
        ])
    }

    private func shortcutsPage() -> NSStackView {
        var rows: [NSView] = [hint("点击右侧按键后录制新快捷键，按 Esc 取消。")]
        for action in HotkeyAction.allCases {
            let recorder = HotkeyRecorderView(hotkey: settings.hotkey(for: action), label: action.title + "快捷键")
            recorder.onChange = { [weak self] in self?.hotkeyRecorded($0, for: action) }
            recorder.onRecordingChange = { [weak self] in self?.onRecordingStateChange?($0) }
            hotkeyRecorders[action] = recorder
            let status = label("", secondary: true)
            status.font = .systemFont(ofSize: 11)
            status.textColor = AppPalette.color(.error)
            status.isHidden = true
            statusLabels[action] = status
            rows.append(settingRow(action.title, control: column([recorder, status], spacing: 5)))
        }
        return page(rows)
    }

    private func outputPage() -> NSStackView {
        directoryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        directoryLabel.textColor = AppPalette.color(.text)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let location = row([directoryLabel, chooseDirectoryButton])
        return page([
            fieldGroup("快捷保存目录", control: location),
            settingRow("导出阴影", detail: "保存或复制图像时添加阴影", control: shadowCheckbox),
            settingRow("复制为图片文件", detail: "在剪贴板中放入可粘贴的 PNG 文件", control: copyAsFilePopup),
        ])
    }

    private func translationPage() -> NSStackView {
        let keyActions = row([translationKeyStatus, NSView(), saveKeyButton, clearKeyButton])
        let key = column([deepSeekKeyField, keyActions], spacing: 8)
        deepSeekKeyField.widthAnchor.constraint(equalTo: key.widthAnchor).isActive = true
        keyActions.widthAnchor.constraint(equalTo: key.widthAnchor).isActive = true
        cloudConfigStack = page([
            heading("AI 服务"),
            fieldGroup("接口地址", control: translationEndpointField),
            fieldGroup("模型 ID", control: deepSeekModelField),
            fieldGroup("API Key", control: key),
        ])
        return page([
            settingRow("翻译服务", control: translationBackendPopup),
            settingRow("默认翻译方向", detail: "自动模式下，中文译为英文，其他语言译为中文", control: translationTargetPopup),
            translationHint,
            cloudConfigStack,
        ])
    }

    private func hotCornersPage() -> NSStackView {
        for corner in [ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            hotCornerBoxes[corner] = AppToggleButton(title: corner.title, target: self, action: #selector(hotCornerToggled(_:)))
        }
        let top = row([hotCornerBoxes[.topLeft]!, NSView(), hotCornerBoxes[.topRight]!])
        let bottom = row([hotCornerBoxes[.bottomLeft]!, NSView(), hotCornerBoxes[.bottomRight]!])
        let screenLabel = label("屏幕", secondary: true)
        screenLabel.alignment = .center
        let diagramContent = column([top, screenLabel, bottom], spacing: 14)
        let diagram = AppSurfaceView(role: .surfaceVariant, cornerRadius: 12, bordered: false)
        pin(diagramContent, inside: diagram, inset: 16)
        for item in [top, screenLabel, bottom] { item.widthAnchor.constraint(equalTo: diagramContent.widthAnchor).isActive = true }
        return page([
            settingRow("启用触发角", detail: "鼠标停留在所选角落后，自动开始截图", control: hotCornerCheckbox),
            diagram,
            settingRow("停留时间", detail: "短暂经过角落时不会触发", control: row([dwellInput, label("毫秒", secondary: true)])),
        ])
    }

    private func configure(_ field: NSTextField, action: Selector, label title: String) {
        field.alignment = .left
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityLabel(title)
    }

    private func page(_ views: [NSView]) -> NSStackView {
        let stack = column(views, spacing: 18)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func settingRow(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        let texts = column([label(title)] + (detail.map { [hint($0)] } ?? []), spacing: 4)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = row([texts, NSView(), control], spacing: 16)
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 40 : 54).isActive = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    private func fieldGroup(_ title: String, control: NSView) -> NSStackView {
        let stack = column([label(title), control], spacing: 8)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: secondary ? .regular : .medium)
        label.textColor = AppPalette.color(secondary ? .secondaryText : .text)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = AppPalette.color(.secondaryText)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func heading(_ text: String) -> NSTextField {
        let field = label(text)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        return field
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

    @objc private func sectionChanged() {
        guard let section = SettingsSection(rawValue: sectionControl.selectedSegment) else { return }
        selectSection(section)
    }

    func selectSection(_ section: SettingsSection) {
        window?.makeFirstResponder(nil)
        stopRecording()
        selectedSection = section
        sectionControl.selectedSegment = section.rawValue
        scrollView.documentView = pages[section]
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        if section == .translation { refreshCredentialStatus() }
        updateFooterHint()
    }

    private func stopRecording() {
        for recorder in hotkeyRecorders.values where recorder.isRecording { recorder.cancelRecording() }
    }

    private func updateTranslationHint() {
        let cloud = settings.translationBackend == .deepSeek
        translationHint.stringValue = cloud
            ? "翻译与润色共用下方 AI 服务，支持兼容 OpenAI 的接口。密钥保存在本机钥匙串。"
            : "系统翻译在本机运行，需要 macOS 26 及对应语言包。润色使用下方 AI 服务。"
        updateFooterHint()
        scrollView.needsLayout = true
    }

    private func updateFooterHint() {
        footerHint.stringValue = selectedSection == .translation
            ? "API Key 需单独保存" : "设置会即时生效"
    }

    private func updateHotCornerControls() {
        let enabled = hotCornerCheckbox.state == .on
        for button in hotCornerBoxes.values { button.isEnabled = enabled }
        dwellInput.isEnabled = enabled
    }

    private func refreshControls() {
        for action in HotkeyAction.allCases {
            hotkeyRecorders[action]?.hotkey = settings.hotkey(for: action)
        }
        updateDirectoryLabel()
        restoreCapacityField.integerValue = settings.restoreCapacity
        restoreCapacityInput.refresh()
        autoSelectCheckbox.state = settings.autoSelectOnCreation ? .on : .off
        detectElementsCheckbox.state = settings.detectUIElements ? .on : .off
        if let index = SelectionAspectRatio.allCases.firstIndex(of: settings.selectionAspectRatio) {
            aspectRatioPopup.selectItem(at: index)
        }
        shadowCheckbox.state = settings.exportShadow ? .on : .off
        if let index = CopyAsFileTrigger.allCases.firstIndex(of: settings.copyAsFileTrigger) {
            copyAsFilePopup.selectItem(at: index)
        }
        hotCornerCheckbox.state = settings.hotCorners.enabled ? .on : .off
        for (corner, box) in hotCornerBoxes {
            box.state = settings.hotCorners.corners.contains(corner) ? .on : .off
        }
        dwellField.integerValue = settings.hotCorners.dwellMilliseconds
        whiteboardCheckbox.state = settings.whiteboard.enabled ? .on : .off
        let whiteboardBackground = settings.whiteboard.background
        let isTransparent = whiteboardBackground == .transparent
        if case .solid(let solid) = whiteboardBackground {
            lastWhiteboardSolidColor = solid
        }
        whiteboardTransparentCheckbox.state = isTransparent ? .on : .off
        whiteboardColorWell.color = NSColor(
            srgbRed: lastWhiteboardSolidColor.r,
            green: lastWhiteboardSolidColor.g,
            blue: lastWhiteboardSolidColor.b,
            alpha: lastWhiteboardSolidColor.a
        )
        whiteboardColorHexField.stringValue = lastWhiteboardSolidColor.hexString
        updateWhiteboardColorControlsEnabled()
        if let index = TranslationBackend.allCases.firstIndex(of: settings.translationBackend) {
            translationBackendPopup.selectItem(at: index)
        }
        translationTargetPopup.selectItem(
            at: TranslationTarget(rawValue: settings.translationTargetLanguage)
                .flatMap { TranslationTarget.allCases.firstIndex(of: $0) } ?? 0
        )
        translationEndpointField.stringValue = settings.translationEndpoint
        deepSeekModelField.stringValue = settings.deepSeekModel
        saveKeyButton.isEnabled = !deepSeekKeyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        updateTranslationHint()
        updateHotCornerControls()
        showRegistrationFailures([])
    }

    private func refreshCredentialStatus() {
        let status = credentials.status()
        switch status {
        case .saved: translationKeyStatus.stringValue = "已保存到钥匙串"
        case .missing: translationKeyStatus.stringValue = "尚未保存密钥"
        case .unavailable: translationKeyStatus.stringValue = "暂时无法确认钥匙串状态"
        }
        translationKeyStatus.textColor = AppPalette.color(.secondaryText)
        clearKeyButton.isEnabled = status != .missing
    }

    private func updateDirectoryLabel() {
        directoryLabel.stringValue = settings.quickSaveDirectory ?? "~/Pictures/ii ne"
        directoryLabel.toolTip = directoryLabel.stringValue
    }

    private func hotkeyRecorded(_ hotkey: Hotkey, for action: HotkeyAction) {
        settings.setHotkey(hotkey, for: action)
        apply()
    }

    private func apply() {
        settings.clamp()
        store.save(settings)
        onChange(settings)
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = settings.quickSaveDirectory
            .map { URL(fileURLWithPath: $0) } ?? QuickSaveStore().directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.quickSaveDirectory = url.path
        updateDirectoryLabel()
        apply()
    }

    @objc private func restoreCapacityCommitted() {
        let typed = restoreCapacityField.integerValue
        // 空输入或 0 恢复为当前值，避免把「没填」当成要清空恢复列表。
        settings.restoreCapacity = typed == 0 ? settings.restoreCapacity : typed
        settings.clampRestoreCapacity()
        restoreCapacityField.integerValue = settings.restoreCapacity
        restoreCapacityInput.refresh()
        apply()
    }

    @objc private func autoSelectToggled() {
        settings.autoSelectOnCreation = autoSelectCheckbox.state == .on
        apply()
    }

    /// 开启时未授权只做引导：设置照常保存，截图时静默回落到窗口吸附。
    @objc private func detectElementsToggled() {
        settings.detectUIElements = detectElementsCheckbox.state == .on
        apply()
        guard settings.detectUIElements, !UIElementDetector.isTrusted else { return }
        // 先登记进「辅助功能」列表，否则系统设置里根本没有本应用可勾选。
        UIElementDetector.requestTrust()
        presentAccessibilityAlert()
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        自动检测 UI 元素需要辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 \
        Iine，然后关闭并重新开启本开关以生效。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(
                      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                  ) else { return }
            NSWorkspace.shared.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    @objc private func aspectRatioChanged() {
        let index = aspectRatioPopup.indexOfSelectedItem
        guard SelectionAspectRatio.allCases.indices.contains(index) else { return }
        settings.selectionAspectRatio = SelectionAspectRatio.allCases[index]
        apply()
    }

    @objc private func shadowToggled() {
        settings.exportShadow = shadowCheckbox.state == .on
        apply()
    }

    @objc private func copyAsFileChanged() {
        let index = copyAsFilePopup.indexOfSelectedItem
        guard CopyAsFileTrigger.allCases.indices.contains(index) else { return }
        settings.copyAsFileTrigger = CopyAsFileTrigger.allCases[index]
        apply()
    }

    @objc private func translationBackendChanged() {
        window?.makeFirstResponder(nil)
        let index = translationBackendPopup.indexOfSelectedItem
        guard TranslationBackend.allCases.indices.contains(index) else { return }
        settings.translationBackend = TranslationBackend.allCases[index]
        updateTranslationHint()
        apply()
    }

    /// 空输入保持当前值，不把「没填」当成清空目标语言。
    @objc private func translationTargetChanged() {
        let index = translationTargetPopup.indexOfSelectedItem
        guard TranslationTarget.allCases.indices.contains(index) else { return }
        settings.translationTargetLanguage = TranslationTarget.allCases[index].rawValue
        apply()
    }

    @objc private func translationEndpointCommitted() {
        let typed = translationEndpointField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.translationEndpoint = typed.isEmpty
            ? DeepSeekTranslationProvider.defaultEndpoint
            : typed
        translationEndpointField.stringValue = settings.translationEndpoint
        apply()
    }

    @objc private func deepSeekModelCommitted() {
        let typed = deepSeekModelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.deepSeekModel = typed.isEmpty ? settings.deepSeekModel : typed
        deepSeekModelField.stringValue = settings.deepSeekModel
        apply()
    }

    @objc private func saveDeepSeekKey() {
        let typed = deepSeekKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else {
            NSSound.beep()
            translationKeyStatus.stringValue = "请先输入 API Key"
            translationKeyStatus.textColor = AppPalette.color(.error)
            return
        }
        guard credentials.save(typed) else {
            translationKeyStatus.stringValue = "保存失败"
            translationKeyStatus.textColor = AppPalette.color(.error)
            return
        }
        // 不把明文回显在界面上，保存成功立即清空输入框。
        deepSeekKeyField.stringValue = ""
        translationKeyStatus.stringValue = "已保存到钥匙串"
        translationKeyStatus.textColor = AppPalette.color(.secondaryText)
        saveKeyButton.isEnabled = false
        clearKeyButton.isEnabled = true
    }

    @objc private func clearDeepSeekKey() {
        guard credentials.clear() else {
            translationKeyStatus.stringValue = "未能移除，请重试"
            translationKeyStatus.textColor = AppPalette.color(.error)
            return
        }
        deepSeekKeyField.stringValue = ""
        refreshCredentialStatus()
        saveKeyButton.isEnabled = false
    }

    @objc private func hotCornersToggled() {
        settings.hotCorners.enabled = hotCornerCheckbox.state == .on
        updateHotCornerControls()
        apply()
    }

    @objc private func hotCornerToggled(_ sender: NSButton) {
        guard let corner = hotCornerBoxes.first(where: { $0.value === sender })?.key else { return }
        if sender.state == .on {
            settings.hotCorners.corners.insert(corner)
        } else {
            settings.hotCorners.corners.remove(corner)
        }
        apply()
    }

    @objc private func dwellCommitted() {
        let typed = dwellField.integerValue
        // 空输入或 0 保持当前值，不把「没填」当成 0 毫秒。
        settings.hotCorners.dwellMilliseconds = typed == 0
            ? settings.hotCorners.dwellMilliseconds : typed
        settings.hotCorners.clampDwell()
        dwellField.integerValue = settings.hotCorners.dwellMilliseconds
        dwellInput.refresh()
        apply()
    }

    @objc private func whiteboardToggled() {
        settings.whiteboard.enabled = whiteboardCheckbox.state == .on
        updateWhiteboardColorControlsEnabled()
        apply()
    }

    @objc private func whiteboardTransparentToggled() {
        let transparent = whiteboardTransparentCheckbox.state == .on
        settings.whiteboard.background = transparent
            ? .transparent
            : .solid(currentWhiteboardColor())
        updateWhiteboardColorControlsEnabled()
        apply()
    }

    @objc private func whiteboardColorChanged() {
        let color = currentWhiteboardColor()
        lastWhiteboardSolidColor = color
        settings.whiteboard.background = .solid(color)
        whiteboardColorHexField.stringValue = color.hexString
        apply()
    }

    /// 非法输入不落库，回填当前颜色，避免设置里出现无法解析的字符串。
    @objc private func whiteboardHexCommitted() {
        let color = WhiteboardColor.parse(whiteboardColorHexField.stringValue) ?? .white
        lastWhiteboardSolidColor = color
        settings.whiteboard.background = .solid(color)
        whiteboardColorHexField.stringValue = color.hexString
        whiteboardColorWell.color = NSColor(
            srgbRed: color.r,
            green: color.g,
            blue: color.b,
            alpha: color.a
        )
        apply()
    }

    private func currentWhiteboardColor() -> RGBAColor {
        let color = whiteboardColorWell.color.usingColorSpace(.sRGB) ?? .white
        return RGBAColor(
            r: color.redComponent,
            g: color.greenComponent,
            b: color.blueComponent,
            a: color.alphaComponent
        )
    }

    /// 透明背景没有颜色可调，禁用颜色控件避免用户误以为修改会生效。
    private func updateWhiteboardColorControlsEnabled() {
        whiteboardTransparentCheckbox.isEnabled = whiteboardCheckbox.state == .on
        let enabled = whiteboardCheckbox.state == .on && whiteboardTransparentCheckbox.state != .on
        whiteboardColorWell.isEnabled = enabled
        whiteboardColorHexField.isEnabled = enabled
        if !enabled { whiteboardColorWell.deactivate() }
    }

    @objc private func resetToDefaults() {
        window?.makeFirstResponder(nil)
        stopRecording()
        settings = .standard
        refreshControls()
        apply()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === restoreCapacityField {
            restoreCapacityCommitted()
        } else if field === dwellField {
            dwellCommitted()
        } else if field === whiteboardColorHexField {
            whiteboardHexCommitted()
        } else if field === translationEndpointField {
            translationEndpointCommitted()
        } else if field === deepSeekModelField {
            deepSeekModelCommitted()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === restoreCapacityField {
            restoreCapacityInput.refresh()
        } else if field === dwellField {
            dwellInput.refresh()
        } else if field === deepSeekKeyField {
            saveKeyButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
    }

    /// 窗口关闭时若还在录制，热键会停在注销状态，这里负责恢复注册。
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        stopRecording()
    }
}

/// NSSecureTextField 默认吞掉 ⌘V，密钥类输入需要粘贴，单开这一条快捷键。
final class PasteableSecureTextField: AppSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let editor = currentEditor() as? NSTextView {
                editor.paste(nil)
            } else {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}


@MainActor
private final class SettingsPageView: NSView {
    private let stack: NSStackView
    override var isFlipped: Bool { true }

    init(content: NSStackView) {
        stack = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func fit(width: CGFloat, minimumHeight: CGFloat) {
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        layoutSubtreeIfNeeded()
        let height = max(minimumHeight, ceil(stack.fittingSize.height) + 40)
        if frame.height != height { setFrameSize(NSSize(width: width, height: height)) }
    }
}

@MainActor
private final class SettingsScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? SettingsPageView)?.fit(width: contentSize.width, minimumHeight: contentSize.height)
    }
}
