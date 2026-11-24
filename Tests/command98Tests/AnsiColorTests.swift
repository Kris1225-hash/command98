import Foundation
import XCTest
@testable import command98

final class AnsiColorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AnsiSys.loaded = true
        AnsiSys.reset()
    }

    override func tearDown() {
        AnsiSys.loaded = true
        AnsiSys.reset()
        super.tearDown()
    }

    private func colorShell() -> TestShell {
        let t = TestShell()
        Shell.installStubs(root: t.root)
        t.shell.envSet("PATH", "C:\\WINDOWS\\COMMAND")
        return t
    }

    private func capture(_ body: (Out) -> Void) -> String {
        let file = CaptureFile(prefix: "command98-ansi")
        body(Out(file.fd))
        file.close()
        let text = file.text()
        file.remove()
        return text
    }

    // MARK: - transport

    func testLoadedPassesCompleteSequencesThrough() {
        let s = "\u{1B}[1;31m"
            + "\u{1B}[H" + "\u{1B}[2J" + "\u{1B}[K"
            + "\u{1B}[s" + "\u{1B}[u"
            + "\u{1B}[?25l" + "\u{1B}[?25h"
            + "\u{1B}[?7h" + "\u{1B}[?7l"
        XCTAssertEqual(AnsiSys.encode(s, fd: 1), s)
    }

    func testUnloadedReplacesTheIntroducerWithAnArrow() {
        AnsiSys.loaded = false
        XCTAssertEqual(AnsiSys.encode("\u{1B}[2J", fd: 1), "\u{2190}[2J")
        XCTAssertEqual(AnsiSys.encode("plain", fd: 1), "plain")
        XCTAssertEqual(AnsiSys.encode("a\u{1B}b", fd: 1), "a\u{2190}b")
    }

    func testControlOutputBypassesTheDriver() {
        AnsiSys.loaded = false
        let written = capture { $0.control("\u{1B}[2J") }
        XCTAssertEqual(written, "\u{1B}[2J")
    }

    // MARK: - SGR state
    //
    // ANSI numbers colours RGB-first, DOS numbers them BGR-first. The driver records the
    // DOS attribute: ANSI 31 (red) is DOS 4 (red), ANSI 34 (blue) is DOS 1 (blue), and the
    // 90-97 / 100-107 ranges are the same eight colours plus the bright bit. SGR 1 is the
    // DOS bold/bright bit, so 1;31 is DOS 12 (bright red).

    func testSGRTracksForegroundAndBackground() {
        _ = AnsiSys.encode("\u{1B}[31m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 4)

        _ = AnsiSys.encode("\u{1B}[34m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 1)

        _ = AnsiSys.encode("\u{1B}[44m", fd: 1)
        XCTAssertEqual(AnsiSys.background, 1)

        _ = AnsiSys.encode("\u{1B}[1;31;44m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 12)
        XCTAssertEqual(AnsiSys.background, 1)

        _ = AnsiSys.encode("\u{1B}[0m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
    }

    func testSGRBrightRangesAndDefaultColours() {
        _ = AnsiSys.encode("\u{1B}[91m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 12)

        _ = AnsiSys.encode("\u{1B}[104m", fd: 1)
        XCTAssertEqual(AnsiSys.background, 9)

        _ = AnsiSys.encode("\u{1B}[39;49m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
    }

    func testBoldIsClearedAgain() {
        _ = AnsiSys.encode("\u{1B}[1;31m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 12)
        _ = AnsiSys.encode("\u{1B}[22m", fd: 1)
        XCTAssertEqual(AnsiSys.foreground, 4)
    }

    func testSGRHelperRoundTripsDOSAttributes() {
        for fg in UInt8(0)...15 {
            for bg in UInt8(0)...15 {
                XCTAssertEqual(AnsiSys.sgr(fg: fg, bg: bg), Screen.sgr(fg: fg, bg: bg))
            }
        }
        XCTAssertEqual(AnsiSys.sgr(fg: 15, bg: 1), "\u{1B}[97;44m")
    }

    // MARK: - split writes

    func testSplitSGRIsBufferedAcrossCalls() {
        XCTAssertEqual(AnsiSys.encode("A\u{1B}[1;3", fd: 1), "A")
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.encode("1mB", fd: 1), "\u{1B}[1;31mB")
        XCTAssertEqual(AnsiSys.foreground, 12)
    }

    func testSplitRightAfterIntroducer() {
        XCTAssertEqual(AnsiSys.encode("hi\u{1B}", fd: 1), "hi")
        XCTAssertEqual(AnsiSys.encode("[32m", fd: 1), "\u{1B}[32m")
        XCTAssertEqual(AnsiSys.foreground, 2)
    }

    func testFlushReturnsAnUnfinishedSequence() {
        XCTAssertEqual(AnsiSys.encode("X\u{1B}[", fd: 1), "X")
        XCTAssertEqual(AnsiSys.flush(), "\u{1B}[")
        XCTAssertEqual(AnsiSys.encode("Y", fd: 1), "Y")
        XCTAssertEqual(AnsiSys.flush(), "")
    }

    func testUnknownCSIIsNotCorrupted() {
        XCTAssertEqual(AnsiSys.encode("\u{1B}[?1234z", fd: 1), "\u{1B}[?1234z")
        XCTAssertEqual(AnsiSys.encode("\u{1B}[5;99m", fd: 1), "\u{1B}[5;99m")
        XCTAssertEqual(AnsiSys.encode("\u{1B}[>0c", fd: 1), "\u{1B}[>0c")
        XCTAssertEqual(AnsiSys.encode("\u{1B}(B", fd: 1), "\u{1B}(B")
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
    }

    // MARK: - COLOR

    func testColorWhiteOnBlue() {
        let t = colorShell()
        let out = t.run("COLOR 1F")
        XCTAssertEqual(out, "\u{1B}[97;44m")
        XCTAssertEqual(AnsiSys.foreground, 15)
        XCTAssertEqual(AnsiSys.background, 1)
        XCTAssertEqual(t.shell.errorLevel, 0)
    }

    func testColorLightGreyOnBlack() {
        let t = colorShell()
        let out = t.run("COLOR 07")
        XCTAssertEqual(out, "\u{1B}[37;40m")
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
        XCTAssertEqual(t.shell.errorLevel, 0)
    }

    func testColorLightGreenOnBlack() {
        let t = colorShell()
        let out = t.run("COLOR 0A")
        XCTAssertEqual(out, "\u{1B}[92;40m")
        XCTAssertEqual(AnsiSys.foreground, 10)
        XCTAssertEqual(AnsiSys.background, 0)
    }

    func testColorAcceptsLowercaseHex() {
        let t = colorShell()
        XCTAssertEqual(t.run("COLOR 1f"), "\u{1B}[97;44m")
        XCTAssertEqual(AnsiSys.foreground, 15)
        XCTAssertEqual(AnsiSys.background, 1)
    }

    func testColorWithoutArgumentsResets() {
        let t = colorShell()
        _ = t.run("COLOR 1F")
        let out = t.run("COLOR")
        XCTAssertEqual(out, "\u{1B}[0m")
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
        XCTAssertEqual(t.shell.errorLevel, 0)
    }

    func testInvalidColorParameter() {
        let t = colorShell()
        let out = t.run("COLOR ZZ")
        XCTAssertEqual(out, "Invalid parameter - ZZ\n")
        XCTAssertEqual(t.shell.errorLevel, 1)
        XCTAssertEqual(AnsiSys.foreground, 7)
        XCTAssertEqual(AnsiSys.background, 0)
    }

    func testInvalidColorParameterShapes() {
        for bad in ["1G", "G1", "1", "123", "-1"] {
            let t = colorShell()
            XCTAssertEqual(t.run("COLOR \(bad)"), "Invalid parameter - \(bad)\n")
            XCTAssertEqual(t.shell.errorLevel, 1)
        }
    }

    // MARK: - prompt integration

    func testPromptEscapeReachesTheRenderer() {
        let t = TestShell()
        t.shell.envSet("PROMPT", "$e[1;31m$p$g")
        let prompt = t.shell.renderPrompt()
        XCTAssertTrue(prompt.hasPrefix("\u{1B}[1;31m"), "prompt was \(prompt)")
        XCTAssertTrue(prompt.contains(t.shell.currentPath()))
        XCTAssertTrue(prompt.hasSuffix(">"))
    }

    func testPromptEscapeBecomesAnArrowWithoutTheDriver() {
        let t = TestShell()
        t.shell.envSet("PROMPT", "$e[1;31m$p$g")
        AnsiSys.loaded = false
        let written = capture { $0.write(t.shell.renderPrompt()) }
        XCTAssertTrue(written.hasPrefix("\u{2190}[1;31m"), "written was \(written)")
        XCTAssertFalse(written.contains("\u{1B}"))
    }

    // MARK: - registration

    func testRegistrationAndStubs() {
        XCTAssertNotNil(ColorTool.utilities["COLOR"])
        XCTAssertEqual(ColorTool.stubVersion, "1")
        XCTAssertNotNil(ColorTool.help["COLOR"])

        XCTAssertTrue(ColorTool.stubFiles.contains {
            $0.0 == "WINDOWS\\COMMAND" && $0.1 == "COLOR.COM" && $0.2 > 0
        })
        XCTAssertTrue(ColorTool.stubFiles.contains {
            $0.0 == "WINDOWS\\COMMAND" && $0.1 == "ANSI.SYS" && $0.2 > 0
        })
        XCTAssertTrue(Shell.stubFiles.contains { $0.1 == "ANSI.SYS" })
        XCTAssertNil(Shell.utilities["ANSI"])
    }
}
