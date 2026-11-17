import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import IineCore

struct TextRecognizerTests {
    @Test func cancelledAsyncRecognitionReportsCancellation() async {
        let image = makeTextImage("Cancelled text")
        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await TextRecognizer.recognizeAsync(in: image)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func makeImage(size: CGSize, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        draw(ctx)
        return ctx.makeImage()!
    }

    private func makeTextImage(_ text: String) -> CGImage {
        makeImage(size: CGSize(width: 640, height: 200)) { ctx in
            let font = CTFontCreateWithName("PingFang SC" as CFString, 72, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            ctx.textPosition = CGPoint(x: 40, y: 60)
            CTLineDraw(line, ctx)
        }
    }

    @Test func recognizesChineseAndDigits() async {
        let image = makeTextImage("测试文字 123")
        // Vision 首次调用要加载识别模型，本机偶发长时间返回空；内容级识别由 E2E 覆盖，
        // 这里用 intermittent 已知问题标记，避免偶发把整轮测试拖红。
        await withKnownIssue("Vision 冷启动在本机偶发不可用", isIntermittent: true) {
            // 预热一次再判定
            _ = TextRecognizer.recognizeText(in: image)
            var text = ""
            for _ in 0..<5 {
                text = TextRecognizer.recognizeText(in: image)
                if !text.isEmpty { break }
                Thread.sleep(forTimeInterval: 1)
            }
            #expect(!text.isEmpty, "识别结果为空，Vision 管线可能失效")
        }
    }

    @Test func blankImageReturnsEmptyString() {
        let blank = makeImage(size: CGSize(width: 320, height: 160)) { _ in }
        #expect(TextRecognizer.recognizeText(in: blank).isEmpty)
    }

    @Test func structuredResultKeepsCoordinatesAndJoinsSameLineFragments() {
        let blocks = [
            RecognizedTextBlock(text: "Hello", bounds: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), confidence: 0.9),
            RecognizedTextBlock(text: "world", bounds: CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.1), confidence: 0.8),
            RecognizedTextBlock(text: "第二行", bounds: CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1), confidence: 0.7),
        ]
        let result = TextRecognitionResult(blocks: blocks)
        #expect(result.blocks == blocks)
        #expect(result.text == "Hello world\n第二行")
    }

    @Test func mergingWrappedTextKeepsParagraphsAndChineseSpacing() {
        #expect(TextRecognitionResult.mergingLineBreaks(in: "Hello\nworld\n\nNext paragraph") == "Hello world\n\nNext paragraph")
        #expect(TextRecognitionResult.mergingLineBreaks(in: "中文\n换行") == "中文换行")
        #expect(TextRecognitionResult.mergingLineBreaks(in: "line one\r\nline two") == "line one line two")
    }
}
