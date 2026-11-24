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
}
