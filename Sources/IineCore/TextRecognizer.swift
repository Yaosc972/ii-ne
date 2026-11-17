import CoreGraphics
import Foundation
import Vision

public struct RecognizedTextBlock: Equatable, Sendable {
    public let text: String
    public let bounds: CGRect
    public let confidence: Float

    public init(text: String, bounds: CGRect, confidence: Float) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
    }
}

public struct TextRecognitionResult: Equatable, Sendable {
    public let blocks: [RecognizedTextBlock]

    public init(blocks: [RecognizedTextBlock]) {
        self.blocks = blocks
    }

    public var text: String {
        var text = ""
        var previous: RecognizedTextBlock?
        for block in blocks {
            if let previous {
                let overlap = min(previous.bounds.maxY, block.bounds.maxY)
                    - max(previous.bounds.minY, block.bounds.minY)
                text += overlap > min(previous.bounds.height, block.bounds.height) * 0.5 ? " " : "\n"
            }
            text += block.text
            previous = block
        }
        return text
    }

    public static func mergingLineBreaks(in text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
        return paragraphs.map { paragraph in
            paragraph.split(separator: "\n").map(String.init).reduce("") { result, line in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !result.isEmpty else { return line }
                let separator = isCJK(result.last) && isCJK(line.first) ? "" : " "
                return result + separator + line
            }
        }.joined(separator: "\n\n")
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let value = character?.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(value) || (0x3000...0x30FF).contains(value)
    }
}

/// 截图文字识别。只做识别，不碰界面与剪贴板。
public enum TextRecognizer {
    /// 按阅读顺序返回文字，行之间换行。识别失败或图中没有文字时返回空串。
    public static func recognizeText(in image: CGImage) -> String {
        (try? recognize(in: image).text) ?? ""
    }

    public static func recognize(in image: CGImage) throws -> TextRecognitionResult {
        try perform(image, request: makeRequest())
    }

    public static func recognizeAsync(in image: CGImage) async throws -> TextRecognitionResult {
        try Task.checkCancellation()
        let request = makeRequest()
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                return try perform(image, request: request)
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            request.cancel()
            worker.cancel()
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 简体中文优先，英文同时保留；混合排版由 Vision 在候选里挑。
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        return request
    }

    private static func perform(_ image: CGImage, request: VNRecognizeTextRequest) throws -> TextRecognitionResult {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        let blocks = readingOrder(request.results ?? []).compactMap { observation -> RecognizedTextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextBlock(
                text: candidate.string,
                bounds: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
        return TextRecognitionResult(blocks: blocks)
    }

    /// Vision 按检测顺序返回，不保证跨行阅读顺序。
    /// 先按视觉行聚簇，行内从左到右，行间从上到下。
    static func readingOrder(
        _ observations: [VNRecognizedTextObservation]
    ) -> [VNRecognizedTextObservation] {
        let topDown = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in topDown {
            if let index = lines.firstIndex(where: {
                sameLine($0[0].boundingBox, observation.boundingBox)
            }) {
                lines[index].append(observation)
            } else {
                lines.append([observation])
            }
        }
        return lines.flatMap { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
    }

    /// boundingBox 原点在左下，y 越大越靠上。垂直重叠过半视为同一行。
    private static func sameLine(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        return overlap > min(lhs.height, rhs.height) * 0.5
    }
}
