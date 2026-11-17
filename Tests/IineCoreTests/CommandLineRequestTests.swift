import Foundation
import Testing
@testable import IineCore

struct CommandLineRequestTests {
    @Test func legacyLinksResolveToTheRenamedScheme() throws {
        let source = try #require(URL(string: "\(LegacyBrandMigration.urlScheme)://save?path=%2Ftmp%2Fexisting.png"))
        let request = try CommandLineRequest(url: source)
        #expect(request.command == .save(path: "/tmp/existing.png"))
        #expect(request.url.scheme == "iine")
    }

    private func request(_ arguments: [String]) throws -> CommandLineRequest? {
        guard case .request(let request) = try CommandLineParser.parse(arguments) else {
            return nil
        }
        return request
    }

    @Test func bareSnipStartsCapture() throws {
        let parsed = try #require(try request([]))
        #expect(parsed.command == .snip)
        #expect(parsed.url.absoluteString == "iine://snip")
        #expect(try request(["snip"])?.command == .snip)
    }

    @Test func outputClipboardMapsToClipboard() throws {
        #expect(try request(["-o", "clipboard"])?.command == .clipboard)
        #expect(try request(["snip", "-o", "clipboard"])?.command == .clipboard)
        #expect(try request(["-o", "clipboard"])?.url.absoluteString == "iine://clipboard")
    }

    @Test func outputQuickSaveMapsToQuickSave() throws {
        #expect(try request(["-o", "quick-save"])?.command == .quickSave)
        #expect(try request(["-o", "quick-save"])?.url.absoluteString == "iine://quick-save")
    }

    @Test func outputFileNameMapsToSavePath() throws {
        let parsed = try #require(try request(["-o", "/tmp/shot.png"]))
        #expect(parsed.command == .save(path: "/tmp/shot.png"))
        #expect(parsed.url.absoluteString == "iine://save?path=/tmp/shot.png")
    }

    @Test func posMapsToPinCoordinates() throws {
        let integer = try #require(try request(["--pos", "12", "34"]))
        #expect(integer.command == .pin(x: 12, y: 34))
        #expect(integer.url.absoluteString == "iine://pin?x=12&y=34")

        let fractional = try #require(try request(["snip", "--pos", "-10.5", "20"]))
        #expect(fractional.command == .pin(x: -10.5, y: 20))
        #expect(fractional.url.absoluteString == "iine://pin?x=-10.5&y=20")
    }

    @Test func standaloneCommands() throws {
        let cases: [(String, CommandLineCommand, String)] = [
            ("pick-color", .pickColor, "iine://pick-color"),
            ("barcode-scan", .barcodeScan, "iine://barcode-scan"),
            ("show-images", .showImages, "iine://show-images"),
            ("hide-images", .hideImages, "iine://hide-images"),
        ]
        for (argument, command, url) in cases {
            let parsed = try #require(try request([argument]))
            #expect(parsed.command == command)
            #expect(parsed.url.absoluteString == url)
        }
    }

    @Test func helpForms() throws {
        #expect(try CommandLineParser.parse(["--help"]) == .help)
        #expect(try CommandLineParser.parse(["-h"]) == .help)
        #expect(try CommandLineParser.parse(["snip", "--help"]) == .help)
    }

    @Test func whiteboardParsesColorAndActiveScreen() throws {
        #expect(try request(["whiteboard"])?.command == .whiteboard(background: nil, activeScreen: false))
        #expect(try request(["snip", "whiteboard"])?.command == .whiteboard(background: nil, activeScreen: false))

        let red = try #require(try request(["whiteboard", "--color", "red"]))
        #expect(red.command == .whiteboard(background: .solid(.red), activeScreen: false))
        #expect(red.url.absoluteString == "iine://whiteboard?color=%23ff0000")

        let hex = try #require(try request(["snip", "whiteboard", "--color", "#112233"]))
        #expect(hex.command == .whiteboard(
            background: .solid(try #require(WhiteboardColor.parse("#112233"))), activeScreen: false
        ))
        #expect(hex.url.absoluteString == "iine://whiteboard?color=%23112233")

        let active = try #require(try request(["whiteboard", "--active-screen"]))
        #expect(active.command == .whiteboard(background: nil, activeScreen: true))
        #expect(active.url.absoluteString == "iine://whiteboard?active_screen=1")

