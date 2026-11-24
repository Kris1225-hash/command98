import XCTest
@testable import command98

final class BlueScreenTests: XCTestCase {
    private func rows(_ screen: Screen) -> [String] {
        (0..<screen.height).map { y in
            String((0..<screen.width).map { screen[$0, y].ch })
        }
    }

    private func pageText(_ screen: Screen) -> String {
        rows(screen).joined(separator: "\n")
    }

    func testPageIsFullScreenBlue() {
        let screen = BlueScreen.makeScreen(reason: "WIN.COM")
        XCTAssertEqual(screen.width, 80)
        XCTAssertEqual(screen.height, 25)

        var wrong: String? = nil
        for y in 0..<screen.height {
            for x in 0..<screen.width where screen[x, y].bg != BlueScreen.background {
                wrong = "cell (\(x),\(y)) has background \(screen[x, y].bg)"
                break
            }
            if wrong != nil { break }
        }
        XCTAssertNil(wrong)
    }

    func testPageCarriesTheStory() {
        let screen = BlueScreen.makeScreen(reason: "WIN.COM")
        let text = pageText(screen)

        XCTAssertTrue(text.contains("COMMAND98"))
        XCTAssertTrue(text.contains("*** STOP: 0xC0DE0001"))
        XCTAssertTrue(text.contains("(0x00000000, 0x00000000, 0x00000000, 0x00000000)"))
        XCTAssertTrue(text.contains("Press any key to return to the command prompt."))
        XCTAssertTrue(text.contains("WIN.COM"))
    }

    func testHeaderIsBrightAndBodyIsGrey() {
        let screen = BlueScreen.makeScreen()
        XCTAssertEqual(screen[4, 2].ch, "C")
        XCTAssertEqual(screen[4, 2].fg, BlueScreen.bright)
        XCTAssertEqual(screen[4, 4].fg, BlueScreen.bright)

        let body = screen[4, 6]
        XCTAssertNotEqual(body.ch, " ")
        XCTAssertEqual(body.fg, BlueScreen.text)
        XCTAssertEqual(body.bg, BlueScreen.background)
    }

    func testReasonIsOptional() {
        let blank = pageText(BlueScreen.makeScreen())
        XCTAssertTrue(blank.contains("could not be loaded from C:\\WINDOWS"))

        let named = pageText(BlueScreen.makeScreen(reason: "WIN.COM"))
        XCTAssertTrue(named.contains("The file WIN.COM could not be loaded"))
    }

    func testWordingIsNotMicrosofts() {
        let text = pageText(BlueScreen.makeScreen(reason: "WIN.COM"))
        let forbidden = [
            "A fatal exception",
            "VXD",
            "invalid VxD",
            "Windows protection error",
        ]
        for phrase in forbidden {
            XCTAssertFalse(text.contains(phrase), "unexpected phrase: \(phrase)")
        }
    }

    func testEveryLineFitsEightyColumns() {
        for line in BlueScreen.layout(reason: "WIN.COM") {
            XCTAssertLessThanOrEqual(line.text.count, 80, "row \(line.row): \(line.text)")
            XCTAssertGreaterThanOrEqual(line.row, 0)
            XCTAssertLessThan(line.row, 25)
        }

        let longReason = String(repeating: "X", count: 200)
        for line in BlueScreen.layout(reason: longReason) where line.row != 10 {
            XCTAssertLessThanOrEqual(line.text.count, 80)
        }
        // A reason longer than the page is clipped by the cell buffer, never past it.
        let screen = BlueScreen.makeScreen(reason: longReason)
        XCTAssertEqual(screen.width, 80)
        XCTAssertEqual(screen.height, 25)
        XCTAssertEqual(screen[79, 10].bg, BlueScreen.background)
    }

    func testHiddenBsodCommandIsRegistered() {
        XCTAssertNotNil(BlueScreen.commands["BSOD"])
        XCTAssertNotNil(BlueScreen.help["BSOD"])
    }
}
