import Foundation
import XCTest
@testable import command98

final class ScreenTests: XCTestCase {
    func testWriteAndClip() {
        let s = Screen(width: 10, height: 3)
        s.write(8, 0, "HELLO", fg: 15, bg: 1)
        XCTAssertEqual(s[8, 0].ch, "H")
        XCTAssertEqual(s[9, 0].ch, "E")
        XCTAssertEqual(s[8, 0].bg, 1)
        // L and O fell off the right edge, not onto the next row
        XCTAssertEqual(s[0, 1].ch, " ")
    }

    func testNewlineReturnsToStartColumn() {
        let s = Screen(width: 10, height: 3)
        s.write(3, 0, "AB\nCD")
        XCTAssertEqual(s[3, 0].ch, "A")
        XCTAssertEqual(s[3, 1].ch, "C")
        XCTAssertEqual(s[4, 1].ch, "D")
    }

    func testCRLFMovesToTheNextRowOnce() {
        let s = Screen(width: 10, height: 3)
        s.write(3, 0, "AB\r\nCD")
        XCTAssertEqual(s[3, 0].ch, "A")
        XCTAssertEqual(s[4, 0].ch, "B")
        XCTAssertEqual(s[3, 1].ch, "C")
        XCTAssertEqual(s[4, 1].ch, "D")
        XCTAssertEqual(s[0, 0].ch, " ")
        XCTAssertEqual(s[0, 1].ch, " ")
    }

    func testBoxDrawsCornersAndClearsInside() {
        let s = Screen(width: 12, height: 5)
        s.fill(x: 0, y: 0, width: 12, height: 5, ch: "X")
        s.box(x: 1, y: 1, width: 6, height: 3, fg: 15, bg: 1, double: true)
        XCTAssertEqual(s[1, 1].ch, "\u{2554}")
        XCTAssertEqual(s[6, 1].ch, "\u{2557}")
        XCTAssertEqual(s[1, 3].ch, "\u{255A}")
        XCTAssertEqual(s[2, 2].ch, " ")
        XCTAssertEqual(s[2, 2].bg, 1)
    }

    func testDosColorOrder() {
        XCTAssertEqual(Screen.sgr(fg: 7, bg: 1), "\u{1B}[37;44m")
        XCTAssertEqual(Screen.sgr(fg: 15, bg: 4), "\u{1B}[97;41m")
        XCTAssertEqual(Screen.sgr(fg: 14, bg: 0), "\u{1B}[93;40m")
    }

    func testRenderDiffOnlyTouchesChangedRows() {
        let a = Screen(width: 8, height: 3)
        a.write(0, 0, "TOP")
        a.write(0, 1, "MID")
        let b = a.copy()
        b.write(0, 1, "NEW")

        let file = CaptureFile(prefix: "command98-screen")
        b.renderDiff(to: Out(file.fd), previous: a)
        file.close()
        let rendered = file.text()
        file.remove()

        XCTAssertTrue(rendered.contains("\u{1B}[2;1H"))
        XCTAssertFalse(rendered.contains("\u{1B}[1;1H"))
        XCTAssertFalse(rendered.contains("\u{1B}[3;1H"))
        XCTAssertTrue(rendered.contains("NEW"))
    }

    func testPutRejectsControlGlyphs() {
        let s = Screen(width: 6, height: 1)
        s.put(0, 0, "\u{1B}")
        s.put(1, 0, "\t")
        s.put(2, 0, "\u{7F}")
        s.put(3, 0, Character(UnicodeScalar(0x9B)!)) // 8-bit CSI
        s.put(4, 0, "\u{2500}")
        s.put(5, 0, "\u{1F600}")
        XCTAssertEqual(s[0, 0].ch, "\u{00B7}")
        XCTAssertEqual(s[1, 0].ch, " ")
        XCTAssertEqual(s[2, 0].ch, "\u{00B7}")
        XCTAssertEqual(s[3, 0].ch, "\u{00B7}")
        XCTAssertEqual(s[4, 0].ch, "\u{2500}")
        XCTAssertEqual(s[5, 0].ch, "\u{1F600}")
    }

    func testControlBytesInFilesNeverReachTheTerminal() {
        let s = Screen(width: 24, height: 2)
        // A .BAS file can be any bytes; loading it must not paint a terminal command.
        s.write(0, 0, "\u{1B}[?1049l\u{1B}[2J")
        XCTAssertEqual(s[0, 0].ch, "\u{00B7}")
        XCTAssertFalse(s.cells.contains { cell in
            cell.ch.unicodeScalars.contains { $0.properties.generalCategory == .control }
        })

        let rendered = renderText(s)
        XCTAssertFalse(rendered.contains("\u{1B}[?1049l"))
        XCTAssertFalse(rendered.contains("\u{1B}[2J"))
    }

    func testTabExpandsToEightColumnStopsAndStaysOnThePage() {
        let s = Screen(width: 80, height: 2)
        s.write(3, 0, "A\tB")
        XCTAssertEqual(s[3, 0].ch, "A")
        XCTAssertEqual(s[8, 0].ch, "B")
        XCTAssertEqual(s[4, 0].ch, " ")

        let narrow = Screen(width: 10, height: 1)
        let end = narrow.write(8, 0, "\tX")
        XCTAssertEqual(end, 10)
        XCTAssertEqual(narrow[8, 0].ch, " ")
        XCTAssertEqual(narrow[9, 0].ch, " ")
        XCTAssertFalse(narrow.cells.contains { $0.ch == "\t" })

        let edge = Screen(width: 80, height: 1)
        XCTAssertEqual(edge.write(79, 0, "\tZ"), 80)
        XCTAssertEqual(edge[79, 0].ch, " ")
        XCTAssertFalse(edge.cells.contains { $0.ch == "\t" })
    }

    private func renderText(_ screen: Screen) -> String {
        let file = CaptureFile(prefix: "command98-screen")
        screen.render(to: Out(file.fd))
        file.close()
        let text = file.text()
        file.remove()
        return text
    }
}