        let both = try #require(try request([
            "whiteboard", "--active-screen", "--color", "#001122",
        ]))
        #expect(both.url.absoluteString == "iine://whiteboard?color=%23001122&active_screen=1")
        #expect(try CommandLineRequest(url: both.url) == both)
    }

    @Test func whiteboardRejectsMalformedOptions() {
        #expect(throws: CommandLineParseError.missingValue("--color COLOR")) {
            try CommandLineParser.parse(["whiteboard", "--color"])
        }
        #expect(throws: CommandLineParseError.missingValue("--color COLOR")) {
            try CommandLineParser.parse(["whiteboard", "--color", ""])
        }
        #expect(throws: CommandLineParseError.unknownArgument("--bogus")) {
            try CommandLineParser.parse(["whiteboard", "--bogus"])
        }
    }

    @Test func whiteboardTransparentBackground() throws {
        let cli = try #require(try request(["whiteboard", "--color", "transparent"]))
        #expect(cli.command == .whiteboard(background: .transparent, activeScreen: false))
        #expect(cli.url.absoluteString == "iine://whiteboard?color=transparent")
        #expect(try CommandLineRequest(url: cli.url) == cli)

        let clear = try #require(try request(["snip", "whiteboard", "--color", "CLEAR"]))
        #expect(clear.command == .whiteboard(background: .transparent, activeScreen: false))
    }

    @Test func whiteboardInvalidColorFallsBackToWhite() throws {
        let parsed = try #require(try request(["whiteboard", "--color", "mauve"]))
        #expect(parsed.command == .whiteboard(background: .solid(.white), activeScreen: false))
    }

    @Test func invalidArgumentsThrow() {
        #expect(throws: CommandLineParseError.unknownArgument("bogus")) {
            try CommandLineParser.parse(["bogus"])
        }
        #expect(throws: CommandLineParseError.missingValue("-o")) {
            try CommandLineParser.parse(["-o"])
        }
        #expect(throws: CommandLineParseError.missingValue("-o")) {
            try CommandLineParser.parse(["-o", ""])
        }
        #expect(throws: CommandLineParseError.missingValue("--pos X Y")) {
            try CommandLineParser.parse(["--pos", "1"])
        }
        #expect(throws: CommandLineParseError.invalidNumber("left")) {
            try CommandLineParser.parse(["--pos", "left", "2"])
        }
        #expect(throws: CommandLineParseError.invalidNumber("1e999")) {
            try CommandLineParser.parse(["--pos", "1e999", "2"])
        }
        #expect(throws: CommandLineParseError.extraArgument("extra")) {
            try CommandLineParser.parse(["-o", "clipboard", "extra"])
        }
        #expect(throws: CommandLineParseError.extraArgument("3")) {
            try CommandLineParser.parse(["--pos", "1", "2", "3"])
        }
        #expect(throws: CommandLineParseError.unknownArgument("junk")) {
            try CommandLineParser.parse(["snip", "junk"])
        }
    }

    @Test func urlRoundTripForEveryCommand() throws {
        let commands: [CommandLineCommand] = [
            .snip,
            .clipboard,
            .save(path: "/tmp/a b&c?.png"),
            .quickSave,
            .pin(x: -12.5, y: 300),
            .pickColor,
            .barcodeScan,
            .showImages,
            .hideImages,
            .whiteboard(background: .solid(.gray), activeScreen: true),
            .whiteboard(background: nil, activeScreen: false),
        ]
        for command in commands {
            let original = CommandLineRequest(command: command)
            let decoded = try CommandLineRequest(url: original.url)
            #expect(decoded == original)
        }
    }

    @Test func urlWithEscapedPathRoundTrips() throws {
        let path = "/tmp/截图 #1 & 100%.png"
        let original = CommandLineRequest(command: .save(path: path))
        let decoded = try CommandLineRequest(url: original.url)
        #expect(decoded == original)
    }

    @Test func invalidURLsThrow() {
        let invalid = [
            "https://snip",
            "iine://bogus",
            "iine://save",
            "iine://save?path=",
            "iine://pin?x=1",
            "iine://pin?x=a&y=2",
            "iine://pin?x=1e999&y=2",
        ]
        for raw in invalid {
            let url = URL(string: raw)!
            #expect(throws: (any Error).self) {
                try CommandLineRequest(url: url)
            }
        }
    }
}
