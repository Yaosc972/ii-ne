import CoreGraphics
import Foundation
import Testing
@testable import IineCore

struct CaptureHistoryStoreTests {
    private let fileManager = FileManager.default

    private func temporaryDirectory() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("CaptureHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try #require(WhiteboardImage.make(
            width: width,
            height: height,
            background: .solid(.black)
        ))
    }

    private func makeEntry(
        width: Int,
        height: Int,
        displaySize: CGSize? = nil,
        at time: TimeInterval
    ) throws -> CaptureHistoryEntry {
        CaptureHistoryEntry(
            image: try makeImage(width: width, height: height),
            displaySize: displaySize ?? CGSize(width: width / 2, height: height / 2),
            createdAt: Date(timeIntervalSince1970: time)
        )
    }

    private func pngFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
    }

    @Test func appendThenLoadRoundTripsImageAndMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let entry = try makeEntry(
            width: 40,
            height: 30,
            displaySize: CGSize(width: 120, height: 90),
            at: 1_700_000_000
        )

        try store.append(entry)
        // 新建实例读盘，等价于进程重启后重新载入历史。
        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()

        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.image.width == 40)
        #expect(first.image.height == 30)
        #expect(first.displaySize == CGSize(width: 120, height: 90))
        #expect(first.createdAt.timeIntervalSince1970 == 1_700_000_000)
        #expect(first.region == nil)
        #expect(try pngFiles(in: directory).count == 1)
    }

    @Test func appendBeyondLimitDropsOldestFileAndIndexEntry() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 2)

        for index in 0..<3 {
            try store.append(try makeEntry(
                width: 10 + index,
                height: 10,
                at: 1_700_000_000 + Double(index)
            ))
        }

        let loaded = try store.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.image.width) == [12, 11])
        #expect(try pngFiles(in: directory).count == 2)
    }

    @Test func clearEmptiesMemoryViewAndDisk() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        try store.append(try makeEntry(width: 20, height: 20, at: 1_700_000_000))
        try store.append(try makeEntry(width: 21, height: 20, at: 1_700_000_001))
        #expect(try store.load().count == 2)

        try store.clear()

        #expect(try store.load().isEmpty)
        #expect(try pngFiles(in: directory).isEmpty)
        #expect(!fileManager.fileExists(
            atPath: directory.appendingPathComponent(CaptureHistoryStore.indexFileName).path
        ))
    }

    @Test func loadSkipsCorruptAndMissingFiles() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        for index in 0..<3 {
            try store.append(try makeEntry(
                width: 30 + index,
                height: 20,
                at: 1_700_000_000 + Double(index)
            ))
        }

        // 文件名带毫秒时间戳，按名称排序即按写入时间从旧到新。
        let files = try pngFiles(in: directory).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        #expect(files.count == 3)
        try Data([0x00, 0x01, 0x02]).write(to: files[0])
        try fileManager.removeItem(at: files[1])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.image.width == 32)
    }

    @Test func missingDirectoryIsCreatedOnAppendAndLoadsAsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)

        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(try store.load().isEmpty)

        try store.append(try makeEntry(width: 15, height: 15, at: 1_700_000_000))

        #expect(fileManager.fileExists(atPath: directory.path))
        #expect(try store.load().count == 1)
    }

    @Test func appendThenLoadPreservesRegion() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let region = CaptureRegion(
            displayID: 1,
            rect: CGRect(x: 120, y: 60, width: 400, height: 300),
            displayBounds: CGRect(x: 0, y: 0, width: 1470, height: 956)
        )
        let entry = CaptureHistoryEntry(
            image: try makeImage(width: 800, height: 600),
            displaySize: CGSize(width: 400, height: 300),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            region: region
        )
        try store.append(entry)

        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()
        let first = try #require(loaded.first)
        #expect(first.region == region)
    }

    @Test func replacingEditableHistoryPreservesBaseAndLatestAnnotations() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let base = try makeImage(width: 100, height: 300)
        let date = Date(timeIntervalSince1970: 1_700_000_200)
        let first = CaptureHistoryEntry(image: base, displaySize: CGSize(width: 50, height: 150),
            createdAt: date, editingImage: base)
        try store.append(first)
        let annotation = Annotation(shape: .arrow(from: CGPoint(x: 5, y: 10), to: CGPoint(x: 25, y: 40)),
            style: Style(color: RGBAColor.palette[0], pen: .p3))
        let updated = CaptureHistoryEntry(image: base, displaySize: first.displaySize,
            createdAt: date, editingImage: base, annotations: [annotation])
        try store.append(updated, replacing: date)
        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.annotations == [annotation])
        #expect(loaded.first?.editingImage?.height == 300)
        #expect(loaded.first?.displaySize == first.displaySize)
        let pngs = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        #expect(pngs.count == 2)
    }

    @Test func replacingHistoryKeepsLoadedImagesUsable() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory)
        let image = try makeImage(width: 800, height: 1600)
        let rect = CGRect(x: 0, y: 0, width: 800, height: 1600)
        let style = Style(color: RGBAColor.palette[0], pen: .p3)
        let arrow = Annotation(shape: .arrow(from: CGPoint(x: 50, y: 100), to: CGPoint(x: 300, y: 400)), style: style)
        let rendered = try #require(AnnotationExport.flatten(base: image, cropRectPx: rect, annotations: [arrow], scale: 1))
        try store.append(CaptureHistoryEntry(image: rendered, displaySize: rect.size,
            editingImage: image, annotations: [arrow]))
        var history = try store.load()
        let loadedBase = try #require(history.first?.editingImage)
        let date = try #require(history.first?.createdAt)
        for index in 0..<3 {
            try autoreleasepool {
                let mark = Annotation(shape: .rect(CGRect(x: 100 + index * 10, y: 800, width: 120, height: 80)), style: style)
                let annotations = [arrow, mark]
                let output = try #require(AnnotationExport.flatten(base: loadedBase, cropRectPx: rect, annotations: annotations, scale: 1))
                let entry = CaptureHistoryEntry(image: output, displaySize: rect.size, createdAt: date,
                    editingImage: loadedBase, annotations: annotations)
                history.removeAll()
                history.append(entry)
                try store.append(entry, replacing: date)
            }
        }
        let restored = try store.load()
        #expect(restored.count == 1)
        #expect(restored.first?.annotations == history.first?.annotations)
    }

    @Test func appendThenLoadPreservesFullFrame() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory, limit: 5)
        let entry = CaptureHistoryEntry(
            image: try makeImage(width: 40, height: 30),
            displaySize: CGSize(width: 20, height: 15),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            fullFrame: try makeImage(width: 60, height: 40)
        )
        try store.append(entry)

        let loaded = try CaptureHistoryStore(directory: directory, limit: 5).load()
        let first = try #require(loaded.first)
        #expect(first.fullFrame?.width == 60)
        #expect(first.fullFrame?.height == 40)
    }

    @Test func appendReturnsAllImagesReadableAfterFilesAreRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory)
        let original = PixelBuffer.solidImage(width: 48, height: 32,
            rects: [(CGRect(x: 5, y: 7, width: 16, height: 18), PixelBuffer.rgb(1, 0, 0))])
        let expected = try #require(PixelBuffer.srgbBytes(original, width: 48, height: 32))
        let annotation = Annotation(shape: .rect(CGRect(x: 1, y: 2, width: 3, height: 4)),
            style: Style(color: .red, pen: .p3))
        let date = Date(timeIntervalSince1970: 1_700_000_300)
        let compact = try store.append(CaptureHistoryEntry(image: original,
            displaySize: CGSize(width: 24, height: 16), createdAt: date,
            fullFrame: original, editingImage: original, annotations: [annotation]))
        try store.clear()
        #expect(try store.load().isEmpty)
        #expect(compact.createdAt == date)
        #expect(compact.displaySize == CGSize(width: 24, height: 16))
        #expect(compact.annotations == [annotation])
        for image in [compact.image, try #require(compact.fullFrame), try #require(compact.editingImage)] {
            let actual = try #require(PixelBuffer.srgbBytes(image, width: 48, height: 32))
            #expect(actual == expected)
        }
    }

    @Test func failedIndexPublicationRemovesUncommittedImages() throws {
        let directory = temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory.appendingPathComponent(CaptureHistoryStore.indexFileName),
            withIntermediateDirectories: true)
        let store = CaptureHistoryStore(directory: directory)
        let entry = try makeEntry(width: 30, height: 20, at: 1_700_000_400)
        #expect(throws: (any Error).self) { try store.append(entry) }
        #expect(try pngFiles(in: directory).isEmpty)
    }

    @Test func unsafeIndexPathsCannotReadOrDeleteFilesOutsideHistory() throws {
        let root = temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("history", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        let bytes = try #require(ImageOutput.pngData(from: makeImage(width: 10, height: 10)))
        try bytes.write(to: outside)
        let record: [String: Any] = ["fileName": "../outside.png", "createdAt": 0,
            "displayWidth": 10, "displayHeight": 10]
        try JSONSerialization.data(withJSONObject: [record])
            .write(to: directory.appendingPathComponent(CaptureHistoryStore.indexFileName))
        let store = CaptureHistoryStore(directory: directory)
        #expect(try store.load().isEmpty)
        let emptyStore = CaptureHistoryStore(directory: directory, limit: 0)
        try emptyStore.append(try makeEntry(width: 10, height: 10, at: 1_700_000_500))
        #expect(try Data(contentsOf: outside) == bytes)
    }

}
