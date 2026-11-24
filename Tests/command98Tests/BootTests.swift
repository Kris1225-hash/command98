import Foundation
import XCTest
@testable import command98

final class BootTests: XCTestCase {
    // MARK: helpers

    private func withRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("command98-boot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func parsed(_ msdos: String?) -> BootOptions {
        var result = BootOptions()
        withRoot { root in
            if let msdos {
                try? msdos.write(to: root.appendingPathComponent("MSDOS.SYS"),
                                 atomically: true, encoding: .utf8)
            }
            result = Boot.options(root: root)
        }
        return result
    }

    private func contents(of screen: Screen) -> String {
        (0..<screen.height).map { y in
            String((0..<screen.width).map { screen[$0, y].ch })
        }.joined(separator: "\n")
    }

    private func capture(_ body: (Out) -> Void) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("command98-boot-out-\(UUID().uuidString)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        body(Out(fd))
        close(fd)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: MSDOS.SYS

    func testMissingFileMeansSilentBoot() {
        XCTAssertEqual(parsed(nil), BootOptions())
        XCTAssertFalse(parsed(nil).bootGUI)
    }

    func testOptionsSectionDrivesThePlan() {
        let o = parsed("""
        [Paths]
        WinDir=C:\\WINDOWS
        BootGUI=1

        [Options]
        BootGUI=1
        BootMenu=1
        BootDelay=8

        """)
        XCTAssertTrue(o.bootGUI)
        XCTAssertTrue(o.bootMenu)
        XCTAssertEqual(o.bootDelay, 8)
    }

    func testOnlyTheOptionsSectionCounts() {
        XCTAssertFalse(parsed("[Paths]\r\nBootGUI=1\r\n").bootGUI)
    }

    func testCaseSpacingCommentsAndCRLF() {
        let o = parsed("; BootGUI=1 outside the section is still a comment\r\n"
                       + "[ options ]\r\n"
                       + "  bootgui = 1   ; ask for the graphical boot\r\n"
                       + "BootMenu = 0\r\n"
                       + "BootDelay = 3\r\n")
        XCTAssertTrue(o.bootGUI)
        XCTAssertFalse(o.bootMenu)
        XCTAssertEqual(o.bootDelay, 3)
    }

    func testBootGuiZeroIsSilent() {
        let o = parsed("[Options]\r\nBootGUI=0\r\nBootMenu=0\r\nBootDelay=0\r\n")
        XCTAssertFalse(o.bootGUI)
        XCTAssertFalse(o.bootMenu)
        XCTAssertEqual(o.bootDelay, 0)
    }

    func testControlZEndsTheFile() {
        let o = parsed("[Options]\r\nBootGUI=1\r\n\u{1A}\r\nBootGUI=0\r\n")
        XCTAssertTrue(o.bootGUI)
    }

    func testBareCarriageReturnsAreLineEndingsToo() {
        let o = parsed("[Options]\rBootGUI = 1\rBootDelay = 5\r")
        XCTAssertTrue(o.bootGUI)
        XCTAssertEqual(o.bootDelay, 5)
    }

    // MARK: plan

    func testDefaultPlanDoesNotSplash() {
        let t = TestShell()
        let plan = Boot.plan(for: t.shell)
        XCTAssertFalse(plan.splash)
        XCTAssertFalse(plan.winComPresent)
    }

    func testEnabledPlanWithWinComContinuesToPrompt() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        t.write("WINDOWS/WIN.COM", "tribute")
        let plan = Boot.plan(for: t.shell)
        XCTAssertTrue(plan.splash)
        XCTAssertTrue(plan.winComPresent)
    }

    func testDirectoryNamedWinComCountsAsMissing() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        let win = t.root.appendingPathComponent("WINDOWS/WIN.COM", isDirectory: true)
        try? FileManager.default.createDirectory(at: win, withIntermediateDirectories: true)
        XCTAssertTrue(isDir(win), "the fixture must be a directory")

