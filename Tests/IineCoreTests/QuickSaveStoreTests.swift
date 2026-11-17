import Foundation
import Testing
@testable import IineCore

struct QuickSaveStoreTests {
    private func workspace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iine-quicksave-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func defaultDirectorySitsUnderPictures() {
        let store = QuickSaveStore()
        #expect(store.directory.lastPathComponent == "ii ne")
        #expect(store.directory.deletingLastPathComponent().lastPathComponent == "Pictures")
    }

    @Test func writeCreatesMissingDirectoryAndUsesDefaultName() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ii ne", isDirectory: true)
        let store = QuickSaveStore(directory: directory)

        let url = try store.write(Data("png".utf8))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("ii-ne_"))
        #expect(url.pathExtension == "png")
    }

    @Test func destinationURLReusesTimestampName() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuickSaveStore(directory: root)

        let first = store.destinationURL(fileName: "ii-ne_2026-10-25_10-00-00.png")
        let second = store.destinationURL(fileName: "ii-ne_2026-10-25_10-00-00.png")

        #expect(first.lastPathComponent == "ii-ne_2026-10-25_10-00-00.png")
        #expect(second == first)
    }

    @Test func existingFileGetsNumericSuffix() throws {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("ii-ne_2026-10-25_10-00-00.png"))
        let store = QuickSaveStore(directory: root)

        let next = store.destinationURL(fileName: "ii-ne_2026-10-25_10-00-00.png")

        #expect(next.lastPathComponent == "ii-ne_2026-10-25_10-00-00-2.png")
    }
}
