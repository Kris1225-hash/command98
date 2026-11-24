import Darwin
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

    func testDecodeSequenceIgnoresCSIParameters() {
        XCTAssertEqual(KeyReader.decodeSequence(Array("[A".utf8)), .up)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[1;5A".utf8)), .up)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[1;5B".utf8)), .down)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[1;5C".utf8)), .right)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[1;5D".utf8)), .left)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[5H".utf8)), .home)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[3;5~".utf8)), .delete)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[11~".utf8)), .f(1))
        XCTAssertEqual(KeyReader.decodeSequence(Array("OP".utf8)), .f(1))
        XCTAssertEqual(KeyReader.decodeSequence(Array("OH".utf8)), .home)
        XCTAssertEqual(KeyReader.decodeSequence(Array("OA".utf8)), .up)
        XCTAssertEqual(KeyReader.decodeSequence(Array("A".utf8)), .up)
        // A truncated CSI, an unknown tilde number and an escape that is not a key.
        XCTAssertEqual(KeyReader.decodeSequence(Array("[".utf8)), .unknown)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[99~".utf8)), .unknown)
        XCTAssertEqual(KeyReader.decodeSequence(Array("[?25l".utf8)), .unknown)
        XCTAssertEqual(KeyReader.decodeSequence([]), .escape)
    }

    func testSeededBytesDecodeWholeSequences() {
        // ESC [ A must not stop at the '[' (it is not a final byte).
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 65]), [.up])
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 49, 59, 53, 65]), [.up])
        XCTAssertEqual(KeyReader.decodeAll([27, 79, 80]), [.f(1)])
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 49, 49, 126]), [.f(1)])
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 66]), [.down])
        XCTAssertEqual(KeyReader.decodeAll([27, 91]), [.escape, .char("[")])
        XCTAssertEqual(KeyReader.decodeAll([27, 79]), [.escape, .char("O")])
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 126]), [.unknown])
        // A byte after a bare Esc belongs to the next key.
        XCTAssertEqual(KeyReader.decodeAll([27, 32]), [.escape, .char(" ")])
        XCTAssertEqual(KeyReader.decodeAll([27, 32, 66]), [.escape, .char(" "), .char("B")])
    }

    func testTruncatedSequenceReplaysEveryConsumedByte() {
        // A CSI that times out before its final byte must give back the whole body,
        // not just the introducer: the '1' used to vanish.
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 49]), [.escape, .char("["), .char("1")])
        XCTAssertEqual(KeyReader.decodeAll([27, 91, 49, 59]), [.escape, .char("["), .char("1"), .char(";")])

        var decoder = KeyDecoder(stream: .seeded([27, 91, 49]))
        XCTAssertEqual(decoder.readKey(), .escape)
        XCTAssertTrue(decoder.hasHeldByte)
        XCTAssertTrue(decoder.hasMore)
        XCTAssertEqual(decoder.readKey(), .char("["))
        XCTAssertTrue(decoder.hasHeldByte)
        XCTAssertEqual(decoder.readKey(), .char("1"))
        XCTAssertFalse(decoder.hasHeldByte)
        XCTAssertFalse(decoder.hasMore)
    }

    func testOverlongSequenceIsBounded() {
        var bytes = [27, 91]
        bytes += Array(repeating: 49, count: 40) // '1' x 40, so no final byte in range
        bytes.append(65) // 'A'
        let keys = KeyReader.decodeAll(bytes)
        XCTAssertEqual(keys.first, .unknown)
        XCTAssertFalse(keys.contains(.up))
        XCTAssertLessThanOrEqual(KeyReader.maxSequenceLength, 32)
    }

    func testLoneEscapeDoesNotWaitForMoreBytes() {
        var decoder = KeyDecoder(stream: .seeded([27]))
        XCTAssertEqual(decoder.readKey(), .escape)
        XCTAssertFalse(decoder.hasMore)
    }

    func testConsoleDecoderReadsFromAPipe() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        let bytes: [UInt8] = [0x1B, 0x5B, 0x41, 0x1B, 0x20]
        let written = bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, bytes.count)
        close(fds[1])

        var decoder = KeyDecoder(stream: .console(fd: fds[0]))
        XCTAssertEqual(decoder.readKey(), .up)
        XCTAssertEqual(decoder.readKey(), .escape)
        XCTAssertEqual(decoder.readKey(), .char(" "))
    }

    func testPipeDoesNotBlockOnEscapeFollowedBySpace() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let bytes: [UInt8] = [0x1B, 0x20]
        let written = bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, bytes.count)
        // The writer stays open: a second unguarded read would hang here.
        var decoder = KeyDecoder(stream: .console(fd: fds[0]))
        XCTAssertEqual(decoder.readKey(), .escape)
        XCTAssertEqual(decoder.readKey(), .char(" "))
    }

    func testPipeLoneEscapeReturnsAfterTheTimeout() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var esc: UInt8 = 27
        XCTAssertEqual(Darwin.write(fds[1], &esc, 1), 1)
        // The writer stays open, so only the continuation timeout can end the read.
        var decoder = KeyDecoder(stream: .console(fd: fds[0]), timeoutMS: 30)
        let start = Date()
        XCTAssertEqual(decoder.readKey(), .escape)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testHeldBackByteIsVisibleToPollingCallers() throws {
        KeyReader.resetDecoders()
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0]); close(fds[1])
            KeyReader.resetDecoders()
        }
        let bytes: [UInt8] = [0x1B, 0x20]
        let written = bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, bytes.count)

        XCTAssertEqual(KeyReader.read(fd: fds[0]), .escape)
        // The space was read to prove the Esc was bare, then held back. The kernel
        // descriptor is now empty, so polling it alone would strand the key.
        XCTAssertTrue(KeyReader.hasBufferedKey(fd: fds[0]))
        XCTAssertEqual(KeyReader.read(fd: fds[0]), .char(" "))
        XCTAssertFalse(KeyReader.hasBufferedKey(fd: fds[0]))
    }

    func testPipeTruncatedSequenceKeepsHeldBytesVisible() throws {
        KeyReader.resetDecoders()
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0]); close(fds[1])
            KeyReader.resetDecoders()
        }
        let bytes: [UInt8] = [0x1B, 0x5B, 0x31]
        let written = bytes.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, bytes.count)
        // The writer stays open: only the continuation timeout can end the CSI, and
        // an open-but-empty descriptor leaves hasBufferedKey to the held bytes.
        XCTAssertEqual(KeyReader.read(fd: fds[0]), .escape)
        // Both '[' and '1' were read while looking for a final byte; polling the
        // kernel descriptor alone would strand them.
        XCTAssertTrue(KeyReader.hasBufferedKey(fd: fds[0]))
        XCTAssertEqual(KeyReader.read(fd: fds[0]), .char("["))
        XCTAssertTrue(KeyReader.hasBufferedKey(fd: fds[0]))
        XCTAssertEqual(KeyReader.read(fd: fds[0]), .char("1"))
        XCTAssertFalse(KeyReader.hasBufferedKey(fd: fds[0]))
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
