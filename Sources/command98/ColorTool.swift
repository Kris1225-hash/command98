import Foundation

/// COLOR.COM. Changes the console attribute and tells ANSI.SYS what it now is. The actual
/// escape goes out through `control`, the same path full-screen tools use, because the
/// command itself is console furniture and must work whether or not DEVICE=ANSI.SYS is in
/// CONFIG.SYS.
enum ColorTool {
    static let utilities: [String: CommandHandler] = ["COLOR": Shell.uColor]
    static let stubFiles: [(String, String, Int)] = [
        ("WINDOWS\\COMMAND", "COLOR.COM", 5357),
        // A driver, not a command: there is no COLOR-style handler for ANSI.SYS. The file
        // exists so CONFIG.SYS has something real to name.
        ("WINDOWS\\COMMAND", "ANSI.SYS", 9029),
    ]
    static let help: [String: String] = [
        "COLOR": """
        Sets the colours used by the console for the rest of the session.

        COLOR [attribute]

          attribute  Two hexadecimal digits, 0-9 and A-F, written as the DOS
                     attribute byte: the first digit picks the background, the
                     second the foreground.

                     0 black       1 blue        2 green       3 cyan
                     4 red         5 magenta     6 brown       7 light grey
                     8 dark grey   9 bright blue A bright green B bright cyan
                     C bright red  D bright magenta E yellow  F white

        COLOR 1F is white on blue. COLOR 07 is light grey on black. Without an
        attribute, COLOR 07; ANSI.SYS is reset at the same time.
        """,
    ]
    static let stubVersion = "1"

    fileprivate static func hexValue(_ c: Character) -> UInt8? {
        guard let v = c.asciiValue else { return nil }
        switch v {
        case 0x30...0x39: return v - 0x30          // 0-9
        case 0x41...0x46: return v - 0x41 + 10     // A-F
        case 0x61...0x66: return v - 0x61 + 10     // a-f
        default: return nil
        }
    }
}

extension Shell {
    func uColor(_ c: Ctx) {
        guard let arg = c.params.first else {
            // No attribute: the boot screen's light grey on black.
            AnsiSys.resetAttribute()
            c.out.control("\u{1B}[0m")
            return
        }

        guard arg.count == 2,
              let bg = ColorTool.hexValue(arg.first!),
              let fg = ColorTool.hexValue(arg.last!) else {
            c.out.line("Invalid parameter - \(arg)")
            errorLevel = 1
            return
        }

        AnsiSys.background = bg
        AnsiSys.foreground = fg
        c.out.control(AnsiSys.sgr(fg: fg, bg: bg))
    }
}
