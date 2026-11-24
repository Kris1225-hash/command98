import Foundation


/// Set by the SIGINT handler. Checked by long-running loops (DIR, COPY, FOR, batch).
var gInterrupted: Int32 = 0

func installSignalHandlers() {
    Platform.installSIGINT { _ in gInterrupted = 1 }
}

/// Raw fd writer. Built-ins write through one of these so redirection is just "a different fd".
final class Out {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }

    func raw(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            var off = 0
            while off < buf.count {
                let n = Platform.sysWrite(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                off += n
            }
        }
    }

    func write(_ s: String) {
        let encoded = AnsiSys.encode(s, fd: fd)
        raw(Array(encoded.utf8))
    }

    /// Shell-owned escape sequences (clear screen, full-screen tools). ANSI.SYS is not
    /// involved: these are the console driver's own control codes.
    func control(_ s: String) { raw(Array(s.utf8)) }
    func line(_ s: String = "") { write(s + "\n") }
}

enum LineResult {
    case line(String)
    case eof
    case interrupt
}

enum Console {
    static let tty = Out(1)
    static var isTTY: Bool { isatty(0) == 1 }

    static func rows() -> Int {
        Platform.termSize()?.rows ?? 25
    }

    static func withRaw<T>(_ body: () -> T) -> T {
        guard isatty(0) == 1 else { return body() }
        var t = termios()
        tcgetattr(0, &t)
        var saved = t
        t.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        withUnsafeMutableBytes(of: &t.c_cc) { p in
            p[Int(VMIN)] = 1
            p[Int(VTIME)] = 0
        }
        tcsetattr(0, TCSANOW, &t)
        defer { tcsetattr(0, TCSANOW, &saved) }
        return body()
    }

    /// -1 = EOF, -2 = interrupted by ^C
    static func readByte(_ fd: Int32 = 0) -> Int {
        var b: UInt8 = 0
        while true {
            let n = read(fd, &b, 1)
            if n == 1 { return Int(b) }
            if n < 0 && errno == EINTR {
                if gInterrupted != 0 { return -2 }
                continue
            }
            return -1
        }
    }

