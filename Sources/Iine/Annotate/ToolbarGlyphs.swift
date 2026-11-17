import AppKit
import IineCore

/// 图标使用 24pt 网格、2pt 圆头描边，输出为 22pt 的 Retina 位图。
/// 单色图使用 template，由按钮的明确前景色着色。
enum ToolbarGlyph: CaseIterable {
    case select, rect, roundedRect, ellipse, line, arrow, polyline, brush, marker
    case mosaic, mosaicRect, blur, magnify, text, serial, eraser
    case undo, redo, copy, extractText, translate, scroll, barcode, save, pin, share, check, close, more, chevronDown
    case zoomOut, zoomIn, rotateLeft, rotateRight, flipHorizontal, flipVertical, grayscale, invert

    /// 背景循环按钮的四档。这里只画状态，语义留在工具条里。
    enum BackgroundSwatch { case none, white, black, tint }

    static let side: CGFloat = 24
    static let imageSide: CGFloat = 22

    /// 缓存键。枚举本身可 CaseIterable，用描述串足够稳定。
    var cacheKey: String {
        String(describing: self)
    }

    private static var imageCache: [String: NSImage] = [:]
    private static var stateCache: [String: NSImage] = [:]

    /// 启动后预热：把图标先画出来，用户第一次按热键不必等。
    static func preload() {
        for glyph in ToolbarGlyph.allCases { _ = image(glyph) }
        for pen in PenSize.allCases { _ = penWidth(pen) }
        for style in LineStyle.allCases { _ = lineStyle(style) }
        for heads in ArrowHeads.allCases { _ = arrowHeads(heads) }
        for swatch in [BackgroundSwatch.none, .white, .black, .tint] {
            _ = background(swatch, tint: .systemRed)
        }
        _ = colorDot(.systemRed)
    }

    /// 色块圆点保留真实颜色，边缘同时区分浅色与透明色。
    static func colorDot(_ color: NSColor, diameter: CGFloat = 14, ringed: Bool = true) -> NSImage {
        let diameter = min(max(diameter, 3), 18)
        let inset = (imageSide - diameter) / 2
        let size = NSSize(width: imageSide, height: imageSide)
        let image = NSImage(size: size)
        image.lockFocus()
        let circle = NSBezierPath(ovalIn: NSRect(
            x: inset, y: inset, width: diameter, height: diameter
        ))
        color.setFill()
        circle.fill()
        NSColor(white: 0.15, alpha: ringed ? 0.45 : 0.20).setStroke()
        circle.lineWidth = ringed ? 1.6 : 0.75
        circle.stroke()
        image.unlockFocus()
        return image
    }

    static func image(_ glyph: ToolbarGlyph) -> NSImage {
        if let cached = imageCache[glyph.cacheKey] { return cached }
        let image = build(glyph)
        imageCache[glyph.cacheKey] = image
        return image
    }

