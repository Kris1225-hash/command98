import XCTest
@testable import command98

/// Percent handling in COMMAND.COM 4.10.2222. At the prompt an unpaired `%` is literal;
/// in a batch file it is swallowed. A closed `%NAME%` is substituted in both, and an
/// undefined name becomes nothing (verified against the real binary at the prompt:
/// `echo %NOSUCHVAR%` turns into a bare `echo`).
final class EchoQuirkTests: XCTestCase {
    func testPromptKeepsLonePercent() {
        let t = TestShell()
        XCTAssertEqual(t.run("echo 50% off", typed: true), "50% off\n")
        XCTAssertEqual(t.run("echo 100%", typed: true), "100%\n")
    }

    func testBatchEatsLonePercent() {
        let t = TestShell()
        t.write("T.BAT", "@ECHO OFF\r\necho 50% off\r\necho 100%\r\n")
        XCTAssertEqual(t.run("C:\\T.BAT"), "50 off\n100\n")
    }

    func testDoublePercentBecomesOnePercentInBatch() {
        let t = TestShell()
        t.write("T.BAT", "@ECHO OFF\r\necho %%\r\n")
        XCTAssertEqual(t.run("C:\\T.BAT"), "%\n")
    }

    func testDoublePercentAtPromptBecomesOnePercent() {
        let t = TestShell()
        XCTAssertEqual(t.run("echo %%", typed: true), "%\n")
    }

    func testPathVariableExpandsAtPromptAndInBatch() {
        let t = TestShell()
        t.shell.envSet("PATH", "C:\\BIN")
        XCTAssertEqual(t.run("echo %PATH%", typed: true), "C:\\BIN\n")
        t.write("T.BAT", "@ECHO OFF\r\necho %PATH%\r\n")
        XCTAssertEqual(t.run("C:\\T.BAT"), "C:\\BIN\n")
    }

    func testUndefinedVariableIsBlankedInBothModes() {
        let t = TestShell()
        // The prompt leaves a bare `%` alone, but `%NOSUCHVAR%` has a partner, so it
        // vanishes and ECHO sees no argument. In a batch file the same line runs with
        // ECHO OFF, hence the different status line.
        XCTAssertEqual(t.run("echo %NOSUCHVAR%", typed: true), "ECHO is on\n")
        t.write("T.BAT", "@ECHO OFF\r\necho %NOSUCHVAR%\r\n")
        XCTAssertEqual(t.run("C:\\T.BAT"), "ECHO is off\n")
    }

    func testForVariableSurvivesAtPrompt() {
        let t = TestShell()
        XCTAssertEqual(t.shell.expandTyped("for %f in (*) do echo %f"),
                       "for %f in (*) do echo %f")
    }
}
