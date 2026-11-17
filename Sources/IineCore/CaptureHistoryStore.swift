import CoreGraphics
import Foundation

/// 磁盘上的截图历史：每张图存成一个 PNG，同目录的 `index.json` 记录文件名、
/// 创建时间与当时的显示尺寸。`load()` 会跳过损坏或缺失图片的索引项，
/// 单条坏数据不会让整份历史不可用。
public final class CaptureHistoryStore {
    /// 索引项。不要把 CGImage 直接编码进 JSON，图片本体永远单独存文件。
    private struct IndexEntry: Codable {
        let fileName: String
        let createdAt: Date
        let displayWidth: Double
        let displayHeight: Double
        /// 旧索引没有这个字段，缺失时回放退回等比居中。
        var region: StoredRegion?
        /// 整屏冻结帧的文件名，旧索引没有。
        var fullFrameFileName: String?
        var editingImageFileName: String?
        /// 当时的标注，旧索引没有；缺失时回放就是一张未标注的图。
        var annotations: [Annotation]?
    }

    /// 选区在源屏上的位置，回放时按它还原原始大小与位置。
    private struct StoredRegion: Codable {
        let displayID: UInt32
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let displayBoundsWidth: Double
        let displayBoundsHeight: Double

        init(_ region: CaptureRegion) {
            displayID = region.displayID
            x = region.rect.origin.x
            y = region.rect.origin.y
            width = region.rect.width
            height = region.rect.height
            displayBoundsWidth = region.displayBounds.width
            displayBoundsHeight = region.displayBounds.height
        }

        var captureRegion: CaptureRegion {
            CaptureRegion(
                displayID: displayID,
                rect: CGRect(x: x, y: y, width: width, height: height),
                displayBounds: CGRect(
                    x: 0,
                    y: 0,
                    width: displayBoundsWidth,
                    height: displayBoundsHeight
                )
            )
        }
    }

    public enum StoreError: Error, Equatable {
        case pngEncodingFailed
    }

    public static let indexFileName = "index.json"

    public let directory: URL
    public let limit: Int
    private let fileManager: FileManager

    public init(directory: URL, limit: Int = 10, fileManager: FileManager = .default) {
        self.directory = directory
        self.limit = limit
        self.fileManager = fileManager
    }

    /// ~/Library/Application Support/ii ne/history
    public static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("ii ne", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }

    /// 目录不存在时返回空历史；索引项按存储顺序（新→旧）还原。
    public func load() throws -> [CaptureHistoryEntry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let records = try readIndex()
        let capped = records.prefix(max(0, limit))
        var entries: [CaptureHistoryEntry] = []
        for record in capped {
            let url = directory.appendingPathComponent(record.fileName)
            guard fileManager.fileExists(atPath: url.path),
                  let image = Self.loadImage(at: url) else { continue }
            entries.append(CaptureHistoryEntry(
                image: image,
                displaySize: CGSize(
                    width: record.displayWidth,
                    height: record.displayHeight
                ),
                createdAt: record.createdAt,
                region: record.region?.captureRegion,
                fullFrame: record.fullFrameFileName.flatMap { name in
                    let url = directory.appendingPathComponent(name)
                    guard fileManager.fileExists(atPath: url.path) else { return nil }
                    return Self.loadImage(at: url)
                },
                editingImage: record.editingImageFileName.flatMap { name in
                    Self.loadImage(at: directory.appendingPathComponent(name))
                },
                annotations: record.annotations ?? []
            ))
        }
        return entries
    }

