import Foundation
import Darwin

/// The screen COMMAND98 shows when it is asked to start Windows and the startup file is
/// not there. No window frame: in 1998 the whole page was the error.
enum BlueScreen {
    /// Internal command: always shows the page, without needing a WIN.COM stub. The shell
    /// merges this table into its own dispatch.
    static let commands: [String: CommandHandler] = ["BSOD": bsodHandler]
    static let stubFiles: [(String, String, Int)] = []
    static let help: [String: String] = [
        "BSOD": """
        Shows the blue screen. No real fault is required.
        """,
    ]
    static let stubVersion = "1"

    static let background: UInt8 = 1
    static let text: UInt8 = 7
    static let bright: UInt8 = 15
    static let pressKeyText = "Press any key to return to the command prompt."

    /// Hidden BSOD command: the page, on demand, independent of WIN.COM.
    static func bsodHandler(_ shell: Shell) -> (Ctx) -> Void {
        return { ctx in
            show(ctx.out, reason: "WIN.COM")
        }
    }

    /// The whole page: blue background, light grey text, a white heading.
    static func makeScreen(reason: String = "") -> Screen {
        let screen = Screen(ch: " ", fg: text, bg: background)
        for line in layout(reason: reason) {
            screen.write(4, line.row, line.text, fg: line.fg, bg: background)
        }
        return screen
    }

    /// Rows and wording live in one place so the tests can check that every line fits.
    static func layout(reason: String = "") -> [(row: Int, text: String, fg: UInt8)] {
        let cause = reason.isEmpty
            ? "A required Windows startup file could not be loaded from C:\\WINDOWS."
            : "The file \(reason) could not be loaded from C:\\WINDOWS."
        return [
            (2, "COMMAND98", bright),
            (4, "A fault has stopped the command interpreter.", bright),
            (6, "The system was ready to hand the session over to Windows, but the", text),
            (7, "program it needed was not available. Control cannot pass to the", text),
            (8, "desktop, so the command prompt has stopped here instead.", text),
            (10, cause, text),
            (12, "The disk has not been written to. Any programs that were running", text),
            (13, "have lost their work; restart the computer to continue.", text),
            (15, "*** STOP: 0xC0DE0001 (0x00000000, 0x00000000, 0x00000000, 0x00000000)", text),
            (17, "Faulting component: WINDOWS\\WIN.COM", text),
            (18, "Cause: STARTUP_COMPONENT_MISSING", text),
            (20, "If this screen appears again, check that WIN.COM is present in", text),
            (21, "C:\\WINDOWS and can be read.", text),
            (23, pressKeyText, text),
        ]
    }

    /// The page as plain lines, for a log rather than a terminal. The interactive prompt
    /// is dropped because a redirected run never waits for a key.
    static func plainText(reason: String = "") -> [String] {
        layout(reason: reason)
            .map(\.text)
            .filter { !$0.isEmpty && $0 != pressKeyText }
    }

    /// Draws the page and, on a terminal, waits for one key. A redirected run (either end)
    /// gets the plain text instead: no escape codes and no invisible key wait.
    static func show(_ out: Out, reason: String = "") {
        guard Console.isFullScreen(out) else {
            for line in plainText(reason: reason) { out.line(line) }
            return
        }
        let screen = makeScreen(reason: reason)
        Screen.begin(out)
        defer { Screen.end(out) }
        screen.render(to: out)
        Console.withRaw { _ = KeyReader.read(fd: 0) }
    }
}

extension Console {
    /// Full-screen tools read keys and paint a page, so both of their ends must be a real
    /// terminal. Checking only stdin misses `QBASIC > OUT.TXT`, which would otherwise paint
    /// the page into the file and swallow the key wait.
    static func isFullScreen(_ out: Out, inputIsTTY: Bool = Console.isTTY) -> Bool {
        inputIsTTY && isatty(out.fd) == 1
    }
}
