import Foundation

/// The screen COMMAND98 shows when it is asked to start Windows and the startup file is
/// not there. No window frame: in 1998 the whole page was the error.
enum BlueScreen {
    static let utilities: [String: CommandHandler] = ["WIN": winHandler]
    /// Internal command: always shows the page, without needing a WIN.COM stub. The shell
    /// merges this table into its own dispatch.
    static let commands: [String: CommandHandler] = ["BSOD": bsodHandler]
    static let stubFiles: [(String, String, Int)] = []
    static let help: [String: String] = [
        "WIN": """
        Starts Windows. Here, that means Explorer.

        WIN.COM is expected in C:\\WINDOWS. If it is missing, WIN stops at a blue
        screen instead.
        """,
    ]
    static let stubVersion = "1"

    static let winComPath = "C:\\WINDOWS\\WIN.COM"
    static let background: UInt8 = 1
    static let text: UInt8 = 7
    static let bright: UInt8 = 15

    /// WIN is reached through the WIN.COM stub when that file exists. The handler checks
    /// the real file too, so a WIN.COM that has been removed lands on the blue screen.
    static func winHandler(_ shell: Shell) -> (Ctx) -> Void {
        return { ctx in
            if winComExists(shell) {
                shell.uWin(ctx)
            } else {
                show(ctx.out, reason: "WIN.COM")
            }
        }
    }

    /// Hidden BSOD command: the same page, on demand, independent of WIN.COM.
    static func bsodHandler(_ shell: Shell) -> (Ctx) -> Void {
        return { ctx in
            show(ctx.out, reason: "WIN.COM")
        }
    }

    /// True when C:\WINDOWS\WIN.COM resolves and is a regular file.
    static func winComExists(_ shell: Shell) -> Bool {
        guard let r = try? shell.drives.resolve(winComPath), r.exists else { return false }
        var isDirectory: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: shell.drives.url(r).path, isDirectory: &isDirectory)
        return ok && !isDirectory.boolValue
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
            (23, "Press any key to return to the command prompt.", text),
        ]
    }

    /// Draws the page and, on a terminal, waits for one key. Redirected input is not
    /// waited on: the page is written and the caller gets control back.
    static func show(_ out: Out, reason: String = "") {
        let screen = makeScreen(reason: reason)
        guard Console.isTTY else {
            screen.render(to: out)
            return
        }
        Screen.begin(out)
        defer { Screen.end(out) }
        screen.render(to: out)
        Console.withRaw { _ = KeyReader.read(fd: 0) }
    }
}