    static func pending(_ ms: Int32) -> Bool {
        var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, ms) > 0
    }

    /// One keypress (PAUSE, "Press any key"). Redirected input just consumes one byte, like DOS.
    static func readKey(fd: Int32 = 0) -> Int {
        if fd != 0 { return readByte(fd) }
        if !isTTY {
            guard let l = Swift.readLine() else { return -1 }
            return Int(l.utf8.first ?? 13)
        }
        return withRaw {
            let b = readByte()
            if b == 27 { while pending(20) { _ = readByte() } }
            return b
        }
    }

    /// "Are you sure (Y/N)?" style prompt. Returns nil on ^C / EOF.
    static func ask(_ prompt: String, _ options: String) -> Character? {
        tty.write(prompt)
        while true {
            let k = readKey()
            if k == -2 { gInterrupted = 0; tty.write("^C\n"); return nil }
            if k < 0 { tty.write("\n"); return nil }
            guard k < 128 else { continue }
            let ch = Character(String(Character(UnicodeScalar(UInt8(k)))).uppercased())
            if options.contains(ch) {
                tty.write("\(ch)\n")
                return ch
            }
        }
    }

    /// A line from an arbitrary fd (used when stdin is redirected).
    static func readLine(fd: Int32) -> LineResult {
        var bytes: [UInt8] = []
        while true {
            let b = readByte(fd)
            if b == -2 { gInterrupted = 0; return .interrupt }
            if b == -1 { return bytes.isEmpty ? .eof : .line(String(decoding: bytes, as: UTF8.self)) }
            if b == 10 { break }
            if b != 13 { bytes.append(UInt8(b)) }
        }
        return .line(String(decoding: bytes, as: UTF8.self))
    }

    /// The DOS-flavoured line editor. Without DOSKEY: no history, the classic template keys
    /// (F1 / right arrow copies one char of the previous line, F3 the rest, Esc cancels with a
    /// backslash, left arrow is just backspace). With DOSKEY loaded: history on up/down,
    /// PgUp/PgDn, F7 list, F8 prefix search, cursor movement, Home/End, Del, and Insert toggles
    /// overstrike, which is what DOSKEY started in.
    static func readLine(template: String, prompt: String = "") -> LineResult {
        guard isTTY else {
            guard let l = Swift.readLine(strippingNewline: true) else { return .eof }
            return .line(l.hasSuffix("\r") ? String(l.dropLast()) : l)
        }
        let tmpl = Array(template)
        let dk = Doskey.installed
        return withRaw {
            var buf: [Character] = []
            var cur = 0
            var overstrike = !Doskey.insertMode
            var hpos = Doskey.history.count
            var searchFrom = Doskey.history.count

            func disp(_ c: Character) -> String { c == "\u{1A}" ? "^Z" : String(c) }
            func width(_ c: Character) -> Int { c == "\u{1A}" ? 2 : 1 }
            func back(_ n: Int) { if n > 0 { tty.write(String(repeating: "\u{8}", count: n)) } }
            func tailWidth(_ from: Int) -> Int { buf[from...].reduce(0) { $0 + width($1) } }

            func insert(_ c: Character) {
                if overstrike && cur < buf.count {
                    let old = width(buf[cur])
                    buf[cur] = c
                    tty.write(disp(c))
                    cur += 1
                    if old != width(c) {
                        let rest = buf[cur...].map(disp).joined()
                        tty.write(rest + "  ")
                        back(tailWidth(cur) + 2)
                    }
                } else {
                    buf.insert(c, at: cur)
                    tty.write(buf[cur...].map(disp).joined())
                    cur += 1
                    back(tailWidth(cur))
                }
            }
            func deleteAt(_ i: Int) {
                guard i >= 0 && i < buf.count else { return }
                let w = width(buf[i])
                buf.remove(at: i)
                tty.write(buf[i...].map(disp).joined() + String(repeating: " ", count: w))
                back(tailWidth(i) + w)
            }
            func backspace() {
                guard cur > 0 else { return }
                if !dk {
                    let last = buf.removeLast()
                    cur -= 1
                    tty.write(last == "\u{1A}" ? "\u{8}\u{8}  \u{8}\u{8}" : "\u{8} \u{8}")
                    return
                }
                cur -= 1
                back(width(buf[cur]))
                deleteAt(cur)
            }
            func home() { back(buf[..<cur].reduce(0) { $0 + width($1) }); cur = 0 }
            func end() { tty.write(buf[cur...].map(disp).joined()); cur = buf.count }
            func replace(_ s: String) {
                home()
                let oldW = tailWidth(0)
                buf = Array(s)
                let newW = tailWidth(0)
                tty.write(buf.map(disp).joined())
                if oldW > newW {
                    tty.write(String(repeating: " ", count: oldW - newW))
                    back(oldW - newW)
                }
                cur = buf.count
            }
            // F1 / F3: the template is the previous line, column for column
            func copyTemplate(all: Bool) {
                repeat {
                    guard cur < tmpl.count else { return }
                    if cur < buf.count {
                        buf[cur] = tmpl[cur]
                        tty.write(disp(tmpl[cur]))
                        cur += 1
                    } else {
                        buf.append(tmpl[cur])
                        tty.write(disp(tmpl[cur]))
                        cur += 1
                    }
                } while all
            }

            while true {
                let b = readByte()
                switch b {
                case -2:
                    gInterrupted = 0
                    tty.write("^C\n")
                    return .interrupt
                case -1:
                    if buf.isEmpty { return .eof }
                    tty.write("\n")
                    return .line(String(buf))
                case 13, 10:
                    end()
                    tty.write("\n")
                    return .line(String(buf))
                case 127, 8:
                    backspace()
                case 4:
                    if buf.isEmpty { tty.write("\n"); return .eof }
                    if dk { deleteAt(cur) }
                case 26:
                    insert("\u{1A}")
                case 27:
                    if !pending(30) {
                        if dk {
                            replace("")
                        } else {
                            tty.write("\\\n")
                            buf.removeAll()
                            cur = 0
                        }
                        continue
                    }
                    let k = readByte()
                    var seq: [UInt8] = k >= 0 ? [UInt8(k)] : []
                    if k == 91 || k == 79 { // '[' or 'O'
                        while true {
                            let c = readByte()
                            if c < 0 { break }
                            seq.append(UInt8(c))
                            if c >= 0x40 && c <= 0x7E { break }
                        }
                    }
                    let key = String(decoding: seq, as: UTF8.self)
                    switch key {
                    case "OP", "[11~":
                        copyTemplate(all: false)
                    case "[C":
                        if dk && cur < buf.count {
                            tty.write(disp(buf[cur]))
                            cur += 1
                        } else {
                            copyTemplate(all: false)
                        }
                    case "OR", "[13~":
                        copyTemplate(all: true)
                    case "[D":
                        if dk {
                            if cur > 0 { cur -= 1; back(width(buf[cur])) }
                        } else {
                            backspace()
                        }
                    case "[A" where dk:
                        if hpos > 0 { hpos -= 1; replace(Doskey.history[hpos]) }
                    case "[B" where dk:
                        if hpos < Doskey.history.count - 1 { hpos += 1; replace(Doskey.history[hpos]) }
                    case "[5~" where dk:
                        if !Doskey.history.isEmpty { hpos = 0; replace(Doskey.history[0]) }
                    case "[6~" where dk:
                        if !Doskey.history.isEmpty { hpos = Doskey.history.count - 1; replace(Doskey.history[hpos]) }
                    case "[H" where dk, "OH" where dk, "[1~" where dk:
                        home()
                    case "[F" where dk, "OF" where dk, "[4~" where dk:
                        end()
                    case "[3~" where dk:
                        deleteAt(cur)
                    case "[2~" where dk:
                        overstrike.toggle()
                    case "[18~" where dk: // F7: the whole history, numbered
                        tty.write("\n")
                        for (i, h) in Doskey.history.enumerated() { tty.write("\(i + 1): \(h)\n") }
                        tty.write("\n" + prompt + buf.map(disp).joined())
                        back(tailWidth(cur))
                    case "[19~" where dk: // F8: previous entry starting with what's left of the cursor
                        let prefix = String(buf[..<cur]).lowercased()
                        var i = searchFrom - 1
                        while i >= 0 && !Doskey.history[i].lowercased().hasPrefix(prefix) { i -= 1 }
                        if i >= 0 {
                            searchFrom = i
                            let keep = cur
                            replace(Doskey.history[i])
                            back(tailWidth(keep))
                            cur = keep
                        } else {
                            tty.write("\u{7}")
                        }
                    default:
                        break
                    }
                default:
                    if b < 32 { continue }
                    if b < 0x80 {
                        insert(Character(UnicodeScalar(UInt8(b))))
                    } else {
                        var bytes = [UInt8(b)]
                        let extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1
                        for _ in 0..<extra {
                            let c = readByte()
                            if c >= 0 { bytes.append(UInt8(c)) }
                        }
                        if let s = String(bytes: bytes, encoding: .utf8), let ch = s.first { insert(ch) }
                    }
                }
            }
        }
    }
}