    private static func build(_ glyph: ToolbarGlyph) -> NSImage {
        make { p in
            switch glyph {
            case .select:
                p.fill(p.polygon([
                    CGPoint(x: 5, y: 22), CGPoint(x: 5, y: 4),
                    CGPoint(x: 9.5, y: 8.5), CGPoint(x: 13, y: 2),
                    CGPoint(x: 16.5, y: 3.8), CGPoint(x: 13, y: 10.3),
                    CGPoint(x: 20, y: 10.3),
                ]))
            case .rect:
                p.box(CGRect(x: 2.5, y: 5, width: 19, height: 14), radius: 0.8)
            case .roundedRect:
                p.box(CGRect(x: 2.5, y: 4, width: 19, height: 16), radius: 5)
            case .ellipse:
                p.ellipse(CGRect(x: 2.5, y: 4, width: 19, height: 16))
            case .line:
                p.line([CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 20)])
            case .arrow:
                p.line([CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 20)])
                p.line([CGPoint(x: 12, y: 20), CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 12)])
            case .polyline:
                let points = [CGPoint(x: 3, y: 6), CGPoint(x: 9, y: 18),
                    CGPoint(x: 15, y: 7), CGPoint(x: 21, y: 17)]
                p.line(points)
                for point in [points[0], points[3]] {
                    p.fillEllipse(CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2))
                }
            case .brush:
                let handle = NSBezierPath()
                handle.move(to: CGPoint(x: 9, y: 10))
                handle.line(to: CGPoint(x: 17.5, y: 21))
                handle.curve(to: CGPoint(x: 21, y: 17.5),
                    controlPoint1: CGPoint(x: 20, y: 23), controlPoint2: CGPoint(x: 23, y: 20))
                handle.line(to: CGPoint(x: 12, y: 7.5))
                handle.close()
                p.stroke(handle, width: 2, alpha: 1, dash: [])
                let tip = NSBezierPath()
                tip.move(to: CGPoint(x: 9, y: 9))
                tip.curve(to: CGPoint(x: 12, y: 5),
                    controlPoint1: CGPoint(x: 12, y: 9), controlPoint2: CGPoint(x: 13, y: 7))
                tip.curve(to: CGPoint(x: 2.5, y: 2.5),
                    controlPoint1: CGPoint(x: 10, y: 1), controlPoint2: CGPoint(x: 5, y: 2))
                tip.curve(to: CGPoint(x: 9, y: 9),
                    controlPoint1: CGPoint(x: 6, y: 4), controlPoint2: CGPoint(x: 4, y: 8.5))
                p.fill(tip)
            case .marker:
                p.line([CGPoint(x: 7, y: 9), CGPoint(x: 16, y: 21),
                    CGPoint(x: 22, y: 16), CGPoint(x: 12, y: 5), CGPoint(x: 7, y: 9)], closed: true)
                p.line([CGPoint(x: 7, y: 9), CGPoint(x: 3, y: 4), CGPoint(x: 7, y: 2.5), CGPoint(x: 12, y: 5)])
                p.line([CGPoint(x: 3, y: 2), CGPoint(x: 13, y: 2)], width: 2.5)
            case .mosaic:
                let blocks: [(CGFloat, CGFloat)] = [(3, 3), (8, 3), (13, 3),
                    (3, 8), (8, 8), (13, 8), (18, 8), (8, 13), (13, 13), (18, 13), (13, 18)]
                for (index, block) in blocks.enumerated() {
                    p.fillBox(CGRect(x: block.0, y: block.1, width: 3.5, height: 3.5),
                        radius: 0.4, alpha: index.isMultiple(of: 3) ? 0.45 : 1)
                }
            case .mosaicRect:
                p.line([CGPoint(x: 2, y: 17), CGPoint(x: 2, y: 22), CGPoint(x: 7, y: 22)], width: 1.7)
                p.line([CGPoint(x: 17, y: 2), CGPoint(x: 22, y: 2), CGPoint(x: 22, y: 7)], width: 1.7)
                for row in 0..<3 {
                    for column in 0..<3 {
                        p.fillBox(CGRect(x: 5 + CGFloat(column) * 5, y: 5 + CGFloat(row) * 5,
                            width: 4, height: 4), radius: 0.4,
                            alpha: (row + column).isMultiple(of: 2) ? 1 : 0.4)
                    }
                }
            case .blur:
                let drop = NSBezierPath()
                drop.move(to: CGPoint(x: 12, y: 22))
                drop.curve(to: CGPoint(x: 4, y: 9),
                    controlPoint1: CGPoint(x: 10, y: 18), controlPoint2: CGPoint(x: 4, y: 13))
                drop.curve(to: CGPoint(x: 20, y: 9),
                    controlPoint1: CGPoint(x: 4, y: -0.5), controlPoint2: CGPoint(x: 20, y: -0.5))
                drop.curve(to: CGPoint(x: 12, y: 22),
                    controlPoint1: CGPoint(x: 20, y: 13), controlPoint2: CGPoint(x: 14, y: 18))
                p.stroke(drop, width: 2, alpha: 1, dash: [])
                let shine = NSBezierPath()
                shine.move(to: CGPoint(x: 8, y: 10))
                shine.curve(to: CGPoint(x: 12, y: 6),
                    controlPoint1: CGPoint(x: 8, y: 7.5), controlPoint2: CGPoint(x: 9.5, y: 6))
                p.stroke(shine, width: 1.8, alpha: 0.65, dash: [])
            case .magnify, .zoomIn, .zoomOut:
                p.circle(CGPoint(x: 10.5, y: 13.5), radius: 7)
                p.line([CGPoint(x: 15.5, y: 8.5), CGPoint(x: 21.5, y: 2.5)], width: 2.4)
                p.line([CGPoint(x: 7, y: 13.5), CGPoint(x: 14, y: 13.5)], width: 1.8)
                if glyph != .zoomOut {
                    p.line([CGPoint(x: 10.5, y: 10), CGPoint(x: 10.5, y: 17)], width: 1.8)
                }
            case .text:
                p.line([CGPoint(x: 4, y: 18), CGPoint(x: 4, y: 21),
                    CGPoint(x: 20, y: 21), CGPoint(x: 20, y: 18)])
                p.line([CGPoint(x: 12, y: 21), CGPoint(x: 12, y: 3)])
                p.line([CGPoint(x: 8, y: 3), CGPoint(x: 16, y: 3)])
            case .serial:
                p.circle(CGPoint(x: 12, y: 12), radius: 9)
                p.line([CGPoint(x: 9.5, y: 15), CGPoint(x: 12.5, y: 17), CGPoint(x: 12.5, y: 7)], width: 1.8)
                p.line([CGPoint(x: 10, y: 7), CGPoint(x: 15, y: 7)], width: 1.8)
            case .eraser:
                p.line([CGPoint(x: 3, y: 9), CGPoint(x: 12, y: 21),
                    CGPoint(x: 22, y: 13), CGPoint(x: 14, y: 3),
                    CGPoint(x: 10, y: 3), CGPoint(x: 3, y: 9)], closed: true)
                p.line([CGPoint(x: 7.5, y: 15), CGPoint(x: 17.5, y: 7)])
                p.line([CGPoint(x: 10, y: 3), CGPoint(x: 22, y: 3)])
            case .undo, .redo:
                if glyph == .redo {
                    let mirror = NSAffineTransform()
                    mirror.translateX(by: side, yBy: 0)
                    mirror.scaleX(by: -1, yBy: 1)
                    mirror.concat()
                }
                let curve = NSBezierPath()
                curve.move(to: CGPoint(x: 3, y: 16))
                curve.line(to: CGPoint(x: 13, y: 16))
                curve.curve(to: CGPoint(x: 13, y: 4),
                    controlPoint1: CGPoint(x: 23, y: 16), controlPoint2: CGPoint(x: 23, y: 4))
                p.stroke(curve, width: 2, alpha: 1, dash: [])
                p.line([CGPoint(x: 8, y: 21), CGPoint(x: 3, y: 16), CGPoint(x: 8, y: 11)])
            case .copy:
                p.line([CGPoint(x: 14, y: 21), CGPoint(x: 3, y: 21), CGPoint(x: 3, y: 8)])
                p.box(CGRect(x: 8, y: 3, width: 13, height: 14), radius: 1.5)
            case .extractText:
                p.line([CGPoint(x: 2.5, y: 16), CGPoint(x: 2.5, y: 21.5), CGPoint(x: 8, y: 21.5)])
                p.line([CGPoint(x: 16, y: 21.5), CGPoint(x: 21.5, y: 21.5), CGPoint(x: 21.5, y: 16)])
                p.line([CGPoint(x: 2.5, y: 8), CGPoint(x: 2.5, y: 2.5), CGPoint(x: 8, y: 2.5)])
                p.line([CGPoint(x: 16, y: 2.5), CGPoint(x: 21.5, y: 2.5), CGPoint(x: 21.5, y: 8)])
                p.line([CGPoint(x: 7.5, y: 16), CGPoint(x: 16.5, y: 16)], width: 1.8)
                p.line([CGPoint(x: 12, y: 16), CGPoint(x: 12, y: 8)], width: 1.8)
            case .translate:
                p.line([CGPoint(x: 2, y: 18.5), CGPoint(x: 13, y: 18.5)], width: 1.8)
                p.line([CGPoint(x: 7, y: 22), CGPoint(x: 7, y: 18.5)], width: 1.8)
                p.line([CGPoint(x: 11, y: 18.5), CGPoint(x: 8.5, y: 13), CGPoint(x: 2.5, y: 8)], width: 1.8)
                p.line([CGPoint(x: 4.5, y: 15.5), CGPoint(x: 7.5, y: 12), CGPoint(x: 12, y: 9)], width: 1.8)
                p.line([CGPoint(x: 12.5, y: 2.5), CGPoint(x: 17, y: 14), CGPoint(x: 21.5, y: 2.5)], width: 1.8)
                p.line([CGPoint(x: 14, y: 6.5), CGPoint(x: 20, y: 6.5)], width: 1.8)
            case .scroll:
                p.box(CGRect(x: 2.5, y: 3, width: 12, height: 18), radius: 1.5, width: 1.8)
                p.line([CGPoint(x: 6, y: 16.5), CGPoint(x: 11, y: 16.5)], width: 1.7)
                p.line([CGPoint(x: 6, y: 12), CGPoint(x: 11, y: 12)], width: 1.7)
                p.line([CGPoint(x: 6, y: 7.5), CGPoint(x: 9, y: 7.5)], width: 1.7)
                p.line([CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 4)], width: 1.8)
                p.line([CGPoint(x: 17, y: 7), CGPoint(x: 20, y: 4), CGPoint(x: 23, y: 7)], width: 1.8)
            case .barcode:
                for rect in [CGRect(x: 2.5, y: 15, width: 6.5, height: 6.5),
                    CGRect(x: 15, y: 15, width: 6.5, height: 6.5),
                    CGRect(x: 2.5, y: 2.5, width: 6.5, height: 6.5)] {
                    p.box(rect, radius: 0.3, width: 1.8)
                    p.fillBox(rect.insetBy(dx: 2.2, dy: 2.2), radius: 0)
                }
                p.line([CGPoint(x: 15, y: 8.5), CGPoint(x: 15, y: 3), CGPoint(x: 21, y: 3)], width: 2)
                p.fillBox(CGRect(x: 19, y: 7, width: 3, height: 3), radius: 0)
            case .save:
                p.line([CGPoint(x: 3, y: 3), CGPoint(x: 21, y: 3), CGPoint(x: 21, y: 17),
                    CGPoint(x: 17, y: 21), CGPoint(x: 3, y: 21), CGPoint(x: 3, y: 3)], closed: true)
                p.line([CGPoint(x: 7.5, y: 21), CGPoint(x: 7.5, y: 14), CGPoint(x: 16.5, y: 14), CGPoint(x: 16.5, y: 21)], width: 1.8)
                p.line([CGPoint(x: 7.5, y: 3), CGPoint(x: 7.5, y: 9), CGPoint(x: 16.5, y: 9), CGPoint(x: 16.5, y: 3)], width: 1.8)
            case .pin:
                p.box(CGRect(x: 7, y: 18, width: 10, height: 3), radius: 0.7, width: 1.8)
                p.line([CGPoint(x: 8, y: 18), CGPoint(x: 8, y: 12), CGPoint(x: 4.5, y: 8),
                    CGPoint(x: 19.5, y: 8), CGPoint(x: 16, y: 12), CGPoint(x: 16, y: 18)], width: 1.8)
                p.line([CGPoint(x: 12, y: 8), CGPoint(x: 12, y: 2)])
            case .share:
                p.line([CGPoint(x: 3, y: 12), CGPoint(x: 3, y: 3), CGPoint(x: 21, y: 3), CGPoint(x: 21, y: 12)])
                p.line([CGPoint(x: 12, y: 9), CGPoint(x: 12, y: 22)])
                p.line([CGPoint(x: 7, y: 17), CGPoint(x: 12, y: 22), CGPoint(x: 17, y: 17)])
            case .check:
                p.line([CGPoint(x: 3, y: 12), CGPoint(x: 10, y: 5), CGPoint(x: 21, y: 19)], width: 2.2)
            case .close:
                p.line([CGPoint(x: 5, y: 19), CGPoint(x: 19, y: 5)])
                p.line([CGPoint(x: 5, y: 5), CGPoint(x: 19, y: 19)])
            case .more:
                for x: CGFloat in [5, 12, 19] {
                    p.fillEllipse(CGRect(x: x - 1.4, y: 10.6, width: 2.8, height: 2.8))
                }
            case .chevronDown:
                p.line([CGPoint(x: 7.5, y: 14.5), CGPoint(x: 12, y: 10), CGPoint(x: 16.5, y: 14.5)])
            case .rotateLeft, .rotateRight:
                if glyph == .rotateRight {
                    let mirror = NSAffineTransform()
                    mirror.translateX(by: side, yBy: 0)
                    mirror.scaleX(by: -1, yBy: 1)
                    mirror.concat()
                }
                p.arc(center: CGPoint(x: 12, y: 12), radius: 8, from: 145, to: -145, width: 2)
                p.line([CGPoint(x: 5.5, y: 21.5), CGPoint(x: 5.5, y: 16.5), CGPoint(x: 10.5, y: 16.5)])
            case .flipHorizontal, .flipVertical:
                if glyph == .flipVertical {
                    let turn = NSAffineTransform()
                    turn.translateX(by: 12, yBy: 12)
                    turn.rotate(byDegrees: 90)
                    turn.translateX(by: -12, yBy: -12)
                    turn.concat()
                }
                p.line([CGPoint(x: 12, y: 2), CGPoint(x: 12, y: 22)], width: 1.5, dash: [2, 3])
                p.line([CGPoint(x: 8, y: 4), CGPoint(x: 2.5, y: 12), CGPoint(x: 8, y: 20)], width: 1.8, closed: true)
                p.line([CGPoint(x: 16, y: 4), CGPoint(x: 21.5, y: 12), CGPoint(x: 16, y: 20)], width: 1.8, closed: true)
            case .grayscale:
                let circle = NSBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 18, height: 18))
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                for (index, alpha) in [CGFloat(1), 0.65, 0.3].enumerated() {
                    p.fillBox(CGRect(x: 3 + CGFloat(index) * 6, y: 3, width: 6, height: 18),
                        radius: 0, alpha: alpha)
                }
                NSGraphicsContext.restoreGraphicsState()
                p.circle(CGPoint(x: 12, y: 12), radius: 9)
            case .invert:
                p.fill(p.polygon([CGPoint(x: 3, y: 3), CGPoint(x: 21, y: 21), CGPoint(x: 21, y: 3)]))
                p.box(CGRect(x: 3, y: 3, width: 18, height: 18), radius: 1)
                p.line([CGPoint(x: 3, y: 3), CGPoint(x: 21, y: 21)], width: 1.5)
            }
        }
    }

    static func penWidth(_ pen: PenSize) -> NSImage {
        if let cached = stateCache["pen-\(pen.rawValue)"] { return cached }
        let image = buildPenWidth(pen)
        stateCache["pen-\(pen.rawValue)"] = image
        return image
    }

    private static func buildPenWidth(_ pen: PenSize) -> NSImage {
        let widths: [CGFloat] = [1.3, 2.6, 4.0]
        let index: Int
        switch pen {
        case .p1, .p2: index = 0
        case .p3, .p4: index = 1
        case .p5: index = 2
        }
        return make { p in
            for (bar, lineWidth) in widths.enumerated() {
                let y = 18 - CGFloat(bar) * 6
                p.line(
                    [CGPoint(x: 4, y: y), CGPoint(x: 20, y: y)],
                    width: lineWidth,
                    alpha: bar == index ? 1 : 0.45
                )
            }
        }
    }

    /// 与画布相同的线型样本。
    static func lineStyle(_ style: LineStyle) -> NSImage {
        if let cached = stateCache["line-\(style.rawValue)"] { return cached }
        let image = buildLineStyle(style)
        stateCache["line-\(style.rawValue)"] = image
        return image
    }

    private static func buildLineStyle(_ style: LineStyle) -> NSImage {
        make { p in
            let width: CGFloat = 2
            let dash = style.dashPattern(lineWidth: width) ?? []
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 3, y: 12))
            path.line(to: CGPoint(x: 21, y: 12))
            p.stroke(path, width: width, alpha: 1, dash: dash)
        }
    }

    /// 背景：圆角方块表示填充档位。四档里只有「无」能当 template 用。
    static func background(_ swatch: BackgroundSwatch, tint: NSColor) -> NSImage {
        let image = make { p in
            let rect = CGRect(x: 4, y: 4, width: 16, height: 16)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            switch swatch {
            case .none:
                p.line([CGPoint(x: 6, y: 6), CGPoint(x: 18, y: 18)], width: 1.8)
            case .white:
                NSColor.white.setFill()
                path.fill()
            case .black:
                NSColor(white: 0.05, alpha: 1).setFill()
                path.fill()
            case .tint:
                tint.withAlphaComponent(0.55).setFill()
                path.fill()
            }
            if swatch == .none {
                p.stroke(path, width: 2, alpha: 1, dash: [])
            } else {
                NSColor(white: 0.15, alpha: 0.45).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }
        image.isTemplate = swatch == .none
        return image
    }

    /// 箭头两端带头方式。
    static func arrowHeads(_ heads: ArrowHeads) -> NSImage {
        if let cached = stateCache["heads-\(heads.rawValue)"] { return cached }
        let image = buildArrowHeads(heads)
        stateCache["heads-\(heads.rawValue)"] = image
        return image
    }

    private static func buildArrowHeads(_ heads: ArrowHeads) -> NSImage {
        make { p in
            let left = CGPoint(x: 3, y: 12)
            let right = CGPoint(x: 21, y: 12)
            p.line([left, right])
            if heads.hasEnd {
                p.line([CGPoint(x: 16, y: 17), right, CGPoint(x: 16, y: 7)])
            }
            if heads.hasStart {
                p.line([CGPoint(x: 8, y: 17), left, CGPoint(x: 8, y: 7)])
            }
        }
    }

}

