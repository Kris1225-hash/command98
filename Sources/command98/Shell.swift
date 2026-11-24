import Foundation
import Darwin

struct Word {
    var text: String
    var quoted: Bool
}

enum Tok {
    static let seps: Set<Character> = [" ", "\t", ",", ";"]

    static func words(_ s: String, keepQuotes: Bool = false, seps: Set<Character> = Tok.seps) -> [Word] {
        var res: [Word] = []
        var cur = ""
        var inQ = false, quoted = false, has = false
        for ch in s {
            if ch == "\"" {
                inQ.toggle(); quoted = true; has = true
                if keepQuotes { cur.append(ch) }
                continue
            }
            if !inQ && seps.contains(ch) {
                if has { res.append(Word(text: cur, quoted: quoted)) }
                cur = ""; quoted = false; has = false
                continue
            }
            cur.append(ch); has = true
        }
        if has { res.append(Word(text: cur, quoted: quoted)) }
        return res
    }

    /// Words, with glued switches split apart the way COMMAND.COM does it: `c:\foo/w/p`.
    static func args(_ s: String) -> [String] {
        words(s).flatMap { w -> [String] in
            if w.quoted || !w.text.contains("/") { return [w.text] }
            var out: [String] = []
            var cur = ""
            for ch in w.text {
                if ch == "/" {
                    if !cur.isEmpty { out.append(cur) }
                    cur = "/"
                } else {
                    cur.append(ch)
                }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
    }

    static func posix(_ s: String) -> [String] { words(s, seps: [" ", "\t"]).map(\.text) }

    static func splitUnquoted(_ s: String, _ sep: Character) -> [String] {
        var res: [String] = []
        var cur = ""
        var q = false
        for ch in s {
            if ch == "\"" { q.toggle() }
            if ch == sep && !q {
                res.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        res.append(cur)
        return res
    }

    /// first whitespace-delimited word (quotes kept) and whatever follows it
    static func firstWord(_ s: Substring) -> (String, Substring) {
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
        var j = i
        var q = false
        while j < s.endIndex {
            let c = s[j]
            if c == "\"" {
                q.toggle()
            } else if !q && (c == " " || c == "\t") {
                break
            }
            j = s.index(after: j)
        }
        return (String(s[i..<j]), s[j...])
    }
}

enum Fmt {
    static func num(_ n: Int64, commas: Bool = true) -> String {
        guard commas else { return String(n) }
        var out = ""
        for (i, ch) in String(n).reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }
    static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    static func lpad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }
    static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    static func parts(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: d)
    }
    static func date(_ d: Date, year4: Bool = false) -> String {
        let c = parts(d)
        let y = year4 ? "\(c.year!)" : two(c.year! % 100)
        return "\(two(c.month!))-\(two(c.day!))-\(y)"
    }
    static func time12(_ d: Date) -> String {
        let c = parts(d)
        let h = c.hour! % 12 == 0 ? 12 : c.hour! % 12
        return lpad("\(h)", 2) + ":" + two(c.minute!) + (c.hour! < 12 ? "a" : "p")
    }
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static func longDate(_ d: Date) -> String {
        let c = parts(d)
        return "\(days[c.weekday! - 1]) \(two(c.month!))-\(two(c.day!))-\(c.year!)"
    }
    static func time24(_ d: Date) -> String {
        let c = parts(d)
        return lpad("\(c.hour!)", 2) + ":" + two(c.minute!) + ":" + two(c.second!) + "." + two(c.nanosecond! / 10_000_000)
    }
    static func timeDOS(_ d: Date) -> String {
        let c = parts(d)
        let h = c.hour! % 12 == 0 ? 12 : c.hour! % 12
        return lpad("\(h)", 2) + ":" + two(c.minute!) + ":" + two(c.second!) + "." + two(c.nanosecond! / 10_000_000)
            + (c.hour! < 12 ? "a" : "p")
    }
}

struct IO {
    let inFD: Int32
    let out: Out
}

struct Ctx {
    let name: String
    let rest: String
    let args: [String]
    let io: IO
    var out: Out { io.out }
    var params: [String] { args.filter { !$0.hasPrefix("/") } }
    func has(_ sw: String) -> Bool { args.contains { $0.uppercased() == sw } }
    /// the raw tail with the single leading delimiter removed
    var tail: String {
        var r = Substring(rest)
        while let f = r.first, f == " " || f == "\t" { r = r.dropFirst() }
        return String(r)
    }
}

final class BatchContext {
    let dosName: String
    let lines: [String]
    let io: IO
    var pc = 0
    var params: [String]
    var shift = 0

    init(dosName: String, lines: [String], params: [String], io: IO) {
        self.dosName = dosName
        self.lines = lines
        self.params = params
        self.io = io
    }
    func param(_ n: Int) -> String {
        let i = n + shift
        return i < params.count ? params[i] : ""
    }
}

enum Program {
    case batch(URL, String)
    case host(String)
    case dosBinary
    /// one of our stub files in \\WINDOWS\\COMMAND: the name of the utility to run in-process
    case utility(String)
}

final class Shell {
    static let version = "4.10.2222"

    let drives: Drives
    var env: [(String, String)] = []
    var hostPath: String
    var echoOn = true
    var errorLevel: Int32 = 0
    var lfnFor = false, breakOn = false, verifyOn = false
    var codePage = 437
    var locked = Set<Character>()
    var lastLine = ""
    var batch: [BatchContext] = []
    var permanent = false, stepMode = false, exitRequested = false
    var inFor = false
    var pipeCounter = 0
    var nlsLoaded = false
    /// what CONFIG.SYS asked for, even when there is nothing to do about it
    var config = ConfigValues()
    /// SUBSTed drives, letter -> what it points at (for SUBST with no arguments)
    var substs: [Character: String] = [:]

    init(drives: Drives) {
        self.drives = drives
        let pe = ProcessInfo.processInfo.environment
        hostPath = pe["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in pe.sorted(by: { $0.key < $1.key }) where k != "PATH" && !k.hasPrefix("_") {
            env.append((k, v))
        }
        envSet("COMSPEC", "C:\\COMMAND.COM")
        envSet("PROMPT", "$p$g")
        let dosPath = hostPath.split(separator: ":").compactMap { p -> String? in
            guard let (l, c) = drives.hostToDos(String(p)), FileManager.default.fileExists(atPath: String(p)) else { return nil }
            return drives.dosPath(l, c)
        }
        envSet("PATH", dosPath.joined(separator: ";"))
    }

    // MARK: environment

    func envGet(_ k: String) -> String? {
        let K = k.uppercased()
        return env.first { $0.0.uppercased() == K }?.1
    }

    func envSet(_ k: String, _ v: String?) {
        let K = k.uppercased()
        let value = (v?.isEmpty ?? true) ? nil : v
        if let i = env.firstIndex(where: { $0.0.uppercased() == K }) {
            if let value { env[i].1 = value } else { env.remove(at: i) }
        } else if let value {
            env.append((K, value))
        }
    }

    // MARK: prompt

    func currentPath() -> String { drives.dosPath(drives.current, drives.cwd) }

    func renderPrompt() -> String {
        let p = Array(envGet("PROMPT") ?? "$p$g")
        var out = ""
        var i = 0
        while i < p.count {
            if p[i] == "$", i + 1 < p.count {
                switch Character(p[i + 1].lowercased()) {
                case "p": out += currentPath()
                case "g": out += ">"
                case "l": out += "<"
                case "b": out += "|"
                case "q": out += "="
                case "$": out += "$"
                case "n": out += String(drives.current)
                case "t": out += Fmt.time24(Date())
                case "d": out += Fmt.longDate(Date())
                case "v": out += "Command98 for macOS [Version \(Shell.version)]"
                case "_": out += "\n"
                case "e": out += "\u{1B}"
                case "h": out += "\u{8}"
                default: break
                }
                i += 2
            } else {
                out.append(p[i])
                i += 1
            }
        }
        return out
    }

    // MARK: main loop

    func interactive() {
        var needBlank = false
        let tty = Console.isTTY
        while !exitRequested {
            gInterrupted = 0
            // faithful: with ECHO OFF at the prompt, there is no prompt
            var prompt = ""
            if echoOn && tty {
                if needBlank { Console.tty.write("\n") }
                prompt = renderPrompt()
                Console.tty.write(prompt)
            }
            switch Console.readLine(template: lastLine, prompt: prompt) {
            case .eof:
                return
            case .interrupt:
                needBlank = false
            case .line(let l):
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    needBlank = false
                    continue
                }
                lastLine = l
                Doskey.remember(l)
                // redirected input: ^Z is end of file, same as in a batch file
                var line = l
                var hitEOF = false
                if !tty, let z = line.firstIndex(of: "\u{1A}") {
                    line = String(line[..<z])
                    hitEOF = true
                }
                if let cmds = Doskey.expand(line) {
                    for cmd in cmds where !exitRequested { runLine(expandTyped(cmd)) }
                } else {
                    runLine(expandTyped(line))
                }
                if hitEOF { return }
                needBlank = true
            }
        }
    }

    // MARK: line execution

    func runLine(_ raw: String, io given: IO? = nil) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("@") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if line.isEmpty || line.hasPrefix(":") { return }
        let base = given ?? IO(inFD: 0, out: Out(1))

        // IF and FOR own their whole tail: `if exist x echo a | more` belongs to the IF
        let segs = Tok.splitUnquoted(line, "|")
        if segs.count == 1 {
            runRedirected(segs[0], base)
            return
        }
        // pipes the DOS way: through temp files, one stage at a time
        var inFD = base.inFD
        var prevTmp: String? = nil
        for (i, seg) in segs.enumerated() {
            let last = i == segs.count - 1
            var outFD = base.out.fd
            var tmp: String? = nil
            if !last {
                pipeCounter += 1
                tmp = NSTemporaryDirectory() + "command98-\(getpid())-\(pipeCounter).$$$"
                outFD = open(tmp!, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            }
            runRedirected(seg, IO(inFD: inFD, out: Out(outFD)))
            if !last { close(outFD) }
            if inFD != base.inFD { close(inFD) }
            if let p = prevTmp { unlink(p) }
            prevTmp = nil
            inFD = base.inFD
            if let t = tmp {
                inFD = open(t, O_RDONLY)
                prevTmp = t
            }
            if gInterrupted != 0 { break }
        }
        if inFD != base.inFD { close(inFD) }
        if let p = prevTmp { unlink(p) }
    }

    func parseRedirection(_ s: String) -> (command: String, input: String?, output: String?, append: Bool) {
        var cmd = ""
        var input: String? = nil, output: String? = nil
        var append = false
        let ch = Array(s)
        var i = 0
        var q = false
        while i < ch.count {
            let c = ch[i]
            if c == "\"" {
                q.toggle(); cmd.append(c); i += 1
                continue
            }
            if !q && (c == ">" || c == "<") {
                var app = false
                if c == ">" && i + 1 < ch.count && ch[i + 1] == ">" {
                    app = true
                    i += 1
                }
                i += 1
                while i < ch.count && (ch[i] == " " || ch[i] == "\t") { i += 1 }
                var name = ""
                var nq = false
                while i < ch.count {
                    let d = ch[i]
                    if d == "\"" { nq.toggle(); i += 1; continue }
                    if !nq && (d == " " || d == "\t" || d == ">" || d == "<") { break }
                    name.append(d)
                    i += 1
                }
                if c == ">" {
                    output = name
                    append = app
                } else {
                    input = name
                }
                continue
            }
            cmd.append(c)
            i += 1
        }
        return (cmd, input, output, append)
    }

    static func deviceName(_ s: String) -> String? {
        let up = s.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let base = up.split(separator: ".").first.map(String.init) ?? up
        return ["CON", "NUL", "PRN", "AUX", "LPT1", "LPT2", "LPT3", "COM1", "COM2", "COM3", "COM4"].contains(base) ? base : nil
    }

    func openDos(_ name: String, write: Bool, append: Bool) -> Int32? {
        if let dev = Shell.deviceName(name) {
            if dev == "CON" { return dup(write ? 1 : 0) }
            let fd = open("/dev/null", write ? O_WRONLY : O_RDONLY)
            return fd >= 0 ? fd : nil
        }
        guard let r = try? drives.resolve(name) else { return nil }
        let path = drives.url(r).path
        let fd = write
            ? open(path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o644)
            : open(path, O_RDONLY)
        return fd >= 0 ? fd : nil
    }

    func runRedirected(_ seg: String, _ io: IO) {
        let r = parseRedirection(seg)
        var inFD = io.inFD, outFD = io.out.fd
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        if let f = r.input {
            guard let fd = openDos(f, write: false, append: false) else {
                io.out.line("File not found")
                return
            }
            inFD = fd
            opened.append(fd)
        }
        if let f = r.output {
            guard let fd = openDos(f, write: true, append: r.append) else {
                io.out.line("File creation error")
                return
            }
            outFD = fd
            opened.append(fd)
        }
        runSimple(r.command, IO(inFD: inFD, out: Out(outFD)))
    }

    static let cmdDelims: Set<Character> = [" ", "\t", "/", "=", ";", ",", "+"]

    /// Split "name rest", recognising the glued forms COMMAND.COM accepts: `cd..`, `echo.`, `cd\dos`.
    func splitCommand(_ t: String) -> (String, String, String?) {
        if t.hasPrefix("\"") {
            let after = t.dropFirst()
            if let end = after.firstIndex(of: "\"") {
                return (String(after[..<end]), String(after[after.index(after: end)...]), nil)
            }
        }
        var end = t.startIndex
        while end < t.endIndex, !Shell.cmdDelims.contains(t[end]) { end = t.index(after: end) }
        let tok = String(t[..<end])
        let rest = String(t[end...])
        let up = tok.uppercased()
        if Shell.table[up] != nil { return (tok, rest, up) }
        for b in Shell.namesByLength where up.hasPrefix(b) && up.count > b.count {
            let i = up.index(up.startIndex, offsetBy: b.count)
            if ".\\:[]".contains(up[i]) {
                let ti = tok.index(tok.startIndex, offsetBy: b.count)
                return (String(tok[..<ti]), String(tok[ti...]) + rest, b)
            }
        }
        return (tok, rest, nil)
    }

    func runSimple(_ text: String, _ io: IO) {
        var t = text.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("@") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if t.isEmpty || t.hasPrefix(":") { return }

        let chars = Array(t)
        if chars.count == 2, chars[1] == ":", chars[0].isLetter, chars[0].isASCII {
            let l = Character(chars[0].uppercased())
            if drives.table[l] != nil {
                drives.current = l
            } else {
                io.out.line("Invalid drive specification")
            }
            return
        }

        let (name, rest, builtin) = splitCommand(t)
        if let b = builtin, let fn = Shell.table[b] {
            let args = Tok.args(rest)
            if args.first == "/?" {
                io.out.write(Shell.helpText(b))
                return
            }
            fn(self)(Ctx(name: b, rest: rest, args: args, io: io))
        } else {
            runExternal(name, rest, io)
        }
    }

    // MARK: external programs

    func findProgram(_ name: String) -> Program? {
        var dirs: [URL] = []
        var base = name
        let hasPath = name.contains("\\") || name.contains(":") || name.contains("/")
        if hasPath {
            guard let r = try? drives.resolve(name), r.parentExists else { return nil }
            dirs = [drives.url(r.parent)]
            base = r.last
        } else {
            dirs = [drives.cwdURL]
            for p in (envGet("PATH") ?? "").split(separator: ";") {
                if let r = try? drives.resolve(String(p)), r.exists { dirs.append(drives.url(r)) }
            }
        }
        for d in dirs {
            if let p = probe(d, base) { return p }
        }
        // a deleted DOS utility stays deleted: no sneaking in the Unix tool of the same name
        // (MAC find ... is how you ask for that one)
        if !hasPath && Shell.utilities[name.uppercased()] == nil {
            for dir in hostPath.split(separator: ":") {
                for cand in Set([name, name.lowercased()]) {
                    let p = "\(dir)/\(cand)"
                    var st = stat()
                    if stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(p, X_OK) == 0 { return .host(p) }
                }
            }
        }
        return nil
    }

    /// .COM before .EXE before .BAT, then a bare executable. Same search order as the real one.
    func probe(_ dir: URL, _ base: String) -> Program? {
        let names = drives.entries(dir)
        let short = ShortName.map(names)
        func find(_ n: String) -> String? {
            names.first { $0.caseInsensitiveCompare(n) == .orderedSame }
                ?? short.first { $0.value == n.uppercased() }?.key
        }
        let hasExt = base.contains(".")
        let bareOK = Shell.utilities[base.uppercased()] == nil
        let candidates = hasExt ? [base] : [base + ".COM", base + ".EXE", base + ".BAT"] + (bareOK ? [base] : [])
        for c in candidates {
            guard let actual = find(c) else { continue }
            let u = dir.appendingPathComponent(actual)
            if isDir(u) { continue }
            let ext = (actual as NSString).pathExtension.uppercased()
            if ext == "BAT" || ext == "CMD" {
                let dn = drives.hostToDos(u.path).map { drives.dosPath($0.0, $0.1) } ?? actual.uppercased()
                return .batch(u, dn)
            }
            let head = (try? FileHandle(forReadingFrom: u).read(upToCount: 64)) ?? nil
            if let h = head, h.count >= 2, h[h.startIndex] == 0x4D, h[h.startIndex + 1] == 0x5A { return .dosBinary }
            if let h = head, let name = Shell.stubName(h) { return .utility(name) }
            if access(u.path, X_OK) == 0 { return .host(u.path) }
            if ext == "COM" || ext == "EXE" { return .dosBinary }
        }
        return nil
    }

    func translateArg(_ a: String) -> String {
        let c = Array(a)
        guard c.count >= 2, c[1] == ":", c[0].isLetter, drives.table[Character(c[0].uppercased())] != nil,
              let r = try? drives.resolve(a) else { return a }
        return drives.url(r).path
    }

    func runExternal(_ name: String, _ rest: String, _ io: IO) {
        switch findProgram(name) {
        case .batch(let u, let dn):
            let params = [name] + Tok.words(rest, keepQuotes: true).map(\.text)
            startBatch(u, dn, params: params, call: false, io: io)
        case .host(let path):
            spawn(path, Tok.posix(rest).map(translateArg), io)
        case .dosBinary:
            io.out.line("This program cannot be run in macOS mode.")
        case .utility(let u):
            runUtility(u, rest, io)
        case nil:
            io.out.line("Bad command or file name")
        }
    }

    func childEnv() -> [String] {
        var e = env.filter { $0.0.uppercased() != "PATH" }.map { "\($0.0)=\($0.1)" }
        e.append("PATH=\(hostPath)")
        e.append("PWD=\(drives.cwdURL.path)")
        return e
    }

    func spawn(_ path: String, _ args: [String], _ io: IO) {
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if io.inFD != 0 { posix_spawn_file_actions_adddup2(&fa, io.inFD, 0) }
        if io.out.fd != 1 { posix_spawn_file_actions_adddup2(&fa, io.out.fd, 1) }
        posix_spawn_file_actions_addchdir_np(&fa, drives.cwdURL.path)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = childEnv().map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, nil, argv, envp)
        guard rc == 0 else {
            io.out.line("Bad command or file name")
            return
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        errorLevel = sig == 0 ? (status >> 8) & 0xff : 128 + sig
        if batch.isEmpty { gInterrupted = 0 }
    }

    // MARK: batch files

    func startBatch(_ url: URL, _ dosName: String, params: [String], call: Bool, io: IO) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            io.out.line("Batch file missing")
            return
        }
        var text = String(decoding: data, as: UTF8.self)
        if let z = text.firstIndex(of: "\u{1A}") { text = String(text[..<z]) } // ^Z is end of file
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let ctx = BatchContext(dosName: dosName, lines: lines, params: params, io: io)

