import CoreGraphics
import Testing
@testable import IineCore

struct PinRestoreListTests {
    @Test func replacingAnImageKeepsRestoreOrderAndDocumentState() throws {
        let original = PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: CGSize(width: 4, height: 4))
        let annotation = Annotation(shape: .rect(CGRect(x: 1, y: 1, width: 2, height: 2)), style: Style(color: .red, pen: .p3))
        let first = PinRestoreEntry(image: original, transform: PinTransform(scale: 2, quarterTurns: 1),
            frame: CGRect(x: 30, y: 40, width: 8, height: 8), basePointSize: CGSize(width: 4, height: 4),
            groupID: 3, annotations: [annotation])
        let second = PinRestoreEntry(image: original, transform: .identity, frame: .zero,
            basePointSize: original.pointSize, groupID: 1)
        var list = PinRestoreList<PinRestoreEntry>(capacity: 2)
        list.record(first, kind: .closed)
        list.record(second, kind: .closed)
        let replacement = makeImage(red: 0, green: 0, blue: 1)
        let replaced = list.replaceImage(id: first.id, with: replacement)
        #expect(replaced)
        #expect(list.takeMostRecent()?.id == second.id)
        let recent = list.takeMostRecent()
        let restored = try #require(recent)
        #expect(restored.id == first.id)
        #expect(restored.transform == first.transform)
        #expect(restored.frame == first.frame)
        #expect(restored.basePointSize == first.basePointSize)
        #expect(restored.groupID == first.groupID)
        #expect(restored.annotations == first.annotations)
        #expect(PasteImage.sameContent(restored.image, PasteImage(image: replacement, pointSize: original.pointSize)))
    }

    @Test func lateCompactionCannotRestoreConsumedOrEvictedEntries() {
        let image = PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: CGSize(width: 8, height: 8))
        let first = PinRestoreEntry(image: image, transform: .identity, frame: .zero, basePointSize: image.pointSize, groupID: 0)
        let second = PinRestoreEntry(image: image, transform: .identity, frame: .zero, basePointSize: image.pointSize, groupID: 0)
        var list = PinRestoreList<PinRestoreEntry>(capacity: 1)
        list.record(first, kind: .closed)
        list.record(second, kind: .closed)
        let replacedEvicted = list.replaceImage(id: first.id, with: image.image)
        #expect(!replacedEvicted)
        #expect(list.count == 1)
        #expect(list.takeMostRecent()?.id == second.id)
        let replacedConsumed = list.replaceImage(id: second.id, with: image.image)
        #expect(!replacedConsumed)
        #expect(list.isEmpty)
        list.record(first, kind: .closed)
        list = list.withCapacity(0)
        let replacedCleared = list.replaceImage(id: first.id, with: image.image)
        #expect(!replacedCleared)
        #expect(list.isEmpty)
    }

    @Test func imageFingerprintTracksPixelsAndPointSize() throws {
        let size = CGSize(width: 8, height: 8)
        let first = PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: size)
        let same = PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: size)
        let different = PasteImage(image: makeImage(red: 0, green: 0, blue: 1), pointSize: size)
        let scaled = PasteImage(image: first.image, pointSize: CGSize(width: 4, height: 4))
        let fingerprint = try #require(first.contentFingerprint)
        #expect(fingerprint == same.contentFingerprint)
        #expect(fingerprint != different.contentFingerprint)
        #expect(fingerprint != scaled.contentFingerprint)
    }

    @Test func increasingCapacityPreservesClosedPins() {
        var list = PinRestoreList<Int>(capacity: 2)
        list.record(10, kind: .closed)
        list.record(20, kind: .closed)
        var resized = list.withCapacity(5)
        #expect(resized.capacity == 5)
        #expect(resized.takeMostRecent() == 20)
        #expect(resized.takeMostRecent() == 10)
    }

    @Test func decreasingCapacityKeepsMostRecentPins() {
        var list = PinRestoreList<Int>(capacity: 3)
        for item in [10, 20, 30] { list.record(item, kind: .closed) }
        var resized = list.withCapacity(2)
        #expect(resized.count == 2)
        #expect(resized.takeMostRecent() == 30)
        #expect(resized.takeMostRecent() == 20)
        #expect(list.withCapacity(0).isEmpty)
    }

    @Test func capacityEvictsOldest() {
        var list = PinRestoreList<Int>(capacity: 2)
        list.record(1, kind: .closed)
        list.record(2, kind: .closed)
        list.record(3, kind: .closed)
        #expect(list.count == 2)
        #expect(list.mostRecent == 3)
        #expect(list.takeMostRecent() == 3)
        #expect(list.takeMostRecent() == 2)
        #expect(list.takeMostRecent() == nil)
    }

    @Test func defaultCapacityOfOneKeepsOnlyLastClose() {
        var list = PinRestoreList<Int>(capacity: 1)
        list.record(1, kind: .closed)
        list.record(2, kind: .closed)
        #expect(list.count == 1)
        #expect(list.takeMostRecent() == 2)
    }

    @Test func destroyedEntryIsNotRecorded() {
        var list = PinRestoreList<Int>(capacity: 1)
        list.record(1, kind: .destroyed)
        #expect(list.isEmpty)
        list.record(2, kind: .closed)
        #expect(list.takeMostRecent() == 2)
    }

    @Test func zeroCapacityKeepsNothing() {
        var list = PinRestoreList<Int>(capacity: 0)
        list.record(1, kind: .closed)
        #expect(list.isEmpty)
        #expect(list.takeMostRecent() == nil)
    }

    /// 贴图关闭时图上的标注要跟着进恢复项，否则恢复出来是白图。
    @Test func restoreEntryCarriesAnnotations() {
        let image = PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: CGSize(width: 8, height: 8))
        let annotation = Annotation(
            shape: .rect(CGRect(x: 1, y: 1, width: 4, height: 3)),
            style: Style(color: RGBAColor.palette[0], pen: .p3)
        )
        let entry = PinRestoreEntry(
            image: image,
            transform: .identity,
            frame: CGRect(x: 0, y: 0, width: 8, height: 8),
            basePointSize: CGSize(width: 8, height: 8),
            groupID: 1,
            annotations: [annotation]
        )
        var list = PinRestoreList<PinRestoreEntry>(capacity: 1)
        list.record(entry, kind: .closed)
        #expect(list.takeMostRecent()?.annotations.map(\.id) == [annotation.id])
    }

    /// 不传标注的老调用点仍然可用，默认是空集合。
    @Test func restoreEntryDefaultsToNoAnnotations() {
        let image = PasteImage(image: makeImage(red: 0, green: 1, blue: 0), pointSize: CGSize(width: 8, height: 8))
        let entry = PinRestoreEntry(
            image: image,
            transform: .identity,
            frame: CGRect(x: 0, y: 0, width: 8, height: 8),
            basePointSize: CGSize(width: 8, height: 8),
            groupID: 1
        )
        #expect(entry.annotations.isEmpty)
    }

    @Test func hitTestPicksTopmostVisibleWindow() {
        let frames = [
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 5, y: 5, width: 10, height: 10),
        ]
        #expect(PinHitTest.topmostIndex(of: CGPoint(x: 6, y: 6), in: frames, visible: [true, true]) == 1)
        #expect(PinHitTest.topmostIndex(of: CGPoint(x: 1, y: 1), in: frames, visible: [true, true]) == 0)
        #expect(PinHitTest.topmostIndex(of: CGPoint(x: 6, y: 6), in: frames, visible: [true, false]) == 0)
        #expect(PinHitTest.topmostIndex(of: CGPoint(x: 50, y: 50), in: frames, visible: [true, true]) == nil)
    }

    @Test func passthroughTogglesOnlyHitWindow() {
        #expect(PinPassthrough.toggled(index: 1, states: [false, false, false]) == [false, true, false])
        #expect(PinPassthrough.toggled(index: 0, states: [true, true, false]) == [false, true, false])
    }

    @Test func passthroughWithoutHitClearsAll() {
        #expect(PinPassthrough.toggled(index: nil, states: [true, true]) == [false, false])
        #expect(PinPassthrough.toggled(index: 9, states: [true]) == [false])
    }

    @Test func sameContentComparesBitmapBytes() {
        let red = makeImage(red: 1, green: 0, blue: 0)
        let blue = makeImage(red: 0, green: 0, blue: 1)
        let size = CGSize(width: 8, height: 8)
        #expect(PasteImage.sameContent(
            PasteImage(image: red, pointSize: size),
            PasteImage(image: makeImage(red: 1, green: 0, blue: 0), pointSize: size)
        ))
        #expect(!PasteImage.sameContent(
            PasteImage(image: red, pointSize: size),
            PasteImage(image: blue, pointSize: size)
        ))
        #expect(!PasteImage.sameContent(nil, PasteImage(image: red, pointSize: size)))
    }

    private func makeImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}
