import Foundation
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import command98

final class QBasicIDETests: XCTestCase {
    private func row(_ screen: Screen, _ y: Int) -> String {
        String((0..<screen.width).map { screen[$0, y].ch })
    }

    func testInsertAndOverwrite() {
        var editor = QBasicEditor(source: "ABC")
        editor.handle(.char("X"))
        XCTAssertEqual(editor.source, "XABC")
        XCTAssertEqual(editor.cursorColumn, 1)

        editor.handle(.insert)
        XCTAssertFalse(editor.insertMode)
        editor.handle(.char("Y"))
        XCTAssertEqual(editor.source, "XYBC")
        XCTAssertEqual(editor.cursorColumn, 2)

        editor.handle(.end)
        editor.handle(.char("Z"))
        XCTAssertEqual(editor.source, "XYBCZ")
    }

    func testEnterBackspaceAndDeleteJoinLines() {
        var editor = QBasicEditor(source: "ABCD")
        editor.handle(.right)
        editor.handle(.right)
        editor.handle(.enter)
        XCTAssertEqual(editor.lines, ["AB", "CD"])
        XCTAssertEqual(editor.cursorRow, 1)
        XCTAssertEqual(editor.cursorColumn, 0)

        editor.handle(.backspace)
        XCTAssertEqual(editor.source, "ABCD")
        XCTAssertEqual(editor.cursorRow, 0)
        XCTAssertEqual(editor.cursorColumn, 2)

        editor.handle(.delete)
        XCTAssertEqual(editor.source, "ABD")
        editor.handle(.backspace)
        XCTAssertEqual(editor.source, "AD")

        editor.handle(.home)
        editor.handle(.backspace)
        XCTAssertEqual(editor.source, "AD")
        editor.handle(.end)
        editor.handle(.delete)
        XCTAssertEqual(editor.source, "AD")
    }

    func testTabUsesFourColumnStops() {
        var editor = QBasicEditor(source: "")
        editor.handle(.tab)
        XCTAssertEqual(editor.source, "    ")
        XCTAssertEqual(editor.cursorColumn, 4)
        editor.handle(.char("A"))
        editor.handle(.tab)
        XCTAssertEqual(editor.source, "    A   ")
        XCTAssertEqual(editor.cursorColumn, 8)
    }

    func testCursorMovementClipsToTextAndDocument() {
        var editor = QBasicEditor(source: "ONE\nLONGER\nX")
        editor.handle(.down)
        editor.handle(.end)
        XCTAssertEqual(editor.cursorColumn, 6)
        editor.handle(.up)
        XCTAssertEqual(editor.cursorRow, 0)
        XCTAssertEqual(editor.cursorColumn, 3)
        editor.handle(.right)
        XCTAssertEqual(editor.cursorRow, 1)
        XCTAssertEqual(editor.cursorColumn, 0)

        editor.handle(.home, control: true)
        XCTAssertEqual(editor.cursorRow, 0)
        XCTAssertEqual(editor.cursorColumn, 0)
        editor.handle(.left)
        XCTAssertEqual(editor.cursorRow, 0)
        XCTAssertEqual(editor.cursorColumn, 0)

        editor.handle(.end, control: true)
        XCTAssertEqual(editor.cursorRow, 2)
        XCTAssertEqual(editor.cursorColumn, 1)
        editor.handle(.right)
        XCTAssertEqual(editor.cursorRow, 2)
        XCTAssertEqual(editor.cursorColumn, 1)
    }

    func testVerticalAndHorizontalScrollingKeepCursorVisible() {
        let source = (1...60).map { "LINE \($0)" }.joined(separator: "\n")
        var editor = QBasicEditor(source: source)
        for _ in 0..<30 { editor.handle(.down) }
        XCTAssertEqual(editor.cursorRow, 30)
        XCTAssertEqual(editor.topRow, 10)
        editor.handle(.pageUp)
        XCTAssertEqual(editor.cursorRow, 9)
        XCTAssertEqual(editor.topRow, 9)
        editor.handle(.pageDown)
        XCTAssertEqual(editor.cursorRow, 30)
        XCTAssertEqual(editor.topRow, 10)
        editor.handle(.end, control: true)
        XCTAssertEqual(editor.topRow, 39)
        editor.handle(.home, control: true)
        XCTAssertEqual(editor.topRow, 0)

        var wide = QBasicEditor(source: String(repeating: "A", count: 100))
        wide.handle(.end)
        XCTAssertEqual(wide.cursorColumn, 100)
        XCTAssertEqual(wide.leftColumn, 21)
        let screen = wide.render()
        XCTAssertEqual(screen[79, 2].ch, "_")
        wide.handle(.home)
        XCTAssertEqual(wide.leftColumn, 0)
    }

