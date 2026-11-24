import Foundation
import XCTest
@testable import command98

final class DebugToolTests: XCTestCase {
    final class Sink {
        var parts: [String] = []
        var text: String { parts.joined() }
    }

    private func make(_ inputs: [String],
                      files: DebugFiles = .unavailable,
                      confirm: @escaping (String) -> Bool = { _ in false },
                      interactive: Bool = false) -> (DebugSession, Sink) {
        let sink = Sink()
        var queue = inputs
        let session = DebugSession(
            files: files,
            input: { queue.isEmpty ? nil : queue.removeFirst() },
            output: { sink.parts.append($0) },
            confirmWrite: confirm,
            interactive: interactive
        )
        return (session, sink)
    }

    private func bytes(_ session: DebugSession, _ start: Int, _ count: Int) -> [UInt8] {
        (0..<count).map { session.memory[(start + $0) & 0xFFFF] }
    }

    // MARK: D

    func testHexDumpExactRow() {
        let (session, sink) = make([])
        session.execute("E 100 4D 5A 90 00 03 00 00 00 04 00 00 00 FF FF 00 00")
        session.execute("D 100 L 10")
        XCTAssertEqual(sink.text,
                       "0000:0100  4D 5A 90 00 03 00 00 00-04 00 00 00 FF FF 00 00  MZ..............\n")
    }

    func testHexDumpAsciiGutterAndPartialRow() {
        let (session, sink) = make([])
        session.execute("E 200 41 42 00 7F")
        session.execute("D 200 L 4")
        let line = sink.text.trimmingCharacters(in: .newlines)
        XCTAssertTrue(line.hasPrefix("0000:0200  41 42 00 7F "), line)
        XCTAssertTrue(line.hasSuffix("  AB.."), line)
        XCTAssertEqual(line.count, 60 + 4)
        XCTAssertEqual(Array(line)[34], "-")
        XCTAssertEqual(Array(line)[11], "4")
        XCTAssertEqual(Array(line)[60], "A")
    }

    func testEnterQuotedTextThenDump() {
        let (session, sink) = make([])
        session.execute("E 100 \"Hello\",00,FF")
        XCTAssertEqual(bytes(session, 0x100, 7), [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0xFF])
        session.execute("D 100 L 7")
        let line = sink.text.trimmingCharacters(in: .newlines)
        XCTAssertTrue(line.hasPrefix("0000:0100  48 65 6C 6C 6F 00 FF "), line)
        XCTAssertTrue(line.hasSuffix("  Hello.."), line)
    }

