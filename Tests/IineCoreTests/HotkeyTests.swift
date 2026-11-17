import Foundation
import CoreGraphics
import Testing
@testable import IineCore

struct HotkeyTests {
    @Test func functionKeyListenerHonorsModifiersAndEventTypes() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 122, keyDown: true))
        for flags: CGEventFlags in [[], .maskSecondaryFn, .maskAlphaShift] {
            event.flags = flags
            #expect(FunctionKeyMonitor.accepts(event, type: .keyDown))
        }
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            event.flags = flags
            #expect(!FunctionKeyMonitor.accepts(event, type: .keyDown))
        }
        event.flags = []
        #expect(!FunctionKeyMonitor.accepts(event, type: .keyUp))
        #expect(!FunctionKeyMonitor.accepts(event, type: .tapDisabledByTimeout))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(!FunctionKeyMonitor.accepts(event, type: .keyDown))
    }

    @Test func codableRoundTrip() throws {
        let original = Hotkey(keyCode: 122, modifiers: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded == original)
    }

    @Test func f1Constant() {
        #expect(Hotkey.f1.keyCode == 122)
        #expect(Hotkey.f1.modifiers == 0)
    }

    // ⌃⇧A 是默认热键：kVK_ANSI_A=0，Control(0x1000)+Shift(0x0200)
    @Test func ctrlShiftAConstant() {
        #expect(Hotkey.ctrlShiftA.keyCode == 0)
        #expect(Hotkey.ctrlShiftA.modifiers == 0x1200)
        #expect(Hotkey.ctrlShiftA.modifiers != Hotkey.f1.modifiers)
    }
}