    func testMenuNavigationAndActions() {
        var editor = QBasicEditor(source: "")
        XCTAssertEqual(editor.handle(.f(10)), .none)
        XCTAssertTrue(editor.menuFocused)
        XCTAssertEqual(editor.selectedMenu, 0)
        editor.handle(.right)
        XCTAssertEqual(editor.selectedMenu, 1)
        editor.handle(.enter)
        XCTAssertTrue(editor.menuOpen)
        editor.handle(.down)
        XCTAssertEqual(editor.selectedItem, 1)
        XCTAssertEqual(editor.handle(.enter), .selectAll)
        XCTAssertFalse(editor.menuFocused)
        editor.selectAll()
        XCTAssertTrue(editor.selectsAll)

        editor.focusMenu(0)
        editor.handle(.enter)
        editor.handle(.escape)
        XCTAssertFalse(editor.menuFocused)
        XCTAssertFalse(editor.menuOpen)

        XCTAssertEqual(editor.handle(.ctrl("S")), .save)
        XCTAssertEqual(editor.handle(.f(5)), .run)
    }

    func testLayoutColoursTitleAndStatus() {
        var editor = QBasicEditor(source: "PRINT 1", fileName: "C:\\CODE\\DEMO.BAS")
        let screen = editor.render()
        XCTAssertTrue(row(screen, 0).contains("File"))
        XCTAssertTrue(row(screen, 0).contains("Edit"))
        XCTAssertTrue(row(screen, 0).contains("Run"))
        XCTAssertTrue(row(screen, 0).contains("Help"))
        XCTAssertTrue(row(screen, 1).contains("DEMO.BAS"))
        XCTAssertTrue(row(screen, 24).contains("Ln 1, Col 1"))
        XCTAssertTrue(row(screen, 24).contains("INS"))
        XCTAssertTrue(row(screen, 24).contains("DEMO.BAS"))
        XCTAssertTrue(screen.cells.allSatisfy { $0.bg == 1 })
        XCTAssertEqual(screen[0, 2].ch, "_")
        XCTAssertEqual(screen[0, 2].fg, 15)
        XCTAssertEqual(screen[2, 0].fg, 15) // highlighted File shortcut

        editor.handle(.insert)
        XCTAssertTrue(row(editor.render(), 24).contains("OVR"))
        editor.focusMenu(0)
        editor.handle(.enter)
        XCTAssertTrue(editor.render().cells.allSatisfy { $0.bg == 1 })
    }

    func testSaveLoadRoundTripWritesDOSNewlines() throws {
        let test = TestShell()
        var editor = QBasicEditor(source: "PRINT \"ONE\"\nEND\n")
        try editor.save("C:\\ROUND.BAS", shell: test.shell)
        XCTAssertFalse(editor.dirty)
        XCTAssertEqual(editor.displayName, "ROUND.BAS")

        let url = test.root.appendingPathComponent("ROUND.BAS")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PRINT \"ONE\"\r\nEND\r\n")

        var loaded = QBasicEditor(source: "")
        try loaded.load("round.bas", shell: test.shell)
        XCTAssertEqual(loaded.source, editor.source)
        XCTAssertEqual(loaded.lines.count, 3)
        XCTAssertFalse(loaded.dirty)
    }

    func testLoadNormalisesNewlinesAndStopsAtDOSEndMarker() throws {
        let test = TestShell()
        test.write("INPUT.BAS", "PRINT 1\r\nPRINT 2\rPRINT 3\n\u{1A}ignored")
        var editor = QBasicEditor(source: "")
        try editor.load("INPUT.BAS", shell: test.shell)
        XCTAssertEqual(editor.source, "PRINT 1\nPRINT 2\nPRINT 3\n")
    }

    func testPromptProducesAFileAction() {
        var editor = QBasicEditor(source: "")
        editor.beginPrompt(.save)
        for ch in "NEW.BAS" { editor.handle(.char(ch)) }
        XCTAssertEqual(editor.handle(.enter), .saveFile("NEW.BAS"))
        XCTAssertNil(editor.prompt)

        editor.beginPrompt(.open)
        editor.handle(.char("X"))
        editor.handle(.backspace)
        XCTAssertEqual(editor.handle(.enter), .openFile(""))
    }

    func testSelectAllCanBeReplacedOrCleared() {
        var editor = QBasicEditor(source: "ONE\nTWO")
        editor.selectAll()
        editor.handle(.char("X"))
        XCTAssertEqual(editor.source, "X")
        editor.selectAll()
        editor.clear()
        XCTAssertEqual(editor.source, "")
        XCTAssertEqual(editor.lines, [""])
    }

    func testScreenIOPrintLocateColourAndScroll() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("command98-qbasic-screen-\(UUID().uuidString)").path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let output = QBasicScreenIO(out: Out(fd))
        output.color(15, 4)
        output.locate(2, 3)
        output.write("A\nB")
        XCTAssertEqual(output.screen[2, 1].ch, "A")
        XCTAssertEqual(output.screen[2, 1].fg, 15)
        XCTAssertEqual(output.screen[2, 1].bg, 4)
        XCTAssertEqual(output.screen[0, 2].ch, "B")

        output.locate(25, 1)
        output.write("LAST\nNEXT")
        XCTAssertTrue(row(output.screen, 23).hasPrefix("LAST"))
        XCTAssertTrue(row(output.screen, 24).hasPrefix("NEXT"))
        output.cls()
        XCTAssertTrue(output.screen.cells.allSatisfy { $0.ch == " " && $0.fg == 15 && $0.bg == 4 })
        close(fd)
        unlink(path)
    }
}
