import AppKit
import Foundation
import IineCore

@MainActor
final class SettingsHarness {
    private var passes = 0
    private var failures = 0
    private var lastChange: Settings?
    private var recordingChanges: [Bool] = []
    private let evidence = URL(fileURLWithPath: "/tmp/iine-verify/evidence/settings", isDirectory: true)

    private struct Missing: Error { let message: String }
    private final class Credentials {
        var value: String?
        var shouldFailSave = false
        var saves = 0
        var clears = 0
    }

    private func check(_ id: String, _ condition: Bool, _ detail: String) {
        if condition {
            passes += 1
            print("PASS \(id) \(detail)")
        } else {
            failures += 1
            print("FAIL \(id) \(detail)")
        }
    }

    private func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Missing(message: message) }
        return value
    }

    private func collect<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        if let value = root as? T { found.append(value) }
        for child in root.subviews { found.append(contentsOf: collect(type, in: child)) }
        return found
    }

    private func sendAction(_ control: NSControl) {
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
    }

    private func commit(_ value: String, to field: NSTextField) {
        field.stringValue = value
        sendAction(field)
    }

    private func navigate(_ section: SettingsSection, in controller: SettingsWindowController) {
        guard let index = SettingsSection.allCases.firstIndex(of: section) else { return }
        controller.sectionControl.selectedSegment = index
        sendAction(controller.sectionControl)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func key(_ code: UInt16, text: String, flags: NSEvent.ModifierFlags = [], to view: NSView) throws {
        let event = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
            keyCode: code), "无法构造键盘事件")
        view.keyDown(with: event)
    }

    private func clickRecorder(_ recorder: HotkeyRecorderView) throws {
        let point = recorder.convert(NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil)
        let event = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: recorder.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "无法构造录制点击")
        recorder.mouseDown(with: event)
    }

    private func render(_ view: NSView, named name: String) throws -> Data {
        view.layoutSubtreeIfNeeded()
        var data: Data?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: representation)
                data = representation.representation(using: .png, properties: [:])
            }
        }
        let png = try require(data, "无法渲染 \(name)")
        try png.write(to: evidence.appendingPathComponent(name + ".png"))
        return png
    }

    private func renderedBytes(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        var data: Data?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let image = representation.cgImage,
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let bytes = context.data { data = Data(bytes: bytes, count: image.width * image.height * 4) }
        }
        return try require(data, "无法读取控件渲染像素")
    }

    private func resolved(_ color: NSColor, in view: NSView) throws -> NSColor {
        var value: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.sRGB) }
        return try require(value, "无法解析颜色")
    }

    private func background(behind view: NSView) throws -> NSColor {
        if let field = view as? NSTextField, field.drawsBackground {
            return try resolved(field.backgroundColor ?? .textBackgroundColor, in: field)
        }
        var ancestor: NSView? = view
        while let current = ancestor {
            if let color = current.layer?.backgroundColor, color.alpha >= 0.99,
               let value = NSColor(cgColor: color) {
                return try resolved(value, in: current)
            }
            ancestor = current.superview
        }
        return try resolved(view.window?.backgroundColor ?? .windowBackgroundColor, in: view)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        let values = [color.redComponent, color.greenComponent, color.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }

    private func contrast(_ field: NSTextField) throws -> CGFloat {
        let foreground = try resolved(field.textColor ?? .labelColor, in: field)
        let backdrop = try background(behind: field)
        let alpha = foreground.alphaComponent
        let composed = NSColor(srgbRed: foreground.redComponent * alpha + backdrop.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + backdrop.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + backdrop.blueComponent * (1 - alpha), alpha: 1)
        let light = luminance(composed)
        let dark = luminance(backdrop)
        return (max(light, dark) + 0.05) / (min(light, dark) + 0.05)
    }

    private func sectionName(_ section: SettingsSection) -> String {
        switch section {
        case .general: return "general"
        case .shortcuts: return "shortcuts"
        case .output: return "output"
        case .translation: return "translation"
        case .hotCorners: return "hot-corners"
        }
    }

    private func general(_ controller: SettingsWindowController, store: SettingsStore) throws {
        navigate(.general, in: controller)
        check("auto-select", controller.autoSelectCheckbox.state == .on, "自动选中默认开启")
        let selectBefore = store.load().autoSelectOnCreation
        controller.autoSelectCheckbox.performClick(nil)
        check("auto-select-toggle", store.load().autoSelectOnCreation == !selectBefore,
            "自动选中开关写回")
        check("auto-select-callback", lastChange?.autoSelectOnCreation == !selectBefore,
            "运行设置回调收到新值")
        check("detect-elements-default", controller.detectElementsCheckbox.state == .off && !store.load().detectUIElements,
            "界面元素检测默认关闭，测试不请求系统权限")
        check("aspect-ratio-default", controller.aspectRatioPopup.titleOfSelectedItem == "自由", "选区比例默认自由")
        controller.aspectRatioPopup.selectItem(withTitle: "16:9")
        sendAction(controller.aspectRatioPopup)
        check("aspect-ratio-write", store.load().selectionAspectRatio == .sixteenNine, "选区比例选择写回")

        commit("7", to: controller.restoreCapacityField)
        check("capacity-write", store.load().restoreCapacity == 7, "手工数量写回7")
        controller.restoreCapacityInput.plusButton.performClick(nil)
        check("capacity-increment", store.load().restoreCapacity == 8 && controller.restoreCapacityField.integerValue == 8,
            "加号同步数量和存储")
        controller.restoreCapacityInput.minusButton.performClick(nil)
        check("capacity-decrement", store.load().restoreCapacity == 7, "减号同步数量和存储")
        commit("20", to: controller.restoreCapacityField)
        check("capacity-upper-bound", !controller.restoreCapacityInput.plusButton.isEnabled && store.load().restoreCapacity == 20,
            "上限20禁止继续增加")
        commit("1", to: controller.restoreCapacityField)
        check("capacity-lower-bound", !controller.restoreCapacityInput.minusButton.isEnabled && store.load().restoreCapacity == 1,
            "下限1禁止继续减少")
        commit("7", to: controller.restoreCapacityField)
        commit("0", to: controller.restoreCapacityField)
        check("capacity-empty-safe", store.load().restoreCapacity == 7 && controller.restoreCapacityField.integerValue == 7,
            "零值恢复原数量")

        let whiteboardBefore = store.load().whiteboard.enabled
        controller.whiteboardCheckbox.performClick(nil)
        check("whiteboard-toggle", store.load().whiteboard.enabled == !whiteboardBefore, "白板开关写回")
        controller.whiteboardColorWell.color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        sendAction(controller.whiteboardColorWell)
        if case .solid(let color) = store.load().whiteboard.background {
            check("whiteboard-color", abs(color.r - 0.1) < 0.01 && abs(color.g - 0.2) < 0.01 && abs(color.b - 0.3) < 0.01,
                "原生色盘修改保存为对应RGB")
        } else { check("whiteboard-color", false, "背景未保存为纯色") }
        commit("#112233", to: controller.whiteboardColorHexField)
        check("whiteboard-hex", store.load().whiteboard.background == .solid(RGBAColor(r: 17.0 / 255, g: 34.0 / 255, b: 51.0 / 255)),
            "十六进制颜色写回")
        commit("not-a-color", to: controller.whiteboardColorHexField)
        check("whiteboard-hex-fallback", store.load().whiteboard.background == .solid(.white)
            && controller.whiteboardColorHexField.stringValue == "#ffffff", "无效颜色恢复白色")
        controller.whiteboardTransparentCheckbox.performClick(nil)
        check("whiteboard-transparent", store.load().whiteboard.background == .transparent
            && !controller.whiteboardColorWell.isEnabled && !controller.whiteboardColorHexField.isEnabled,
            "透明背景禁用颜色编辑")
        controller.whiteboardTransparentCheckbox.performClick(nil)
        check("whiteboard-transparent-off", store.load().whiteboard.background == .solid(.white)
            && controller.whiteboardColorWell.isEnabled && controller.whiteboardColorHexField.isEnabled,
            "取消透明恢复颜色编辑")
        controller.whiteboardCheckbox.performClick(nil)
        check("whiteboard-disabled", !controller.whiteboardColorWell.isEnabled && !controller.whiteboardColorHexField.isEnabled
            && !controller.whiteboardTransparentCheckbox.isEnabled, "关闭白板后从属控件禁用")
        controller.whiteboardCheckbox.performClick(nil)

        let content = try require(controller.window?.contentView, "设置内容缺失")
        let switches = collect(AppSwitch.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        let labels = collect(NSTextField.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        check("switch-labels", !switches.isEmpty && switches.allSatisfy { toggle in
            toggle.bounds.width <= 48 && labels.filter { $0.stringValue == toggle.title }.count <= 1
        }, "开关保留紧凑轨道，旁边没有重复标签")
    }

    private func numberEditingNavigation(_ controller: SettingsWindowController, store: SettingsStore) throws {
        let window = try require(controller.window, "设置窗口缺失")
        for value in ["99", ""] {
            navigate(.general, in: controller)
            commit("7", to: controller.restoreCapacityField)
            window.makeFirstResponder(controller.restoreCapacityField)
            let editor = try require(controller.restoreCapacityField.currentEditor() as? NSTextView, "数值输入没有原生field editor")
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(value, replacementRange: editor.selectedRange())
            let entered = editor.string
            navigate(.output, in: controller)
            let fieldVisible = !controller.restoreCapacityField.isHiddenOrHasHiddenAncestor
                && controller.restoreCapacityField.window === window
                && !controller.restoreCapacityField.visibleRect.isEmpty
            let retainsEditor = window.firstResponder === editor
            let hiddenEditor = retainsEditor && !fieldVisible
            let retainedPendingValue = controller.selectedSection == .general && editor.string == entered
            let validCommittedValue = controller.selectedSection == .output
                && Settings.restoreCapacityRange.contains(store.load().restoreCapacity)
                && controller.restoreCapacityField.integerValue == store.load().restoreCapacity
                && !retainsEditor
            check(value.isEmpty ? "empty-number-navigation" : "invalid-number-navigation",
                !hiddenEditor && (retainedPendingValue || validCommittedValue),
                "输入 \(value.debugDescription)，编辑值 \(entered.debugDescription)，页面 \(controller.selectedSection)，焦点仍在编辑器 \(retainsEditor)，字段可见 \(fieldVisible)，存储 \(store.load().restoreCapacity)")
            _ = controller.restoreCapacityField.abortEditing()
            window.makeFirstResponder(nil)
            commit("7", to: controller.restoreCapacityField)
        }
    }

    private func output(_ controller: SettingsWindowController, store: SettingsStore) {
        navigate(.output, in: controller)
        check("directory-button", !controller.chooseDirectoryButton.isHiddenOrHasHiddenAncestor,
            "保存页面可访问选择目录操作")
        check("directory-label", !controller.directoryLabel.stringValue.isEmpty,
            "保存目录有可读显示")
        let before = store.load().exportShadow
        controller.shadowCheckbox.performClick(nil)
        check("shadow-toggle", store.load().exportShadow == !before, "导出阴影开关写回")
        controller.copyAsFilePopup.selectItem(at: CopyAsFileTrigger.allCases.firstIndex(of: .always)!)
        sendAction(controller.copyAsFilePopup)
        check("copy-file-policy", store.load().copyAsFileTrigger == .always, "复制文件策略写回")
    }

    private func corners(_ controller: SettingsWindowController, store: SettingsStore) throws {
        navigate(.hotCorners, in: controller)
        check("hot-corner-disabled", !controller.dwellField.isEnabled
            && controller.hotCornerBoxes.values.allSatisfy { !$0.isEnabled }, "未启用时角落和停留时间不可修改")
        controller.hotCornerCheckbox.performClick(nil)
        check("hot-corner-toggle", store.load().hotCorners.enabled && controller.dwellField.isEnabled
            && controller.hotCornerBoxes.values.allSatisfy(\.isEnabled), "启用后从属控件可用")
        let topLeft = try require(controller.hotCornerBoxes[.topLeft], "缺少左上角按钮")
        let before = store.load().hotCorners.corners.contains(.topLeft)
        topLeft.performClick(nil)
        check("hot-corner-select", store.load().hotCorners.corners.contains(.topLeft) == !before, "角落选择写回")
        commit("750", to: controller.dwellField)
        check("dwell-write", store.load().hotCorners.dwellMilliseconds == 750, "停留时间保存750毫秒")
        controller.dwellInput.plusButton.performClick(nil)
        check("dwell-increment", store.load().hotCorners.dwellMilliseconds == 850, "加号增加100毫秒")
        controller.dwellInput.minusButton.performClick(nil)
        check("dwell-decrement", store.load().hotCorners.dwellMilliseconds == 750, "减号减少100毫秒")
        commit("3000", to: controller.dwellField)
        check("dwell-upper-bound", !controller.dwellInput.plusButton.isEnabled, "最大停留时间禁止继续增加")
        commit("100", to: controller.dwellField)
        check("dwell-lower-bound", !controller.dwellInput.minusButton.isEnabled, "最小停留时间禁止继续减少")
        commit("750", to: controller.dwellField)
        let selected = store.load().hotCorners.corners
        controller.hotCornerCheckbox.performClick(nil)
        check("hot-corner-preserve", store.load().hotCorners.corners == selected && !controller.dwellField.isEnabled,
            "关闭触发角保留角落选择")
        controller.hotCornerCheckbox.performClick(nil)
    }

    private func shortcuts(_ controller: SettingsWindowController, store: SettingsStore) throws {
        navigate(.shortcuts, in: controller)
        let window = try require(controller.window, "设置窗口缺失")
        let content = try require(window.contentView, "设置内容缺失")
        check("hotkey-controls", collect(HotkeyRecorderView.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }.count == HotkeyAction.allCases.count,
            "快捷键页显示四个录制入口")
        let recorder = try require(controller.hotkeyRecorders[.snip], "截图快捷键控件缺失")
        try clickRecorder(recorder)
        check("recording-state", recorder.isRecording && recordingChanges.last == true, "点击录制暂停全局快捷键")
        let previous = store.load().snipHotkey
        try key(0, text: "a", to: recorder)
        check("hotkey-rejects-bare-letter", recorder.isRecording && store.load().snipHotkey == previous,
            "单字母不注册为全局快捷键")
        try key(11, text: "b", flags: [.control, .shift], to: recorder)
        check("hotkey-record", store.load().snipHotkey.keyCode == 11 && store.load().snipHotkey.modifiers == 0x1200,
            "Ctrl+Shift+B保存为快捷键")
        check("hotkey-display", recorder.hotkey.displayName == "⌃⇧B", "录制结果正确显示")
        check("recording-finished", !recorder.isRecording && recordingChanges.last == false,
            "录制完成恢复全局快捷键")
        try clickRecorder(recorder)
        window.appearance = NSAppearance(named: .darkAqua)
        _ = try render(content, named: "settings-shortcuts-recording")
        try key(53, text: "\u{1b}", to: recorder)
        check("escape-cancels", !recorder.isRecording && store.load().snipHotkey.keyCode == 11
            && recordingChanges.last == false, "Esc取消录制并保留原快捷键")
        try clickRecorder(recorder)
        navigate(.general, in: controller)
        check("navigation-cancels-recording", !recorder.isRecording && recordingChanges.last == false,
            "切页取消隐藏的录制会话")
        navigate(.shortcuts, in: controller)
        controller.showRegistrationFailures([.pin])
        check("failure-mark", controller.statusLabels[.pin]?.stringValue == "被其他程序占用"
            && controller.statusLabels[.snip]?.stringValue == "", "占用提示只出现在对应快捷键")
        _ = try render(content, named: "settings-shortcuts-conflict")
        controller.showRegistrationFailures([])
    }

    private func keyText(_ value: String, controller: SettingsWindowController) {
        controller.deepSeekKeyField.stringValue = value
        controller.deepSeekKeyField.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: controller.deepSeekKeyField))
    }

    private func translation(_ controller: SettingsWindowController, store: SettingsStore, credentials: Credentials) throws {
        navigate(.translation, in: controller)
        check("translation-system", !controller.translationEndpointField.isHiddenOrHasHiddenAncestor
            && !controller.deepSeekKeyField.isHiddenOrHasHiddenAncestor, "系统翻译下仍可配置润色使用的 AI 服务")
        let content = try require(controller.window?.contentView, "设置内容缺失")
        let systemLabels = collect(NSTextField.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        check("translation-system-hint", systemLabels.contains { $0.stringValue.contains("系统翻译在本机运行")
            && $0.stringValue.contains("润色使用下方 AI 服务") },
            "系统翻译页面说明本地翻译与云端润色的配置用途")
        _ = try render(content, named: "settings-translation-system")
        controller.translationBackendPopup.selectItem(at: TranslationBackend.allCases.firstIndex(of: .deepSeek)!)
        sendAction(controller.translationBackendPopup)
        check("translation-cloud", !controller.translationEndpointField.isHiddenOrHasHiddenAncestor
            && !controller.deepSeekKeyField.isHiddenOrHasHiddenAncestor, "兼容接口显示完整配置")
        let endpoint = "https://api.example.invalid/compatible/openai/v1/chat/completions"
        commit(endpoint, to: controller.translationEndpointField)
        commit("model-for-settings-preview", to: controller.deepSeekModelField)
        check("translation-fields", store.load().translationEndpoint == endpoint
            && store.load().deepSeekModel == "model-for-settings-preview", "接口和模型输入持久化")
        check("translation-alignment", controller.translationEndpointField.alignment == .left
            && controller.deepSeekModelField.alignment == .left, "接口和模型文字从左侧开始显示")
        controller.translationTargetPopup.selectItem(at: TranslationTarget.allCases.firstIndex(of: .ja)!)
        sendAction(controller.translationTargetPopup)
        check("translation-language", store.load().translationTargetLanguage == TranslationTarget.ja.rawValue,
            "默认翻译语言保存")
        controller.translationBackendPopup.selectItem(at: TranslationBackend.allCases.firstIndex(of: .system)!)
        sendAction(controller.translationBackendPopup)
        let switchedSystemLabels = collect(NSTextField.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        check("translation-system-preserves", !controller.deepSeekKeyField.isHiddenOrHasHiddenAncestor
            && store.load().translationEndpoint == endpoint
            && store.load().deepSeekModel == "model-for-settings-preview"
            && store.load().translationBackend == .system
            && switchedSystemLabels.contains { $0.stringValue.contains("润色使用下方 AI 服务") },
            "切换系统翻译后保留可编辑的润色服务配置")
        controller.translationBackendPopup.selectItem(at: TranslationBackend.allCases.firstIndex(of: .deepSeek)!)
        sendAction(controller.translationBackendPopup)

        check("key-secure-cell", controller.deepSeekKeyField.cell is NSSecureTextFieldCell,
            "密钥使用原生安全输入单元")
        controller.saveKeyButton.performClick(nil)
        check("key-empty-save", credentials.value == nil && credentials.saves == 0
            && !controller.translationKeyStatus.stringValue.isEmpty, "空密钥不能提交给凭据存储")
        controller.window?.makeFirstResponder(nil)
        keyText("AAAAAAAA", controller: controller)
        let firstMask = try renderedBytes(controller.deepSeekKeyField)
        keyText("BBBBBBBB", controller: controller)
        let secondMask = try renderedBytes(controller.deepSeekKeyField)
        check("key-masked-render", firstMask == secondMask, "等长不同密钥渲染为同样的安全遮罩")
        keyText("settings-test-secret", controller: controller)
        controller.saveKeyButton.performClick(nil)
        check("key-save", credentials.value == "settings-test-secret" && credentials.saves == 1,
            "保存按钮只向注入凭据存储提交一次")
        check("key-not-echoed", controller.deepSeekKeyField.stringValue.isEmpty && controller.clearKeyButton.isEnabled,
            "保存后不回显密钥，并允许清除")
        credentials.shouldFailSave = true
        keyText("settings-test-retry", controller: controller)
        controller.saveKeyButton.performClick(nil)
        check("key-save-failure", credentials.value == "settings-test-secret"
            && controller.deepSeekKeyField.stringValue == "settings-test-retry"
            && controller.translationKeyStatus.stringValue.contains("失败"), "保存失败保留输入供重试")
        credentials.shouldFailSave = false
        controller.saveKeyButton.performClick(nil)
        check("key-save-retry", credentials.value == "settings-test-retry" && controller.deepSeekKeyField.stringValue.isEmpty,
            "重试成功后清空输入")
        controller.clearKeyButton.performClick(nil)
        check("key-clear", credentials.value == nil && credentials.clears == 1
            && controller.deepSeekKeyField.stringValue.isEmpty, "清除仅影响注入凭据")
        navigate(.general, in: controller)
        controller.autoSelectCheckbox.performClick(nil)
        check("other-page-preserves-service", store.load().translationEndpoint == endpoint
            && store.load().deepSeekModel == "model-for-settings-preview", "其他页面设置不覆盖接口配置")
        navigate(.translation, in: controller)
    }

    private func editingSurvivesClose(store: SettingsStore, defaults: UserDefaults, access: SettingsWindowController.CredentialAccess) throws {
        let inputs: [(name: String, field: (SettingsWindowController) -> NSTextField,
                      value: String, stored: (Settings) -> String)] = [
            ("endpoint", { $0.translationEndpointField },
             "https://api.example.invalid/edited-before-close/v1/chat/completions", { $0.translationEndpoint }),
            ("model", { $0.deepSeekModelField }, "model-edited-before-close", { $0.deepSeekModel }),
        ]
        for input in inputs {
            let controller = SettingsWindowController(store: store, settings: store.load(), credentialAccess: access,
                onChange: { _ in })
            defer { controller.close() }
            let window = try require(controller.window, "关闭编辑测试没有窗口")
            window.makeKeyAndOrderFront(nil)
            navigate(.translation, in: controller)
            controller.translationBackendPopup.selectItem(at: TranslationBackend.allCases.firstIndex(of: .deepSeek)!)
            sendAction(controller.translationBackendPopup)
            window.contentView?.layoutSubtreeIfNeeded()
            let field = input.field(controller)
            window.makeFirstResponder(field)
            let editor = try require(field.currentEditor() as? NSTextView, "文本框没有原生field editor")
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(input.value, replacementRange: editor.selectedRange())
            let entered = editor.string
            window.performClose(nil)
            let reloaded = SettingsStore(defaults: defaults)
            let deadline = Date().addingTimeInterval(1)
            while input.stored(reloaded.load()) != input.value, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let persisted = input.stored(reloaded.load())
            check("close-commits-\(input.name)", entered == input.value && persisted == input.value && !window.isVisible,
                "编辑内容已进入field editor \(entered == input.value)，关闭后保存 \(persisted == input.value)，窗口已关闭 \(!window.isVisible)")
        }
    }

    private func scrollToTop(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let y = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: document.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func appearanceAndLayout(_ controller: SettingsWindowController) throws {
        let window = try require(controller.window, "设置窗口缺失")
        let content = try require(window.contentView, "设置内容缺失")
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for section in SettingsSection.allCases {
                navigate(section, in: controller)
                let name = sectionName(section)
                let fields = collect(NSTextField.self, in: content).filter {
                    !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty && $0.bounds.width > 0 && !$0.visibleRect.isEmpty
                }
                let ratios = try fields.map(contrast)
                let lowest = ratios.min() ?? 0
                check("appearance-\(name)-\(suffix)", !ratios.isEmpty && lowest >= 4.5,
                    "实际标签和字段对比度至少4.5，最低 \(String(format: "%.2f", Double(lowest)))")
                for scroll in collect(NSScrollView.self, in: content) where !scroll.isHiddenOrHasHiddenAncestor { scrollToTop(scroll) }
                _ = try render(content, named: "settings-\(name)-\(suffix)")
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        navigate(.general, in: controller)
        let rootBackground = try background(behind: content)
        check("appearance-roundtrip", luminance(rootBackground) > 0.7, "同一窗口返回浅色背景")
        _ = try render(content, named: "settings-light-again")

        let originalFrame = window.frame
        let minimumContent = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let minimumFrame = NSSize(width: max(window.minSize.width, minimumContent.width),
            height: max(window.minSize.height, minimumContent.height))
        window.setFrame(NSRect(origin: originalFrame.origin, size: minimumFrame), display: true)
        content.layoutSubtreeIfNeeded()
        check("compact-width", content.bounds.width <= 721, "长接口地址不会撑大最小设置窗口")
        for section in SettingsSection.allCases {
            navigate(section, in: controller)
            let scroll = try require(collect(NSScrollView.self, in: content).first {
                !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil
            }, "设置页缺少滚动容器")
            let document = try require(scroll.documentView, "设置页文档缺失")
            let controls = collect(NSControl.self, in: document).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            let overflow = controls.filter { control in
                let rect = control.convert(control.bounds, to: document)
                return rect.minX < document.bounds.minX - 1 || rect.maxX > document.bounds.maxX + 1
            }
            check("compact-\(sectionName(section))", !controls.isEmpty && overflow.isEmpty,
                "最小窗口无横向裁切，异常控件 \(overflow.map { String(describing: type(of: $0)) })")
            var reachable = true
            for control in controls {
                _ = document.scrollToVisible(control.convert(control.bounds, to: document))
                content.layoutSubtreeIfNeeded()
                reachable = reachable && control.visibleRect.height >= control.bounds.height - 1
                    && control.visibleRect.width >= control.bounds.width - 1
            }
            check("reachable-\(sectionName(section))", reachable, "该页全部控件可滚动到完整可见")
            scrollToTop(scroll)
        }
        navigate(.translation, in: controller)
        _ = try render(content, named: "settings-translation-compact")
        window.setFrame(originalFrame, display: true)
    }

    func runAll() -> Bool {
        let suiteName = "iine.settings.e2e.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("suite", false, "无法创建测试设置存储")
            print("SUMMARY passes=\(passes) failures=\(failures)")
            return false
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let credentials = Credentials()
        let access = SettingsWindowController.CredentialAccess(
            isSaved: { credentials.value != nil },
            save: { value in
                credentials.saves += 1
                guard !credentials.shouldFailSave else { return false }
                credentials.value = value
                return true
            },
            clear: { credentials.value = nil; credentials.clears += 1 }
        )
        let controller = SettingsWindowController(store: store, settings: store.load(),
            credentialAccess: access, onChange: { [weak self] in self?.lastChange = $0 })
        controller.onRecordingStateChange = { [weak self] in self?.recordingChanges.append($0) }
        defer { controller.close() }
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            let window = try require(controller.window, "设置窗口未创建")
            let content = try require(window.contentView, "设置内容缺失")
            window.makeKeyAndOrderFront(nil)
            content.layoutSubtreeIfNeeded()
            check("window", window.title == "设置", "原生设置窗口可显示")
            check("sections", controller.sectionControl.segmentCount == 5, "五个设置页面均有导航入口")
            try general(controller, store: store)
            try numberEditingNavigation(controller, store: store)
            output(controller, store: store)
            try corners(controller, store: store)
            try shortcuts(controller, store: store)
            try translation(controller, store: store, credentials: credentials)
            try appearanceAndLayout(controller)

            navigate(.translation, in: controller)
            keyText("settings-reset-retains-credential", controller: controller)
            controller.saveKeyButton.performClick(nil)
            controller.resetButton.performClick(nil)
            check("reset-defaults", store.load() == Settings.standard, "恢复默认保存标准设置")
            check("reset-controls", controller.restoreCapacityField.integerValue == 1, "恢复默认同步控件")
            check("reset-retains-key", credentials.value == "settings-reset-retains-credential",
                "恢复普通设置不删除已保存凭据")
            check("persisted", defaults.data(forKey: SettingsStore.defaultsKey) != nil, "设置已写入独立UserDefaults")
            check("reload", SettingsStore(defaults: defaults).load() == store.load(), "重新读取设置与当前状态一致")
            navigate(.shortcuts, in: controller)
            let recorder = try require(controller.hotkeyRecorders[.pin], "贴图快捷键控件缺失")
            try clickRecorder(recorder)
            controller.close()
            check("close-cancels-recording", !recorder.isRecording && recordingChanges.last == false,
                "关闭窗口取消录制并恢复全局快捷键")
            try editingSurvivesClose(store: store, defaults: defaults, access: access)
        } catch {
            check("harness", false, String(describing: error))
        }
        print("SUMMARY passes=\(passes) failures=\(failures)")
        return failures == 0
    }
}

@main
struct SettingsE2EMain {
    static func main() {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            exit(SettingsHarness().runAll() ? 0 : 1)
        }
    }
}
