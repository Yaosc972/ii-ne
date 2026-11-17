import AppKit
import Darwin
import IineCore

private struct BenchFailure: Error { let message: String }

@MainActor
private final class ResourceBench {
    let root: URL
    let scenario: String
    var checksum: UInt64 = 0
    var completed = 0
    let started = ProcessInfo.processInfo.systemUptime

    init(root: URL, scenario: String) { self.root = root; self.scenario = scenario }

    func report(_ phase: String, extra: [String: Any] = [:]) {
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var result: [String: Any] = ["scenario": scenario, "phase": phase, "memoryStatus": status,
            "footprintBytes": memory.phys_footprint, "residentBytes": memory.resident_size,
            "peakFootprintBytes": memory.ledger_phys_footprint_peak, "completed": completed,
            "checksum": checksum, "elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000]
        result.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("RESOURCE " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    func fixture(_ index: Int) throws -> CGImage {
        let data = try Data(contentsOf: root.appendingPathComponent("frame-\(index).png"))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BenchFailure(message: "fixture decode failed")
        }
        return image
    }

    static func image(width: Int, height: Int, seed: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw BenchFailure(message: "fixture allocation failed")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = ((x / 7) * 13 + (y / 3) * 29 + seed * 37) & 255
                bytes[offset] = UInt8(value)
                bytes[offset + 1] = UInt8((value + y / 11 + seed) & 255)
                bytes[offset + 2] = UInt8((value + x / 13) & 255)
                bytes[offset + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw BenchFailure(message: "fixture image failed") }
        return image
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = CaptureHistoryStore(directory: root.appendingPathComponent("history"))
        for index in 0..<10 {
            try autoreleasepool {
                let image = try Self.image(width: 3840, height: 2160, seed: index)
                guard let data = ImageOutput.pngData(from: image),
                      let output = AnnotationExport.flatten(base: image, cropRectPx: CGRect(x: 0, y: 0, width: 1920, height: 1080), annotations: [], scale: 2) else {
                    throw BenchFailure(message: "fixture encode failed")
                }
                try data.write(to: root.appendingPathComponent("frame-\(index).png"))
                try history.append(CaptureHistoryEntry(image: output, displaySize: CGSize(width: 960, height: 540),
                    createdAt: Date(timeIntervalSince1970: Double(1700000000 + index)), fullFrame: image))
            }
        }
        completed = 10
        report("prepared")
    }

    func touch(_ image: CGImage) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw BenchFailure(message: "render allocation failed")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        checksum &+= UInt64(bytes[0]) + UInt64(bytes[context.bytesPerRow * (image.height / 2)]) + UInt64(image.width * image.height)
    }

    func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }

    func history() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("iine-resource-history-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: root.appendingPathComponent("history"), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let controller = SnipController(historyStore: CaptureHistoryStore(directory: copy))
        report("loaded", extra: ["entries": controller.historyCount])
        for index in 0..<controller.historyCount {
            try autoreleasepool {
                let entry = controller.historySnapshot[index]
                try touch(entry.image)
                if let fullFrame = entry.fullFrame { try touch(fullFrame) }
                completed += 1
            }
        }
        await settle()
        report("browsed")
        controller.clearHistory()
        await settle()
        report("cleared", extra: ["entries": controller.historyCount])
    }

    func pins(restore: Bool) async throws {
        let controller = PinController(restoreCapacity: restore ? 10 : 0)
        for index in 0..<10 {
            try autoreleasepool {
                let image = try Self.image(width: 3840, height: 2160, seed: index)
                guard controller.pin(image: PasteImage(image: image, pointSize: CGSize(width: 960, height: 540)), at: nil) else {
                    throw BenchFailure(message: "pin failed")
                }
                for window in NSApp.windows.compactMap({ $0 as? PinWindow }) where window.isVisible {
                    window.displayIfNeeded()
                    if restore { window.close() } else { window.destroy() }
                }
                completed += 1
            }
            await settle()
        }
        report("closed", extra: ["visiblePins": NSApp.windows.filter { $0 is PinWindow && $0.isVisible }.count])
        controller.setRestoreCapacity(0)
        await settle()
        report("restoreCleared")
        withExtendedLifetime(controller) {}
    }