    /// 返回的图像持有已编码的数据，文件替换或删除后仍可回放。
    @discardableResult
    public func append(_ entry: CaptureHistoryEntry, replacing createdAt: Date? = nil) throws -> CaptureHistoryEntry {
        guard let outputData = ImageOutput.pngData(from: entry.image),
              let compactImage = ImageOutput.image(fromPNG: outputData) else {
            throw StoreError.pngEncodingFailed
        }
        let fullFrameData: Data?
        if let frame = entry.fullFrame {
            fullFrameData = frame === entry.image ? outputData : ImageOutput.pngData(from: frame)
            guard fullFrameData != nil else { throw StoreError.pngEncodingFailed }
        } else {
            fullFrameData = nil
        }
        let editingData: Data?
        if let image = entry.editingImage {
            if image === entry.image {
                editingData = outputData
            } else if let frame = entry.fullFrame, image === frame {
                editingData = fullFrameData
            } else {
                editingData = ImageOutput.pngData(from: image)
            }
            guard editingData != nil else { throw StoreError.pngEncodingFailed }
        } else {
            editingData = nil
        }
        let compactFullFrame = try fullFrameData.map { data in
            guard let image = ImageOutput.image(fromPNG: data) else { throw StoreError.pngEncodingFailed }
            return image
        }
        let compactEditingImage = try editingData.map { data in
            guard let image = ImageOutput.image(fromPNG: data) else { throw StoreError.pngEncodingFailed }
            return image
        }
        let compact = CaptureHistoryEntry(image: compactImage, displaySize: entry.displaySize,
            createdAt: entry.createdAt, region: entry.region, fullFrame: compactFullFrame,
            editingImage: compactEditingImage, annotations: entry.annotations)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = Self.fileName(for: entry.createdAt)
        let fullFrameFileName = fullFrameData.map { _ in "full-" + fileName }
        let editingImageFileName = editingData.map { _ in "edit-" + fileName }
        var files: [(name: String, data: Data)] = [(fileName, outputData)]
        if let fullFrameFileName, let fullFrameData { files.append((fullFrameFileName, fullFrameData)) }
        if let editingImageFileName, let editingData { files.append((editingImageFileName, editingData)) }
        var committed = false
        defer {
            if !committed {
                for file in files { try? fileManager.removeItem(at: fileURL(named: file.name)) }
            }
        }
        for file in files { try file.data.write(to: fileURL(named: file.name), options: .atomic) }

        var records = (try? readIndex()) ?? []
        var removed: [IndexEntry] = []
        if let createdAt {
            removed = records.filter { $0.createdAt == createdAt }
            records.removeAll { $0.createdAt == createdAt }
        }
        records.insert(IndexEntry(
            fileName: fileName,
            createdAt: entry.createdAt,
            displayWidth: Double(entry.displaySize.width),
            displayHeight: Double(entry.displaySize.height),
            region: entry.region.map(StoredRegion.init),
            fullFrameFileName: fullFrameFileName,
            editingImageFileName: editingImageFileName,
            annotations: entry.annotations.isEmpty ? nil : entry.annotations
        ), at: 0)

        let capacity = max(0, limit)
        if records.count > capacity {
            removed.append(contentsOf: records[capacity...])
            records.removeSubrange(capacity...)
        }
        try writeIndex(records)
        committed = true
        for item in removed {
            for name in [item.fileName, item.fullFrameFileName, item.editingImageFileName].compactMap({ $0 }) {
                try? fileManager.removeItem(at: fileURL(named: name))
            }
        }
        return compact
    }

    /// 删除目录里的历史图片与索引，目录本身保留。
    public func clear() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.removeItem(at: indexURL)
        }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            guard url.pathExtension.lowercased() == "png" else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func readIndex() throws -> [IndexEntry] {
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode([IndexEntry].self, from: data).filter { record in
            [record.fileName, record.fullFrameFileName, record.editingImageFileName].compactMap { $0 }.allSatisfy {
                ($0 as NSString).lastPathComponent == $0 && ($0 as NSString).pathExtension.lowercased() == "png"
            }
        }
    }

    private func writeIndex(_ records: [IndexEntry]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
    }

    /// 毫秒时间戳 + 随机后缀，同一秒内连续截图也不会撞名。
    private static func fileName(for date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return "history-\(millis)-\(UUID().uuidString.prefix(8)).png"
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImageOutput.image(fromPNG: data)
    }
}
