import Foundation

/// ANSI.SYS. Every host terminal we run on already speaks the same escape language the
/// 1998 driver did, so with the driver loaded the sequence stream is simply forwarded.
/// The driver still has to look at SGR sequences, because COLOR and the tests want to know
/// which attribute is current, and it has to hold on to a sequence that a write chopped in
/// half so the second write can finish it.
enum AnsiSys {
    /// The console these platforms give us is an ANSI terminal. CONFIG.SYS can ask for the
    /// driver, and the prompt is expected to colour itself without any setup, so start on.
    static var loaded = true
    static var foreground: UInt8 = 7
    static var background: UInt8 = 0

    /// The tail of an escape sequence that has not arrived yet. Kept across write calls.
    private static var pending = ""

    /// DOS set the bright foreground bit when a bold SGR arrived, so remember it.
    private static var bold = false

    private static let esc: Character = "\u{1B}"
    private static let arrow: Character = "\u{2190}"

    /// ANSI numbers its colours red/green/yellow/blue; DOS numbers them blue/green/cyan/red.
    /// This is the ANSI 30-37 order translated into the DOS attribute order that Screen,
    /// ScreenCell and the rest of the shell already use:
    ///   ANSI 30 black->0, 31 red->4, 32 green->2, 33 yellow->6,
    ///   ANSI 34 blue->1, 35 magenta->5, 36 cyan->3, 37 white->7.
    /// The 90-97 range is the same eight colours with the bright bit (DOS +8).
    private static let ansiToDos: [UInt8] = [0, 4, 2, 6, 1, 5, 3, 7]

    static func load() { loaded = true }

    /// Back to the attribute a freshly booted screen has: light grey on black.
    static func reset() {
        resetAttribute()
        pending = ""
    }

    /// The attribute half of reset, for callers that must not disturb a half-written
    /// escape sequence sitting in the buffer.
    static func resetAttribute() {
        foreground = 7
        background = 0
        bold = false
    }

    /// ANSI SGR for a DOS attribute pair. Same tables Screen uses, so a COLOR and a
    /// full-screen repaint cannot disagree about what "white on blue" means.
    static func sgr(fg: UInt8, bg: UInt8) -> String {
        let f = Screen.fgCodes[Int(fg & 0x0F)]
        let b = Screen.bgCodes[Int(bg & 0x0F)]
        return "\u{1B}[\(f);\(b)m"
    }

    /// Hand back (and forget) a sequence that was left unfinished. The shell never calls
    /// this on its own; a caller uses it only when it knows no more output is coming.
    static func flush() -> String {
        let tail = pending
        pending = ""
        guard !tail.isEmpty, !loaded else { return tail }
        return tail.replacingOccurrences(of: String(esc), with: String(arrow))
    }

    /// Called by Out.write for every normal write. `control` output skips this.
    static func encode(_ s: String, fd: Int32) -> String {
        // Finish whatever the previous write had to abandon.
        let input = pending + s
        pending = ""

        guard loaded else {
            // Without the driver DOS echoed the escape introducer as a left arrow and the
            // rest of the sequence arrived as ordinary characters.
            return input.replacingOccurrences(of: String(esc), with: String(arrow))
        }

        let chars = Array(input)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            guard ch == esc else {
                out.append(ch)
                i += 1
                continue
            }

            // A lone introducer at the end of a write is the start of the next one.
            guard i + 1 < chars.count else {
                pending = String(chars[i...])
                break
            }

            if chars[i + 1] == "[" {
                var j = i + 2
                while j < chars.count, isParameter(chars[j]) { j += 1 }
                while j < chars.count, isIntermediate(chars[j]) { j += 1 }
                guard j < chars.count else {
                    // ESC [ 1 ; 3 with no final byte yet.
                    pending = String(chars[i...])
                    break
                }
                guard isFinal(chars[j]) else {
                    // Malformed: keep the introducer, let the rest be normal text.
                    out.append(ch)
                    i += 1
                    continue
                }
                let final = chars[j]
                if final == "m" {
                    applySGR(String(chars[(i + 2)..<j]))
                }
                // Every complete CSI goes through untouched, including finals we do not
                // recognise: cursor motion, erase, save/restore, private modes and all.
                out.append(contentsOf: chars[i...j])
                i = j + 1
                continue
            }

            // Two-character escape (charset selection, keypad modes, and so on).
            out.append(ch)
            out.append(chars[i + 1])
            i += 2
        }
        return out
    }

    // MARK: - CSI

    private static func isParameter(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return v >= 0x30 && v <= 0x3F
    }

    private static func isIntermediate(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return v >= 0x20 && v <= 0x2F
    }

    private static func isFinal(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return v >= 0x40 && v <= 0x7E
    }

    /// SGR parameters. Empty fields mean 0. Unknown values are ignored but the sequence
    /// itself is still passed through by encode.
    private static func applySGR(_ params: String) {
        let fields = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let parts = fields.isEmpty ? ["0"] : fields
        var i = 0
        while i < parts.count {
            let raw = parts[i]
            i += 1
            let n: Int
            if raw.isEmpty {
                n = 0
            } else if let v = Int(raw) {
                n = v
            } else {
                continue // colon sub-parameters and other extensions
            }
            switch n {
            case 0:
                foreground = 7
                background = 0
                bold = false
            case 1:
                bold = true
                if foreground < 8 { foreground += 8 }
            case 22:
                if bold {
                    bold = false
                    if foreground >= 8 { foreground -= 8 }
                }
            case 30...37:
                setForeground(Int(n - 30))
            case 39:
                foreground = bold ? 15 : 7
            case 40...47:
                background = ansiToDos[Int(n - 40)]
            case 49:
                background = 0
            case 90...97:
                foreground = 8 + ansiToDos[Int(n - 90)]
            case 100...107:
                background = 8 + ansiToDos[Int(n - 100)]
            default:
                continue
            }
        }
    }

    private static func setForeground(_ index: Int) {
        let base = ansiToDos[index]
        foreground = bold ? base + 8 : base
    }
}
