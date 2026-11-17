import AppKit
import IineCore

/// 工具条图标的视觉稿：把所有自绘图标按工具条的实际尺寸渲染成一张对比图，
/// 供人眼检查笔画粗细、光学尺寸、可辨识度。不做断言，只出图。
@MainActor
final class GlyphSheet {
    private let cell = NSSize(width: 80, height: 74)

    private let toolItems: [(ToolbarGlyph, String)] = [
        (.select, "选择"), (.rect, "矩形"), (.roundedRect, "圆角矩形"), (.ellipse, "椭圆"),
        (.line, "直线"), (.arrow, "箭头"), (.polyline, "折线"), (.brush, "画笔"),
        (.marker, "记号笔"), (.mosaic, "涂抹马赛克"), (.mosaicRect, "区域马赛克"), (.blur, "模糊"),
        (.magnify, "局部放大"), (.text, "文字"), (.serial, "序号"), (.eraser, "橡皮擦"),
        (.undo, "撤销"), (.redo, "重做"), (.copy, "复制"), (.extractText, "提取文字"),
        (.translate, "翻译"), (.scroll, "滚动截图"), (.barcode, "识别码"), (.save, "保存"),
        (.pin, "贴到屏幕"), (.share, "分享"), (.check, "完成"), (.close, "关闭"),
        (.more, "更多"), (.chevronDown, "展开"), (.zoomOut, "缩小"), (.zoomIn, "放大"),
        (.rotateLeft, "左转"), (.rotateRight, "右转"), (.flipHorizontal, "水平翻转"),
        (.flipVertical, "垂直翻转"), (.grayscale, "灰度"), (.invert, "反色"),
    ]

    func render() -> NSImage {
        let columns = 8
        let rows = (toolItems.count + columns - 1) / columns
        // 最后两行展示笔宽、线型和背景状态。
        let size = NSSize(
            width: CGFloat(columns) * cell.width + 40,
            height: CGFloat(rows) * cell.height + 186
        )
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        for (index, item) in toolItems.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = CGPoint(
                x: 20 + CGFloat(column) * cell.width,
                y: size.height - CGFloat(row + 1) * cell.height - 20
            )
            draw(glyph: item.0, label: item.1, at: origin)
        }

        // 状态图标：笔宽 / 线型 / 背景 / 箭头。
        let stateOrigin = CGPoint(x: 20, y: size.height - CGFloat(rows) * cell.height - 100)
        let states: [(NSImage, String)] = [
            (ToolbarGlyph.penWidth(.p1), "细笔宽"),
            (ToolbarGlyph.penWidth(.p3), "中笔宽"),
            (ToolbarGlyph.penWidth(.p5), "粗笔宽"),
            (ToolbarGlyph.lineStyle(.solid), "实线"),
            (ToolbarGlyph.lineStyle(.dashed), "虚线"),
            (ToolbarGlyph.lineStyle(.dotted), "点线"),
            (ToolbarGlyph.arrowHeads(.end), "单向箭头"),
            (ToolbarGlyph.arrowHeads(.both), "双向箭头"),
            (ToolbarGlyph.arrowHeads(.start), "反向箭头"),
            (ToolbarGlyph.background(.none, tint: .white), "无背景"),
            (ToolbarGlyph.background(.white, tint: .white), "白背景"),
            (ToolbarGlyph.background(.black, tint: .white), "黑背景"),
            (ToolbarGlyph.background(.tint, tint: .systemRed), "彩色背景"),
        ]
        for (index, item) in states.enumerated() {
            let origin = CGPoint(
                x: stateOrigin.x + CGFloat(index % 8) * cell.width,
                y: stateOrigin.y - CGFloat(index / 8) * cell.height
            )
            draw(image: item.0, label: item.1, at: origin)
        }

        image.unlockFocus()
        return image
    }

    private func draw(glyph: ToolbarGlyph, label: String, at origin: CGPoint) {
        draw(image: ToolbarGlyph.image(glyph), label: label, at: origin)
    }

    private func draw(image glyph: NSImage, label: String, at origin: CGPoint) {
        // 按照实际主工具条的点击区域展示图标。
        let buttonRect = NSRect(
            x: origin.x + (cell.width - 34) / 2,
            y: origin.y + 26,
            width: 34,
            height: 34
        )
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 6, yRadius: 6).fill()

        let glyphSize = glyph.size
        let glyphRect = NSRect(
            x: buttonRect.midX - glyphSize.width / 2,
            y: buttonRect.midY - glyphSize.height / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        // 自绘图标本来就是白色笔画，直接画即可；isTemplate 只影响 NSButton 的着色。
        glyph.draw(in: glyphRect)

        let text = label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: origin.x + (cell.width - textSize.width) / 2, y: origin.y + 8),
            withAttributes: attributes)
    }

    /// 单独导出一张 1:1 的工具条图，便于按像素检查间距与对齐。
    func writeToolbar(to path: String) {
        let bar = AnnotateToolbar(
            initialKind: .arrow,
            initialStyle: ShapeCatalog.entry(for: .arrow)?.defaultStyle
                ?? Style(color: RGBAColor.palette[0], pen: .p3)
        )
        bar.updateTranslationTarget(.auto)
        let size = bar.frame.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.35, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("TOOLBAR \(path) \(Int(size.width))x\(Int(size.height))")
    }

    /// 贴图标注底栏：同一套图标，单独出图核对。
    func writePinBar(to path: String) {
        let bar = PinAnnotateBar()
        bar.updateState(tool: .rect, color: RGBAColor.palette[0], pen: .p3, canUndo: true)
        bar.layoutSubtreeIfNeeded()
        let size = bar.intrinsicContentSize
        bar.frame = NSRect(origin: .zero, size: size)
        bar.layoutSubtreeIfNeeded()
        let image = NSImage(size: size)
        image.lockFocus()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("PINBAR \(path) \(Int(size.width))x\(Int(size.height))")
    }

    func write(to path: String) {
        let image = render()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SHEET \(path)")
    }
}

@main
struct ToolbarGlyphSheetMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let sheet = GlyphSheet()
            sheet.write(to: "/tmp/iine-verify/evidence/toolbar-glyphs.png")
            sheet.writeToolbar(to: "/tmp/iine-verify/evidence/toolbar.png")
            sheet.writePinBar(to: "/tmp/iine-verify/evidence/pin-bar.png")
        }
    }
}