/// DOSKEY's state. Not loaded until someone runs DOSKEY, just like 1998.
enum Doskey {
    static var installed = false
    static var insertMode = false
    static var history: [String] = []
    static var macros: [(String, String)] = []

    static func remember(_ l: String) {
        guard installed, !l.isEmpty, history.last != l else { return }
        history.append(l)
        if history.count > 500 { history.removeFirst() }
    }

    /// $1-$9, $* and $T (command separator) in a macro, like DOSKEY did it
    static func expand(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let name = String(t.prefix { $0 != " " && $0 != "\t" })
        guard !name.isEmpty, let m = macros.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let rest = String(t.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        let args = Tok.words(rest, keepQuotes: true, seps: [" ", "\t"]).map(\.text)
        var out = ""
        let c = Array(m.1)
        var i = 0
        while i < c.count {
            if c[i] == "$", i + 1 < c.count {
                let n = Character(c[i + 1].lowercased())
                i += 2
                switch n {
                case "*": out += rest
                case "t": out += "\u{0}"
                case "g": out += ">"
                case "l": out += "<"
                case "b": out += "|"
                case "$": out += "$"
                default:
                    if let d = n.wholeNumberValue, d >= 1 {
                        out += d <= args.count ? args[d - 1] : ""
                    } else {
                        out += "$" + String(n)
                    }
                }
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
    }
}