        let plan = Boot.plan(for: t.shell)
        XCTAssertTrue(plan.splash)
        XCTAssertFalse(plan.winComPresent, "a directory is not WIN.COM")
    }

    func testEnabledPlanWithoutWinComReportsFailure() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        let plan = Boot.plan(for: t.shell)
        XCTAssertTrue(plan.splash)
        XCTAssertFalse(plan.winComPresent)
    }

    // MARK: rendering

    func testRenderShowsCentredPhraseOnAnEightyByTwentyFivePage() {
        let screen = Screen()
        Boot.render(plan: BootPlan(splash: true, winComPresent: true), to: screen, tick: 4)
        XCTAssertEqual(screen.width, 80)
        XCTAssertEqual(screen.height, 25)
        let page = contents(of: screen)
        XCTAssertTrue(page.contains(Boot.splashText))
        let phraseRow = page.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains(Boot.splashText) }
        XCTAssertEqual(phraseRow?.trimmingCharacters(in: .whitespaces), Boot.splashText)
    }

    func testEveryTickStaysOnThePage() {
        for tick in [-100, -1, 0, 1, 7, Boot.splashFrames, 999, Int.max] {
            let screen = Screen()
            Boot.render(plan: BootPlan(splash: true, winComPresent: true),
                        to: screen, tick: tick)
            XCTAssertTrue(contents(of: screen).contains(Boot.splashText),
                          "tick \(tick) lost the phrase")
        }
    }

    func testRenderingOnATinyPageIsSafe() {
        let screen = Screen(width: 8, height: 3)
        Boot.render(plan: BootPlan(splash: true, winComPresent: true), to: screen, tick: 5)
        XCTAssertEqual(screen.cells.count, 24)
    }

    func testDisabledPlanDrawsNoSplash() {
        let screen = Screen(ch: "X", fg: 15, bg: 4)
        Boot.render(plan: BootPlan(splash: false, winComPresent: true), to: screen)
        XCTAssertFalse(contents(of: screen).contains(Boot.splashText))
        XCTAssertEqual(screen[0, 0].ch, " ")
        XCTAssertEqual(screen[0, 0].bg, 0)
    }

    // MARK: run

    func testRunIsSilentWhenNotConfigured() {
        let t = TestShell()
        let output = capture { Boot.run(t.shell, out: $0, interactive: false, frameDelay: {}) }
        XCTAssertEqual(output, "")
    }

    func testRunNonTTYPrintsPhraseAndMissingWinComText() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        let output = capture { Boot.run(t.shell, out: $0, interactive: false, frameDelay: {}) }
        XCTAssertTrue(output.contains("Starting Windows 98...\n"), output)
        XCTAssertTrue(output.contains("WIN.COM is missing, so Windows cannot continue loading.\n"), output)
        XCTAssertTrue(output.contains("Press any key to return to the command prompt.\n"), output)
    }

    func testRunNonTTYWithWinComJustPrintsPhrase() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        t.write("WINDOWS/WIN.COM", "tribute")
        let output = capture { Boot.run(t.shell, out: $0, interactive: false, frameDelay: {}) }
        XCTAssertTrue(output.contains("Starting Windows 98...\n"), output)
        XCTAssertFalse(output.contains("WIN.COM is missing"), output)
        XCTAssertFalse(output.contains("Press any key"), output)
    }

    func testInteractiveRunRefusesToAnimateIntoARedirectedLog() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        t.write("WINDOWS/WIN.COM", "tribute")
        var frames = 0
        var keys = 0
        let output = capture {
            Boot.run(t.shell, out: $0, interactive: true,
                     frameDelay: { frames += 1 }, key: { keys += 1; return 13 })
        }
        XCTAssertEqual(frames, 0, "a redirected splash never animates")
        XCTAssertEqual(keys, 0, "a redirected splash never waits for a key")
        XCTAssertFalse(output.contains("\u{1B}[?1049h"), "no alternate screen in a log")
        XCTAssertTrue(output.contains(Boot.splashText + "\n"), output)
        XCTAssertFalse(output.contains("WIN.COM is missing"), output)
    }

    func testInteractiveRunAnimatesOnlyWhenTheOutputIsATerminal() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        var frames = 0
        let output = capture {
            Boot.run(t.shell, out: $0, interactive: true, outputIsTTY: true,
                     frameDelay: { frames += 1 }, key: { 13 })
        }
        XCTAssertEqual(frames, Boot.splashFrames)
        XCTAssertTrue(output.contains("\u{1B}[?1049h"), "no alternate screen")
        XCTAssertTrue(output.contains("\u{1B}[?1049l"), "alternate screen not restored")
        XCTAssertTrue(output.contains("WIN.COM is missing, so Windows cannot continue loading.\n"))
        XCTAssertTrue(output.contains("Press any key to return to the command prompt.\n"))
    }

    func testRedirectedSplashDoesNotWaitForAMissingWinComKey() {
        let t = TestShell()
        t.write("MSDOS.SYS", "[Options]\r\nBootGUI=1\r\n")
        var keys = 0
        let output = capture {
            Boot.run(t.shell, out: $0, interactive: true,
                     frameDelay: {}, key: { keys += 1; return 13 })
        }
        XCTAssertEqual(keys, 0)
        XCTAssertTrue(output.contains("WIN.COM is missing, so Windows cannot continue loading.\n"))
        XCTAssertTrue(output.contains("Press any key to return to the command prompt.\n"))
        XCTAssertFalse(output.contains("\u{1B}"), "plain text only")
    }
}
