import CoreGraphics
import CryptoKit
import Foundation

/// 关闭原因决定是否进入恢复列表：销毁（Shift+Esc）不进，普通关闭才进。
public enum PinCloseKind: Equatable {
    case closed
    case destroyed
}

/// 重建一张贴图所需的最小状态。窗口尺寸由 basePointSize 与 transform 推导，frame 记录关闭时的位置。
public struct PinRestoreEntry {
    public let id: UUID
    public let image: PasteImage
    public let fingerprint: PasteImage.ContentFingerprint?
    public let transform: PinTransform
    public let frame: CGRect
    public let basePointSize: CGSize
    /// 恢复时回到原分组，避免关闭再恢复把贴图跨组搬走。
    public let groupID: Int
    /// 关闭时图上的标注。画布坐标与图像绑定，恢复后可以直接套回去。
    public let annotations: [Annotation]

    public init(
        id: UUID = UUID(),
        image: PasteImage,
        transform: PinTransform,
        frame: CGRect,
        basePointSize: CGSize,
        groupID: Int,
        annotations: [Annotation] = [],
        fingerprint: PasteImage.ContentFingerprint? = nil
    ) {
        self.id = id
        self.image = image
        self.fingerprint = fingerprint
        self.transform = transform
        self.frame = frame
        self.basePointSize = basePointSize
        self.groupID = groupID
        self.annotations = annotations
    }
}

extension PinRestoreList where Entry == PinRestoreEntry {
    public func entry(id: UUID) -> PinRestoreEntry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    public mutating func replaceImage(id: UUID, with image: CGImage) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = entries[index]
        entries[index] = PinRestoreEntry(
            id: entry.id,
            image: PasteImage(image: image, pointSize: entry.image.pointSize, annotations: entry.image.annotations),
            transform: entry.transform,
            frame: entry.frame,
            basePointSize: entry.basePointSize,
            groupID: entry.groupID,
            annotations: entry.annotations,
            fingerprint: entry.fingerprint
        )
        return true
    }
}

/// 最近关闭的贴图，超出容量时丢最旧的。
public struct PinRestoreList<Entry> {
    public let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var mostRecent: Entry? { entries.last }

    public func withCapacity(_ capacity: Int) -> Self {
        var resized = Self(capacity: capacity)
        resized.entries = Array(entries.suffix(resized.capacity))
        return resized
    }

    public mutating func record(_ entry: Entry, kind: PinCloseKind) {
        guard kind == .closed, capacity > 0 else { return }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 恢复即消费，避免同一张关闭的贴图被反复贴出。
    public mutating func takeMostRecent() -> Entry? {
        entries.popLast()
    }

    /// 历史翻页用：按索引读取但不消费，0 是最早关闭的一张。
    public func entry(at index: Int) -> Entry? {
        entries.indices.contains(index) ? entries[index] : nil
    }
}

public enum PinHitTest {
    /// frames 按从底到顶排列，返回光标下最上层可见贴图的下标。
    public static func topmostIndex(of point: CGPoint, in frames: [CGRect], visible: [Bool]) -> Int? {
        guard frames.count == visible.count else { return nil }
        return frames.indices.last { index in
            visible[index] && frames[index].contains(point)
        }
    }
}

public enum PinPassthrough {
    /// index 为 nil 表示光标下没有贴图，此时取消全部穿透。
    public static func toggled(index: Int?, states: [Bool]) -> [Bool] {
        guard let index, states.indices.contains(index) else {
            return states.map { _ in false }
        }
        var next = states
        next[index].toggle()
        return next
    }
}

extension PasteImage {
    public struct ContentFingerprint: Equatable {
        private let pointSize: CGSize
        private let width: Int
        private let height: Int
        private let digest: SHA256.Digest

        fileprivate init(image: PasteImage, data: Data) {
            pointSize = image.pointSize
            width = image.image.width
            height = image.image.height
            digest = SHA256.hash(data: data)
        }
    }

    public var contentFingerprint: ContentFingerprint? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        return ContentFingerprint(image: self, data: data)
    }

    /// 判定剪贴板内容是否仍是上次贴出的那一份：点尺寸与位图字节都相同。
    public static func sameContent(_ lhs: PasteImage?, _ rhs: PasteImage?) -> Bool {
        guard let lhs, let rhs else { return false }
        guard lhs.pointSize == rhs.pointSize,
              lhs.image.width == rhs.image.width,
              lhs.image.height == rhs.image.height else { return false }
        guard let left = lhs.image.dataProvider?.data as Data?,
              let right = rhs.image.dataProvider?.data as Data? else {
            return lhs.image === rhs.image
        }
        return left == right
    }
}