// MARK: - 画法

private extension ToolbarGlyph {
    struct Painter {
        func polygon(_ points: [CGPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            return path
        }

        func fill(_ path: NSBezierPath, alpha: CGFloat = 1) {
            NSColor(white: 1, alpha: alpha).setFill()
            path.fill()
        }

        func fillBox(_ rect: CGRect, radius: CGFloat, alpha: CGFloat = 1) {
            fill(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), alpha: alpha)
        }

        func fillEllipse(_ rect: CGRect, alpha: CGFloat = 1) {
            fill(NSBezierPath(ovalIn: rect), alpha: alpha)
        }

        func line(
            _ points: [CGPoint],
            width: CGFloat = 2,
            alpha: CGFloat = 1,
            closed: Bool = false,
            dash: [CGFloat] = []
        ) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            if closed { path.close() }
            stroke(path, width: width, alpha: alpha, dash: dash)
        }

        func stroke(_ path: NSBezierPath, width: CGFloat, alpha: CGFloat, dash: [CGFloat]) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if !dash.isEmpty {
                path.setLineDash(dash, count: dash.count, phase: 0)
            }
            NSColor(white: 1, alpha: alpha).setStroke()
            path.stroke()
        }

        func box(
            _ rect: CGRect,
            radius: CGFloat,
            width: CGFloat = 2,
            alpha: CGFloat = 1,
            dash: [CGFloat] = []
        ) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            stroke(path, width: width, alpha: alpha, dash: dash)
        }

        func circle(_ center: CGPoint, radius: CGFloat, width: CGFloat = 2, alpha: CGFloat = 1) {
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            stroke(NSBezierPath(ovalIn: rect), width: width, alpha: alpha, dash: [])
        }

        func ellipse(_ rect: CGRect, width: CGFloat = 2, alpha: CGFloat = 1) {
            stroke(NSBezierPath(ovalIn: rect), width: width, alpha: alpha, dash: [])
        }

        /// 角度按 AppKit 约定：0° 在右，逆时针为正。
        func arc(center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat = 2) {
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: from,
                endAngle: to,
                clockwise: true
            )
            stroke(path, width: width, alpha: 1, dash: [])
        }
    }

    /// 直接画进位图。三个理由都不用 NSImage.lockFocus / drawingHandler：
    /// - drawingHandler 把绘制推迟到首次上屏，33 个图标一起推迟，第一次呼出截图肉眼可见地慢；
    /// - lockFocus 走 CGLayer，创建与首次绘制都明显更贵；
    /// - 位图表示可以缓存下来反复用，工具条每次重建不必重画。
    static func make(_ build: @escaping (Painter) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(imageSide * scale)
        let image = NSImage(size: NSSize(width: imageSide, height: imageSide))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        // 保留图标坐标，位图输出按实际显示尺寸生成。
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        build(Painter())
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: imageSide, height: imageSide)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }


}

extension ToolbarGlyph {
    /// 形状工具一一对应。
    static func shape(_ kind: ShapeKind) -> ToolbarGlyph {
        switch kind {
        case .rect: return .rect
        case .roundedRect: return .roundedRect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .polyline: return .polyline
        case .brush: return .brush
        case .marker: return .marker
        case .mosaic: return .mosaic
        case .mosaicRect: return .mosaicRect
        case .blur: return .blur
        case .magnify: return .magnify
        case .text: return .text
        case .serial: return .serial
        case .eraser: return .eraser
        }
    }
}
