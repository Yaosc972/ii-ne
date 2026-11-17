import Foundation
import IineCore

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// app 侧 application(_:open:) 直接使用同一个 CommandLineRequest(url:) 解析函数，
// 这里编译 Core 即可覆盖 app 收到的每种 URL 形态。
let urlCases: [(CommandLineCommand, String)] = [
    (.snip, "iine://snip"),
    (.delayedSnip(seconds: 3), "iine://snip?delay=3"),
    (.clipboard, "iine://clipboard"),
    (.save(path: "/tmp/a.png"), "iine://save?path=/tmp/a.png"),
    (.quickSave, "iine://quick-save"),
    (.pin(x: 12, y: 34), "iine://pin?x=12&y=34"),
    (.pickColor, "iine://pick-color"),
    (.barcodeScan, "iine://barcode-scan"),
    (.showImages, "iine://show-images"),
    (.hideImages, "iine://hide-images"),
    (.whiteboard(background: nil, activeScreen: false), "iine://whiteboard"),
    (.whiteboard(background: .solid(WhiteboardColor.parse("#112233")!), activeScreen: false),
     "iine://whiteboard?color=%23112233"),
    (.whiteboard(background: .solid(.gray), activeScreen: true),
     "iine://whiteboard?color=%23808080&active_screen=1"),
    (.whiteboard(background: .transparent, activeScreen: false),
     "iine://whiteboard?color=transparent"),
]

for (command, expected) in urlCases {
    let request = CommandLineRequest(command: command)
    check(request.url.absoluteString == expected, "build \(expected), got \(request.url.absoluteString)")
    check((try? CommandLineRequest(url: request.url)) == request, "round trip \(expected)")
}

let argumentCases: [([String], String)] = [
    ([], "iine://snip"),
    (["snip"], "iine://snip"),
    (["--delay", "1"], "iine://snip?delay=1"),
    (["snip", "--delay", "60"], "iine://snip?delay=60"),
    (["-o", "clipboard"], "iine://clipboard"),
    (["snip", "-o", "clipboard"], "iine://clipboard"),
    (["-o", "quick-save"], "iine://quick-save"),
    (["-o", "/tmp/shot.png"], "iine://save?path=/tmp/shot.png"),
    (["--pos", "12", "34"], "iine://pin?x=12&y=34"),
    (["snip", "--pos", "-10.5", "20"], "iine://pin?x=-10.5&y=20"),
    (["pick-color"], "iine://pick-color"),
    (["barcode-scan"], "iine://barcode-scan"),
    (["show-images"], "iine://show-images"),
    (["hide-images"], "iine://hide-images"),
    (["whiteboard"], "iine://whiteboard"),
    (["snip", "whiteboard", "--color", "#112233"],
     "iine://whiteboard?color=%23112233"),
    (["whiteboard", "--active-screen"], "iine://whiteboard?active_screen=1"),
    (["whiteboard", "--color", "red", "--active-screen"],
     "iine://whiteboard?color=%23ff0000&active_screen=1"),
    (["whiteboard", "--color", "transparent"],
     "iine://whiteboard?color=transparent"),
]

for (arguments, expected) in argumentCases {
    guard case .request(let request) = try? CommandLineParser.parse(arguments) else {
        check(false, "parse \(arguments)")
        continue
    }
    check(request.url.absoluteString == expected, "parse \(arguments) -> \(expected)")
}

let rejected: [([String], String)] = [
    (["bogus"], "unknown argument"),
    (["-o"], "missing -o value"),
    (["-o", ""], "empty -o value"),
    (["--pos", "1"], "missing y"),
    (["--pos", "left", "2"], "non numeric x"),
    (["-o", "clipboard", "extra"], "extra argument"),
    (["--delay", "0"], "delay below range"),
    (["--delay", "61"], "delay above range"),
    (["whiteboard", "--color"], "whiteboard missing color"),
    (["whiteboard", "--bogus"], "whiteboard unknown option"),
]

for (arguments, label) in rejected {
    check((try? CommandLineParser.parse(arguments)) == nil, "reject \(label)")
}

print("HARNESS passes=\(passes) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
