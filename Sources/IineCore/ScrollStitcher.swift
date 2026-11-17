import CoreGraphics

public struct ScrollStitchState: Equatable {
    public let frameCount: Int
    public let changed: Bool
    public let reachedLimit: Bool

    public init(frameCount: Int, changed: Bool, reachedLimit: Bool) {
        self.frameCount = frameCount
        self.changed = changed
        self.reachedLimit = reachedLimit
    }
}

public final class ScrollStitcher {
    public let maxHeightPx: Int
    public let deadZonePx: CGFloat
    public let maxPixelBytes: Int
    public private(set) var frameCount = 0

    private var strips: [CGImage] = []
    private var width = 0
    private var height = 0
    private var capacityHeight = 0
    private var colorSpace: CGColorSpace?

    public init(maxHeightPx: Int = 8_000, deadZonePx: CGFloat = 3, maxPixelBytes: Int = 256 * 1024 * 1024) {
        self.maxHeightPx = max(0, maxHeightPx)
        self.deadZonePx = max(0, deadZonePx)
        self.maxPixelBytes = max(0, maxPixelBytes)
    }

    public var pixelSize: CGSize { CGSize(width: width, height: height) }
    public var isAtLimit: Bool { height >= capacityHeight }

    public var image: CGImage? {
        guard !strips.isEmpty else { return nil }
        if strips.count == 1 { return strips[0] }
        guard let composed = render(width: width, height: height) else { return nil }
        strips = [composed]
        return composed
    }

    public func preview(maxDimension: Int) -> CGImage? {
        guard width > 0, height > 0, maxDimension > 0 else { return nil }
        let scale = min(1, CGFloat(maxDimension) / CGFloat(max(width, height)))
        let previewWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let previewHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        return render(width: previewWidth, height: previewHeight)
    }

    @discardableResult
    public func start(first: CGImage) -> ScrollStitchState {
        strips.removeAll()
        frameCount = 0
        width = first.width
        height = 0
        colorSpace = first.colorSpace
        let rowBytes = width.multipliedReportingOverflow(by: 4)
        guard !rowBytes.overflow, rowBytes.partialValue > 0 else {
            capacityHeight = 0
            return state(changed: false)
        }
        capacityHeight = min(maxHeightPx, maxPixelBytes / rowBytes.partialValue)
        let initialHeight = min(first.height, capacityHeight)
        guard initialHeight > 0 else { return state(changed: false) }
        if initialHeight == first.height {
            strips = [first]
        } else {
            guard let strip = copyStrip(first, top: 0, height: initialHeight) else { return state(changed: false) }
            strips = [strip]
        }
        height = initialHeight
        frameCount = 1
        return state(changed: true)
    }

    @discardableResult
    public func trimTop(_ pixels: Int) -> Bool {
        trim(pixels, fromTop: true)
    }

    @discardableResult
    public func trimBottom(_ pixels: Int) -> Bool {
        trim(pixels, fromTop: false)
    }

    @discardableResult
    public func ingest(
        frame: CGImage,
        offsetPx: CGFloat,
        stickyBottomPx: Int = 0,
        stickyTopPx: Int = 0
    ) -> ScrollStitchState? {
        guard !strips.isEmpty else { return start(first: frame) }
        guard frame.width == width, offsetPx.isFinite, abs(offsetPx) > deadZonePx else {
            return state(changed: false)
        }
        let allowed = capacityHeight - height
        guard allowed > 0 else { return state(changed: false) }
        let downward = offsetPx > 0
        let sticky = min(max(0, downward ? stickyBottomPx : stickyTopPx), frame.height / 3)
        let available = max(0, frame.height - sticky)
        let distance = Int(min(abs(offsetPx.rounded()), CGFloat(available)))
        let take = min(distance, allowed)
        let sourceTop = downward ? available - take : sticky
        guard take > 0, let strip = copyStrip(frame, top: sourceTop, height: take) else {
            return state(changed: false)
        }
        if downward { strips.append(strip) } else { strips.insert(strip, at: 0) }
        height += take
        frameCount += 1
        return state(changed: true)
    }

    private func trim(_ pixels: Int, fromTop: Bool) -> Bool {
        guard pixels > 0, height > pixels, height - pixels > 16 else { return false }
        var remaining = pixels
        var kept = strips
        while remaining > 0 {
            let index = fromTop ? 0 : kept.count - 1
            let strip = kept[index]
            if remaining >= strip.height {
                remaining -= strip.height
                kept.remove(at: index)
            } else {
                let top = fromTop ? remaining : 0
                guard let cropped = copyStrip(strip, top: top, height: strip.height - remaining) else { return false }
                kept[index] = cropped
                remaining = 0
            }
        }
        strips = kept
        height -= pixels
        return true
    }

    private func copyStrip(_ source: CGImage, top: Int, height: Int) -> CGImage? {
        guard top >= 0, height > 0, top <= source.height - height,
              let context = makeContext(width: width, height: height),
              let cropped = source.cropping(to: CGRect(x: 0, y: top, width: width, height: height)) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        AnnotationRenderer.drawUpright(cropped, in: CGRect(x: 0, y: 0, width: width, height: height), ctx: context)
        return context.makeImage()
    }

    private func render(width targetWidth: Int, height targetHeight: Int) -> CGImage? {
        guard let context = makeContext(width: targetWidth, height: targetHeight), height > 0 else { return nil }
        context.interpolationQuality = targetWidth == width ? .none : .medium
        context.setBlendMode(.copy)
        let scaleY = CGFloat(targetHeight) / CGFloat(height)
        var top = 0
        for strip in strips {
            let bottom = height - top - strip.height
            AnnotationRenderer.drawUpright(strip,
                in: CGRect(x: 0, y: CGFloat(bottom) * scaleY, width: CGFloat(targetWidth), height: CGFloat(strip.height) * scaleY),
                ctx: context)
            top += strip.height
        }
        return context.makeImage()
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        let rowBytes = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !rowBytes.overflow,
              height <= maxPixelBytes / rowBytes.partialValue else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: rowBytes.partialValue, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func state(changed: Bool) -> ScrollStitchState {
        ScrollStitchState(frameCount: frameCount, changed: changed, reachedLimit: isAtLimit)
    }
}