    func annotations() throws {
        let image = try fixture(0)
        let view = OverlayView(shot: DisplayShot(displayID: 1, image: image,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        view.applyInitialSelection(CGRect(x: 0, y: 0, width: 1800, height: 1000))
        guard let canvas = view.subviews.compactMap({ $0 as? AnnotationCanvas }).first else {
            throw BenchFailure(message: "capture annotation canvas missing")
        }
        canvas.selectTool(nil)
        canvas.annotations = (0..<100).map { index in
            Annotation(shape: .rect(CGRect(x: 20 + index % 10 * 80, y: 20 + index / 10 * 80, width: 50, height: 50)),
                style: Style(color: .red, pen: .p3))
        }
        canvas.setSelection(Set(canvas.annotations.map(\.id)))
        var notifications = 0
        let updateToolbar = canvas.onChange
        canvas.onChange = { notifications += 1; updateToolbar?() }
        let before = ProcessInfo.processInfo.systemUptime
        canvas.pointerDown(at: CGPoint(x: 20, y: 45))
        for index in 1...120 {
            canvas.pointerDragged(to: CGPoint(x: 20 + index, y: 45 + index))
        }
        canvas.pointerUp(at: CGPoint(x: 140, y: 165))
        guard case .rect(let first) = canvas.annotations.first?.shape, abs(first.minX - 140) < 0.01,
              canvas.annotations.count == 100 else { throw BenchFailure(message: "annotation move did not complete") }
        completed = 120
        checksum = UInt64(canvas.annotations.count)
        report("dragged", extra: ["notifications": notifications, "operationMs": (ProcessInfo.processInfo.systemUptime - before) * 1000])
    }

    func staticScroll() throws {
        let previous = try fixture(0)
        let current = try fixture(0)
        let estimator = ScrollOffsetEstimator()
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<12 {
            try autoreleasepool {
                guard let estimate = estimator.estimate(current: current, previous: previous), estimate.offsetPx == 0 else {
                    throw BenchFailure(message: "static frame incorrectly moved")
                }
                completed += 1
                checksum &+= UInt64(estimate.confidence * 1000)
            }
        }
        report("estimated", extra: ["operationMs": (ProcessInfo.processInfo.systemUptime - before) * 1000, "pixelsPerFrame": previous.width * previous.height])
    }

    func liveHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iine-resource-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureHistoryStore(directory: directory)
        let controller = SnipController(historyStore: store)
        let before = ProcessInfo.processInfo.systemUptime
        for index in 0..<10 {
            try autoreleasepool {
                let frame = try Self.image(width: 3840, height: 2160, seed: index)
                guard let output = AnnotationExport.flatten(base: frame,
                    cropRectPx: CGRect(x: 0, y: 0, width: 1920, height: 1080), annotations: [], scale: 2) else {
                    throw BenchFailure(message: "capture export failed")
                }
                controller.remember(output, displaySize: CGSize(width: 960, height: 540), region: nil, fullFrame: frame)
                completed += 1
            }
        }
        report("recordingReturned", extra: ["operationMs": (ProcessInfo.processInfo.systemUptime - before) * 1000])
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let savedCount = try autoreleasepool { try store.load().count }
        guard savedCount == 10 && controller.historyCount == 10 else { throw BenchFailure(message: "history did not persist all captures") }
        checksum = UInt64(savedCount)
        report("recorded", extra: ["entries": savedCount])
        controller.clearHistory()
        await settle()
        report("cleared", extra: ["entries": controller.historyCount])
    }

    func stitch() throws {
        let frame = try fixture(0)
        let stitcher = ScrollStitcher()
        _ = stitcher.start(first: frame)
        let before = ProcessInfo.processInfo.systemUptime
        for index in 0..<50 {
            try autoreleasepool {
                let incoming = try fixture(index % 10)
                guard let state = stitcher.ingest(frame: incoming, offsetPx: 112), state.changed else {
                    throw BenchFailure(message: "stitch skipped a strip")
                }
                completed += 1
            }
        }
        guard let image = stitcher.image, image.height == 7760, image.width == 3840 else {
            throw BenchFailure(message: "stitch dimensions differ")
        }
        try touch(image)
        report("stitched", extra: ["operationMs": (ProcessInfo.processInfo.systemUptime - before) * 1000,
                                   "outputWidth": image.width, "outputHeight": image.height])
    }

    func effects() async throws {
        let before = ProcessInfo.processInfo.systemUptime
        try autoreleasepool {
            let image = try fixture(0)
            let sampler = BaseSampler(base: image, cropOriginPx: .zero, canvasSize: CGSize(width: 1920, height: 1080), scale: 2)
            for index in 0..<30 {
                try autoreleasepool {
                    let region = CGRect(x: 100 + index, y: 100 + index, width: 800, height: 450)
                    guard let blurred = sampler.blurred(region: region, radiusPoints: 6) else {
                        throw BenchFailure(message: "blur failed")
                    }
                    try touch(blurred)
                    completed += 1
                }
            }
        }
        report("blurred", extra: ["operationMs": (ProcessInfo.processInfo.systemUptime - before) * 1000])
        try await Task.sleep(nanoseconds: 2_300_000_000)
        report("settled")
    }

    func run() async throws {
        report("start")
        switch scenario {
        case "prepare": try prepare()
        case "history": try await history()
        case "live-history": try await liveHistory()
        case "pin-restore": try await pins(restore: true)
        case "pin-destroy": try await pins(restore: false)
        case "annotations": try annotations()
        case "static-scroll": try staticScroll()
        case "stitch": try stitch()
        case "effects": try await effects()
        default: throw BenchFailure(message: "unknown scenario")
        }
        report("done", extra: ["errors": 0])
    }
}

@main
private struct ResourceBenchMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let scenario = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        Task { @MainActor in
            do { try await ResourceBench(root: root, scenario: scenario).run(); exit(0) }
            catch { print("RESOURCE_ERROR \(scenario) \(error)"); fflush(stdout); exit(1) }
        }
        app.run()
    }
}