    func testDumpDefaultIs128BytesFrom0100() {
        let (session, sink) = make([])
        session.execute("D")
        let lines = sink.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 8)
        XCTAssertTrue(lines.first!.hasPrefix("0000:0100"), lines.first!)
        XCTAssertTrue(lines.last!.hasPrefix("0000:0170"), lines.last!)
    }

    func testRangeFormsAgree() {
        let (a, sinkA) = make([])
        a.execute("E 100 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F")
        a.execute("D 100 L 10")
        let (b, sinkB) = make([])
        b.execute("E 100 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F")
        b.execute("D 100 10F")
        XCTAssertEqual(sinkA.text, sinkB.text)
    }

    // MARK: A

    func testAssembleEncodings() {
        let cases: [(String, [UInt8])] = [
            ("NOP", [0x90]),
            ("RET", [0xC3]),
            ("INT 20", [0xCD, 0x20]),
            ("INT 21", [0xCD, 0x21]),
            ("MOV AL,12", [0xB0, 0x12]),
            ("MOV AX,1234", [0xB8, 0x34, 0x12]),
            ("MOV AH,56", [0xB4, 0x56]),
            ("JMP 0200", [0xE9, 0xFD, 0x00]),
            ("CALL 0200", [0xE8, 0xFD, 0x00]),
            ("DB 41 42 \"CD\"", [0x41, 0x42, 0x43, 0x44]),
            ("DW 1234 ABCD", [0x34, 0x12, 0xCD, 0xAB]),
        ]
        for (line, expected) in cases {
            let (session, sink) = make([line, ""])
            session.execute("A 100")
            XCTAssertEqual(bytes(session, 0x100, expected.count), expected, line)
            XCTAssertTrue(sink.text.contains("0000:0100  "), line)
        }
    }

    func testAssembleUnknownDoesNotAdvance() {
        let (session, sink) = make(["BOGUS", "NOP", ""])
        session.execute("A 100")
        XCTAssertTrue(sink.text.contains("^ Error"))
        XCTAssertEqual(session.memory[0x100], 0x90)
        XCTAssertTrue(sink.text.contains("0000:0100  90"))
    }

    func testAssembleAtGivenSegmentOffset() {
        let (session, _) = make(["MOV AL,01", ""])
        session.execute("A 2000:0100")
        XCTAssertEqual(session.memory[0x20100 & 0xFFFF], 0xB0)
        XCTAssertEqual(session.memory[0x20101 & 0xFFFF], 0x01)
    }

    // MARK: U

    func testDisassembleEncodings() {
        let cases: [([UInt8], String)] = [
            ([0x90], "NOP"),
            ([0xC3], "RET"),
            ([0xCD, 0x20], "INT 20"),
            ([0xB0, 0x01], "MOV AL,01"),
            ([0xB8, 0x34, 0x12], "MOV AX,1234"),
            ([0xB4, 0x56], "MOV AH,56"),
            ([0xE9, 0xFD, 0x00], "JMP 0200"),
            ([0xE8, 0xFD, 0x00], "CALL 0200"),
            ([0x0F], "DB 0F"),
        ]
        for (raw, expected) in cases {
            let (session, sink) = make([])
            let text = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
            session.execute("E 100 " + text)
            session.execute("U 100 L " + String(raw.count, radix: 16))
            XCTAssertTrue(sink.text.contains(expected), expected + " in " + sink.text)
        }
    }

    func testAssembleThenUnassembleRoundTrip() {
        let (session, sink) = make(["MOV AL,7F", "INT 20", ""])
        session.execute("A 100")
        sink.parts.removeAll()
        session.execute("U 100 L 4")
        XCTAssertTrue(sink.text.contains("MOV AL,7F"), sink.text)
        XCTAssertTrue(sink.text.contains("INT 20"), sink.text)
    }

    func testDisassemblyShowsAddressAndBytes() {
        let (session, sink) = make([])
        session.execute("E 100 B8 34 12")
        session.execute("U 100 L 3")
        XCTAssertTrue(sink.text.hasPrefix("0000:0100  B8 34 12     MOV AX,1234"), sink.text)
    }

    // MARK: N and L

    func testNameAndLoadFromTestShellFile() throws {
        let shell = TestShell()
        let url = shell.root.appendingPathComponent("TEST.COM")
        try Data([0x4D, 0x5A, 0x90, 0x00]).write(to: url)
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell))

        session.execute("N C:\\TEST.COM")
        session.execute("L")
        XCTAssertEqual(session.fileName, "C:\\TEST.COM")
        XCTAssertEqual(session.loadedLength, 4)
        XCTAssertEqual(session.loadedStart, 0x100)
        XCTAssertEqual(session.regs.cx, 4)
        XCTAssertEqual(bytes(session, 0x100, 4), [0x4D, 0x5A, 0x90, 0x00])

        session.execute("D 100 L 4")
        XCTAssertTrue(sink.text.contains("4D 5A 90 00"))
    }

    func testLoadWithoutNameRefuses() {
        let shell = TestShell()
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell))
        session.execute("L")
        XCTAssertTrue(sink.text.contains("No file name"))
        XCTAssertFalse(session.hasImage)
    }

    func testLoadMissingFileRefuses() {
        let shell = TestShell()
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell))
        session.execute("N C:\\NOPE.COM")
        session.execute("L")
        XCTAssertTrue(sink.text.contains("File not found"), sink.text)
        XCTAssertFalse(session.hasImage)
    }

    // MARK: W

    private func writeFile(_ shell: TestShell, _ name: String, _ data: [UInt8]) throws -> URL {
        let url = shell.root.appendingPathComponent(name)
        try Data(data).write(to: url)
        return url
    }

    func testWriteDeclinedLeavesFileByteIdentical() throws {
        let shell = TestShell()
        let original: [UInt8] = [1, 2, 3, 4]
        let url = try writeFile(shell, "TEST.COM", original)
        var warning = ""
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell)) { text in
            warning = text
            return false
        }
        session.execute("N C:\\TEST.COM")
        session.execute("L")
        session.execute("E 100 AA BB CC DD")
        session.execute("W")

        XCTAssertTrue(warning.contains("C:\\TEST.COM"), warning)
        XCTAssertTrue(warning.contains("4 bytes"), warning)
        XCTAssertTrue(sink.text.contains("Write cancelled."))
        XCTAssertEqual(try Data(contentsOf: url), Data(original))
    }

    func testWriteAcceptedWritesExactlyLoadedBytes() throws {
        let shell = TestShell()
        let url = try writeFile(shell, "TEST.COM", [1, 2, 3, 4])
        var asked = false
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell)) { _ in
            asked = true
            return true
        }
        session.execute("N C:\\TEST.COM")
        session.execute("L")
        session.execute("E 100 AA BB CC DD")
        session.execute("W")

        XCTAssertTrue(asked)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, Data([0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(written.count, 4)
        XCTAssertTrue(sink.text.contains("4 bytes written to C:\\TEST.COM"), sink.text)
    }

    func testWriteWithoutLoadedFileRefuses() {
        let shell = TestShell()
        let (session, sink) = make([], files: DebugTool.files(for: shell.shell))
        session.execute("W")
        XCTAssertTrue(sink.text.contains("No file to write"), sink.text)
    }

    func testWriteToReadOnlyFileRefuses() throws {
        let shell = TestShell()
        let original: [UInt8] = [9, 8, 7, 6]
        let url = try writeFile(shell, "LOCKED.COM", original)
        Platform.setAttributes(url.path, readOnly: true)

        let (session, sink) = make([], files: DebugTool.files(for: shell.shell)) { _ in
            XCTFail("a read-only file must never reach the confirmation")
            return true
        }
        session.execute("N C:\\LOCKED.COM")
        session.execute("L")
        session.execute("E 100 00 00 00 00")
        session.execute("W")

        XCTAssertTrue(sink.text.contains("read-only"), sink.text)
        XCTAssertEqual(try Data(contentsOf: url), Data(original))
    }

    func testWriteOutsideMountedDrivesRefuses() throws {
        let shell = TestShell()
        let url = try writeFile(shell, "OK.COM", [1, 2, 3, 4])
        // An unmounted drive is the Windows way to name a path outside the sandbox; on
        // POSIX use a symlink leaving C:.
        let outside: String
        #if os(Windows)
        outside = "Z:\\passwd"
        let refusal = "Invalid drive specification"
        #else
        let link = shell.root.appendingPathComponent("OUT")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(fileURLWithPath: "/etc"))
        outside = "C:\\OUT\\passwd"
        let refusal = "Access denied"
        #endif

        let (session, sink) = make([], files: DebugTool.files(for: shell.shell)) { _ in
            XCTFail("an outside path must never reach the confirmation")
            return true
        }
        session.execute("N C:\\OK.COM")
        session.execute("L")
        session.execute("E 100 00 00 00 00")
        session.execute("N \(outside)")
        session.execute("W")

        XCTAssertTrue(sink.text.contains(refusal), sink.text)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
    }

    // MARK: control flow and errors

    func testDebugUtilityIsRegisteredAndRunsFromAShell() throws {
        XCTAssertNotNil(Shell.utilities["DEBUG"])
        XCTAssertTrue(DebugTool.stubFiles.contains { $0.1 == "DEBUG.EXE" })
        XCTAssertTrue(Shell.helpText("DEBUG").contains("DEBUG is a small assembler"))

        let shell = TestShell()
        try "C98U DEBUG\r\n".write(to: shell.root.appendingPathComponent("DEBUG.EXE"),
                                   atomically: true, encoding: .utf8)
        try Data([0xCD, 0x20]).write(to: shell.root.appendingPathComponent("T.COM"))

        let out = shell.run("DEBUG", input: "N C:\\T.COM\nL\nD 100 L 2\nQ\n")
        XCTAssertTrue(out.contains("0000:0100  CD 20"), out)
    }

    func testQuitLeavesSession() {
        let (session, sink) = make(["Q"])
        session.run()
        XCTAssertFalse(session.running)
        XCTAssertEqual(sink.parts.filter { $0 == "-" }.count, 1)
    }

    func testPromptAfterEveryCommand() {
        let (session, sink) = make(["D 100 L 1", "R", "Q"])
        session.run()
        XCTAssertEqual(sink.parts.filter { $0 == "-" }.count, 3)
    }

    func testRangeParsingErrors() {
        let commands = ["D XYZ", "D 100 0FF", "D 100 L", "D 100 L 0", "U 100 0FF", "E 100 GG"]
        for command in commands {
            let (session, sink) = make([])
            session.execute(command)
            XCTAssertTrue(sink.text.contains("^ Error"), command + " -> " + sink.text)
        }
    }

    func testBlankLineIsHarmless() {
        let (session, sink) = make([])
        XCTAssertTrue(session.execute("   "))
        XCTAssertEqual(sink.text, "")
    }

    func testQuestionMarkShowsHelp() {
        let (session, sink) = make([])
        session.execute("?")
        XCTAssertTrue(sink.text.contains("Commands:"))
        XCTAssertTrue(sink.text.contains("W [address]"))
    }

    // MARK: R

    func testRegistersShowAndChange() {
        let (session, sink) = make(["1234", "00C1"])
        session.execute("R")
        XCTAssertTrue(sink.text.contains("AX=0000"), sink.text)
        XCTAssertTrue(sink.text.contains("IP=0100"), sink.text)
        XCTAssertTrue(sink.text.contains("EI"), sink.text)

        session.execute("R AX")
        XCTAssertEqual(session.regs.ax, 0x1234)

        session.execute("R F")
        XCTAssertEqual(session.regs.flags, 0x00C1)
    }

    func testRegisterChangeRejectsBadHex() {
        let (session, sink) = make(["WXYZ"])
        session.execute("R BX")
        XCTAssertTrue(sink.text.contains("^ Error"))
        XCTAssertEqual(session.regs.bx, 0)
    }

    // MARK: E byte mode

    func testEnterByteByByte() {
        let (session, sink) = make(["11", "22", ""], interactive: true)
        session.execute("E 100")
        XCTAssertEqual(session.memory[0x100], 0x11)
        XCTAssertEqual(session.memory[0x101], 0x22)
        XCTAssertTrue(sink.text.contains("0000:0100  00."), sink.text)
    }

    func testEnterByteByByteNeedsConsole() {
        let (session, sink) = make([])
        session.execute("E 100")
        XCTAssertTrue(sink.text.contains("^ Error"))
    }
}
