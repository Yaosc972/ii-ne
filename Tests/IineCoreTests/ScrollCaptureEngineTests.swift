import CoreGraphics
import Foundation
import Testing

@testable import IineCore

private struct FixedEstimator: ScrollOffsetEstimating {
    let offset: CGFloat
    let confidence: Float

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        ScrollOffsetEstimate(offsetPx: offset, confidence: confidence)
    }
}

private struct NeverEstimator: ScrollOffsetEstimating {
    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? { nil }
}


/// 与上一帧配准失败一次、但宽窗口重建能成功的估计器。
private final class FailsOnceThenEstimator: ScrollOffsetEstimating {
    private let offset: CGFloat
    private var didFail = false

    init(offset: CGFloat) { self.offset = offset }

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        guard didFail else {
            didFail = true
            return nil
        }
        return ScrollOffsetEstimate(offsetPx: offset, confidence: 0.9)
    }

    func estimateForReconnect(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        ScrollOffsetEstimate(offsetPx: offset, confidence: 0.9)
    }
}

struct ScrollCaptureEngineTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 200, count: bytesPerRow * height)
        for i in stride(from: 3, to: data.count, by: 4) { data[i] = 255 }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test func growsByEstimatedOffset() {
        let engine = ScrollCaptureEngine(estimator: FixedEstimator(offset: 30, confidence: 0.9))
        engine.start(first: makeImage(width: 20, height: 100))
        engine.consume(frame: makeImage(width: 20, height: 100))
        engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(engine.image?.height == 160)
        #expect(engine.frameCount == 3)
    }

    @Test func lowConfidenceFrameSkipped() {
        let engine = ScrollCaptureEngine(estimator: FixedEstimator(offset: 30, confidence: 0.1))
        engine.start(first: makeImage(width: 20, height: 100))
        #expect(engine.consume(frame: makeImage(width: 20, height: 100)) == nil)
        #expect(engine.image?.height == 100)
    }

    @Test func missingEstimateSkipped() {
        let engine = ScrollCaptureEngine(estimator: NeverEstimator())
        engine.start(first: makeImage(width: 20, height: 100))
        #expect(engine.consume(frame: makeImage(width: 20, height: 100)) == nil)
        #expect(engine.image?.height == 100)
    }

    /// 单帧位移落在死区内不拼，但它记进锚点链，下一帧累计起来就能拼——
    /// 慢速滚动不会被死区吃掉。
    @Test func smallOffsetsAccumulateAcrossAnchors() {
        let estimator = FixedEstimator(offset: 2, confidence: 0.9)
        let engine = ScrollCaptureEngine(estimator: estimator)
        engine.start(first: makeImage(width: 20, height: 100))

        let first = engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(first?.changed == false)
        #expect(engine.image?.height == 100)

        let second = engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(second?.changed == true)
        #expect(engine.frameCount == 2)
        #expect(engine.image?.height == 104)
    }

    /// 断链重建：与上一帧配准失败时，同一帧必须靠宽窗口与最后一个已拼接帧接回长图。
    @Test func reconnectsAfterFailedFrame() {
        let estimator = FailsOnceThenEstimator(offset: 40)
        let engine = ScrollCaptureEngine(estimator: estimator)
        engine.start(first: makeImage(width: 20, height: 100))
        let state = engine.consume(frame: makeImage(width: 20, height: 100))
        #expect(state?.changed == true)
        #expect(engine.image?.height == 140)
    }

    @Test func stationaryReplacementReleasesThePreviousCapture() {
        let engine = ScrollCaptureEngine(estimator: FixedEstimator(offset: 0, confidence: 1))
        engine.start(first: makeImage(width: 20, height: 100))
        let previous = autoreleasepool {
            let tracked = TrackedScrollFrame()
            engine.consume(frame: tracked.image)
            return tracked.lifetime
        }
        #expect(previous.value != nil)
        autoreleasepool {
            engine.consume(frame: makeImage(width: 20, height: 100))
        }
        #expect(previous.value == nil)
        #expect(engine.frameCount == 1)
    }

}

private final class ScrollFrameBytes {
    let data: UnsafeMutableRawPointer
    init(count: Int) {
        data = .allocate(byteCount: count, alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 200, count: count)
    }
    deinit { data.deallocate() }
}

private final class ScrollFrameLifetime {
    weak var value: ScrollFrameBytes?
    init(_ value: ScrollFrameBytes) { self.value = value }
}

private struct TrackedScrollFrame {
    let image: CGImage
    let lifetime: ScrollFrameLifetime

    init() {
        let bytes = ScrollFrameBytes(count: 20 * 100 * 4)
        lifetime = ScrollFrameLifetime(bytes)
        let info = Unmanaged.passRetained(bytes).toOpaque()
        let provider = CGDataProvider(dataInfo: info, data: bytes.data, size: 20 * 100 * 4) { info, _, _ in
            if let info { Unmanaged<ScrollFrameBytes>.fromOpaque(info).release() }
        }!
        image = CGImage(width: 20, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