        // running a batch file from a batch file without CALL replaces it (no return)
        if !call && !batch.isEmpty {
            batch[batch.count - 1] = ctx
            return
        }
        let depth = batch.count
        batch.append(ctx)
        while batch.count > depth && !exitRequested { stepBatch() }
        if batch.isEmpty { echoOn = true }
    }

    func stepBatch() {
        let ctx = batch[batch.count - 1]
        if gInterrupted != 0 {
            gInterrupted = 0
            Console.tty.write("^C\n")
            if Console.ask("Terminate batch job (Y/N)?", "YN") != "N" {
                batch.removeAll()
                return
            }
        }
        guard ctx.pc < ctx.lines.count else {
            batch.removeLast()
            return
        }
        let raw = ctx.lines[ctx.pc]
        ctx.pc += 1
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix(":") { return }
        let line = expand(raw, ctx).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        let silent = line.hasPrefix("@")
        if echoOn && !silent {
            Console.tty.write("\n" + renderPrompt() + line + "\n")
        }
        if stepMode {
            let shown = silent ? String(line.dropFirst()) : line
            guard Console.ask("\(shown) [Enter=Y,Esc=N]?", "YN\r\u{1B}").map({ $0 == "Y" || $0 == "\r" }) == true else { return }
        }
        runLine(line, io: ctx.io)
    }

    // Prompt vs batch: a `%` with no partner stays literal at the prompt, while batch eats it.
    /// Typed at the prompt, DOS 7 still substitutes `%VAR%` (an undefined name becomes empty)
    /// and turns `%%` into `%`; only an unpaired `%` stays literal. That keeps `echo 100%`
    /// and `%1` intact, and the FOR pre-scan lets `for %f in (*) do echo %f` survive.
    func expandTyped(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let forVar = typedForVar(s)
        var out = ""
        let c = Array(s)
        var i = 0
        while i < c.count {
            guard c[i] == "%" else {
                out.append(c[i])
                i += 1
                continue
            }
            if i + 1 < c.count, c[i + 1] == "%" {
                out.append("%")
                i += 2
                continue
            }
            if i + 1 < c.count, c[i + 1] >= "0", c[i + 1] <= "9" {
                out.append("%")
                out.append(c[i + 1])
                i += 2
                continue
            }
            if let j = c[(i + 1)...].firstIndex(of: "%") {
                if let v = envGet(String(c[(i + 1)..<j])) {
                    out += v
                } else if let fv = forVar, i + 1 < c.count, c[i + 1] == fv {
                    out.append("%")
                    out.append(fv)
                    i += 2
                    continue
                }
                i = j + 1
                continue
            }
            out.append("%")
            i += 1
        }
        return out
    }

    /// The character of a prompt-time `FOR %x ...`; COMMAND.COM protects it from expansion.
    private func typedForVar(_ s: String) -> Character? {
        let c = Array(s.drop(while: { $0 == " " || $0 == "\t" }))
        guard c.count > 4, String(c[0..<3]).uppercased() == "FOR", c[3] == " " || c[3] == "\t" else { return nil }
        var i = 4
        while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
        guard i + 1 < c.count, c[i] == "%", c[i + 1] != "%", c[i + 1] != " ", c[i + 1] != "\t" else { return nil }
        return c[i + 1]
    }

    /// %0-%9, %VAR%, %% -> %. A lone % just vanishes, exactly like the real thing.
    func expand(_ s: String, _ ctx: BatchContext) -> String {
        var out = ""
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "%" {
                if i + 1 < c.count {
                    let n = c[i + 1]
                    if n == "%" {
                        out.append("%")
                        i += 2
                        continue
                    }
                    if n.isASCII, let d = n.wholeNumberValue {
                        out += ctx.param(d)
                        i += 2
                        continue
                    }
                    if let j = c[(i + 1)...].firstIndex(of: "%") {
                        out += envGet(String(c[(i + 1)..<j])) ?? ""
                        i = j + 1
                        continue
                    }
                }
                i += 1
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }
}
