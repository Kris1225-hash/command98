import XCTest
@testable import command98

final class KeyTests: XCTestCase {
    func testPlainKeys() {
        XCTAssertEqual(KeyReader.decode(13), .enter)
        XCTAssertEqual(KeyReader.decode(9), .tab)
        XCTAssertEqual(KeyReader.decode(8), .backspace)
        XCTAssertEqual(KeyReader.decode(127), .backspace)
        XCTAssertEqual(KeyReader.decode(3), .interrupt)
        XCTAssertEqual(KeyReader.decode(26), .eof)
        XCTAssertEqual(KeyReader.decode(65), .char("A"))
        XCTAssertEqual(KeyReader.decode(1), .ctrl("A"))
    }

    func testCursorAndFunctionKeys() {
        XCTAssertEqual(KeyReader.decodeEscape("[A"), .up)
        XCTAssertEqual(KeyReader.decodeEscape("[B"), .down)
        XCTAssertEqual(KeyReader.decodeEscape("[C"), .right)
        XCTAssertEqual(KeyReader.decodeEscape("[D"), .left)
        XCTAssertEqual(KeyReader.decodeEscape("[5~"), .pageUp)
        XCTAssertEqual(KeyReader.decodeEscape("[6~"), .pageDown)
        XCTAssertEqual(KeyReader.decodeEscape("[3~"), .delete)
        XCTAssertEqual(KeyReader.decodeEscape("OP"), .f(1))
        XCTAssertEqual(KeyReader.decodeEscape("[11~"), .f(1))
        XCTAssertEqual(KeyReader.decodeEscape("[24~"), .f(12))
        XCTAssertEqual(KeyReader.decodeEscape("[99~"), .unknown)
    }

    func testMenuLetters() {
        XCTAssertEqual(KeyReader.letter(.char("r")), "R")
        XCTAssertNil(KeyReader.letter(.f(1)))
    }
}

final class AnsiTests: XCTestCase {
    override func tearDown() {
        AnsiSys.loaded = true
        AnsiSys.reset()
        super.tearDown()
    }

    func testLoadedPassesEscapesThrough() {
        AnsiSys.loaded = true
        let s = "\u{1B}[1;31mRED"
        XCTAssertEqual(AnsiSys.encode(s, fd: 1), s)
    }

    func testUnloadedShowsTheArrowCharacter() {
        AnsiSys.loaded = false
        XCTAssertEqual(AnsiSys.encode("\u{1B}[2J", fd: 1), "\u{2190}[2J")
    }
}
