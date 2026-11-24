import Foundation

/// One character cell, with the 16-colour DOS attribute split into fg and bg.
struct ScreenCell: Equatable {
    var ch: Character = " "
    var fg: UInt8 = 7
    var bg: UInt8 = 0
    var blink = false
}

/// The 80x25 text page that every full-screen 1998 program owned. Nothing here knows
/// about DOS functions or file systems; it is just cells and the escape sequences that
/// paint them. Tests compare cells; the real terminal gets one repaint per frame.
final class Screen {
    let width: Int
    let height: Int
    private(set) var cells: [ScreenCell]

    init(width: Int = 80, height: Int = 25, ch: Character = " ", fg: UInt8 = 7, bg: UInt8 = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        let cell = ScreenCell(ch: Screen.sanitize(ch), fg: fg, bg: bg)
        self.cells = Array(repeating: cell, count: self.width * self.height)
    }

    subscript(x: Int, y: Int) -> ScreenCell {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return ScreenCell() }
            return cells[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            var cell = newValue
            cell.ch = Screen.sanitize(cell.ch)
            cells[y * width + x] = cell
        }
    }

    func clear(ch: Character = " ", fg: UInt8 = 7, bg: UInt8 = 0) {
        let cell = ScreenCell(ch: Screen.sanitize(ch), fg: fg, bg: bg)
        cells = Array(repeating: cell, count: width * height)
    }

    /// A snapshot for animation frames and tests.
    func copy() -> Screen {
        let s = Screen(width: width, height: height)
        s.cells = cells
        return s
    }

    /// A screen cell holds one visible glyph. Raw file bytes reach `put`/`write`, so
    /// C0 controls, DEL and C1 controls must never survive into the page: a repaint
    /// would otherwise hand the terminal an escape sequence or a tab that breaks the
    /// fixed 80-column layout. Tabs are layout, not glyphs, and are rejected here;
    /// `write` expands them at eight-column stops.
    static func sanitize(_ ch: Character) -> Character {
        if ch == "\t" { return " " }
        for scalar in ch.unicodeScalars where scalar.properties.generalCategory == .control {
            return "\u{00B7}" // middle dot: visible, printable, and not a terminal control
        }
        return ch
    }

    func put(_ x: Int, _ y: Int, _ ch: Character, fg: UInt8 = 7, bg: UInt8 = 0, blink: Bool = false) {
        self[x, y] = ScreenCell(ch: ch, fg: fg, bg: bg, blink: blink)
    }

    /// Writes a string at x,y. A newline moves to the start of the next row and a tab
    /// advances to the next eight-column stop; the cursor never leaves the page.
    /// Returns the column after the last character.
    @discardableResult
    func write(_ x: Int, _ y: Int, _ s: String, fg: UInt8 = 7, bg: UInt8 = 0) -> Int {
        var cx = x, cy = y
        for ch in s {
            // Swift treats CR-LF as one grapheme, so check for it before the lone CR.
            if ch == "\n" || ch == "\r\n" {
                cx = x
                cy += 1
                continue
            }
            if ch == "\r" { cx = x; continue }
            if ch == "\t" {
                cx = min(((cx / 8) + 1) * 8, width)
                continue
            }
            put(cx, cy, ch, fg: fg, bg: bg)
            cx = min(cx + 1, width)
        }
        return cx
    }

    func fill(x: Int, y: Int, width w: Int, height h: Int,
              ch: Character = " ", fg: UInt8 = 7, bg: UInt8 = 0) {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                put(xx, yy, ch, fg: fg, bg: bg)
            }
        }
    }

    /// The classic double-line dialogue frame (or a single-line one).
    func box(x: Int, y: Int, width w: Int, height h: Int,
             fg: UInt8 = 7, bg: UInt8 = 0, double: Bool = true) {
        guard w >= 2, h >= 2 else { return }
        let glyph: (Character) -> Character = { c in
            guard double else { return c }
            switch c {
            case "\u{250C}": return "\u{2554}" // corner
            case "\u{2510}": return "\u{2557}"
            case "\u{2514}": return "\u{255A}"
            case "\u{2518}": return "\u{255D}"
            case "\u{2500}": return "\u{2550}"
            case "\u{2502}": return "\u{2551}"
            default: return c
            }
        }
        for xx in x..<(x + w) {
            put(xx, y, glyph(xx == x ? "\u{250C}" : xx == x + w - 1 ? "\u{2510}" : "\u{2500}"), fg: fg, bg: bg)
            put(xx, y + h - 1, glyph(xx == x ? "\u{2514}" : xx == x + w - 1 ? "\u{2518}" : "\u{2500}"), fg: fg, bg: bg)
        }
        for yy in (y + 1)..<(y + h - 1) {
            put(x, yy, glyph("\u{2502}"), fg: fg, bg: bg)
            put(x + w - 1, yy, glyph("\u{2502}"), fg: fg, bg: bg)
        }
        fill(x: x + 1, y: y + 1, width: w - 2, height: h - 2, fg: fg, bg: bg)
    }

    func center(_ y: Int, _ s: String, fg: UInt8 = 7, bg: UInt8 = 0) {
        let x = max(0, (width - s.count) / 2)
        write(x, y, s, fg: fg, bg: bg)
    }

    /// DOS colour number -> the terminal's nearest SGR foreground/background code.
    static let fgCodes: [Int] = [30, 34, 32, 36, 31, 35, 33, 37, 90, 94, 92, 96, 91, 95, 93, 97]
    static let bgCodes: [Int] = [40, 44, 42, 46, 41, 45, 43, 47, 100, 104, 102, 106, 101, 105, 103, 107]

    static func sgr(fg: UInt8, bg: UInt8, blink: Bool = false) -> String {
        let f = fgCodes[Int(fg & 0x0F)]
        let b = bgCodes[Int(bg & 0x0F)]
        return "\u{1B}[\(f);\(b)\(blink ? ";5" : "")m"
    }

    /// Full repaint. Positioned rows, so an 80-column page never relies on the terminal
    /// deciding to wrap at the same place we do.
    func render(to out: Out) {
        var s = "\u{1B}[0m"
        var lastFg: UInt8 = 255
        var lastBg: UInt8 = 255
        for y in 0..<height {
            s += "\u{1B}[\(y + 1);1H"
            for x in 0..<width {
                let c = cells[y * width + x]
                if c.fg != lastFg || c.bg != lastBg {
                    s += Screen.sgr(fg: c.fg, bg: c.bg)
                    lastFg = c.fg
                    lastBg = c.bg
                }
                s.append(c.ch)
            }
        }
        s += "\u{1B}[0m"
        out.control(s)
    }

    /// Only the rows that changed. The 1998 frame rate came from not redrawing the world.
    func renderDiff(to out: Out, previous: Screen) {
        guard previous.width == width, previous.height == height else { return render(to: out) }
        var s = "\u{1B}[0m"
        for y in 0..<height {
            var changed = false
            for x in 0..<width where cells[y * width + x] != previous.cells[y * width + x] {
                changed = true
                break
            }
            guard changed else { continue }
            s += "\u{1B}[\(y + 1);1H"
            var lastFg: UInt8 = 255
            var lastBg: UInt8 = 255
            for x in 0..<width {
                let c = cells[y * width + x]
                if c.fg != lastFg || c.bg != lastBg {
                    s += Screen.sgr(fg: c.fg, bg: c.bg)
                    lastFg = c.fg
                    lastBg = c.bg
                }
                s.append(c.ch)
            }
        }
        s += "\u{1B}[0m"
        out.control(s)
    }

    /// Take over the terminal: the alternate page, no cursor, a known black page.
    static func begin(_ out: Out) {
        out.control("\u{1B}[?1049h\u{1B}[?25l\u{1B}[0m\u{1B}[2J\u{1B}[H")
    }

    static func end(_ out: Out) {
        out.control("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
    }
}
